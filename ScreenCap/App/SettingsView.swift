import AppKit
import Carbon.HIToolbox
import SwiftUI
import ScreenCapCore

struct SettingsView: View {
    @AppStorage(Prefs.Key.autoZoom) private var autoZoom = Sensitivity.normal
    @AppStorage(Prefs.Key.highlightClicks) private var highlightClicks = true
    let hotkeysChanged: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Auto zoom", selection: $autoZoom) {
                    ForEach(Sensitivity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Highlight clicks", isOn: $highlightClicks)
            } header: {
                Text("New recordings")
            } footer: {
                Text("Applied when a recording is first opened. Each recording can be changed afterwards in the editor.")
            }

            Section("Shortcuts") {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.title) { ShortcutField(action: action, changed: hotkeysChanged) }
                }
            }

            Section("Recordings") {
                LabeledContent("Saved in") {
                    Button("Movies › ScreenCap") { NSWorkspace.shared.open(ProjectStore.folder) }.buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Click, then press a key combination to rebind a global hotkey.
private struct ShortcutField: View {
    let action: HotkeyAction
    let changed: () -> Void
    @State private var label = ""
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(monitor == nil ? label : "Press shortcut…") { monitor == nil ? startListening() : stopListening() }
                .frame(minWidth: 110)
            Button("Reset") {
                set(action.defaultCombo)
            }
            .buttonStyle(.link)
            .disabled(action.combo == action.defaultCombo)
        }
        .onAppear { label = action.combo.label }
        .onDisappear { stopListening() }
    }

    private func startListening() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopListening()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // A global hotkey without ⌘, ⌥ or ⌃ would swallow ordinary typing everywhere.
            guard !flags.intersection([.command, .option, .control]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
            var modifiers = 0, symbols = ""
            if flags.contains(.control) { modifiers |= controlKey; symbols += "⌃" }
            if flags.contains(.option) { modifiers |= optionKey; symbols += "⌥" }
            if flags.contains(.shift) { modifiers |= shiftKey; symbols += "⇧" }
            if flags.contains(.command) { modifiers |= cmdKey; symbols += "⌘" }
            set(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), label: symbols + key))
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func set(_ combo: KeyCombo) {
        action.combo = combo
        label = combo.label
        changed()
    }
}
