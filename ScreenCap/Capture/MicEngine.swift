@preconcurrency import AVFoundation

/// Microphone capture. The session runs while the record panel is open (for the level
/// meter) and while recording; samples are only written when a sink is attached.
final class MicEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "screencap.mic.session")
    private let sampleQueue = DispatchQueue(label: "screencap.mic.samples", qos: .userInitiated)
    private let lock = NSLock()
    private var sink: (writer: TrackWriter, clock: SessionClock)?

    override init() {
        super.init()
        // One fixed format whatever the device, so the writer's settings never depend on the mic.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }

    /// Switches to the given microphone and runs the session; nil stops it.
    func select(deviceID: String?) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            var running = false
            if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
                running = true
            }
            session.commitConfiguration()
            if running, !session.isRunning { session.startRunning() }
            if !running, session.isRunning { session.stopRunning() }
        }
    }

    func setSink(writer: TrackWriter, clock: SessionClock) {
        lock.withLock { sink = (writer, clock) }
    }

    func clearSink() {
        lock.withLock { sink = nil }
    }

    /// Current input level, 0…1, for the meter.
    var level: Float {
        let decibels = output.connections.first?.audioChannels.map(\.averagePowerLevel).max() ?? -160
        return max(0, min(1, (decibels + 50) / 50))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let sink = lock.withLock({ self.sink }), let start = sink.clock.start else { return }
        // Capture timestamps are on the session's clock, which can be the audio device's.
        // Screen frames use the host clock, so move the audio onto it to keep the tracks in sync.
        var sample = sample
        if let sessionClock = session.synchronizationClock {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let hostPTS = CMSyncConvertTime(pts, from: sessionClock, to: CMClockGetHostTimeClock())
            if hostPTS != pts, let retimed = sample.retimed(to: hostPTS) { sample = retimed }
        }
        sink.writer.append(sample, sessionStart: start)
    }
}
