import Foundation

/// The virtual camera over the whole recording: zoom scale and centre, sampled at a fixed step.
/// It is precomputed from the regions and cursor data, so any frame can be rendered from its
/// time alone and scrubbing, playback and export all show exactly the same motion.
public struct ZoomPath: Sendable {
    public let step: Double
    let scales: [Float]
    let xs: [Float]
    let ys: [Float]

    public static let identity = ZoomPath(step: 1, scales: [], xs: [], ys: [])

    public func sample(at time: Double) -> (scale: Double, center: CGPoint) {
        guard !scales.isEmpty else { return (1, CGPoint(x: 0.5, y: 0.5)) }
        let position = max(0, min(Double(scales.count - 1), time / step))
        let i = Int(position), j = min(i + 1, scales.count - 1)
        let f = Float(position - Double(i))
        return (Double(scales[i] + (scales[j] - scales[i]) * f),
                CGPoint(x: Double(xs[i] + (xs[j] - xs[i]) * f), y: Double(ys[i] + (ys[j] - ys[i]) * f)))
    }
}

public enum ZoomCamera {
    /// The cursor can roam this fraction of the visible half-width before the camera follows,
    /// which keeps the frame still during small movements instead of jittering along.
    static let deadZone = 0.45
    static let scaleOmega = 5.5
    static let panOmega = 4.5

    public static func path(regions: [ZoomRegion], cursor: CursorTrack, duration: Double, step: Double = 1.0 / 60) -> ZoomPath {
        let regions = regions.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !regions.isEmpty, duration > 0 else { return .identity }
        let count = Int(duration / step) + 2
        var scales = [Float](), xs = [Float](), ys = [Float]()
        scales.reserveCapacity(count)
        xs.reserveCapacity(count)
        ys.reserveCapacity(count)

        var scale = Spring(value: 1), x = Spring(value: 0.5), y = Spring(value: 0.5)
        var aim = CGPoint(x: 0.5, y: 0.5)
        var activeID: UUID?
        var next = 0
        for index in 0..<count {
            let time = Double(index) * step
            while next < regions.count, regions[next].end <= time { next += 1 }
            let region = next < regions.count && regions[next].start <= time ? regions[next] : nil

            if let region {
                let cursorPoint = region.followsCursor ? cursor.position(at: time) : nil
                if let cursorPoint {
                    if activeID != region.id {
                        aim = cursorPoint
                    } else {
                        let reach = 0.5 / region.scale * deadZone
                        aim.x = min(max(aim.x, cursorPoint.x - reach), cursorPoint.x + reach)
                        aim.y = min(max(aim.y, cursorPoint.y - reach), cursorPoint.y + reach)
                    }
                } else {
                    aim = region.focus
                }
            }
            activeID = region?.id

            scale.step(toward: region?.scale ?? 1, omega: scaleOmega, dt: step)
            x.step(toward: aim.x, omega: panOmega, dt: step)
            y.step(toward: aim.y, omega: panOmega, dt: step)
            // Keep the framed area inside the recording. Writing the clamp back also recentres
            // the camera whenever it is fully zoomed out, so the next zoom starts from the middle.
            let half = 0.5 / max(1, scale.value)
            x.value = min(max(x.value, half), 1 - half)
            y.value = min(max(y.value, half), 1 - half)

            scales.append(Float(max(1, scale.value)))
            xs.append(Float(x.value))
            ys.append(Float(y.value))
        }
        return ZoomPath(step: step, scales: scales, xs: xs, ys: ys)
    }
}

public enum AutoZoom {
    struct Tuning {
        var scale: Double
        /// Clicks needed in a burst before it earns a zoom.
        var minClicks: Int
        /// Typing counts as focus too.
        var includesTyping: Bool
    }

    static func tuning(_ sensitivity: Sensitivity) -> Tuning? {
        switch sensitivity {
        case .off: nil
        case .subtle: Tuning(scale: 1.5, minClicks: 2, includesTyping: false)
        case .normal: Tuning(scale: 1.8, minClicks: 1, includesTyping: true)
        case .strong: Tuning(scale: 2.3, minClicks: 1, includesTyping: true)
        }
    }

    /// Activity closer together than this belongs to one zoom.
    static let joinGap = 3.0
    /// Start slightly before the first click so the zoom has landed when it happens.
    static let lead = 0.35
    /// How long to stay zoomed after the last activity before easing back out.
    static let hold = 1.8

    /// Zoom regions for bursts of clicking and typing. Pure: the same events always give the same regions.
    public static func regions(events: [RecordedEvent], duration: Double, sensitivity: Sensitivity) -> [ZoomRegion] {
        guard let tuning = tuning(sensitivity) else { return [] }
        let activity = events.filter { $0.kind == .down || (tuning.includesTyping && $0.kind == .key) }
        var regions: [ZoomRegion] = []
        var burst: [RecordedEvent] = []

        func flush() {
            defer { burst = [] }
            guard let first = burst.first, let last = burst.last else { return }
            let clicks = burst.filter { $0.kind == .down }
            // Typing alone has no click to anchor on unless it follows one, so it only extends bursts.
            guard clicks.count >= tuning.minClicks, let anchor = clicks.first else { return }
            let start = max(0, first.t - lead), end = min(duration, last.t + hold)
            guard end - start > 0.5 else { return }
            regions.append(ZoomRegion(start: start, end: end, scale: tuning.scale,
                                      focus: CGPoint(x: anchor.x, y: anchor.y), followsCursor: true, origin: .auto))
        }

        for event in activity {
            if let last = burst.last, event.t - last.t > joinGap { flush() }
            burst.append(event)
        }
        flush()
        return regions
    }

    /// Regions for the "zoom here" hotkey: each press toggles zoom at the cursor.
    public static func markerRegions(events: [RecordedEvent], duration: Double, scale: Double = 2) -> [ZoomRegion] {
        var regions: [ZoomRegion] = []
        var open: RecordedEvent?
        for event in events {
            if event.kind == .zoomOn, open == nil {
                open = event
            } else if event.kind == .zoomOff, let start = open {
                regions.append(ZoomRegion(start: start.t, end: event.t, scale: scale,
                                          focus: CGPoint(x: start.x, y: start.y), followsCursor: true, origin: .marker))
                open = nil
            }
        }
        if let start = open, duration > start.t {
            regions.append(ZoomRegion(start: start.t, end: duration, scale: scale,
                                      focus: CGPoint(x: start.x, y: start.y), followsCursor: true, origin: .marker))
        }
        return regions
    }

    /// Auto regions that don't collide with ones the user placed (markers or manual edits).
    public static func merged(auto: [ZoomRegion], keeping kept: [ZoomRegion]) -> [ZoomRegion] {
        let free = auto.filter { candidate in
            !kept.contains { $0.start < candidate.end && candidate.start < $0.end }
        }
        return (kept + free).sorted { $0.start < $1.start }
    }
}
