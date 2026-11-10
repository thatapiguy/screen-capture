import SwiftUI
import ScreenCapCore

/// Settings for the selected zoom, plus the global look: cursor, camera, background, audio.
struct Inspector: View {
    let model: EditorModel
    @AppStorage(Prefs.Key.autoZoom) private var sensitivity = Sensitivity.normal

    var body: some View {
        Form {
            if let region = model.selectedZoom {
                Section("Selected zoom") {
                    slider("Zoom level", value: zoomBinding(region, \.scale), range: ZoomRegion.scaleRange, format: "%.1f×")
                    Toggle("Follow the cursor", isOn: committed(zoomBinding(region, \.followsCursor)))
                    Text("Drag the rectangle on the preview to choose what's framed. Press play to see the result.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Delete Zoom", role: .destructive) { model.deleteSelection() }
                }
            }

            Section("Auto zoom") {
                Picker("Sensitivity", selection: $sensitivity) {
                    ForEach(Sensitivity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Button("Regenerate Zooms") { model.regenerateAutoZoom(sensitivity) }
                    .help("Rebuilds the automatic zooms from your clicks and typing. Zooms you added or adjusted are kept.")
            }

            Section("Cursor") {
                Toggle("Show cursor", isOn: toggle(\.cursor.visible))
                slider("Size", value: live(\.cursor.scale), range: 1...3, format: "%.1f×")
                slider("Smoothing", value: live(\.cursor.smoothing), range: 0...1, format: nil)
                Toggle("Highlight clicks", isOn: toggle(\.cursor.highlightClicks))
            }

            if model.hasCamera {
                Section("Camera") {
                    Toggle("Show camera", isOn: toggle(\.camera.enabled))
                    Picker("Position", selection: toggle(\.camera.corner)) {
                        Text("Top left").tag(Corner.topLeft)
                        Text("Top right").tag(Corner.topRight)
                        Text("Bottom left").tag(Corner.bottomLeft)
                        Text("Bottom right").tag(Corner.bottomRight)
                    }
                    Picker("Shape", selection: toggle(\.camera.shape)) {
                        Text("Circle").tag(CameraShape.circle)
                        Text("Rounded").tag(CameraShape.rounded)
                    }
                    .pickerStyle(.segmented)
                    slider("Size", value: live(\.camera.size), range: 0.1...0.45, format: nil)
                    Toggle("Border", isOn: toggle(\.camera.border))
                    Toggle("Mirror", isOn: toggle(\.camera.mirrored))
                }
            }

            Section("Background") {
                Toggle("Padding and background", isOn: toggle(\.background.enabled))
                if model.edits.background.enabled {
                    HStack(spacing: 6) {
                        ForEach(Background.presets.indices, id: \.self) { index in
                            swatch(index)
                        }
                    }
                    slider("Padding", value: live(\.background.padding), range: 0.02...0.15, format: nil)
                    slider("Corners", value: live(\.background.cornerRadius), range: 0...0.06, format: nil)
                    Toggle("Shadow", isOn: toggle(\.background.shadow))
                }
            }

            if model.hasMic || model.hasSystemAudio {
                Section("Audio") {
                    if model.hasMic { slider("Microphone", value: live(\.volumes.mic), range: 0...1.5, format: "%.0f%%", scale: 100) }
                    if model.hasSystemAudio { slider("System", value: live(\.volumes.system), range: 0...1.5, format: "%.0f%%", scale: 100) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Bindings. Sliders change live and close one undo step when released; toggles commit at once.

    private func live<T>(_ keyPath: WritableKeyPath<EditDecisions, T>) -> Binding<T> {
        Binding(get: { model.edits[keyPath: keyPath] }, set: { value in model.live { $0[keyPath: keyPath] = value } })
    }

    private func toggle<T>(_ keyPath: WritableKeyPath<EditDecisions, T>) -> Binding<T> {
        committed(live(keyPath))
    }

    private func committed<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { value in
            binding.wrappedValue = value
            model.commit()
        })
    }

    private func zoomBinding<T>(_ region: ZoomRegion, _ keyPath: WritableKeyPath<ZoomRegion, T>) -> Binding<T> {
        Binding(
            get: { (model.edits.zoomRegions.first { $0.id == region.id } ?? region)[keyPath: keyPath] },
            set: { value in model.updateZoom(region.id) { $0[keyPath: keyPath] = value } })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String?, scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range) { editing in
                    if !editing { model.commit() }
                }
                if let format {
                    Text(String(format: format, value.wrappedValue * scale))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private func swatch(_ index: Int) -> some View {
        let colors = Background.presets[index].map { hex in
            Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        return Circle()
            .fill(LinearGradient(colors: colors.count > 1 ? colors : colors + colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Circle().strokeBorder(model.edits.background.preset == index ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 2))
            .frame(width: 24, height: 24)
            .onTapGesture { model.apply { $0.background.preset = index } }
            .accessibilityLabel("Background \(index + 1)")
    }
}
