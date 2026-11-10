@preconcurrency import AVFoundation
import ScreenCapCore

enum ExportError: LocalizedError {
    case tooLargeForH264
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .tooLargeForH264: "H.264 can't encode a frame this large. Choose HEVC or a lower resolution."
        case .failed(let detail): "Export failed: \(detail)"
        }
    }
}

/// Renders a composition to an MP4 with hardware encoding. Reads frames from the same video
/// composition the preview uses and feeds them to a writer, which gives control over bitrate.
final class Exporter: @unchecked Sendable {
    struct Job: @unchecked Sendable {
        let asset: AVComposition
        let videoComposition: AVVideoComposition
        let audioMix: AVAudioMix
        let settings: ExportSettings
        let destination: URL
    }

    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// `progress` is called from a background thread with 0…1.
    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.pump(job, progress: progress)
                    continuation.resume()
                } catch {
                    try? FileManager.default.removeItem(at: job.destination)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func pump(_ job: Job, progress: @Sendable (Double) -> Void) throws {
        let size = job.videoComposition.renderSize
        if job.settings.codec == .h264, size.width > 4096 || size.height > 2304 { throw ExportError.tooLargeForH264 }

        let reader = try AVAssetReader(asset: job.asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: job.asset.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = job.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        let audioTracks = job.asset.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            // Mixes every source down to one stereo stream, applying the per-source volumes.
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = job.audioMix
            output.alwaysCopiesSampleData = false
            reader.add(output)
            audioOutput = output
        }

        try? FileManager.default.removeItem(at: job.destination)
        let writer = try AVAssetWriter(outputURL: job.destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: job.settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: job.settings.videoBitrate(size: size),
                AVVideoExpectedSourceFrameRateKey: job.settings.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else { throw reader.error ?? ExportError.failed("couldn't read the recording") }
        guard writer.startWriting() else { throw writer.error ?? ExportError.failed("couldn't create the file") }
        writer.startSession(atSourceTime: .zero)

        let duration = max(0.001, job.asset.duration.seconds)
        var videoDone = false, audioDone = audioInput == nil
        // Feed whichever input wants data. The writer interleaves, so each input pauses until
        // the other catches up; serving both from one loop can't deadlock.
        while !(videoDone && audioDone) {
            if isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw CancellationError()
            }
            if writer.status == .failed { throw writer.error ?? ExportError.failed("the encoder stopped") }
            var idle = true
            if !videoDone, videoInput.isReadyForMoreMediaData {
                idle = false
                if let sample = videoOutput.copyNextSampleBuffer() {
                    videoInput.append(sample)
                    progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
                } else {
                    videoInput.markAsFinished()
                    videoDone = true
                }
            }
            if !audioDone, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                idle = false
                if let sample = audioOutput.copyNextSampleBuffer() {
                    audioInput.append(sample)
                } else {
                    audioInput.markAsFinished()
                    audioDone = true
                }
            }
            if idle { Thread.sleep(forTimeInterval: 0.002) }
        }
        if reader.status == .failed { throw reader.error ?? ExportError.failed("couldn't read the recording") }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        if writer.status != .completed { throw writer.error ?? ExportError.failed("couldn't finish the file") }
    }
}
