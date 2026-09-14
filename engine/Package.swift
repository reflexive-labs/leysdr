// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Leyline engine — SwiftPM package. See docs/dev/engine-internals.md for the module map.
//
// Targets:
//   LeylineProto   generated leyline.v1 messages + grpc-swift 2 stubs (never hand-edit; `make proto`)
//   CRTLSDR        system-library shim over librtlsdr (brew install librtlsdr)
//   EngineCore     hand-written engine: devices, capture, DSP, sinks (proto-free)
//   TestSupport    fakes shared by both test suites (test-only; no product depends on it)
//   LeylineDaemon  the `leylined` executable: gRPC over UDS; ProtoMapping renders engine values
//                  to proto, and the session and job stores hold proto messages as their own
//                  record type
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
        .executable(name: "leylined", targets: ["LeylineDaemon"]),
        .executable(name: "s2-throughput", targets: ["S2Throughput"]),
        // A decoder plugin that decodes nothing, for the daemon's decode-job tests (DEC-4).
        .executable(name: "leyline-fake-decoder", targets: ["FakeDecoder"]),
        .library(name: "EngineCore", targets: ["EngineCore"]),
        .library(name: "LeylineProto", targets: ["LeylineProto"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.9.2"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CRTLSDR",
            path: "Sources/CRTLSDR",
            pkgConfig: "librtlsdr",
            providers: [.brew(["librtlsdr"]), .apt(["librtlsdr-dev"])]
        ),
        .target(
            name: "LeylineProto",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/LeylineProto"
        ),
        .target(
            name: "EngineCore",
            dependencies: [
                "CRTLSDR",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/EngineCore"
        ),
        .executableTarget(
            name: "LeylineDaemon",
            dependencies: [
                "EngineCore",
                "LeylineProto",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/LeylineDaemon"
        ),
        .executableTarget(
            name: "FakeDecoder",
            dependencies: [
                "LeylineProto",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/FakeDecoder"
        ),
        .executableTarget(
            name: "S2Throughput",
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
            dependencies: ["EngineCore", "TestSupport"],
            path: "Tests/EngineCoreTests",
            // The sub-audible taps of real-radio captures (SubAudibleCaptureTests): the 1 kHz
            // discriminator output the detector sees, kept because the captures themselves are
            // tens of megabytes and gitignored.
            resources: [.copy("Captures")]
        ),
        .testTarget(
            name: "LeylineDaemonTests",
            dependencies: [
                "LeylineDaemon",
                "EngineCore",
                "LeylineProto",
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
