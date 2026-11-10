import XCTest
@testable import ScreenCapCore

final class CaptureGeometryTests: XCTestCase {
    func testNativeUsesRetinaPixels() {
        let size = CaptureGeometry.outputSize(points: CGSize(width: 1512, height: 982), scale: 2, cap: .native)
        XCTAssertEqual(size.width, 3024)
        XCTAssertEqual(size.height, 1964)
    }

    func testCapScalesDownPreservingAspect() {
        let size = CaptureGeometry.outputSize(points: CGSize(width: 2560, height: 1440), scale: 2, cap: .p1080)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }

    func testCapNeverScalesUp() {
        let size = CaptureGeometry.outputSize(points: CGSize(width: 800, height: 600), scale: 1, cap: .p1440)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    func testTallSourceIsLimitedByHeight() {
        let size = CaptureGeometry.outputSize(points: CGSize(width: 1000, height: 2000), scale: 1, cap: .p1080)
        XCTAssertEqual(size.height, 1080)
        XCTAssertEqual(size.width, 540)
    }

    func testDimensionsAreEven() {
        let size = CaptureGeometry.outputSize(points: CGSize(width: 333, height: 201), scale: 1, cap: .native)
        XCTAssertEqual(size.width % 2, 0)
        XCTAssertEqual(size.height % 2, 0)
    }

    func testBitrateScalesWithFrameRateAndHasFloor() {
        let b30 = CaptureGeometry.screenBitrate(width: 3840, height: 2160, fps: 30)
        let b60 = CaptureGeometry.screenBitrate(width: 3840, height: 2160, fps: 60)
        XCTAssertEqual(b60, b30 * 2)
        XCTAssertEqual(CaptureGeometry.screenBitrate(width: 320, height: 240, fps: 30), 4_000_000)
    }
}
