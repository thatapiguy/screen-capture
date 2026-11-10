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
    }

    static var fps: Int {
        let value = UserDefaults.standard.integer(forKey: Key.fps)
        return value == 0 ? 60 : value
    }

    static var cap: ResolutionCap {
        UserDefaults.standard.string(forKey: Key.cap).flatMap(ResolutionCap.init) ?? .native
    }

    /// nil means the microphone is off.
    static var micID: String? {
        let value = UserDefaults.standard.string(forKey: Key.micID) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// The recording state machine: what to capture, and starting/stopping a recording.
@MainActor @Observable
final class Recorder {
    enum State { case idle, starting, recording, finishing }

    // What to capture. Not persisted: display and window IDs don't survive relaunches.
    var mode: SourceMode = .display
    var displayID: CGDirectDisplayID?
    var windowID: CGWindowID?
    var region: CGRect?

    private(set) var displays: [SCDisplay] = []
    private(set) var windows: [SCWindow] = []
    private(set) var mics: [AVCaptureDevice] = []

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var droppedFrames = 0
    /// True while frames have been dropped in the last few seconds.
    private(set) var isDroppingFrames = false
    private(set) var lastRecording: URL?
    var errorMessage: String?

    @ObservationIgnored let mic = MicEngine()
    @ObservationIgnored var hidePanel: () -> Void = {}
    @ObservationIgnored var showPanel: () -> Void = {}

    private struct Active {
        let folder: URL
        let engine: CaptureEngine
        let screen: TrackWriter
        let mic: TrackWriter?
        let startedAt: Date
    }

    @ObservationIgnored private var active: Active?
    @ObservationIgnored private var ownApp: SCRunningApplication?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastDropAt = Date.distantPast
    @ObservationIgnored private var panelVisible = false

    /// Highest frame rate the selected source can actually deliver.
    var maxFPS: Int {
        let screen = mode == .window ? NSScreen.main : displays.first { $0.displayID == displayID }?.screen
        return screen?.maximumFramesPerSecond ?? 60
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        updateMic()
        if visible { Task { await refreshContent() } }
    }

    /// Runs the mic only when it's needed, so the menu bar app is idle otherwise.
    func updateMic() {
        let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let needed = authorized && (panelVisible || state != .idle)
        mic.select(deviceID: needed ? Prefs.micID : nil)
    }

    func refreshContent() async {
        mics = MicEngine.devices
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

    func start() async {
        guard state == .idle else { return }
        state = .starting
        errorMessage = nil
        hidePanel()
        updateMic()
        var folder: URL?
        do {
            await refreshContent()
            let source = try resolveSource()
            let fps = min(Prefs.fps, maxFPS)
            let filter = CaptureEngine.makeFilter(source: source, excluding: ownApp)
            let config = CaptureEngine.makeConfiguration(source: source, filter: filter, fps: fps, cap: Prefs.cap)

            let bundle = try Self.makeBundleFolder()
            folder = bundle
            let clock = SessionClock()
            let screenWriter = try TrackWriter(
                url: bundle.appending(path: "screen.mov"), mediaType: .video,
                settings: TrackWriter.screenSettings(width: config.width, height: config.height, fps: fps))
            var micWriter: TrackWriter?
            if Prefs.micID != nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                let writer = try TrackWriter(
                    url: bundle.appending(path: "mic.mov"), mediaType: .audio, settings: TrackWriter.audioSettings)
                mic.setSink(writer: writer, clock: clock)
                micWriter = writer
            }
            let engine = CaptureEngine(writer: screenWriter, clock: clock) { [weak self] error in
                // The system ended the stream (display unplugged, "Stop Sharing" in the menu bar…).
                Task { @MainActor in await self?.stop(error: error) }
            }
            try await engine.start(filter: filter, configuration: config)

            active = Active(folder: bundle, engine: engine, screen: screenWriter, mic: micWriter, startedAt: Date())
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
            if let folder { try? FileManager.default.removeItem(at: folder) }
            errorMessage = error.localizedDescription
            state = .idle
            updateMic()
            showPanel()
        }
    }

    func stop(error: Error? = nil) async {
        guard state == .recording, let active else { return }
        state = .finishing
        ticker?.cancel()
        let end = SessionClock.now
        await active.engine.stop()
        mic.clearSink()
        let screenOK = await active.screen.finish(at: end)
        if let micWriter = active.mic, await !micWriter.finish(at: end) {
            try? FileManager.default.removeItem(at: active.folder.appending(path: "mic.mov"))
        }
        droppedFrames = active.screen.dropped
        isDroppingFrames = false
        self.active = nil
        state = .idle
        updateMic()

        if screenOK {
            lastRecording = active.folder
        } else {
            try? FileManager.default.removeItem(at: active.folder)
        }
        if let message = error?.localizedDescription ?? (screenOK ? nil : "The recording couldn't be saved.") {
            errorMessage = message
            showPanel()
        }
    }

    private func tick() async {
        guard state == .recording, let active else { return }
        elapsed = Date().timeIntervalSince(active.startedAt)
        let dropped = active.screen.dropped
        if dropped > droppedFrames { lastDropAt = Date() }
        droppedFrames = dropped
        isDroppingFrames = Date().timeIntervalSince(lastDropAt) < 3
        if let failure = active.screen.error ?? active.mic?.error {
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

    /// ~/Movies/ScreenCap/Recording <date>.reel — one folder per recording, raw tracks inside.
    private static func makeBundleFolder() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let movies = try FileManager.default.url(for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = movies.appending(path: "ScreenCap/Recording \(formatter.string(from: Date())).reel")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
