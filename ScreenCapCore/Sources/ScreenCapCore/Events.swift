import CoreGraphics
import Foundation

/// Which system cursor was showing, so the redrawn cursor matches (I-beam over text, hand over links).
public enum CursorShape: String, Codable, CaseIterable, Sendable {
    case arrow, iBeam, pointingHand, crosshair, openHand, closedHand, resizeLeftRight, resizeUpDown
}

/// One line of `events.jsonl`. Positions are normalised to the captured area (0…1, origin top-left).
public struct RecordedEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case move = "m", down = "d", up = "u"
        /// Keystroke activity: timing only, never which key.
        case key = "k"
        case zoomOn = "z+", zoomOff = "z-"
        /// The cursor changed shape; `shape` says to what.
        case cursor = "c"
    }

    public var t: Double
    public var kind: Kind
    public var x: Double
    public var y: Double
    public var shape: CursorShape?

    public init(t: Double, kind: Kind, x: Double, y: Double, shape: CursorShape? = nil) {
        self.t = t
        self.kind = kind
        self.x = x
        self.y = y
        self.shape = shape
    }
}

public enum EventLog {
    public static func line(_ event: RecordedEvent) -> String {
        let shape = event.shape.map { ",\"s\":\"\($0.rawValue)\"" } ?? ""
        return String(format: "{\"t\":%.4f,\"k\":\"%@\",\"x\":%.5f,\"y\":%.5f%@}\n",
                      event.t, event.kind.rawValue, event.x, event.y, shape)
    }

    /// Tolerates a truncated final line, which is what a crash mid-write leaves behind.
    public static func parse(_ data: Data) -> [RecordedEvent] {
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        if let lastNewline = text.lastIndex(of: "\n") {
            text = String(text[..<lastNewline])
        } else {
            return []
        }
        // One parse of a JSON array is far faster than decoding line by line.
        let array = "[" + text.split(separator: "\n").joined(separator: ",") + "]"
        guard let rows = try? JSONSerialization.jsonObject(with: Data(array.utf8)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let t = row["t"] as? Double, let kind = (row["k"] as? String).flatMap(RecordedEvent.Kind.init),
                  let x = row["x"] as? Double, let y = row["y"] as? Double else { return nil }
            return RecordedEvent(t: t, kind: kind, x: x, y: y, shape: (row["s"] as? String).flatMap(CursorShape.init))
        }
    }
}

/// Cursor positions over time, with interpolation.
public struct CursorTrack: Sendable {
    public private(set) var times: [Double] = []
    public private(set) var xs: [Double] = []
    public private(set) var ys: [Double] = []
    public private(set) var clicks: [RecordedEvent] = []
    private var shapes: [(time: Double, shape: CursorShape)] = []

    public init(events: [RecordedEvent]) {
        for event in events {
            // Every event carries the cursor position, so all of them refine the path.
            if let last = times.last, event.t <= last { continue }
            times.append(event.t)
            xs.append(event.x)
            ys.append(event.y)
        }
        clicks = events.filter { $0.kind == .down }
        shapes = events.compactMap { event in event.shape.map { (time: event.t, shape: $0) } }
    }

    public func shape(at time: Double) -> CursorShape {
        shapes.last { $0.time <= time }?.shape ?? .arrow
    }

    public var isEmpty: Bool { times.isEmpty }

    public func position(at time: Double) -> CGPoint? {
        guard let first = times.first, let last = times.last else { return nil }
        if time <= first { return CGPoint(x: xs[0], y: ys[0]) }
        if time >= last { return CGPoint(x: xs[xs.count - 1], y: ys[ys.count - 1]) }
        var low = 0, high = times.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if times[mid] <= time { low = mid } else { high = mid }
        }
        let span = times[high] - times[low]
        let f = span > 0 ? (time - times[low]) / span : 0
        return CGPoint(x: xs[low] + (xs[high] - xs[low]) * f, y: ys[low] + (ys[high] - ys[low]) * f)
    }

    /// The same path followed by a critically damped spring, which removes hand jitter
    /// without the lag-then-overshoot of a simple average. `strength` is 0…1.
    public func smoothed(strength: Double, step: Double = 1.0 / 120) -> CursorTrack {
        guard strength > 0.01, let first = times.first, let last = times.last, last > first else { return self }
        let omega = 60 - 48 * min(1, strength)
        var result = self
        result.times.removeAll(keepingCapacity: true)
        result.xs.removeAll(keepingCapacity: true)
        result.ys.removeAll(keepingCapacity: true)
        var x = Spring(value: xs[0]), y = Spring(value: ys[0])
        var time = first
        while time <= last {
            let target = position(at: time) ?? CGPoint(x: x.value, y: y.value)
            x.step(toward: target.x, omega: omega, dt: step)
            y.step(toward: target.y, omega: omega, dt: step)
            result.times.append(time)
            result.xs.append(x.value)
            result.ys.append(y.value)
            time += step
        }
        return result
    }
}

/// Critically damped spring, integrated exactly so it is stable at any step size.
public struct Spring: Sendable {
    public var value: Double
    public var velocity = 0.0

    public init(value: Double) { self.value = value }

    public mutating func step(toward target: Double, omega: Double, dt: Double) {
        let delta = value - target
        let decay = exp(-omega * dt)
        let temp = (velocity + omega * delta) * dt
        value = target + (delta + temp) * decay
        velocity = (velocity - omega * temp) * decay
    }
}
