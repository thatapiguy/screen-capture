import AppKit
@preconcurrency import AVFoundation
import Observation
@preconcurrency import ScreenCaptureKit
import ScreenCapCore

enum SourceMode: String, CaseIterable, Identifiable {
    case display, window, region
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Persisted recording preferences. Views bind to the same keys with @AppStorage.
enum Prefs {
    enum Key {
        static let fps = "fps"
        static let cap = "resolutionCap"
        static let micID = "micID"
        static let cameraID = "cameraID"
        static let cameraShape = "cameraShape"
        static let cameraMirrored = "cameraMirrored"
        static let systemAudio = "systemAudio"
        static let autoZoom = "autoZoom"
        static let highlightClicks = "highlightClicks"
    }

    private static var defaults: UserDefaults { .standard }

    private static func id(_ key: String) -> String? {
        let value = defaults.string(forKey: key) ?? ""
        return value.isEmpty ? nil : value
    }

    static var fps: Int {
        let value = defaults.integer(forKey: Key.fps)
        return value == 0 ? 60 : value
    }

    static var cap: ResolutionCap { defaults.string(forKey: Key.cap).flatMap(ResolutionCap.init) ?? .native }
    /// nil means the microphone is off.
    static var micID: String? { id(Key.micID) }
    /// nil means the camera is off.
    static var cameraID: String? { id(Key.cameraID) }
    static var cameraShape: CameraShape { defaults.string(forKey: Key.cameraShape).flatMap(CameraShape.init) ?? .circle }
    static var cameraMirrored: Bool { defaults.object(forKey: Key.cameraMirrored) as? Bool ?? true }
    static var systemAudio: Bool { defaults.bool(forKey: Key.systemAudio) }
    static var autoZoom: Sensitivity { defaults.string(forKey: Key.autoZoom).flatMap(Sensitivity.init) ?? .normal }
    static var highlightClicks: Bool { defaults.object(forKey: Key.highlightClicks) as? Bool ?? true }
}

/// The recording state machine: what to capture, and starting, pausing and stopping a recording.
@MainActor @Observable
final class Recorder {
    enum State { case idle, starting, recording, paused, finishing }

    // What to capture. Not persisted: display and window IDs don't survive relaunches.
    var mode: SourceMode = .display
    var displayID: CGDirectDisplayID?
    var windowID: CGWindowID?
    var region: CGRect?

    private(set) var displays: [SCDisplay] = []
    private(set) var windows: [SCWindow] = []
    private(set) var mics: [AVCaptureDevice] = []
    private(set) var cameras: [AVCaptureDevice] = []

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var droppedFrames = 0
    /// True while frames have been dropped in the last few seconds.
    private(set) var isDroppingFrames = false
    private(set) var lastRecording: ReelBundle?
    var errorMessage: String?

    @ObservationIgnored let mic = MicEngine()
    @ObservationIgnored let camera = CameraEngine()
    @ObservationIgnored var hidePanel: () -> Void = {}
    @ObservationIgnored var showPanel: () -> Void = {}
    @ObservationIgnored var onFinished: (ReelBundle) -> Void = { _ in }

    private struct Active {
        let bundle: ReelBundle
        var info: ProjectInfo
        let clock: SessionClock
        let engine: CaptureEngine
        let metadata: MetadataRecorder
        let screen: TrackWriter
        /// Optional tracks with the file each one writes, removed again if it ends up empty.
        let extras: [(writer: TrackWriter, file: URL)]
    }

    @ObservationIgnored private var active: Active?
    @ObservationIgnored private var ownApp: SCRunningApplication?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastDropAt = Date.distantPast
    @ObservationIgnored private var panelVisible = false
    @ObservationIgnored private let bubble = CameraBubble()

    /// Highest frame rate the selected source can actually deliver.
    var maxFPS: Int {
        let screen = mode == .window ? NSScreen.main : displays.first { $0.displayID == displayID }?.screen
        return screen?.maximumFramesPerSecond ?? 60
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        updateDevices()
        if visible { Task { await refreshContent() } }
    }

