// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "anDropProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "anDropProtocol", targets: ["anDropProtocol"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "anDropProtocol", dependencies: ["ZIPFoundation"], path: "Core"),
        .testTarget(name: "ProtocolTests", dependencies: ["anDropProtocol"], path: "Tests")
    ]
)
