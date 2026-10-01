// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Leyline engine — SwiftPM package. See docs/dev/engine-internals.md for the module map.
//
// Targets:
//   CRTLSDR        optional runtime loader for librtlsdr
//   CHackRF         optional runtime loader for libhackrf
//   EngineCore     hand-written engine: devices, capture, DSP, sinks (proto-free)
//   TestSupport    fakes shared by both test suites (test-only; no product depends on it)
//   LeylineServer  the daemon as a library: gRPC over UDS, the session and job stores, the
//                  services; ProtoMapping renders engine values to proto, and the session and job
//                  stores hold proto messages as their own record type
//   LeylineDaemon  the `leylined` executable: argument parsing and `main`, nothing else
//
// The generated leyline.v1 contract is not a target here: it is the `swift/LeylineProto` package
// this one depends on, so the Apache-2.0 contract sits outside the GPL directory
// (docs/decisions/D2-licensing.md).
//
// The product is Mac-only. Platform-specific code (Accelerate, AVFoundation, IOKit, os_signpost) is
// guarded with `#if canImport(...)` so the package also builds on Linux for CI/dev checks. The only
// portable code path is DSP/Kernels.swift, which is the reference implementation the macOS parity
// tests compare vDSP against (docs/dev/engine-internals.md, "Platform posture").
import PackageDescription

let package = Package(
    name: "Leyline",
    platforms: [.macOS("26.0")],
    products: [
        // The daemon is the one thing this package ships. EngineCore and LeylineServer are not
        // products: their declarations are `package`, visible to the targets here and to nothing
        // outside (the app links LeylineProto only; `make license-check`).
        .executable(name: "leylined", targets: ["LeylineDaemon"]),
    ],
    dependencies: [
        .package(name: "LeylineProto", path: "../swift/LeylineProto"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.9.2"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "CRTLSDR",
            path: "Sources/CRTLSDR",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]
        ),
        .target(
            name: "CHackRF",
            path: "Sources/CHackRF",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]
        ),
        .target(
            name: "EngineCore",
            dependencies: [
                "CRTLSDR",
                "CHackRF",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/EngineCore"
        ),
        .target(
            name: "LeylineServer",
            dependencies: [
                "EngineCore",
                .product(name: "LeylineProto", package: "LeylineProto"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/LeylineServer"
        ),
        .executableTarget(
            name: "LeylineDaemon",
            dependencies: [
                "EngineCore",
                "LeylineServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/LeylineDaemon"
        ),
        // The two executables below are not products: they are a test fixture and a spike harness,
        // not something this package ships. SwiftPM still builds an executable target in the root
        // package under the target's name, so the names are the binaries' names, which
        // DaemonTestHarness, scripts/hot-path-allocations.sh and docs/decisions/S2-throughput.md use.
        //
        // A decoder plugin that decodes nothing, for the daemon's decode-job tests.
        .executableTarget(
            name: "leyline-fake-decoder",
            dependencies: [
                .product(name: "LeylineProto", package: "LeylineProto"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/FakeDecoder"
        ),
        // The S2 throughput harness (docs/decisions/S2-throughput.md).
        .executableTarget(
            name: "s2-throughput",
            dependencies: ["EngineCore"],
            path: "Sources/S2Throughput"
        ),
        .target(
            name: "TestSupport",
            dependencies: ["EngineCore"],
            path: "Tests/TestSupport"
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: ["EngineCore", "TestSupport", "CHackRF"],
            path: "Tests/EngineCoreTests",
            // The sub-audible taps of real-radio captures (SubAudibleCaptureTests): the 1 kHz
            // discriminator output the detector sees, kept because the captures themselves are
            // tens of megabytes and gitignored.
            resources: [.copy("Captures")]
        ),
        .testTarget(
            name: "LeylineDaemonTests",
            dependencies: [
                "LeylineServer",
                "EngineCore",
                .product(name: "LeylineProto", package: "LeylineProto"),
                "TestSupport",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            path: "Tests/LeylineDaemonTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
