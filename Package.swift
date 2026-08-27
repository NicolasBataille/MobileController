// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MobileController",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SimProbeCore", targets: ["SimProbeCore"]),
        .executable(name: "simprobe", targets: ["simprobe"]),
        // The warm action daemon, deliberately a *second* product: it is the only thing here
        // that needs gRPC, and gRPC costs 22 transitive packages and a ~19-minute clean build
        // (BoringSSL, for a plaintext unix socket). `swift build --product simprobe` never
        // touches any of it. See `docs/plans/05-warm-daemon.md` §1.
        .executable(name: "simprobe-daemon", targets: ["SimProbeDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
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
        // Depends on the CLI library, never the reverse: the wire protocol, the router and the
        // element parser are the same code on both sides of the socket, and the test bundle
        // reaches them without ever linking gRPC.
        .executableTarget(
            name: "SimProbeDaemon",
            dependencies: [
                "SimProbeCLI",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
            ]
        ),
        .testTarget(name: "SimProbeCoreTests", dependencies: ["SimProbeCore"]),
        .testTarget(name: "SimProbeCLITests", dependencies: ["SimProbeCLI"]),
    ]
)
