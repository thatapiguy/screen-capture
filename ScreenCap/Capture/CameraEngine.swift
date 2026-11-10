@preconcurrency import AVFoundation

/// Webcam capture. Feeds the floating preview bubble through `session`, and writes raw
/// (unmirrored, uncropped) frames to its own track when a sink is attached.
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "screencap.camera.session")
    private let sampleQueue = DispatchQueue(label: "screencap.camera.samples", qos: .userInitiated)
    private let lock = NSLock()
    private var sink: (writer: TrackWriter, clock: SessionClock)?
    private var currentDeviceID: String?

    override init() {
        super.init()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified
        ).devices
    }

    /// Switches to the given camera and runs the session; nil stops it.
    func select(deviceID: String?) {
        sessionQueue.async { [self] in
            guard deviceID != currentDeviceID || (deviceID != nil) != session.isRunning else { return }
            currentDeviceID = deviceID
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            var running = false
            if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
                session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
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

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let sink = lock.withLock({ self.sink }) else { return }
        sink.writer.append(sample, hostTime: session.hostTime(of: sample), clock: sink.clock)
    }
}
