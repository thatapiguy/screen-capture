import SwiftUI
import ScreenCapCore

/// Clips, camera, audio waveform and zoom segments, laid out in output time (after cuts).
struct EditorTimeline: View {
    let model: EditorModel
    /// 1 fits the whole recording in the window.
    let zoom: Double

    private let gutter: CGFloat = 64
    private let rulerHeight: CGFloat = 20
    private let clipHeight: CGFloat = 34
    private let rowHeight: CGFloat = 24
    private let waveHeight: CGFloat = 34
    private let spacing: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let duration = max(0.1, model.timeline.duration)
            let width = Double(max(100, geometry.size.width - gutter - 12)) * zoom
            let pps = width / duration
            HStack(alignment: .top, spacing: 0) {
                labels.frame(width: gutter)
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: spacing) {
                            ruler(duration: duration, pps: pps)
                            clips(pps: pps)
                            if model.hasCamera { cameraRow(width: width, pps: pps) }
                            if !model.waveform.isEmpty { waveformRow(width: width, pps: pps) }
                            zoomRow(width: width, pps: pps)
                        }
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 1.5)
                            .offset(x: model.playhead * pps)
                            .allowsHitTesting(false)
                    }
                    .frame(width: width, alignment: .topLeading)
                    .padding(.trailing, 12)
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var labels: some View {
        VStack(alignment: .trailing, spacing: spacing) {
            Color.clear.frame(height: rulerHeight)
            label("Screen", clipHeight)
            if model.hasCamera { label("Camera", rowHeight) }
            if !model.waveform.isEmpty { label("Audio", waveHeight) }
            label("Zoom", rowHeight)
        }
        .padding(.trailing, 8)
    }

    private func label(_ text: String, _ height: CGFloat) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(height: height)
    }

    /// Click or drag on the ruler to scrub.
    private func ruler(duration: Double, pps: Double) -> some View {
        Canvas { context, size in
            // Aim for a label roughly every 80 points whatever the zoom.
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let step = steps.first { $0 * pps >= 80 } ?? 600
            var time = 0.0
            while time <= duration {
                let x = time * pps
                context.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.secondary.opacity(0.6)))
                let text = Text(String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)).font(.caption2).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: x + 3, y: 6), anchor: .leading)
                time += step
            }
        }
        .frame(height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            model.seek(toOutput: value.location.x / pps)
        })
    }

    private func clips(pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.timeline.clips(splits: model.edits.splits).enumerated()), id: \.offset) { _, clip in
                if let range = model.timeline.outputRange(forSource: clip) {
                    let selected = model.selection == .clip(clip)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(selected ? 0.55 : 0.28))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                        .frame(width: max(2, range.duration * pps - 1.5), height: clipHeight)
                        .offset(x: range.start * pps)
                        .onTapGesture {
                            model.select(selected ? .none : .clip(clip))
                        }
                }
            }
        }
        .frame(height: clipHeight, alignment: .topLeading)
    }

    private func cameraRow(width: Double, pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.teal.opacity(model.edits.camera.enabled ? 0.3 : 0.1))
                .frame(width: width, height: rowHeight)
                .onTapGesture { model.select(.none) }
            ForEach(model.edits.cameraHidden) { span in
                if let range = model.timeline.outputRange(forSource: TimeRange(span.start, span.end)) {
                    SegmentBar(model: model, target: .cameraHide(span.id), range: range, pps: pps, height: rowHeight,
                               color: .gray, title: "Hidden")
                }
            }
        }
        .frame(height: rowHeight, alignment: .topLeading)
    }

    private func waveformRow(width: Double, pps: Double) -> some View {
        let waveform = model.waveform, rate = model.waveformRate, timeline = model.timeline
        return Canvas { context, size in
            var path = Path()
            let middle = size.height / 2
            // One bar per 2 points, each showing the loudest bucket it covers.
            for x in stride(from: 0.0, to: size.width, by: 2) {
                let from = Int(timeline.sourceTime(forOutput: x / pps) * rate)
                let to = max(from, Int(timeline.sourceTime(forOutput: (x + 2) / pps) * rate))
                guard from < waveform.count else { break }
                let peak = waveform[from...min(to, waveform.count - 1)].max() ?? 0
                let height = max(1, CGFloat(peak) * size.height)
                path.addRect(CGRect(x: x, y: middle - height / 2, width: 1.2, height: height))
            }
            context.fill(path, with: .color(.green.opacity(0.75)))
        }
        .frame(width: width, height: waveHeight)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.08)))
    }

    private func zoomRow(width: Double, pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: width, height: rowHeight)
                .onTapGesture { model.select(.none) }
            ForEach(model.edits.zoomRegions) { region in
                if let range = model.timeline.outputRange(forSource: TimeRange(region.start, region.end)) {
                    SegmentBar(model: model, target: .zoom(region.id), range: range, pps: pps, height: rowHeight,
                               color: .purple, title: String(format: "%.1f×", region.scale))
                }
            }
        }
        .frame(height: rowHeight, alignment: .topLeading)
    }
}

/// A draggable, resizable segment (zoom region or camera-hidden span).
private struct SegmentBar: View {
    let model: EditorModel
    let target: Selection
    /// Output-time range.
    let range: TimeRange
    let pps: Double
    let height: CGFloat
    let color: Color
    let title: String

    var body: some View {
        let selected = model.selection == target
        let width = max(8, range.duration * pps)
        RoundedRectangle(cornerRadius: 5)
            .fill(color.opacity(selected ? 0.85 : 0.55))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.primary.opacity(0.8) : .clear, lineWidth: 1.5))
            .overlay(Text(title).font(.caption2).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 8), alignment: .leading)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(drag(.move))
            .overlay(alignment: .leading) { handle(.start) }
            .overlay(alignment: .trailing) { handle(.end) }
            .offset(x: range.start * pps)
            .help("Drag to move, drag an edge to resize")
    }

    private func handle(_ mode: DragMode) -> some View {
        Color.clear
            .frame(width: 7, height: height)
            .contentShape(Rectangle())
            .gesture(drag(mode))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func drag(_ mode: DragMode) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.select(target)
                if abs(value.translation.width) > 1 {
                    model.drag(target, mode: mode, delta: value.translation.width / pps)
                }
            }
            .onEnded { _ in model.commit() }
    }
}
