// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MImoMeter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MImoMeter", targets: ["MImoMeter"])
    ],
    targets: [
        .executableTarget(
            name: "MImoMeter",
            path: "Sources/MImoMeter"
        ),
    ]
)
