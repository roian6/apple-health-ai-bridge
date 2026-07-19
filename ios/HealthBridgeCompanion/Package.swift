// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HealthBridgeCompanion",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "HealthBridgeCompanionCore", targets: ["HealthBridgeCompanionCore"]),
    ],
    targets: [
        .target(name: "HealthBridgeCompanionCore"),
        .testTarget(
            name: "HealthBridgeCompanionCoreTests",
            dependencies: ["HealthBridgeCompanionCore"]
        ),
    ]
)
