// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XScreenshot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "XScreenshot"),
        .testTarget(name: "XScreenshotTests", dependencies: ["XScreenshot"])
    ]
)
