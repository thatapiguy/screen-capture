// swift-tools-version: 6.0
import PackageDescription

// Pure logic with no AppKit/AVFoundation, so it is testable with plain `swift test`.
let package = Package(
    name: "ScreenCapCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ScreenCapCore", targets: ["ScreenCapCore"])],
    targets: [
        .target(name: "ScreenCapCore"),
        .testTarget(name: "ScreenCapCoreTests", dependencies: ["ScreenCapCore"]),
    ]
)
