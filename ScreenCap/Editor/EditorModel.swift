import AppKit
@preconcurrency import AVFoundation
import CoreImage
import Observation
import ScreenCapCore

enum Selection: Equatable {
    case none
    /// A clip on the timeline, as its source range.
    case clip(TimeRange)
    case zoom(UUID)
    case cameraHide(UUID)
}

enum DragMode { case move, start, end }

enum ExportState: Equatable {
    case idle
    case exporting(Double)
    case done(URL)
    case failed(String)
}

/// One open recording: its edit decisions, undo history, player and export.
/// Every change goes through `live`/`commit`, which keeps the preview, undo stack and
/// `edits.json` in step. Raw media is only ever read.
@MainActor @Observable
final class EditorModel {
    let bundle: ReelBundle
    let player = AVPlayer()

    private(set) var isLoaded = false
    private(set) var loadError: String?
    private(set) var info: ProjectInfo?
    private(set) var edits = EditDecisions()
    private(set) var timeline = Timeline(duration: 0, edits: EditDecisions())
    private(set) var sourceDuration = 0.0
    /// Output time of the frame on screen.
    private(set) var playhead = 0.0
    private(set) var isPlaying = false
    private(set) var selection = Selection.none
    private(set) var hasCamera = false
    private(set) var hasMic = false
    private(set) var hasSystemAudio = false
    /// Peak level per bucket of source time, `waveformRate` buckets per second.
    private(set) var waveform: [Float] = []
    let waveformRate = 50.0
    private(set) var canUndo = false
    private(set) var canRedo = false
    var exportState = ExportState.idle

    @ObservationIgnored private var events: [RecordedEvent] = []
    @ObservationIgnored private var rawCursor = CursorTrack(events: [])
    @ObservationIgnored private var smoothedCursor: (strength: Double, track: CursorTrack)?
    @ObservationIgnored private var zoomCache: (regions: [ZoomRegion], path: ZoomPath)?
    @ObservationIgnored private var built: BuiltComposition?
    @ObservationIgnored private var cursorImage: CIImage?
    @ObservationIgnored private var undoStack: [EditDecisions] = []
    @ObservationIgnored private var redoStack: [EditDecisions] = []
    @ObservationIgnored private var dragSnapshot: EditDecisions?
    @ObservationIgnored private var dragBase: TimeRange?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var exporter: Exporter?

    init(bundle: ReelBundle) {
        self.bundle = bundle
    }

    // MARK: - Loading

