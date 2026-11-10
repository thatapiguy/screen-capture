import AppKit

/// Full-screen dimmed overlay on one display; the user drags out the region to record.
@MainActor
enum RegionPicker {
    /// Returns the region in the screen's own points with a top-left origin, or nil if cancelled.
    static func pick(on screen: NSScreen) async -> CGRect? {
        await withCheckedContinuation { continuation in
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            let view = RegionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            // The view's closure keeps the window alive until the user finishes.
            view.onDone = { rect in
                window.orderOut(nil)
                continuation.resume(returning: rect)
            }
            window.contentView = view
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
    }
}

/// Borderless windows refuse key status by default, which would swallow Esc.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class RegionView: NSView {
    var onDone: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var selection: CGRect?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(anchor.x, point.x), y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)
        ).intersection(bounds).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Tiny drags are almost always accidental clicks; let the user try again.
        if let selection, selection.width >= 32, selection.height >= 32 {
            finish(selection)
        } else {
            selection = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) }
    }

    private func finish(_ rect: CGRect?) {
        let done = onDone
        onDone = nil
        done?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
        ]
        guard let selection else {
            let hint = NSAttributedString(string: "Drag to select a region  ·  Esc to cancel", attributes: attributes)
            let size = hint.size()
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
            return
        }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
        let label = NSAttributedString(string: "\(Int(selection.width)) × \(Int(selection.height))", attributes: attributes)
        let labelY = selection.maxY + 6 + label.size().height < bounds.maxY ? selection.maxY + 6 : selection.minY + 6
        label.draw(at: CGPoint(x: selection.minX + 2, y: labelY))
    }
}
