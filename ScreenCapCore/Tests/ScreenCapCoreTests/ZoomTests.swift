import XCTest
@testable import ScreenCapCore

final class ZoomTests: XCTestCase {
    private func click(_ t: Double, _ x: Double = 0.5, _ y: Double = 0.5) -> RecordedEvent {
        RecordedEvent(t: t, kind: .down, x: x, y: y)
    }

    // MARK: Auto zoom

    func testOffProducesNothing() {
        XCTAssertTrue(AutoZoom.regions(events: [click(1)], duration: 10, sensitivity: .off).isEmpty)
    }

    func testNearbyClicksFormOneRegion() {
        let regions = AutoZoom.regions(events: [click(5, 0.2, 0.3), click(6), click(7.5)], duration: 60, sensitivity: .normal)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].start, 5 - AutoZoom.lead, accuracy: 1e-9)
        XCTAssertEqual(regions[0].end, 7.5 + AutoZoom.hold, accuracy: 1e-9)
        XCTAssertEqual(regions[0].focus, CGPoint(x: 0.2, y: 0.3))
        XCTAssertTrue(regions[0].followsCursor)
    }

    func testDistantClicksFormSeparateRegions() {
        let regions = AutoZoom.regions(events: [click(5), click(20)], duration: 60, sensitivity: .normal)
        XCTAssertEqual(regions.count, 2)
        XCTAssertLessThan(regions[0].end, regions[1].start)
    }

    func testSubtleIgnoresSingleClicks() {
        XCTAssertTrue(AutoZoom.regions(events: [click(5), click(20)], duration: 60, sensitivity: .subtle).isEmpty)
        XCTAssertEqual(AutoZoom.regions(events: [click(5), click(6)], duration: 60, sensitivity: .subtle).count, 1)
    }

    func testTypingExtendsARegionButNeverStartsOne() {
        let key = { (t: Double) in RecordedEvent(t: t, kind: .key, x: 0.5, y: 0.5) }
        XCTAssertTrue(AutoZoom.regions(events: [key(3), key(4)], duration: 60, sensitivity: .normal).isEmpty)
        let regions = AutoZoom.regions(events: [click(5), key(7), key(9)], duration: 60, sensitivity: .normal)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].end, 9 + AutoZoom.hold, accuracy: 1e-9)
    }

    func testRegionsAreClampedToTheRecording() {
        let regions = AutoZoom.regions(events: [click(0.1), click(9)], duration: 10, sensitivity: .normal)
        XCTAssertEqual(regions.first?.start, 0)
        XCTAssertEqual(regions.last?.end, 10)
    }

    func testMarkersToggleAndUnclosedRunsToEnd() {
        let events = [
            RecordedEvent(t: 2, kind: .zoomOn, x: 0.1, y: 0.1), RecordedEvent(t: 4, kind: .zoomOff, x: 0.1, y: 0.1),
            RecordedEvent(t: 8, kind: .zoomOn, x: 0.9, y: 0.9),
        ]
        let regions = AutoZoom.markerRegions(events: events, duration: 10)
        XCTAssertEqual(regions.map(\.start), [2, 8])
        XCTAssertEqual(regions.map(\.end), [4, 10])
        XCTAssertTrue(regions.allSatisfy { $0.origin == .marker })
    }

    func testMergedDropsAutoRegionsThatOverlapKeptOnes() {
        let kept = [ZoomRegion(start: 4, end: 8, scale: 2, focus: .zero, followsCursor: false, origin: .manual)]
        let auto = AutoZoom.regions(events: [click(5), click(20)], duration: 60, sensitivity: .normal)
        let merged = AutoZoom.merged(auto: auto, keeping: kept)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].origin, .manual)
        XCTAssertEqual(merged[1].origin, .auto)
    }

    // MARK: Camera motion

    private let lockedRegion = ZoomRegion(start: 2, end: 6, scale: 2, focus: CGPoint(x: 0.9, y: 0.1), followsCursor: false, origin: .manual)

    func testNoRegionsIsIdentity() {
        let sample = ZoomCamera.path(regions: [], cursor: CursorTrack(events: []), duration: 10).sample(at: 3)
        XCTAssertEqual(sample.scale, 1)
        XCTAssertEqual(sample.center, CGPoint(x: 0.5, y: 0.5))
    }

    func testReachesTargetThenReturns() {
        let path = ZoomCamera.path(regions: [lockedRegion], cursor: CursorTrack(events: []), duration: 12)
        XCTAssertEqual(path.sample(at: 1).scale, 1, accuracy: 0.001)
        XCTAssertEqual(path.sample(at: 5.5).scale, 2, accuracy: 0.02)
        XCTAssertEqual(path.sample(at: 11).scale, 1, accuracy: 0.02)
    }

    func testFramedAreaStaysInsideTheRecording() {
        let path = ZoomCamera.path(regions: [lockedRegion], cursor: CursorTrack(events: []), duration: 12)
        for time in stride(from: 0.0, through: 12, by: 0.05) {
            let sample = path.sample(at: time)
            let half = 0.5 / sample.scale
            XCTAssertGreaterThanOrEqual(sample.center.x, half - 1e-4)
            XCTAssertLessThanOrEqual(sample.center.x, 1 - half + 1e-4)
            XCTAssertGreaterThanOrEqual(sample.center.y, half - 1e-4)
            XCTAssertLessThanOrEqual(sample.center.y, 1 - half + 1e-4)
        }
        // Focus is in the top-right corner, so the camera ends up pinned against it.
        let settled = path.sample(at: 5.5)
        XCTAssertEqual(settled.center.x, 0.75, accuracy: 0.01)
        XCTAssertEqual(settled.center.y, 0.25, accuracy: 0.01)
    }

    func testMotionHasNoHardCuts() {
        let path = ZoomCamera.path(regions: [lockedRegion], cursor: CursorTrack(events: []), duration: 12)
        var previous = path.sample(at: 0)
        for frame in 1...(12 * 60) {
            let sample = path.sample(at: Double(frame) / 60)
            XCTAssertLessThan(abs(sample.scale - previous.scale), 0.05)
            XCTAssertLessThan(abs(sample.center.x - previous.center.x), 0.02)
            previous = sample
        }
    }

    func testSmallCursorMovesDoNotMoveTheCamera() {
        // Cursor wiggles ±1% around the centre: well inside the dead zone.
        let events = stride(from: 0.0, through: 10, by: 0.05).map { t in
            RecordedEvent(t: t, kind: .move, x: 0.5 + 0.01 * sin(t * 20), y: 0.5)
        }
        let region = ZoomRegion(start: 1, end: 9, scale: 2, focus: CGPoint(x: 0.5, y: 0.5), followsCursor: true, origin: .auto)
        let path = ZoomCamera.path(regions: [region], cursor: CursorTrack(events: events), duration: 10)
        let a = path.sample(at: 5).center.x, b = path.sample(at: 5.08).center.x, c = path.sample(at: 5.16).center.x
        XCTAssertEqual(a, b, accuracy: 0.002)
        XCTAssertEqual(b, c, accuracy: 0.002)
    }

    func testCameraFollowsALargeCursorMove() {
        let events = [RecordedEvent(t: 0, kind: .move, x: 0.3, y: 0.5), RecordedEvent(t: 4, kind: .move, x: 0.3, y: 0.5),
                      RecordedEvent(t: 4.5, kind: .move, x: 0.7, y: 0.5), RecordedEvent(t: 10, kind: .move, x: 0.7, y: 0.5)]
        let region = ZoomRegion(start: 1, end: 9, scale: 2, focus: CGPoint(x: 0.3, y: 0.5), followsCursor: true, origin: .auto)
        let path = ZoomCamera.path(regions: [region], cursor: CursorTrack(events: events), duration: 10)
        XCTAssertEqual(path.sample(at: 3.5).center.x, 0.3, accuracy: 0.02)
        XCTAssertGreaterThan(path.sample(at: 8).center.x, 0.55)
    }

    // MARK: Events and cursor

    func testEventLogRoundTripAndTruncatedTail() {
        let events = [RecordedEvent(t: 0.5, kind: .move, x: 0.25, y: 0.75), RecordedEvent(t: 1, kind: .down, x: 0.5, y: 0.5),
                      RecordedEvent(t: 2, kind: .zoomOn, x: 0.1, y: 0.9)]
        var text = events.map(EventLog.line).joined()
        XCTAssertEqual(EventLog.parse(Data(text.utf8)), events)
        text += "{\"t\":3.0,\"k\":\"m\",\"x\":0."
        XCTAssertEqual(EventLog.parse(Data(text.utf8)), events)
        XCTAssertTrue(EventLog.parse(Data()).isEmpty)
    }

    func testCursorInterpolationAndSmoothing() {
        let track = CursorTrack(events: [RecordedEvent(t: 0, kind: .move, x: 0, y: 0), RecordedEvent(t: 2, kind: .move, x: 1, y: 0.5)])
        XCTAssertEqual(track.position(at: 1)?.x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(track.position(at: -1), CGPoint(x: 0, y: 0))
        XCTAssertEqual(track.position(at: 9), CGPoint(x: 1, y: 0.5))
        XCTAssertNil(CursorTrack(events: []).position(at: 1))

        let smooth = track.smoothed(strength: 1)
        // Smoothed motion trails the raw path but ends up in the same place.
        XCTAssertLessThan(smooth.position(at: 1)?.x ?? 1, 0.5)
        XCTAssertEqual(smooth.position(at: 2)?.x ?? 0, 1, accuracy: 0.1)
    }

    // MARK: Layout and export

    func testLayout() {
        let canvas = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(Layout.screenFrame(canvas: canvas, background: Background()), CGRect(x: 0, y: 0, width: 1920, height: 1080))
        var background = Background()
        background.enabled = true
        let frame = Layout.screenFrame(canvas: canvas, background: background)
        XCTAssertEqual(frame.width / frame.height, 1920.0 / 1080, accuracy: 1e-6)
        XCTAssertGreaterThan(frame.minX, 0)

        let camera = Layout.cameraFrame(canvas: canvas, camera: CameraLayout())
        XCTAssertEqual(camera.width, camera.height)
        XCTAssertGreaterThan(camera.midX, canvas.width / 2)
        XCTAssertGreaterThan(camera.midY, canvas.height / 2)

        XCTAssertEqual(Layout.visibleRect(scale: 2, center: CGPoint(x: 0.95, y: 0.5)), CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5))
    }

    func testExportSizing() {
        var settings = ExportSettings()
        let source = CGSize(width: 3024, height: 1964)
        XCTAssertEqual(settings.renderSize(source: source), source)
        settings.resolution = .p1080
        let size = settings.renderSize(source: source)
        XCTAssertEqual(size.height, 1080)
        XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0)
        settings.resolution = .p2160
        XCTAssertEqual(settings.renderSize(source: CGSize(width: 1280, height: 720)), CGSize(width: 1280, height: 720))

        settings.quality = .small
        let small = settings.videoBitrate(size: size)
        settings.quality = .high
        XCTAssertGreaterThan(settings.videoBitrate(size: size), small)
    }
}
