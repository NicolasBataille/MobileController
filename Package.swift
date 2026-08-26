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
        // The CLI lives in a library target rather than in the executable: a test target
        // cannot reliably `@testable import` an executable target, and every verb here is
        // meant to be exercised with injected fakes. `simprobe` is a three-line shim.
        .target(
            name: "SimProbeCLI",
            dependencies: [
                "SimProbeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "simprobe", dependencies: ["SimProbeCLI"]),
        .testTarget(name: "SimProbeCoreTests", dependencies: ["SimProbeCore"]),
        .testTarget(name: "SimProbeCLITests", dependencies: ["SimProbeCLI"]),
    ]
)
