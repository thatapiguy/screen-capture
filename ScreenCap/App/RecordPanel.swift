import AVFoundation
import ScreenCaptureKit
import SwiftUI
import ScreenCapCore

/// The small pre-record panel shown from the menu bar icon.
struct RecordPanel: View {
    @Environment(Recorder.self) private var recorder
    @Environment(Permissions.self) private var permissions
    @AppStorage(Prefs.Key.fps) private var fps = 60
    @AppStorage(Prefs.Key.cap) private var cap = ResolutionCap.native
    @AppStorage(Prefs.Key.micID) private var micID = ""
    let showPermissions: () -> Void

    var body: some View {
        @Bindable var recorder = recorder
        VStack(alignment: .leading, spacing: 12) {
            if !permissions.screen {
                Label("Screen Recording permission is needed before you can record.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up Permissions…", action: showPermissions)
            } else {
                Picker("Source", selection: $recorder.mode) {
                    ForEach(SourceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                sourcePicker

                Divider()

                LabeledContent("Microphone") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Picker("Microphone", selection: $micID) {
                            Text("Off").tag("")
                            ForEach(recorder.mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }
                        .labelsHidden()
                        .disabled(permissions.mic != .authorized)
                        if permissions.mic != .authorized {
                            Button("Allow microphone…", action: showPermissions).buttonStyle(.link).font(.caption)
                        } else if !micID.isEmpty {
                            LevelMeter(mic: recorder.mic)
                        }
                    }
                }
                LabeledContent("Frame rate") {
                    Picker("Frame rate", selection: $fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                        if recorder.maxFPS >= 120 { Text("120").tag(120) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent("Resolution") {
                    Picker("Resolution", selection: $cap) {
                        Text("Native").tag(ResolutionCap.native)
                        Text("Up to 1440p").tag(ResolutionCap.p1440)
                        Text("Up to 1080p").tag(ResolutionCap.p1080)
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Button {
                    Task { await recorder.start() }
                } label: {
                    Text("Start Recording").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(recorder.state != .idle || !canRecord)
            }

            if let message = recorder.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onChange(of: micID) { recorder.updateMic() }
        .onChange(of: recorder.displayID) { recorder.region = nil }
    }

    private var canRecord: Bool {
        switch recorder.mode {
        case .display: recorder.displayID != nil
        case .window: recorder.windowID != nil
        case .region: recorder.region != nil
        }
    }

    @ViewBuilder private var sourcePicker: some View {
        @Bindable var recorder = recorder
        switch recorder.mode {
        case .display:
            displayPicker
        case .window:
            if recorder.windows.isEmpty {
                Text("No windows to record.").foregroundStyle(.secondary)
            } else {
                LabeledContent("Window") {
                    Picker("Window", selection: $recorder.windowID) {
                        ForEach(recorder.windows, id: \.windowID) { window in
                            Text("\(window.owningApplication?.applicationName ?? "") — \(window.title ?? "")")
                                .tag(Optional(window.windowID))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
            }
        case .region:
            displayPicker
            LabeledContent("Region") {
                HStack {
                    if let region = recorder.region {
                        Text("\(Int(region.width)) × \(Int(region.height))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button(recorder.region == nil ? "Select…" : "Reselect…") {
                        Task { await recorder.pickRegion() }
                    }
                }
            }
        }
    }

    private var displayPicker: some View {
        @Bindable var recorder = recorder
        return LabeledContent("Display") {
            Picker("Display", selection: $recorder.displayID) {
                ForEach(recorder.displays, id: \.displayID) { display in
                    Text(display.screen?.localizedName ?? "Display \(display.displayID)")
                        .tag(Optional(display.displayID))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
        }
    }

    private var footer: some View {
        HStack {
            if let url = recorder.lastRecording {
                Button("Show Last Recording") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
                if recorder.droppedFrames > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("\(recorder.droppedFrames) frames were dropped. Try a lower frame rate or resolution.")
                }
            }
            Spacer()
            Menu {
                Button("Permissions…", action: showPermissions)
                Divider()
                Button("Quit ScreenCap") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct LevelMeter: View {
    let mic: MicEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green).frame(width: geometry.size.width * CGFloat(mic.level))
                }
            }
        }
        .frame(width: 160, height: 4)
        .accessibilityLabel("Microphone level")
    }
}