    /// Runs the mic and camera only while they're needed, so the menu bar app is idle otherwise.
    func updateDevices() {
        let needed = panelVisible || state != .idle
        let micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        mic.select(deviceID: needed && micAllowed ? Prefs.micID : nil)

        let cameraAllowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let cameraID = needed && cameraAllowed ? Prefs.cameraID : nil
        camera.select(deviceID: cameraID)
        if cameraID != nil {
            bubble.show(session: camera.session, shape: Prefs.cameraShape, mirrored: Prefs.cameraMirrored)
        } else {
            bubble.hide()
        }
    }

    func refreshContent() async {
        mics = MicEngine.devices
        cameras = CameraEngine.devices
        guard CGPreflightScreenCaptureAccess() else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ownBundleID = Bundle.main.bundleIdentifier
            ownApp = content.applications.first { $0.bundleIdentifier == ownBundleID } ?? ownApp
            displays = content.displays
            windows = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100
                    && $0.owningApplication?.bundleIdentifier != ownBundleID
                    && !($0.title ?? "").isEmpty
            }
            if !displays.contains(where: { $0.displayID == displayID }) {
                displayID = displays.first { $0.displayID == CGMainDisplayID() }?.displayID ?? displays.first?.displayID
                region = nil
            }
            if !windows.contains(where: { $0.windowID == windowID }) {
                windowID = windows.first?.windowID
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pickRegion() async {
        guard let screen = displays.first(where: { $0.displayID == displayID })?.screen else { return }
        hidePanel()
        if let rect = await RegionPicker.pick(on: screen) { region = rect }
        showPanel()
    }

    // MARK: - Controls (panel, menu bar item and hotkeys all call these)

    func toggleRecording() {
        switch state {
        case .idle: start()
        case .starting: startTask?.cancel()
        case .recording, .paused: Task { await stop() }
        case .finishing: break
        }
    }

    func togglePause() {
        guard let active else { return }
        if state == .recording {
            active.clock.pause()
            state = .paused
        } else if state == .paused {
            active.clock.resume()
            state = .recording
        }
    }

    func zoomHere() {
        guard state == .recording else { return }
        active?.metadata.toggleZoom()
    }

    func start() {
        guard state == .idle else { return }
        state = .starting
        errorMessage = nil
        hidePanel()
        updateDevices()
        startTask = Task { await begin() }
    }

    private func begin() async {
        var created: ReelBundle?
        do {
            await refreshContent()
            if displays.isEmpty { throw RecordingError.noPermission }
            let source = try resolveSource()
            let fps = min(Prefs.fps, maxFPS)
            let wantsSystemAudio = Prefs.systemAudio
            let filter = CaptureEngine.makeFilter(source: source, excluding: ownApp)
            let config = CaptureEngine.makeConfiguration(
                source: source, filter: filter, fps: fps, cap: Prefs.cap, systemAudio: wantsSystemAudio)
            let captureRect = Self.globalRect(of: source)

            guard await Countdown.run(on: Self.screen(of: source)) else {
                state = .idle
                updateDevices()
                return
            }

            let info = ProjectInfo(
                createdAt: Date(), state: .recording, width: config.width, height: config.height,
                scale: Double(config.width) / max(1, captureRect.width), fps: fps,
                cameraMirrored: Prefs.cameraMirrored, cameraShape: Prefs.cameraShape)
            let bundle = try ProjectStore.create(info: info)
            created = bundle
            let clock = SessionClock()
            let screenWriter = try TrackWriter(
                url: bundle.screen, mediaType: .video,
                settings: TrackWriter.screenSettings(width: config.width, height: config.height, fps: fps))
            var extras: [(writer: TrackWriter, file: URL)] = []
            if Prefs.micID != nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                let writer = try TrackWriter(url: bundle.mic, mediaType: .audio, settings: TrackWriter.audioSettings)
                mic.setSink(writer: writer, clock: clock)
                extras.append((writer, bundle.mic))
            }
            if Prefs.cameraID != nil, AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                let writer = try TrackWriter(url: bundle.camera, mediaType: .video, settings: TrackWriter.cameraSettings)
                camera.setSink(writer: writer, clock: clock)
                extras.append((writer, bundle.camera))
            }
            var systemWriter: TrackWriter?
            if wantsSystemAudio {
                let writer = try TrackWriter(url: bundle.systemAudio, mediaType: .audio, settings: TrackWriter.audioSettings)
                extras.append((writer, bundle.systemAudio))
                systemWriter = writer
            }
            let metadata = try MetadataRecorder(url: bundle.events, clock: clock, captureRect: captureRect)
            let engine = CaptureEngine(writer: screenWriter, systemAudio: systemWriter, clock: clock) { [weak self] error in
                // The system ended the stream (display unplugged, "Stop Sharing" in the menu bar…).
                Task { @MainActor in await self?.stop(error: error) }
            }
            try await engine.start(filter: filter, configuration: config)
            metadata.start()

            active = Active(bundle: bundle, info: info, clock: clock, engine: engine, metadata: metadata,
                            screen: screenWriter, extras: extras)
            elapsed = 0
            droppedFrames = 0
            isDroppingFrames = false
            state = .recording
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    await self?.tick()
                }
            }
        } catch {
            mic.clearSink()
            camera.clearSink()
            if let created { try? FileManager.default.removeItem(at: created.url) }
            errorMessage = error.localizedDescription
            state = .idle
            updateDevices()
            showPanel()
        }
    }

    func stop(error: Error? = nil) async {
        guard state == .recording || state == .paused, var active else { return }
        state = .finishing
        ticker?.cancel()
        let end = active.clock.now
        await active.engine.stop()
        mic.clearSink()
        camera.clearSink()
        active.metadata.stop()
        let screenOK = await active.screen.finish(at: end)
        for extra in active.extras {
            let written = await extra.writer.finish(at: end)
            if !written { try? FileManager.default.removeItem(at: extra.file) }
        }
        droppedFrames = active.screen.dropped
        isDroppingFrames = false
        self.active = nil
        state = .idle
        updateDevices()

        if screenOK {
            active.info.state = .complete
            try? active.bundle.save(active.info)
            lastRecording = active.bundle
            onFinished(active.bundle)
        } else {
            try? FileManager.default.removeItem(at: active.bundle.url)
        }
        if let message = error?.localizedDescription ?? (screenOK ? nil : "The recording couldn't be saved.") {
            errorMessage = message
            showPanel()
        }
    }

    private func tick() async {
        guard state == .recording || state == .paused, let active else { return }
        elapsed = active.clock.now.seconds
        let dropped = active.screen.dropped
        if dropped > droppedFrames { lastDropAt = Date() }
        droppedFrames = dropped
        isDroppingFrames = Date().timeIntervalSince(lastDropAt) < 3
        if let failure = active.screen.error ?? active.extras.lazy.compactMap(\.writer.error).first {
            await stop(error: failure)
        }
    }

    private func resolveSource() throws -> CaptureSource {
        let display = displays.first { $0.displayID == displayID }
        switch mode {
        case .display:
            if let display { return .display(display) }
        case .window:
            if let window = windows.first(where: { $0.windowID == windowID }) { return .window(window) }
        case .region:
            if let display, let region { return .region(display, region) }
        }
        throw RecordingError.noSource
    }

    /// The captured area in global display points (origin top-left), for normalising cursor positions.
    private static func globalRect(of source: CaptureSource) -> CGRect {
        switch source {
        case .display(let display): display.frame
        case .window(let window): window.frame
        case .region(let display, let rect): rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        }
    }

    private static func screen(of source: CaptureSource) -> NSScreen? {
        switch source {
        case .display(let display), .region(let display, _): display.screen
        case .window: NSScreen.main
        }
    }
}
