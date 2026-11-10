import AppKit
import AVFoundation
import ScreenCapCore

/// The floating webcam preview shown while setting up and recording. Drag to move, drag an
/// edge or scroll to resize. It is only a preview: the app's windows are excluded from
/// capture, and the camera is recorded as its own track.
@MainActor
final class CameraBubble {
    private var panel: NSPanel?
    private var view: BubbleView?

    func show(session: AVCaptureSession, shape: CameraShape, mirrored: Bool) {
        if panel == nil {
            let side: CGFloat = 200
            let area = NSScreen.main?.visibleFrame ?? .zero
            let panel = NSPanel(
                contentRect: CGRect(x: area.maxX - side - 32, y: area.minY + 32, width: side, height: side),
                styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentAspectRatio = CGSize(width: 1, height: 1)
            panel.contentMinSize = CGSize(width: 96, height: 96)
            panel.contentMaxSize = CGSize(width: 480, height: 480)
            let view = BubbleView(session: session)
            panel.contentView = view
            panel.setFrameAutosaveName("CameraBubble")
            self.panel = panel
            self.view = view
        }
        view?.shape = shape
        view?.mirrored = mirrored
        view?.needsLayout = true
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private final class BubbleView: NSView {
    var shape = CameraShape.circle
    var mirrored = true
    private let preview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        preview.videoGravity = .resizeAspectFill
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(preview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        layer?.cornerRadius = shape == .circle ? bounds.width / 2 : bounds.width * 0.16
        // The connection only exists once the camera is attached, so this is reapplied on every layout.
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        CATransaction.commit()
        window?.invalidateShadow()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let side = min(480, max(96, window.frame.width + event.scrollingDeltaY))
        // Grow around the centre so the bubble stays where the user put it.
        window.setFrame(CGRect(x: window.frame.midX - side / 2, y: window.frame.midY - side / 2, width: side, height: side), display: true)
    }
}
