import CoreGraphics
import Foundation

// MARK: - Bundle files

/// `project.json`: facts about the raw recording. Written by the recorder, never by the editor.
public struct ProjectInfo: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case recording, complete }

    public var version = 1
    public var createdAt: Date
    /// `recording` on disk after launch means the app died mid-recording.
    public var state: State
    /// Screen track size in pixels.
    public var width: Int
    public var height: Int
    /// Screen track pixels per screen point (after any resolution cap); sizes the redrawn cursor.
    public var scale: Double
    public var fps: Int
    public var cameraMirrored: Bool
    public var cameraShape: CameraShape

    public init(createdAt: Date, state: State, width: Int, height: Int, scale: Double, fps: Int,
                cameraMirrored: Bool, cameraShape: CameraShape) {
        self.createdAt = createdAt
        self.state = state
        self.width = width
        self.height = height
        self.scale = scale
        self.fps = fps
        self.cameraMirrored = cameraMirrored
        self.cameraShape = cameraShape
    }
}

public enum ReelJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

// MARK: - Edit decisions (`edits.json`)

/// A span of source time, in seconds from the start of the recording.
public struct TimeRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }

    public init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = end
    }

    public func contains(_ time: Double) -> Bool { time >= start && time < end }
}

public struct Span: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public struct ZoomRegion: Codable, Equatable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable { case auto, marker, manual }

    public var id = UUID()
    /// Source time, so cuts and trims never invalidate a region.
    public var start: Double
    public var end: Double
    public var scale: Double
    /// Normalised centre of the framed area (0…1, origin top-left).
    public var focus: CGPoint
    /// Follow the cursor with damping, or stay locked on `focus`.
    public var followsCursor: Bool
    public var origin: Origin

    public static let scaleRange = 1.2...4.0

    public init(start: Double, end: Double, scale: Double, focus: CGPoint, followsCursor: Bool, origin: Origin) {
        self.start = start
        self.end = end
        self.scale = scale
        self.focus = focus
        self.followsCursor = followsCursor
        self.origin = origin
    }
}

public enum CameraShape: String, Codable, CaseIterable, Sendable { case circle, rounded }
public enum Corner: String, Codable, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

public struct CameraLayout: Codable, Equatable, Sendable {
    public var enabled = true
    public var corner = Corner.bottomRight
    /// Side length as a fraction of the canvas's shorter side.
    public var size = 0.22
    public var shape = CameraShape.circle
    public var border = true
    public var mirrored = true
    public init() {}
}

public struct Background: Codable, Equatable, Sendable {
    public var enabled = false
    /// Index into `Background.presets`.
    public var preset = 0
    /// Padding as a fraction of the canvas's shorter side.
    public var padding = 0.06
    /// Corner radius as a fraction of the canvas's shorter side.
    public var cornerRadius = 0.02
    public var shadow = true
    public init() {}

    /// Each preset is one colour (solid) or two (top-left to bottom-right gradient), as 0xRRGGBB.
    public static let presets: [[UInt32]] = [
        [0x5B6CFF, 0xC86DD7], [0x0F2027, 0x2C5364], [0xFF9966, 0xFF5E62],
        [0x11998E, 0x38EF7D], [0x1E1E1E], [0xF2F2F2],
    ]
}

public struct CursorStyle: Codable, Equatable, Sendable {
    public var visible = true
    public var scale = 1.5
    /// 0 = raw recorded motion, 1 = heavily smoothed.
    public var smoothing = 0.4
    public var highlightClicks = true
    public init() {}
}

public struct Volumes: Codable, Equatable, Sendable {
    public var mic = 1.0
    public var system = 1.0
    public init() {}
}

public enum Sensitivity: String, Codable, CaseIterable, Sendable { case off, subtle, normal, strong }

public struct EditDecisions: Codable, Equatable, Sendable {
    public var trimStart = 0.0
    /// nil keeps everything to the end of the recording.
    public var trimEnd: Double?
    /// Removed source ranges (ripple-deleted).
    public var cuts: [TimeRange] = []
    /// Source times where the user split a clip.
    public var splits: [Double] = []
    public var zoomRegions: [ZoomRegion] = []
    public var camera = CameraLayout()
    public var cameraHidden: [Span] = []
    public var background = Background()
    public var cursor = CursorStyle()
    public var volumes = Volumes()

    public init() {}

    public mutating func split(at time: Double) {
        guard !splits.contains(where: { abs($0 - time) < 0.01 }) else { return }
        splits.append(time)
        splits.sort()
    }

    /// Ripple-deletes a source range, merging it with any cuts it touches.
    public mutating func delete(_ range: TimeRange) {
        var merged = range
        var remaining: [TimeRange] = []
        for cut in cuts {
            if cut.end < merged.start || cut.start > merged.end {
                remaining.append(cut)
            } else {
                merged = TimeRange(min(merged.start, cut.start), max(merged.end, cut.end))
            }
        }
        cuts = (remaining + [merged]).sorted { $0.start < $1.start }
        splits.removeAll { $0 > merged.start - 0.001 && $0 < merged.end + 0.001 }
    }
}
