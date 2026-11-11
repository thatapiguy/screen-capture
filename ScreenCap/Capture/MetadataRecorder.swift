import AppKit
@preconcurrency import AVFoundation
import ScreenCapCore

/// Writes `events.jsonl`: cursor path, clicks, keystroke timing and zoom markers.
///
/// Everything is polled from system-wide counters rather than an event tap, so it needs no
/// Input Monitoring permission and can never see which keys were pressed, only that one was.
final class MetadataRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "screencap.metadata", qos: .utility)
    private let timer: DispatchSourceTimer
    /// The current system cursor can only be read on the main thread.
    private let shapeTimer = DispatchSource.makeTimerSource(queue: .main)
    private var lastShape = CursorShape.arrow
    private let handle: FileHandle
    private let clock: SessionClock
    /// Captured area in global display points (origin top-left), used to normalise positions.
    private let captureRect: CGRect

    private var pending = ""
    private var lastFlush = Date()
    private var lastPoint = CGPoint(x: -1, y: -1)
    private var counts: [CGEventType: UInt32] = [:]
    private var lastKeyTime = -1.0
    private var zoomOn = false

    init(url: URL, clock: SessionClock, captureRect: CGRect) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.clock = clock
        self.captureRect = captureRect
        timer = DispatchSource.makeTimerSource(queue: queue)
    }

    func start() {
        timer.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()

        shapeTimer.schedule(deadline: .now(), repeating: 1.0 / 15, leeway: .milliseconds(10))
        shapeTimer.setEventHandler { [weak self] in
            let shape = MainActor.assumeIsolated { CursorShape.current }
            self?.queue.async { self?.record(shape) }
        }
        shapeTimer.resume()
    }

    private func record(_ shape: CursorShape) {
        guard shape != lastShape, let time = clock.position(for: SessionClock.hostNow)?.seconds, let point = cursor() else { return }
        lastShape = shape
        write(RecordedEvent(t: time, kind: .cursor, x: point.x, y: point.y, shape: shape))
    }

    func stop() {
        shapeTimer.cancel()
        timer.cancel()
        queue.sync {
            flush()
            try? handle.close()
        }
    }

    /// "Zoom here" hotkey: toggles a zoom marker at the cursor.
    func toggleZoom() {
        queue.async { [self] in
            guard let time = clock.position(for: SessionClock.hostNow)?.seconds, let point = cursor() else { return }
            zoomOn.toggle()
            write(RecordedEvent(t: time, kind: zoomOn ? .zoomOn : .zoomOff, x: point.x, y: point.y))
            flush()
        }
    }

    private func cursor() -> CGPoint? {
        guard let location = CGEvent(source: nil)?.location, captureRect.width > 0, captureRect.height > 0 else { return nil }
        return CGPoint(x: (location.x - captureRect.minX) / captureRect.width,
                       y: (location.y - captureRect.minY) / captureRect.height)
    }

    /// True when the system has seen a new event of this type since the last poll.
    private func happened(_ type: CGEventType) -> Bool {
        let count = CGEventSource.counterForEventType(.combinedSessionState, eventType: type)
        defer { counts[type] = count }
        guard let previous = counts[type] else { return false }
        return count != previous
    }

    private func poll() {
        let down = happened(.leftMouseDown), rightDown = happened(.rightMouseDown)
        let up = happened(.leftMouseUp), key = happened(.keyDown)
        guard let time = clock.position(for: SessionClock.hostNow)?.seconds, let point = cursor() else { return }

        if down || rightDown { write(RecordedEvent(t: time, kind: .down, x: point.x, y: point.y)) }
        if up { write(RecordedEvent(t: time, kind: .up, x: point.x, y: point.y)) }
        // Typing only matters as "the user is busy here", so a few marks per second is enough.
        if key, time - lastKeyTime > 0.25 {
            lastKeyTime = time
            write(RecordedEvent(t: time, kind: .key, x: point.x, y: point.y))
        }
        let moved = abs(point.x - lastPoint.x) * captureRect.width + abs(point.y - lastPoint.y) * captureRect.height
        if moved >= 0.5 {
            lastPoint = point
            write(RecordedEvent(t: time, kind: .move, x: point.x, y: point.y))
        }
        if pending.utf8.count > 4096 || Date().timeIntervalSince(lastFlush) > 1 { flush() }
    }

    private func write(_ event: RecordedEvent) {
        pending += EventLog.line(event)
    }

    private func flush() {
        lastFlush = Date()
        guard !pending.isEmpty else { return }
        try? handle.write(contentsOf: Data(pending.utf8))
        pending = ""
    }
}

extension CursorShape {
    @MainActor var cursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .iBeam: .iBeam
        case .pointingHand: .pointingHand
        case .crosshair: .crosshair
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown
        }
    }

    /// The system doesn't say which cursor is showing, only what it looks like, so the current
    /// one is matched to the standard cursors by size and hot spot. Anything else counts as the arrow.
    @MainActor static var current: CursorShape {
        guard let system = NSCursor.currentSystem else { return .arrow }
        return allCases.first {
            $0.cursor.hotSpot == system.hotSpot && $0.cursor.image.size == system.image.size
        } ?? .arrow
    }
}
