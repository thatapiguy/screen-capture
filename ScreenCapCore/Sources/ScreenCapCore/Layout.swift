import Foundation

/// Where things sit on the output canvas. Shared by the compositor and the editor's overlays.
/// Rects use a top-left origin, in canvas pixels.
public enum Layout {
    public static func screenFrame(canvas: CGSize, background: Background) -> CGRect {
        guard background.enabled else { return CGRect(origin: .zero, size: canvas) }
        let inset = min(canvas.width, canvas.height) * background.padding
        return CGRect(origin: .zero, size: canvas).insetBy(dx: inset, dy: inset * canvas.height / canvas.width)
    }

    public static func cameraFrame(canvas: CGSize, camera: CameraLayout) -> CGRect {
        let shortSide = min(canvas.width, canvas.height)
        let side = shortSide * camera.size
        let margin = shortSide * 0.035
        let left = camera.corner == .topLeft || camera.corner == .bottomLeft
        let top = camera.corner == .topLeft || camera.corner == .topRight
        return CGRect(x: left ? margin : canvas.width - margin - side,
                      y: top ? margin : canvas.height - margin - side, width: side, height: side)
    }

    /// The part of the recording (normalised) that a zoom of `scale` around `center` shows.
    public static func visibleRect(scale: Double, center: CGPoint) -> CGRect {
        let size = 1 / max(1, scale)
        let x = min(max(center.x - size / 2, 0), 1 - size)
        let y = min(max(center.y - size / 2, 0), 1 - size)
        return CGRect(x: x, y: y, width: size, height: size)
    }
}

public struct ExportSettings: Equatable, Sendable {
    public enum Codec: String, CaseIterable, Sendable { case h264, hevc }
    public enum Resolution: String, CaseIterable, Sendable { case p1080, p1440, p2160, source }
    public enum Quality: String, CaseIterable, Sendable { case small, balanced, high }

    public var codec = Codec.h264
    public var resolution = Resolution.source
    public var fps = 60
    public var quality = Quality.balanced

    public init() {}

    /// Output size: the source aspect ratio fitted inside the chosen resolution, never enlarged.
    public func renderSize(source: CGSize) -> CGSize {
        let box: CGSize? = switch resolution {
        case .p1080: CGSize(width: 1920, height: 1080)
        case .p1440: CGSize(width: 2560, height: 1440)
        case .p2160: CGSize(width: 3840, height: 2160)
        case .source: nil
        }
        var factor = 1.0
        if let box { factor = min(1, box.width / source.width, box.height / source.height) }
        func even(_ value: Double) -> Double { max(2, (value * factor / 2).rounded() * 2) }
        return CGSize(width: even(source.width), height: even(source.height))
    }

    public func videoBitrate(size: CGSize) -> Int {
        let bitsPerPixel: Double = switch quality {
        case .small: 0.035
        case .balanced: 0.07
        case .high: 0.13
        }
        let codecFactor = codec == .hevc ? 0.65 : 1
        // Doubling the frame rate needs well under double the bits.
        let rateFactor = fps > 30 ? 1.5 : 1
        return max(1_000_000, Int(size.width * size.height * 30 * bitsPerPixel * codecFactor * rateFactor))
    }
}
