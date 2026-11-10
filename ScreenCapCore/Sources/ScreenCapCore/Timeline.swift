import Foundation

/// Maps between source time (the raw recording) and output time (what plays after trims and cuts).
public struct Timeline: Equatable, Sendable {
    /// Kept source ranges, ascending and non-overlapping. They play back to back.
    public let segments: [TimeRange]

    public init(duration: Double, edits: EditDecisions) {
        let low = max(0, min(edits.trimStart, duration))
        let high = max(low, min(duration, edits.trimEnd ?? duration))
        var kept: [TimeRange] = []
        var cursor = low
        for cut in edits.cuts.sorted(by: { $0.start < $1.start }) {
            let start = max(cut.start, low), end = min(cut.end, high)
            guard end > start else { continue }
            if start > cursor { kept.append(TimeRange(cursor, start)) }
            cursor = max(cursor, end)
        }
        if high > cursor { kept.append(TimeRange(cursor, high)) }
        segments = kept
    }

    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    public func sourceTime(forOutput time: Double) -> Double {
        var offset = 0.0
        for segment in segments {
            if time < offset + segment.duration { return segment.start + max(0, time - offset) }
            offset += segment.duration
        }
        return segments.last?.end ?? 0
    }

    /// Source times that were removed map to the point where the removal happens.
    public func outputTime(forSource time: Double) -> Double {
        var offset = 0.0
        for segment in segments {
            if time < segment.start { return offset }
            if time < segment.end { return offset + (time - segment.start) }
            offset += segment.duration
        }
        return offset
    }

    /// Where a source range lands in the output, or nil if none of it survives.
    public func outputRange(forSource range: TimeRange) -> TimeRange? {
        let start = outputTime(forSource: range.start), end = outputTime(forSource: range.end)
        return end - start > 0.0001 ? TimeRange(start, end) : nil
    }

    /// The kept segments, further divided at the user's split points. Source ranges.
    public func clips(splits: [Double]) -> [TimeRange] {
        segments.flatMap { segment -> [TimeRange] in
            let points = [segment.start] + splits.filter { $0 > segment.start + 0.001 && $0 < segment.end - 0.001 }.sorted() + [segment.end]
            return zip(points, points.dropFirst()).map { TimeRange($0, $1) }
        }
    }
}
