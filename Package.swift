// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocationBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LocationBridgeCore", targets: ["LocationBridgeCore"]),
        .executable(name: "location-bridge", targets: ["location-bridge"]),
        .executable(name: "LocationBridge", targets: ["LocationBridgeApp"])
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")],
    targets: [
        .target(name: "LocationBridgeCore", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .executableTarget(name: "location-bridge", dependencies: ["LocationBridgeCore"]),
        .executableTarget(name: "LocationBridgeApp", dependencies: ["LocationBridgeCore"]),
        .testTarget(name: "LocationBridgeCoreTests", dependencies: ["LocationBridgeCore"])
    ]
)
