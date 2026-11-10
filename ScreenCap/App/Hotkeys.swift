import AppKit
import Carbon.HIToolbox

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey…).
    var modifiers: UInt32
    /// What to show the user, e.g. "⌥⌘R".
    var label: String
}

enum HotkeyAction: UInt32, CaseIterable, Identifiable {
    case toggleRecording = 1, togglePause, zoomHere

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .toggleRecording: "Start / stop recording"
        case .togglePause: "Pause / resume"
        case .zoomHere: "Zoom here"
        }
    }

    var defaultCombo: KeyCombo {
        let modifiers = UInt32(cmdKey | optionKey)
        return switch self {
        case .toggleRecording: KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers, label: "⌥⌘R")
        case .togglePause: KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers, label: "⌥⌘P")
        case .zoomHere: KeyCombo(keyCode: UInt32(kVK_ANSI_Z), modifiers: modifiers, label: "⌥⌘Z")
        }
    }

    var combo: KeyCombo {
        get {
            UserDefaults.standard.data(forKey: "hotkey.\(rawValue)")
                .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? defaultCombo
        }
        nonmutating set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "hotkey.\(rawValue)")
        }
    }
}

/// System-wide hotkeys via Carbon, which works in the sandbox and needs no permission.
@MainActor
final class Hotkeys {
    var handler: (HotkeyAction) -> Void = { _ in }
    private var registered: [EventHotKeyRef] = []

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard let userData, let action = HotkeyAction(rawValue: hotKeyID.id) else { return noErr }
            let address = Int(bitPattern: userData)
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated {
                guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
                Unmanaged<Hotkeys>.fromOpaque(pointer).takeUnretainedValue().handler(action)
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        reload()
    }

    /// Re-registers every hotkey from the current preferences.
    func reload() {
        for reference in registered { UnregisterEventHotKey(reference) }
        registered = []
        for action in HotkeyAction.allCases {
            let combo = action.combo
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5343_4150), id: action.rawValue)
            RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &reference)
            if let reference { registered.append(reference) }
        }
    }
}
