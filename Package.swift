// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenHeadPointer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "OpenHeadPointer", targets: ["OpenHeadPointer"]),
        .library(name: "GazeCore", targets: ["GazeCore"]),
    ],
    targets: [
        // Pure, testable maths: features, regression, filtering, dwell/blink logic, iris locator.
        .target(name: "GazeCore"),
        // The macOS menu-bar app: camera, Vision, calibration UI, cursor control.
        .executableTarget(name: "OpenHeadPointer", dependencies: ["GazeCore"]),
        .testTarget(name: "GazeCoreTests", dependencies: ["GazeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
