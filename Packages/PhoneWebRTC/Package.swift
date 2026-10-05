// swift-tools-version: 6.0
import PackageDescription

// A distinct product prevents Xcode from choosing the Watch source package's
// identically named WebRTC product for the iPhone binary SDK.
let package = Package(
    name: "PhoneWebRTC",
    platforms: [.iOS("26.4")],
    products: [.library(name: "PhoneWebRTC", targets: ["PhoneWebRTC"])],
    dependencies: [.package(url: "https://github.com/stasel/WebRTC.git",
                            revision: "0c0ad84dac6c1941c16a414dfcfba94691866e4c")],
    targets: [.target(name: "PhoneWebRTC", dependencies: [.product(name: "WebRTC", package: "WebRTC")])]
)
