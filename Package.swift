// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MobileController",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SimProbeCore", targets: ["SimProbeCore"]),
        .executable(name: "simprobe", targets: ["simprobe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(name: "SimProbeCore"),
        .executableTarget(
            name: "simprobe",
            dependencies: [
                "SimProbeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SimProbeCoreTests", dependencies: ["SimProbeCore"]),
        .testTarget(name: "SimProbeCLITests", dependencies: ["SimProbeCore"]),
    ]
)
