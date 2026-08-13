// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ResetMeter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ResetMeter", targets: ["ResetMeterApp"]),
    ],
    targets: [
        .target(name: "UsageMeterCore"),
        .executableTarget(
            name: "ResetMeterApp",
            dependencies: ["UsageMeterCore"]
        ),
        .testTarget(
            name: "UsageMeterCoreTests",
            dependencies: ["UsageMeterCore"]
        ),
    ]
)
