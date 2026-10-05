// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DotWatch",
    platforms: [.macOS(.v14), .iOS("26.4"), .watchOS("26.0")],
    products: [
        .library(name: "DotCore", targets: ["DotCore"]),
        .library(name: "DotCompanion", targets: ["DotCompanion"]),
        .executable(name: "dot-probe", targets: ["DotProbe"]),
    ],
    targets: [
        .target(name: "DotCore"),
        .target(name: "DotCompanion"),
        .testTarget(name: "DotCompanionTests", dependencies: ["DotCompanion"]),
        .executableTarget(name: "DotProbe", dependencies: ["DotCore"]),
        .testTarget(name: "DotCoreTests", dependencies: ["DotCore"], resources: [.copy("Fixtures")]),
        // Test the native private importer without linking it into DotCore or
        // distributing it as a public package product.
        .target(name: "DotPrivateBootstrap", dependencies: ["DotCore"],
                path: "Apps/Phone/PrivateSetup", swiftSettings: [.define("PERSONAL_DIAGNOSTICS")]),
        .testTarget(name: "DotPrivateBootstrapTests", dependencies: ["DotCore", "DotPrivateBootstrap"]),
        .target(name: "DotPrivateWatch", dependencies: ["DotCore", "DotCompanion"],
                path: "Apps/PrivateWatch", swiftSettings: [.define("PERSONAL_DIAGNOSTICS")]),
        .testTarget(name: "DotPrivateWatchTests", dependencies: ["DotPrivateWatch", "DotCore", "DotCompanion"]),
    ]
)
