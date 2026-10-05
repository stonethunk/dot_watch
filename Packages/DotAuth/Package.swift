// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DotAuth",
    platforms: [.macOS(.v14), .iOS("26.4")],
    products: [.library(name: "DotAuth", targets: ["DotAuth"])],
    dependencies: [.package(url: "https://github.com/vapor/jwt-kit.git", revision: "1b55c7529eff82cd9fa907e67a539404459a02e6")],
    targets: [
        .target(name: "DotAuth", dependencies: [.product(name: "JWTKit", package: "jwt-kit")]),
        .testTarget(name: "DotAuthTests", dependencies: ["DotAuth", .product(name: "JWTKit", package: "jwt-kit")]),
    ]
)
