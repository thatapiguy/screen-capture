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

/// Menu bar item and its popover panel, plus the app's windows: permissions, settings and editors.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let recorder = Recorder()
    private let permissions = Permissions()
    private let popover = NSPopover()
    private let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem!
    private var permissionsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var editors: [NSWindow: EditorModel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let panel = RecordPanel(
            showPermissions: { [weak self] in self?.showPermissions() },
            showSettings: { [weak self] in self?.showSettings() },
            openRecording: { [weak self] in self?.openEditor($0) })
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

        recorder.onFinished = { [weak self] in self?.openEditor($0) }
        buildMainMenu()

        permissions.refresh()
        if permissions.needsOnboarding { showPermissions() }
        trackRecorder()
        recoverInterruptedRecordings()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == "reel" { openEditor(ReelBundle(url: url)) }
    }

    /// Quitting mid-recording finishes the files properly first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.state == .recording || recorder.state == .paused else { return .terminateNow }
        Task {
            await recorder.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Crash recovery

    /// Tracks are written in fragments, so a recording cut short by a crash is still playable.
    /// All that's missing is the "complete" mark; set it and offer to open the recording.
    private func recoverInterruptedRecordings() {
        let interrupted = ProjectStore.unfinished()
        guard !interrupted.isEmpty else { return }
        for bundle in interrupted {
            guard var info = try? bundle.loadInfo() else { continue }
            info.state = .complete
            try? bundle.save(info)
        }
        let alert = NSAlert()
        alert.messageText = interrupted.count == 1 ? "A recording was recovered" : "\(interrupted.count) recordings were recovered"
        alert.informativeText = "ScreenCap quit unexpectedly while recording. Everything up to the last second or so was saved."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            interrupted.forEach(openEditor)
        }
    }

    // MARK: - Editors

    private func openEditor(_ bundle: ReelBundle) {
        if let existing = editors.first(where: { $0.value.bundle == bundle })?.key {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        popover.performClose(nil)
        let model = EditorModel(bundle: bundle)
        let window = NSWindow(contentViewController: NSHostingController(rootView: EditorView(model: model)))
        window.title = bundle.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        editors[window] = model
        // An editor is a real window, so the app shows in the Dock and app switcher while one is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let model = editors.removeValue(forKey: window) else { return }
        model.close()
        if editors.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    private var keyEditor: EditorModel? {
        NSApp.keyWindow.flatMap { editors[$0] }
    }

    // MARK: - Main menu (visible while an editor is open; also provides the standard shortcuts)

    private func buildMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        let app = submenu("ScreenCap")
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit ScreenCap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: #selector(undoEdit), keyEquivalent: "z").target = self
        edit.addItem(withTitle: "Redo", action: #selector(redoEdit), keyEquivalent: "Z").target = self
        NSApp.mainMenu = main
    }

    @objc private func undoEdit() { keyEditor?.undo() }
    @objc private func redoEdit() { keyEditor?.redo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoEdit): keyEditor?.canUndo ?? false
        case #selector(redoEdit): keyEditor?.canRedo ?? false
        default: true
        }
    }

    @objc private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let view = SettingsView(hotkeysChanged: { [weak self] in self?.hotkeys.reload() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "ScreenCap Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
