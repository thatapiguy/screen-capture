import AVFoundation
import SwiftUI
import ScreenCapCore

/// The single editor window: preview and inspector on top, transport and timeline below.
struct EditorView: View {
    @State var model: EditorModel
    @State private var showsExport = false
    @State private var timelineZoom = 1.0

    var body: some View {
        Group {
            if let error = model.loadError {
                ContentUnavailableView("Couldn't open this recording", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !model.isLoaded {
                ProgressView("Opening…")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        PreviewView(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(nsColor: .underPageBackgroundColor))
                        Divider()
                        Inspector(model: model)
                            .frame(width: 270)
                    }
                    Divider()
                    transport
                    Divider()
                    EditorTimeline(model: model, zoom: timelineZoom)
                        .frame(height: 190)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .task { await model.load() }
        .sheet(isPresented: $showsExport) { ExportSheet(model: model) }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")

            Text("\(Self.timecode(model.playhead)) / \(Self.timecode(model.timeline.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
                .keyboardShortcut("s", modifiers: [])
                .help("Split the clip at the playhead (S)")
            Button { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.selection == .none)
                .help("Delete the selected clip or segment (⌫). Deleting a clip closes the gap.")
            Menu {
                Button("Trim Start to Playhead") { model.trimStartToPlayhead() }.keyboardShortcut("[", modifiers: [])
                Button("Trim End to Playhead") { model.trimEndToPlayhead() }.keyboardShortcut("]", modifiers: [])
                Divider()
                Button("Restore Removed Sections") { model.restoreRemovedSections() }.disabled(!model.hasRemovedSections)
            } label: {
                Label("Trim", systemImage: "timeline.selection")
            }
            .fixedSize()

            Divider().frame(height: 16)

            Button { model.addZoomAtPlayhead() } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                .keyboardShortcut("z", modifiers: [])
                .help("Add a zoom at the playhead (Z)")
            if model.hasCamera {
                Button { model.addCameraHideAtPlayhead() } label: { Label("Hide Camera", systemImage: "video.slash") }
                    .help("Hide the camera for a stretch starting at the playhead")
            }

            Spacer()

            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $timelineZoom, in: 1...20).frame(width: 110).help("Timeline zoom")

            Button("Export…") { showsExport = true }
                .keyboardShortcut("e")
                .buttonStyle(.borderedProminent)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            // Frame stepping has no visible control; these only exist for their shortcuts.
            Group {
                Button("") { model.step(frames: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { model.step(frames: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { model.select(.none) }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    static func timecode(_ seconds: Double) -> String {
        let total = max(0, seconds)
        return String(format: "%02d:%02d.%02d", Int(total) / 60, Int(total) % 60, Int(total * 100) % 100)
    }
}

// MARK: - Preview

struct PreviewView: View {
    let model: EditorModel
    @State private var dragStart: (center: CGPoint, scale: Double)?

    var body: some View {
        let canvas = model.previewCanvas
        PlayerLayerView(player: model.player)
            .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
            .overlay {
                if model.showsFraming, let region = model.selectedZoom {
                    GeometryReader { geometry in framing(region, in: geometry.size) }
                }
            }
            .padding(16)
    }

    /// The rectangle shows what the selected zoom frames. Drag it to move, drag its corner to change the zoom level.
    private func framing(_ region: ZoomRegion, in size: CGSize) -> some View {
        let screen = Layout.screenFrame(canvas: size, background: model.edits.background)
        let visible = Layout.visibleRect(scale: region.scale, center: region.focus)
        let rect = CGRect(x: screen.minX + visible.minX * screen.width, y: screen.minY + visible.minY * screen.height,
                          width: visible.width * screen.width, height: visible.height * screen.height)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = begin(region, visible: visible)
                        let center = CGPoint(x: start.center.x + value.translation.width / screen.width,
                                             y: start.center.y + value.translation.height / screen.height)
                        setFraming(region.id, center: center, scale: start.scale)
                    }
                    .onEnded { _ in end() })
                .offset(x: rect.minX, y: rect.minY)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                .frame(width: 14, height: 14)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = begin(region, visible: visible)
                        // The top-left corner stays put while the opposite corner follows the pointer.
                        let width = min(1 / ZoomRegion.scaleRange.lowerBound,
                                        max(1 / ZoomRegion.scaleRange.upperBound, 1 / start.scale + value.translation.width / screen.width))
                        let origin = CGPoint(x: start.center.x - 0.5 / start.scale, y: start.center.y - 0.5 / start.scale)
                        setFraming(region.id, center: CGPoint(x: origin.x + width / 2, y: origin.y + width / 2), scale: 1 / width)
                    }
                    .onEnded { _ in end() })
                .offset(x: rect.maxX - 7, y: rect.maxY - 7)
                .help("Drag to change the zoom level")
        }
    }

    private func begin(_ region: ZoomRegion, visible: CGRect) -> (center: CGPoint, scale: Double) {
        if let dragStart { return dragStart }
        // Start from the clamped rectangle that is actually drawn, not a focus point that may sit near an edge.
        let start = (center: CGPoint(x: visible.midX, y: visible.midY), scale: region.scale)
        dragStart = start
        return start
    }

    private func setFraming(_ id: UUID, center: CGPoint, scale: Double) {
        let half = 0.5 / scale
        let clamped = CGPoint(x: min(max(center.x, half), 1 - half), y: min(max(center.y, half), 1 - half))
        model.updateZoom(id) {
            $0.focus = clamped
            $0.scale = scale
            // Choosing an exact frame means it should stay there.
            $0.followsCursor = false
        }
    }

    private func end() {
        dragStart = nil
        model.commit()
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Export

struct ExportSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("export.codec") private var codec = ExportSettings.Codec.h264
    @AppStorage("export.resolution") private var resolution = ExportSettings.Resolution.source
    @AppStorage("export.fps") private var fps = 60
    @AppStorage("export.quality") private var quality = ExportSettings.Quality.balanced

    private var settings: ExportSettings {
        var settings = ExportSettings()
        settings.codec = codec
        settings.resolution = resolution
        settings.fps = fps
        settings.quality = quality
        return settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title3.bold())
            switch model.exportState {
            case .exporting(let fraction):
                ProgressView(value: fraction) { Text("Exporting… \(Int(fraction * 100))%") }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelExport() }.keyboardShortcut(.cancelAction)
                }
            case .done(let url):
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack {
                    Spacer()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                }
            case .idle, .failed:
                if case .failed(let message) = model.exportState {
                    Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                form
                HStack {
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    Button("Export…") { chooseDestination() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var form: some View {
        Form {
            Picker("Format", selection: $codec) {
                Text("H.264 (most compatible)").tag(ExportSettings.Codec.h264)
                Text("HEVC (smaller files)").tag(ExportSettings.Codec.hevc)
            }
            Picker("Resolution", selection: $resolution) {
                Text("1080p").tag(ExportSettings.Resolution.p1080)
                Text("1440p").tag(ExportSettings.Resolution.p1440)
                Text("4K").tag(ExportSettings.Resolution.p2160)
                Text("Source size").tag(ExportSettings.Resolution.source)
            }
            Picker("Frame rate", selection: $fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Quality", selection: $quality) {
                Text("Small").tag(ExportSettings.Quality.small)
                Text("Balanced").tag(ExportSettings.Quality.balanced)
                Text("High").tag(ExportSettings.Quality.high)
            }
            if let info = model.info {
                let size = settings.renderSize(source: CGSize(width: info.width, height: info.height))
                let megabytes = Double(settings.videoBitrate(size: size) + 192_000) / 8 * model.timeline.duration / 1_000_000
                LabeledContent("Output", value: "\(Int(size.width)) × \(Int(size.height)), about \(Int(megabytes.rounded())) MB")
            }
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = model.bundle.name + ".mp4"
        if panel.runModal() == .OK, let url = panel.url {
            model.export(settings, to: url)
        }
    }

    private func close() {
        model.exportState = .idle
        dismiss()
    }
}
