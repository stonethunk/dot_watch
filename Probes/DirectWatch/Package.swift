// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DirectWatchInvestigation",
    platforms: [.macOS(.v26), .watchOS(.v26)],
    products: [.library(name: "DirectWatchLink", targets: ["DirectWatchLink"]),
               .executable(name: "watch-link-probe", targets: ["WatchLinkProbe"])],
    dependencies: [
        .package(path: "../.."),
        .package(path: "Vendor/WatchWebRTC"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1"),
    ],
    targets: [
        .target(name: "DirectWatchLink", dependencies: [
            .product(name: "WatchWebRTC", package: "WatchWebRTC"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "WatchLinkProbe", dependencies: [
            "DirectWatchLink", .product(name: "DotCore", package: "dot_watch"),
        ]),
        .testTarget(name: "DirectWatchLinkTests", dependencies: ["DirectWatchLink"]),
    ]
)
