import Foundation

public enum ResolutionCap: String, CaseIterable, Codable, Sendable {
    case native, p1440, p1080

    /// Bounding box in pixels the recording must fit inside; nil means no cap.
    public var box: (width: Double, height: Double)? {
        switch self {
        case .native: nil
        case .p1440: (2560, 1440)
        case .p1080: (1920, 1080)
        }
    }
}

public enum CaptureGeometry {
    /// Pixel size to record at: the source's native pixels, scaled down (never up) to fit the cap.
    /// Dimensions are rounded to even numbers because the video encoder requires them.
    public static func outputSize(points: CGSize, scale: Double, cap: ResolutionCap) -> (width: Int, height: Int) {
        var width = Double(points.width) * scale
        var height = Double(points.height) * scale
        if let box = cap.box, width > 0, height > 0 {
            let factor = min(1, box.width / width, box.height / height)
            width *= factor
            height *= factor
        }
        return (even(width), even(height))
    }

    /// Target bitrate for the raw screen track. Generous, because the editor zooms into this footage.
    public static func screenBitrate(width: Int, height: Int, fps: Int) -> Int {
        let bitsPerPixelPerFrame = 0.05
        return max(4_000_000, Int(Double(width * height * fps) * bitsPerPixelPerFrame))
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }
}
