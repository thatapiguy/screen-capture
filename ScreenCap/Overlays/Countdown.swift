import AppKit

/// The 3-2-1 before recording starts.
@MainActor
enum Countdown {
    /// Returns false if the surrounding task was cancelled during the countdown.
    static func run(on screen: NSScreen?) async -> Bool {
        let side: CGFloat = 160
        let area = (screen ?? NSScreen.main)?.frame ?? .zero
        let window = NSWindow(
            contentRect: CGRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let backdrop = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        backdrop.material = .hudWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 36
        backdrop.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 96, weight: .semibold)
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 18, width: side, height: 120)
        backdrop.addSubview(label)
        window.contentView = backdrop

        defer { window.orderOut(nil) }
        for number in [3, 2, 1] {
            label.stringValue = "\(number)"
            window.orderFrontRegardless()
            do { try await Task.sleep(for: .seconds(1)) } catch { return false }
        }
        return true
    }
}
