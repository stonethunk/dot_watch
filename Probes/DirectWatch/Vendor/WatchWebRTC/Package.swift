// swift-tools-version: 6.4
import PackageDescription

// Native-only manifest for the byte-identical pinned upstream source snapshot.
// Unique module/product names avoid Xcode's conflicting WebRTC product graphs.
let package = Package(
    name: "WatchWebRTC",
    platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
    products: [.library(name: "WatchWebRTC", targets: ["WatchWebRTC"])],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-networking.git", revision: "c5da46c2ab2fd1244b40a208cd1fa406ead43dca"),
        .package(url: "https://github.com/1amageek/swift-ssl.git", revision: "045d6c1ccffd5adc7f2da2fd748de86f05bbde9b"),
        .package(url: "https://github.com/1amageek/swift-tls.git", revision: "cbb2f5b3e3355c51cfea2edc6a8282fed16e790d"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1"),
    ],
    targets: [.target(name: "WatchWebRTC", dependencies: [
        .product(name: "TLS", package: "swift-tls"),
        .product(name: "NetworkingCore", package: "swift-networking"),
        .product(name: "NetworkingTime", package: "swift-networking"),
        .product(name: "NetworkingPOSIX", package: "swift-networking"),
        .product(name: "NetworkingWASI", package: "swift-networking"),
        .product(name: "SSLCrypto", package: "swift-ssl"),
        .product(name: "SSLASN1", package: "swift-ssl"),
        .product(name: "SSLX509", package: "swift-ssl"),
        .product(name: "Logging", package: "swift-log"),
    ], path: "Sources/WebRTC", exclude: ["CONTEXT.md", "Transport/RTP/CONTEXT.md", "Transport/SRTP/CONTEXT.md"],
       swiftSettings: [.enableExperimentalFeature("Lifetimes")])]
)
