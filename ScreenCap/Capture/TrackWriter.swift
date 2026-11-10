@preconcurrency import AVFoundation
import ScreenCapCore

enum RecordingError: LocalizedError {
    case noSource
    case writerSetup(String)

    var errorDescription: String? {
        switch self {
        case .noSource: "Nothing to record. Pick a display, window or region first."
        case .writerSetup(let detail): "Couldn't create the recording file (\(detail))."
        }
    }
}

/// The instant every track's file starts at. Set by the first screen frame so all
/// files share one host-clock origin and stay in sync without any later alignment.
final class SessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CMTime?

    var start: CMTime? { lock.withLock { value } }

    func startIfNeeded(at time: CMTime) -> CMTime {
        lock.withLock {
            if value == nil { value = time }
            return value!
        }
    }

    static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
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

    /// Called synchronously on the capture queue. Never blocks: if the encoder is
    /// backed up the sample is dropped and counted, which keeps memory bounded.
    func append(_ sample: CMSampleBuffer, sessionStart: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts >= sessionStart else { return }
        if !started {
            writer.startSession(atSourceTime: sessionStart)
            started = true
        }
        guard input.isReadyForMoreMediaData else {
            droppedCount += 1
            return
        }
        if input.append(sample) { lastPTS = pts }
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