    func load() async {
        guard !isLoaded, loadError == nil else { return }
        do {
            let info = try bundle.loadInfo()
            self.info = info
            sourceDuration = try await AVURLAsset(url: bundle.screen).load(.duration).seconds
            events = bundle.loadEvents()
            rawCursor = CursorTrack(events: events)
            cursorImage = Self.arrowImage()
            hasCamera = bundle.has(bundle.camera)
            hasMic = bundle.has(bundle.mic)
            hasSystemAudio = bundle.has(bundle.systemAudio)

            if let saved = bundle.loadEdits() {
                edits = saved
            } else {
                // First open: seed the edit from how it was recorded and from the auto-zoom preference.
                edits.camera.shape = info.cameraShape
                edits.camera.mirrored = info.cameraMirrored
                edits.cursor.highlightClicks = Prefs.highlightClicks
                edits.zoomRegions = generatedZoom(Prefs.autoZoom, keeping: [])
                try? bundle.save(edits)
            }
            timeline = Timeline(duration: sourceDuration, edits: edits)
            try await rebuild()

            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.playerTicked(time.seconds) }
            }
            isLoaded = true
            loadWaveform()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        exporter?.cancel()
        try? bundle.save(edits)
    }

    private func loadWaveform() {
        guard let url = hasMic ? bundle.mic : (hasSystemAudio ? bundle.systemAudio : nil) else { return }
        let rate = waveformRate
        Task {
            let peaks = await Task.detached(priority: .utility) { await Waveform.peaks(url: url, bucketsPerSecond: rate) }.value
            waveform = peaks
        }
    }

    /// The system arrow, drawn large so it stays sharp when zoomed.
    private static func arrowImage() -> CIImage? {
        let image = NSCursor.arrow.image
        var rect = CGRect(x: 0, y: 0, width: image.size.width * 8, height: image.size.height * 8)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil).map { CIImage(cgImage: $0) }
    }

    // MARK: - Rendering (shared with export)

    private var canvasSource: CGSize {
        CGSize(width: info?.width ?? 1920, height: info?.height ?? 1080)
    }

    /// The preview renders at up to 1440p: plenty for an editor window and much lighter than 5K.
    var previewCanvas: CGSize {
        var settings = ExportSettings()
        settings.resolution = .p1440
        return settings.renderSize(source: canvasSource)
    }

    private func renderState(built: BuiltComposition, showsFullFrame: Bool) -> RenderState? {
        guard let info else { return nil }
        if zoomCache?.regions != edits.zoomRegions {
            zoomCache = (edits.zoomRegions, ZoomCamera.path(regions: edits.zoomRegions, cursor: rawCursor, duration: sourceDuration))
        }
        if smoothedCursor?.strength != edits.cursor.smoothing {
            smoothedCursor = (edits.cursor.smoothing, rawCursor.smoothed(strength: edits.cursor.smoothing))
        }
        return RenderState(
            timeline: timeline, edits: edits, info: info, zoomPath: zoomCache?.path ?? .identity,
            cursor: smoothedCursor?.track ?? rawCursor, cursorImage: cursorImage,
            cursorSize: NSCursor.arrow.image.size, cursorHotSpot: NSCursor.arrow.hotSpot,
            showsFullFrame: showsFullFrame, screenTrack: built.screenTrack, cameraTrack: built.cameraTrack)
    }

    /// While a zoom is selected and playback is stopped, the preview shows the whole frame
    /// with the zoom's framing rectangle over it.
    var showsFraming: Bool {
        if case .zoom = selection { return !isPlaying }
        return false
    }

    /// Cheap: swaps the drawing instructions on the current player item.
    private func refreshVideo() {
        guard let built, let item = player.currentItem, let info,
              let state = renderState(built: built, showsFullFrame: showsFraming) else { return }
        item.videoComposition = CompositionBuilder.videoComposition(for: built, state: state, canvas: previewCanvas, fps: info.fps)
        item.audioMix = CompositionBuilder.audioMix(for: built, volumes: edits.volumes)
    }

    /// Needed when trims or cuts change, because the tracks themselves are laid out differently.
    private func rebuild() async throws {
        let built = try await CompositionBuilder.build(bundle: bundle, timeline: timeline)
        self.built = built
        let item = AVPlayerItem(asset: built.asset)
        player.replaceCurrentItem(with: item)
        refreshVideo()
        seek(toOutput: playhead)
    }

    // MARK: - Playback

    private func playerTicked(_ time: Double) {
        let playing = player.timeControlStatus != .paused
        if playing { playhead = min(time, timeline.duration) }
        if playing != isPlaying {
            isPlaying = playing
            if case .zoom = selection { refreshVideo() }
        }
    }

    func togglePlay() {
        if player.timeControlStatus == .paused {
            if playhead >= timeline.duration - 0.05 { seek(toOutput: 0) }
            player.play()
        } else {
            player.pause()
        }
    }

    /// Frame-accurate: zero tolerance makes the player decode the exact frame.
    func seek(toOutput time: Double) {
        playhead = min(max(0, time), timeline.duration)
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        player.pause()
        seek(toOutput: playhead + Double(frames) / Double(info?.fps ?? 60))
    }

    var playheadSource: Double { timeline.sourceTime(forOutput: playhead) }

    // MARK: - Editing primitives

    /// Applies a change immediately without closing the undo step; call `commit` when the gesture ends.
    func live(_ change: (inout EditDecisions) -> Void) {
        if dragSnapshot == nil { dragSnapshot = edits }
        var updated = edits
        change(&updated)
        set(updated)
    }

    func commit() {
        dragBase = nil
        guard let snapshot = dragSnapshot else { return }
        dragSnapshot = nil
        guard snapshot != edits else { return }
        undoStack.append(snapshot)
        redoStack = []
        updateUndoState()
        try? bundle.save(edits)
    }

    func apply(_ change: (inout EditDecisions) -> Void) {
        live(change)
        commit()
    }

    private func set(_ updated: EditDecisions) {
        guard updated != edits else { return }
        let source = playheadSource
        edits = updated
        let newTimeline = Timeline(duration: sourceDuration, edits: updated)
        if newTimeline != timeline {
            timeline = newTimeline
            // Keep the playhead on the same moment of the recording after the ripple.
            playhead = newTimeline.outputTime(forSource: source)
            rebuildTask?.cancel()
            rebuildTask = Task {
                guard !Task.isCancelled else { return }
                try? await rebuild()
            }
        } else {
            refreshVideo()
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edits)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edits)
        restore(next)
    }

    private func restore(_ state: EditDecisions) {
        selection = .none
        set(state)
        updateUndoState()
        try? bundle.save(edits)
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func select(_ new: Selection) {
        guard new != selection else { return }
        let framed = showsFraming
        selection = new
        if framed != showsFraming || showsFraming { refreshVideo() }
    }

    // MARK: - Timeline edits

    func splitAtPlayhead() {
        let time = playheadSource
        apply { $0.split(at: time) }
    }

    func trimStartToPlayhead() {
        let time = playheadSource
        apply { $0.trimStart = time }
    }

    func trimEndToPlayhead() {
        let time = playheadSource
        apply { $0.trimEnd = time }
    }

    func restoreRemovedSections() {
        apply {
            $0.trimStart = 0
            $0.trimEnd = nil
            $0.cuts = []
            $0.splits = []
        }
    }

    var hasRemovedSections: Bool {
        edits.trimStart > 0 || edits.trimEnd != nil || !edits.cuts.isEmpty || !edits.splits.isEmpty
    }

    func deleteSelection() {
        switch selection {
        case .none:
            return
        case .clip(let range):
            // Never delete the last remaining clip: there would be nothing left to play.
            guard timeline.clips(splits: edits.splits).count > 1 else { return }
            apply { $0.delete(range) }
        case .zoom(let id):
            apply { $0.zoomRegions.removeAll { $0.id == id } }
        case .cameraHide(let id):
            apply { $0.cameraHidden.removeAll { $0.id == id } }
        }
        select(.none)
    }

    // MARK: - Zoom regions

    private func generatedZoom(_ sensitivity: Sensitivity, keeping kept: [ZoomRegion]) -> [ZoomRegion] {
        let markers = kept.isEmpty ? AutoZoom.markerRegions(events: events, duration: sourceDuration) : kept
        let auto = AutoZoom.regions(events: events, duration: sourceDuration, sensitivity: sensitivity)
        return AutoZoom.merged(auto: auto, keeping: markers)
    }

    /// Replaces the automatic regions; ones the user made or adjusted are kept.
    func regenerateAutoZoom(_ sensitivity: Sensitivity) {
        let kept = edits.zoomRegions.filter { $0.origin != .auto }
        let regions = kept.isEmpty && sensitivity == .off ? [] : AutoZoom.merged(
            auto: AutoZoom.regions(events: events, duration: sourceDuration, sensitivity: sensitivity), keeping: kept)
        select(.none)
        apply { $0.zoomRegions = regions }
    }

    func addZoomAtPlayhead() {
        let time = playheadSource
        if let existing = edits.zoomRegions.first(where: { time >= $0.start && time < $0.end }) {
            select(.zoom(existing.id))
            return
        }
        let nextStart = edits.zoomRegions.map(\.start).filter { $0 > time }.min() ?? sourceDuration
        let end = min(time + 3, nextStart, sourceDuration)
        guard end - time > 0.3 else { return }
        let focus = rawCursor.position(at: time) ?? CGPoint(x: 0.5, y: 0.5)
        let region = ZoomRegion(start: time, end: end, scale: 2, focus: focus, followsCursor: !rawCursor.isEmpty, origin: .manual)
        apply {
            $0.zoomRegions.append(region)
            $0.zoomRegions.sort { $0.start < $1.start }
        }
        select(.zoom(region.id))
    }

    var selectedZoom: ZoomRegion? {
        if case .zoom(let id) = selection { return edits.zoomRegions.first { $0.id == id } }
        return nil
    }

    func updateZoom(_ id: UUID, _ change: (inout ZoomRegion) -> Void) {
        live { edits in
            guard let index = edits.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
            change(&edits.zoomRegions[index])
            // Once the user touches a region it is theirs: regenerating auto-zoom leaves it alone.
            edits.zoomRegions[index].origin = .manual
        }
    }

    // MARK: - Camera hide spans

    func addCameraHideAtPlayhead() {
        let time = playheadSource
        let span = Span(start: time, end: min(time + 3, sourceDuration))
        guard span.end - span.start > 0.3 else { return }
        apply { $0.cameraHidden.append(span) }
        select(.cameraHide(span.id))
    }

    // MARK: - Dragging segments on the timeline

    /// `delta` is seconds since the drag began. Call `commit()` when it ends.
    func drag(_ target: Selection, mode: DragMode, delta: Double) {
        let minimum = 0.3
        switch target {
        case .zoom(let id):
            guard let region = edits.zoomRegions.first(where: { $0.id == id }) else { return }
            if dragBase == nil { dragBase = TimeRange(region.start, region.end) }
            // Zoom regions can't overlap, so each is confined between its neighbours.
            let others = edits.zoomRegions.filter { $0.id != id }
            let low = others.map(\.end).filter { $0 <= dragBase!.start + 0.001 }.max() ?? 0
            let high = others.map(\.start).filter { $0 >= dragBase!.end - 0.001 }.min() ?? sourceDuration
            let range = Self.moved(dragBase!, mode: mode, delta: delta, low: low, high: high, minimum: minimum)
            updateZoomTimes(id, range)
        case .cameraHide(let id):
            guard let span = edits.cameraHidden.first(where: { $0.id == id }) else { return }
            if dragBase == nil { dragBase = TimeRange(span.start, span.end) }
            let range = Self.moved(dragBase!, mode: mode, delta: delta, low: 0, high: sourceDuration, minimum: minimum)
            live { edits in
                guard let index = edits.cameraHidden.firstIndex(where: { $0.id == id }) else { return }
                edits.cameraHidden[index].start = range.start
                edits.cameraHidden[index].end = range.end
            }
        case .none, .clip:
            return
        }
    }

    private func updateZoomTimes(_ id: UUID, _ range: TimeRange) {
        live { edits in
            guard let index = edits.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
            edits.zoomRegions[index].start = range.start
            edits.zoomRegions[index].end = range.end
            edits.zoomRegions[index].origin = .manual
        }
    }

    private static func moved(_ base: TimeRange, mode: DragMode, delta: Double, low: Double, high: Double, minimum: Double) -> TimeRange {
        switch mode {
        case .move:
            let shift = min(max(delta, low - base.start), high - base.end)
            return TimeRange(base.start + shift, base.end + shift)
        case .start:
            return TimeRange(min(max(base.start + delta, low), base.end - minimum), base.end)
        case .end:
            return TimeRange(base.start, max(min(base.end + delta, high), base.start + minimum))
        }
    }

    // MARK: - Export

    func export(_ settings: ExportSettings, to destination: URL) {
        guard let info, exporter == nil else { return }
        exportState = .exporting(0)
        let exporter = Exporter()
        self.exporter = exporter
        Task {
            do {
                // Built fresh, but by the same builder and compositor the preview uses.
                let built = try await CompositionBuilder.build(bundle: bundle, timeline: timeline)
                guard let state = renderState(built: built, showsFullFrame: false) else { throw ExportError.failed("the project is not loaded") }
                let canvas = settings.renderSize(source: CGSize(width: info.width, height: info.height))
                let job = Exporter.Job(
                    asset: built.asset,
                    videoComposition: CompositionBuilder.videoComposition(for: built, state: state, canvas: canvas, fps: settings.fps),
                    audioMix: CompositionBuilder.audioMix(for: built, volumes: edits.volumes),
                    settings: settings, destination: destination)
                try await exporter.run(job) { [weak self] fraction in
                    Task { @MainActor in
                        if case .exporting = self?.exportState { self?.exportState = .exporting(fraction) }
                    }
                }
                exportState = .done(destination)
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = .failed(error.localizedDescription)
            }
            self.exporter = nil
        }
    }

    func cancelExport() {
        exporter?.cancel()
    }
}

enum Waveform {
    /// Peak amplitude (0…1) per bucket, read at low sample rate since it only drives a drawing.
    static func peaks(url: URL, bucketsPerSecond: Double) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let sampleRate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }

        let perBucket = max(1, Int(sampleRate / bucketsPerSecond))
        var peaks: [Float] = []
        var peak: Int32 = 0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: length / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count * 2, destination: &samples)
            for value in samples {
                peak = max(peak, abs(Int32(value)))
                count += 1
                if count == perBucket {
                    peaks.append(Float(peak) / 32768)
                    peak = 0
                    count = 0
                }
            }
        }
        return peaks
    }
}
