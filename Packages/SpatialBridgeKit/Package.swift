// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SpatialBridgeKit",
    platforms: [
        .iOS(.v18),
        .visionOS(.v2),
        .macOS(.v15)
    ],
    products: [
        .library(name: "SpatialBridgeKit", targets: ["SpatialBridgeKit"])
    ],
    targets: [
        .target(name: "SpatialBridgeKit"),
        .testTarget(
            name: "SpatialBridgeKitTests",
            dependencies: ["SpatialBridgeKit"]
        )
    ],
    swiftLanguageModes: [.v5]
)
