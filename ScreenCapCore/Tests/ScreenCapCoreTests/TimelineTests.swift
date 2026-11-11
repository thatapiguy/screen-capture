import XCTest
@testable import ScreenCapCore

final class TimelineTests: XCTestCase {
    private func edits(trimStart: Double = 0, trimEnd: Double? = nil, cuts: [TimeRange] = []) -> EditDecisions {
        var edits = EditDecisions()
        edits.trimStart = trimStart
        edits.trimEnd = trimEnd
        edits.cuts = cuts
        return edits
    }

    func testNoEditsIsIdentity() {
        let timeline = Timeline(duration: 10, edits: EditDecisions())
        XCTAssertEqual(timeline.duration, 10)
        XCTAssertEqual(timeline.sourceTime(forOutput: 4), 4)
        XCTAssertEqual(timeline.outputTime(forSource: 4), 4)
    }

    func testTimeMappingAfterCuts() {
        let timeline = Timeline(duration: 20, edits: edits(trimStart: 2, trimEnd: 18, cuts: [TimeRange(5, 8), TimeRange(10, 11)]))
        XCTAssertEqual(timeline.segments, [TimeRange(2, 5), TimeRange(8, 10), TimeRange(11, 18)])
        XCTAssertEqual(timeline.duration, 12, accuracy: 1e-9)
        XCTAssertEqual(timeline.sourceTime(forOutput: 0), 2)
        XCTAssertEqual(timeline.sourceTime(forOutput: 3.5), 8.5)
        XCTAssertEqual(timeline.sourceTime(forOutput: 6), 12)
        XCTAssertEqual(timeline.outputTime(forSource: 9), 4)
        XCTAssertEqual(timeline.outputTime(forSource: 17), 11)
    }

    func testRemovedSourceTimeSnapsToCutPoint() {
        let timeline = Timeline(duration: 20, edits: edits(cuts: [TimeRange(5, 8)]))
        XCTAssertEqual(timeline.outputTime(forSource: 6), 5)
        XCTAssertEqual(timeline.outputTime(forSource: 1000), 17)
    }

    func testRoundTripForKeptTimes() {
        let timeline = Timeline(duration: 30, edits: edits(trimStart: 1, cuts: [TimeRange(4, 6), TimeRange(12, 20)]))
        for source in [1.0, 3.9, 6.0, 11.5, 20.0, 29.0] {
            XCTAssertEqual(timeline.sourceTime(forOutput: timeline.outputTime(forSource: source)), source, accuracy: 1e-9)
        }
    }

    func testOverlappingAndOutOfRangeCuts() {
        let timeline = Timeline(duration: 10, edits: edits(cuts: [TimeRange(2, 5), TimeRange(4, 6), TimeRange(9, 30), TimeRange(-3, 1)]))
        XCTAssertEqual(timeline.segments, [TimeRange(1, 2), TimeRange(6, 9)])
    }

    func testOutputRangeAcrossCut() {
        let timeline = Timeline(duration: 20, edits: edits(cuts: [TimeRange(5, 8)]))
        XCTAssertEqual(timeline.outputRange(forSource: TimeRange(4, 10)), TimeRange(4, 7))
        XCTAssertNil(timeline.outputRange(forSource: TimeRange(5.5, 7)))
    }

    func testSplitThenDeleteMiddleClip() {
        var edits = EditDecisions()
        edits.split(at: 4)
        edits.split(at: 7)
        edits.split(at: 4.001)
        XCTAssertEqual(edits.splits, [4, 7])
        var clips = Timeline(duration: 10, edits: edits).clips(splits: edits.splits)
        XCTAssertEqual(clips, [TimeRange(0, 4), TimeRange(4, 7), TimeRange(7, 10)])

        edits.delete(clips[1])
        XCTAssertEqual(edits.cuts, [TimeRange(4, 7)])
        XCTAssertEqual(edits.splits, [])
        clips = Timeline(duration: 10, edits: edits).clips(splits: edits.splits)
        XCTAssertEqual(clips, [TimeRange(0, 4), TimeRange(7, 10)])
    }

    func testDeleteMergesTouchingCuts() {
        var edits = EditDecisions()
        edits.delete(TimeRange(2, 4))
        edits.delete(TimeRange(8, 9))
        edits.delete(TimeRange(4, 6))
        XCTAssertEqual(edits.cuts, [TimeRange(2, 6), TimeRange(8, 9)])
    }

    func testEditDecisionsRoundTripThroughJSON() throws {
        var edits = EditDecisions()
        edits.delete(TimeRange(1, 2))
        edits.zoomRegions = [ZoomRegion(start: 3, end: 5, scale: 2, focus: CGPoint(x: 0.3, y: 0.6), followsCursor: false, origin: .manual)]
        edits.cameraHidden = [Span(start: 1, end: 2)]
        let decoded = try ReelJSON.decode(EditDecisions.self, from: ReelJSON.encode(edits))
        XCTAssertEqual(decoded, edits)
    }
}

final class SilenceTests: XCTestCase {
    /// 10 peaks per second: `loud` seconds of speech then `quiet` seconds of nothing, repeated.
    private func peaks(_ pattern: [(seconds: Double, level: Float)]) -> [Float] {
        pattern.flatMap { [Float](repeating: $0.level, count: Int($0.seconds * 10)) }
    }

    func testFindsLongSilencesWithPadding() {
        let ranges = Silence.ranges(peaks: peaks([(2, 0.5), (3, 0.001), (2, 0.4)]), rate: 10)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 2.2, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].end, 4.8, accuracy: 1e-9)
    }

    func testIgnoresShortPausesAndFindsTrailingSilence() {
        let ranges = Silence.ranges(peaks: peaks([(2, 0.5), (0.8, 0), (2, 0.5), (4, 0)]), rate: 10)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 5.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].end, 8.6, accuracy: 1e-9)
    }

    func testMutedRecordingIsLeftAlone() {
        XCTAssertTrue(Silence.ranges(peaks: peaks([(30, 0.001)]), rate: 10).isEmpty)
        XCTAssertTrue(Silence.ranges(peaks: [], rate: 10).isEmpty)
    }

    func testCursorShapeRoundTripsAndIsLookedUpByTime() {
        let events = [RecordedEvent(t: 0, kind: .move, x: 0.1, y: 0.1),
                      RecordedEvent(t: 2, kind: .cursor, x: 0.2, y: 0.2, shape: .iBeam),
                      RecordedEvent(t: 5, kind: .cursor, x: 0.3, y: 0.3, shape: .arrow)]
        let parsed = EventLog.parse(Data(events.map(EventLog.line).joined().utf8))
        XCTAssertEqual(parsed, events)
        let track = CursorTrack(events: parsed)
        XCTAssertEqual(track.shape(at: 1), .arrow)
        XCTAssertEqual(track.shape(at: 3), .iBeam)
        XCTAssertEqual(track.shape(at: 6), .arrow)
        XCTAssertEqual(track.smoothed(strength: 0.5).shape(at: 3), .iBeam)
    }
}
