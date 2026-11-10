@preconcurrency import AVFoundation
import ScreenCapCore

enum RecordingError: LocalizedError {
    case noSource
    case noPermission
    case writerSetup(String)

    var errorDescription: String? {
        switch self {
        case .noSource: "Nothing to record. Pick a display, window or region first."
        case .noPermission: "ScreenCap needs Screen Recording permission. Open the menu bar panel to set it up."
        case .writerSetup(let detail): "Couldn't create the recording file (\(detail))."
        }
    }
}

/// One timeline for every track. Position zero is the first screen frame; time spent paused
/// is removed. All capture timestamps are host-clock times and are mapped through here, which
/// is what keeps camera, microphone, system audio and cursor data in sync with the screen.
final class SessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var startTime: CMTime?
    private var pausedTotal = CMTime.zero
    private var pauseBegan: CMTime?

    static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    func startIfNeeded(at hostTime: CMTime) {
        lock.withLock { if startTime == nil { startTime = hostTime } }
    }

    /// Timeline position of a host-clock timestamp; nil before the start and while paused.
    func position(for hostTime: CMTime) -> CMTime? {
        lock.withLock {
            guard let startTime, hostTime >= startTime else { return nil }
            if let pauseBegan, hostTime >= pauseBegan { return nil }
            return hostTime - startTime - pausedTotal
        }
    }

    /// Current timeline position; stands still while paused.
    var now: CMTime {
        lock.withLock {
            guard let startTime else { return .zero }
            return (pauseBegan ?? Self.hostNow) - startTime - pausedTotal
        }
    }

    func pause() {
        lock.withLock { if pauseBegan == nil { pauseBegan = Self.hostNow } }
    }

    func resume() {
        lock.withLock {
            guard let began = pauseBegan else { return }
            pausedTotal = pausedTotal + (Self.hostNow - began)
            pauseBegan = nil
        }
    }
}

/// One media file with one track, written incrementally as a fragmented QuickTime
/// movie: if the app dies, everything up to the last fragment (~1 s) is still playable.
final class TrackWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var finished = false
    private var lastPTS = CMTime.invalid
    private var droppedCount = 0

    init(url: URL, mediaType: AVMediaType, settings: [String: Any]) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        // Checked first because AVAssetWriterInput raises an uncatchable exception on bad settings.
        guard writer.canApply(outputSettings: settings, forMediaType: mediaType) else {
            throw RecordingError.writerSetup("unsupported \(mediaType.rawValue) settings")
        }
        input = AVAssetWriterInput(mediaType: mediaType, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.writerSetup("can't add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecordingError.writerSetup(writer.error?.localizedDescription ?? "can't start writing")
        }
    }

    /// Samples dropped because the encoder couldn't keep up.
    var dropped: Int { lock.withLock { droppedCount } }

    var error: Error? { lock.withLock { writer.status == .failed ? writer.error : nil } }

    /// Called synchronously on a capture queue. Never blocks: if the encoder is backed up
    /// the sample is dropped and counted, which keeps memory bounded.
    func append(_ sample: CMSampleBuffer, hostTime: CMTime, clock: SessionClock) {
        guard let position = clock.position(for: hostTime) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finished, writer.status == .writing else { return }
        // A sample captured just before a pause can arrive after the resume; it would run backwards.
        if lastPTS.isValid, position <= lastPTS { return }
        if !started {
            writer.startSession(atSourceTime: .zero)
            started = true
        }
        guard input.isReadyForMoreMediaData else {
            droppedCount += 1
            return
        }
        if let retimed = sample.retimed(to: position), input.append(retimed) { lastPTS = position }
    }

    /// Returns true if a playable file was written.
    func finish(at end: CMTime) async -> Bool {
        let hasContent = lock.withLock {
            guard !finished else { return false }
            finished = true
            guard started, writer.status == .writing else {
                writer.cancelWriting()
                return false
            }
            input.markAsFinished()
            // Screen frames only arrive when pixels change, so this holds the last one until stop.
            writer.endSession(atSourceTime: max(end, lastPTS))
            return true
        }
        guard hasContent else { return false }
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        return lock.withLock { writer.status == .completed }
    }

    static func screenSettings(width: Int, height: Int, fps: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: CaptureGeometry.screenBitrate(width: width, height: height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
    }

    /// The camera is cropped to a square inset later, so 720p is plenty; aspect-fill keeps
    /// 4:3 cameras undistorted.
    static var cameraSettings: [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
    }

    static var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ]
    }
}

extension CMSampleBuffer {
    /// A copy of this buffer (sharing its data) whose timestamps are moved so it starts at `pts`.
    func retimed(to pts: CMTime) -> CMSampleBuffer? {
        let shift = pts - CMSampleBufferGetPresentationTimeStamp(self)
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + shift
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + shift
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: self,
            sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
    }
}

extension AVCaptureSession {
    /// Capture timestamps are on the session's clock, which can be a device clock. Screen
    /// frames use the host clock, so everything is converted to it before being written.
    func hostTime(of sample: CMSampleBuffer) -> CMTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let clock = synchronizationClock else { return pts }
        return CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
    }
}
