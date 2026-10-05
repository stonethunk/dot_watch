// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchAudioInvestigation",
    platforms: [.macOS(.v15), .watchOS("26.0")],
    products: [.library(name: "WatchAudioKit", targets: ["WatchAudioKit"]),
               .executable(name: "watch-codec-probe", targets: ["WatchCodecProbe"])],
    targets: [
        .target(name: "WatchAudioKit"),
        .executableTarget(name: "WatchCodecProbe", dependencies: ["WatchAudioKit"]),
        .testTarget(name: "WatchAudioKitTests", dependencies: ["WatchAudioKit"]),
    ]
)
