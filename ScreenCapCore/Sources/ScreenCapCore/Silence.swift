import Foundation

public enum Silence {
    /// Stretches of dead air worth cutting, from audio peak levels (`rate` peaks per second).
    /// A little quiet is left on each side so speech doesn't sound clipped together.
    public static func ranges(peaks: [Float], rate: Double, minDuration: Double = 1.2, padding: Double = 0.2) -> [TimeRange] {
        // If nothing is clearly audible (muted mic), "silence" would be the whole recording.
        guard let loudest = peaks.max(), loudest > 0.02, rate > 0 else { return [] }
        let threshold = max(0.01, loudest * 0.06)
        var result: [TimeRange] = []
        var runStart: Int?
        for index in 0...peaks.count {
            let quiet = index < peaks.count && peaks[index] < threshold
            if quiet {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runStart = nil
                let from = Double(start) / rate, to = Double(index) / rate
                if to - from >= minDuration { result.append(TimeRange(from + padding, to - padding)) }
            }
        }
        return result
    }
}
