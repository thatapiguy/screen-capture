import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import ScreenCapCore

enum CaptureSource {
    case display(SCDisplay)
    case window(SCWindow)
    /// Rect is in the display's own points, origin top-left.
    case region(SCDisplay, CGRect)
}

extension SCDisplay {
    @MainActor var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}

/// Owns the SCStream and hands complete screen frames straight to the screen track's writer.
/// Mutable state is only touched from start/stop, which the Recorder calls serially.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "screencap.capture.screen", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "screencap.capture.audio", qos: .userInitiated)
    private let writer: TrackWriter
    private let systemAudio: TrackWriter?
    private let clock: SessionClock
    private let onStop: @Sendable (Error) -> Void
    private var stream: SCStream?

    init(writer: TrackWriter, systemAudio: TrackWriter?, clock: SessionClock, onStop: @escaping @Sendable (Error) -> Void) {
        self.writer = writer
        self.systemAudio = systemAudio
        self.clock = clock
        self.onStop = onStop
    }

    /// `ownApp` is excluded so ScreenCap's panels and overlays never appear in a recording.
    static func makeFilter(source: CaptureSource, excluding ownApp: SCRunningApplication?) -> SCContentFilter {
        switch source {
        case .display(let display), .region(let display, _):
            SCContentFilter(display: display, excludingApplications: ownApp.map { [$0] } ?? [], exceptingWindows: [])
        case .window(let window):
            SCContentFilter(desktopIndependentWindow: window)
        }
    }

    static func makeConfiguration(
        source: CaptureSource, filter: SCContentFilter, fps: Int, cap: ResolutionCap, systemAudio: Bool
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        var points = filter.contentRect.size
        if case .region(_, let rect) = source {
            config.sourceRect = rect
            points = rect.size
        }
        let size = CaptureGeometry.outputSize(points: points, scale: Double(filter.pointPixelScale), cap: cap)
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // Bounded: if the encoder stalls, ScreenCaptureKit drops frames instead of queueing without limit.
        config.queueDepth = 6
        // The encoder is 4:2:0 anyway; asking for it here avoids a colour conversion per frame.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // The cursor is recorded as data (events.jsonl) and drawn by the compositor instead.
        config.showsCursor = false
        if systemAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        return config
    }

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        if type == .audio {
            systemAudio?.append(sample, hostTime: sample.presentationTimeStamp, clock: clock)
            return
        }
        // Idle/blank status frames carry no new pixels; only complete frames are written.
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete
        else { return }
        clock.startIfNeeded(at: sample.presentationTimeStamp)
        writer.append(sample, hostTime: sample.presentationTimeStamp, clock: clock)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}
