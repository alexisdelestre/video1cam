// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Video1Cam",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "RecorderCore", path: "Sources/RecorderCore"),
        .executableTarget(name: "Video1Cam", dependencies: ["RecorderCore"], path: "Sources/Video1Cam"),
        .executableTarget(name: "CoreTests", dependencies: ["RecorderCore"], path: "Sources/CoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
