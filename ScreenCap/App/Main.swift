import AppKit
import Observation
import SwiftUI

@main
struct ScreenCapMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// Menu bar item, its popover panel, and the permissions window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let recorder = Recorder()
    private let permissions = Permissions()
    private let popover = NSPopover()
    private let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem!
    private var permissionsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let panel = RecordPanel(showPermissions: { [weak self] in self?.showPermissions() })
            .environment(recorder)
            .environment(permissions)
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        recorder.hidePanel = { [weak self] in self?.popover.performClose(nil) }
        recorder.showPanel = { [weak self] in self?.showPanel() }
        hotkeys.handler = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleRecording: recorder.toggleRecording()
            case .togglePause: recorder.togglePause()
            case .zoomHere: recorder.zoomHere()
            }
        }

        permissions.refresh()
        if permissions.needsOnboarding { showPermissions() }
        trackRecorder()
    }

    /// Clicking the icon stops a recording in progress; right-click offers pause. Otherwise it toggles the panel.
    @objc private func statusItemClicked() {
        switch recorder.state {
        case .recording, .paused:
            if NSApp.currentEvent?.type == .rightMouseUp {
                showRecordingMenu()
            } else {
                recorder.toggleRecording()
            }
        case .starting:
            recorder.toggleRecording()
        case .idle:
            if popover.isShown { popover.performClose(nil) } else { showPanel() }
        case .finishing:
            break
        }
    }

    private func showRecordingMenu() {
        let menu = NSMenu()
        let pause = menu.addItem(withTitle: recorder.state == .paused ? "Resume" : "Pause",
                                 action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        let stop = menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stop.target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach again so a normal click keeps meaning "stop".
        statusItem.menu = nil
    }

    @objc private func togglePause() { recorder.togglePause() }
    @objc private func stopRecording() { recorder.toggleRecording() }

    private func showPanel() {
        guard let button = statusItem.button, !popover.isShown else { return }
        permissions.refresh()
        recorder.setPanelVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        recorder.setPanelVisible(false)
    }

    private func showPermissions() {
        popover.performClose(nil)
        if permissionsWindow == nil {
            let view = PermissionsView(done: { [weak self] in self?.permissionsWindow?.close() })
                .environment(permissions)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "ScreenCap"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            permissionsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        permissionsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Redraws the menu bar item whenever the recorder state it reads changes.
    private func trackRecorder() {
        withObservationTracking {
            updateStatusItem()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackRecorder() }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        var symbol = "record.circle"
        var title = ""
        var tint: NSColor?
        var tip = "ScreenCap"
        switch recorder.state {
        case .idle, .starting:
            break
        case .recording, .paused:
            let paused = recorder.state == .paused
            symbol = paused ? "pause.circle.fill" : "stop.circle.fill"
            tint = paused ? .systemOrange : .systemRed
            let seconds = Int(recorder.elapsed)
            title = String(format: " %02d:%02d", seconds / 60, seconds % 60)
            tip = "Click to stop recording. Right-click to pause."
            if recorder.isDroppingFrames {
                title += " ⚠︎"
                tip = "Frames are being dropped (\(recorder.droppedFrames) so far). Click to stop recording."
            }
        case .finishing:
            title = " Saving…"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScreenCap")
        button.contentTintColor = tint
        button.title = title
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.toolTip = tip
    }
}
