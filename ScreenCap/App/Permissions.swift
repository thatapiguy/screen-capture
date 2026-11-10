import AppKit
import AVFoundation
import Observation
import SwiftUI

@MainActor @Observable
final class Permissions {
    private(set) var screen = false
    private(set) var camera = AVAuthorizationStatus.notDetermined
    private(set) var mic = AVAuthorizationStatus.notDetermined

    /// Screen Recording is the only one the app can't work without.
    var needsOnboarding: Bool { !screen || camera == .notDetermined || mic == .notDetermined }

    func refresh() {
        screen = CGPreflightScreenCaptureAccess()
        camera = AVCaptureDevice.authorizationStatus(for: .video)
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestScreen() {
        // macOS shows its prompt only once; after that the user has to flip the switch in Settings.
        let askedKey = "askedForScreenRecording"
        if UserDefaults.standard.bool(forKey: askedKey) {
            openSettings("Privacy_ScreenCapture")
        } else {
            UserDefaults.standard.set(true, forKey: askedKey)
            CGRequestScreenCaptureAccess()
        }
        refresh()
    }

    func request(_ type: AVMediaType) async {
        if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: type)
        } else {
            openSettings(type == .video ? "Privacy_Camera" : "Privacy_Microphone")
        }
        refresh()
    }

    /// Screen Recording permission only takes effect in a fresh process.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionsView: View {
    @Environment(Permissions.self) private var permissions
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ScreenCap needs a few permissions")
                .font(.title2.bold())
            Text("Recordings stay on this Mac. You can change any of these later in System Settings › Privacy & Security.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            row(icon: "rectangle.dashed.badge.record", title: "Screen Recording",
                detail: "Required. Lets ScreenCap capture your display, a window or a region.",
                granted: permissions.screen, denied: false) { permissions.requestScreen() }
            row(icon: "mic", title: "Microphone",
                detail: "Optional. Records your narration as its own track.",
                granted: permissions.mic == .authorized, denied: permissions.mic == .denied || permissions.mic == .restricted) {
                Task { await permissions.request(.audio) }
            }
            row(icon: "web.camera", title: "Camera",
                detail: "Optional. Records your webcam as a separate track.",
                granted: permissions.camera == .authorized, denied: permissions.camera == .denied || permissions.camera == .restricted) {
                Task { await permissions.request(.video) }
            }

            if !permissions.screen {
                HStack(alignment: .firstTextBaseline) {
                    Text("Already switched Screen Recording on? macOS applies it after ScreenCap restarts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Quit & Reopen") { permissions.relaunch() }
                }
            }

            HStack {
                Spacer()
                Button(permissions.screen ? "Done" : "Not Now", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task {
            // Grants happen in System Settings, outside the app, so poll while this window is open.
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(icon: String, title: String, detail: String, granted: Bool, denied: Bool,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button(denied ? "Open Settings…" : "Allow…", action: action)
            }
        }
    }
}
