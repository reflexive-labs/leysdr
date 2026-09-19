// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
// Leyline Mac app — SwiftPM package. See docs/dev/app.md for the module map and the rules.
//
// Targets:
//   LeylineClient      the Swift client façade over leyline.v1: dial, identity, the observable
//                      state mirror, the write coalescer, stream helpers. No UI, no DSP; builds
//                      and is tested on Linux as well as macOS, because the contract it wraps is
//                      the same one `ley` proves from Go.
//   LeylineApp         the SwiftUI app (macOS only): renders what the mirror holds, writes through
//                      the coalescer, draws the bulk streams. Declared only when the manifest is
//                      evaluated on macOS, so `swift build` on Linux builds and tests the façade.
//
// The app is a peer client of the daemon (CLAUDE.md invariant 1) and a separate Apache-2.0 work
// beside the GPL engine (docs/decisions/D2-licensing.md): it depends on the `swift/LeylineProto`
// package for the generated contract and on the engine package not at all, so nothing GPL is in its
// graph and nothing in the app can reach around the wire. `make license-check` refuses an
// `import EngineCore` under app/.
import PackageDescription

var targets: [Target] = [
    .target(
        name: "LeylineClient",
        dependencies: [
            .product(name: "LeylineProto", package: "LeylineProto"),
            .product(name: "GRPCCore", package: "grpc-swift-2"),
            .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        path: "Sources/LeylineClient",
        // The band table as `ley bands --json` prints it (`make bands-json`; a Go test fails on
        // drift), so the app has no table of its own.
        resources: [.copy("Resources/bands.json")]
    ),
    .testTarget(
        name: "LeylineClientTests",
        dependencies: ["LeylineClient"],
        path: "Tests/LeylineClientTests"
    ),
    // Against the real daemon (`leylined --no-hardware` on a temp socket, an IQ fixture as the
    // radio). Skips itself unless LEYLINED_BIN names a built daemon; `make app-e2e` is the only
    // place it runs, as `go/internal/e2e` is for `ley`.
    .testTarget(
        name: "LeylineClientDaemonTests",
        dependencies: ["LeylineClient"],
        path: "Tests/LeylineClientDaemonTests"
    ),
]

var products: [Product] = [
    .library(name: "LeylineClient", targets: ["LeylineClient"])
]

#if os(macOS)
    targets.append(
        .executableTarget(
            name: "LeylineApp",
            dependencies: ["LeylineClient"],
            path: "Sources/LeylineApp",
            exclude: ["Info.plist"]
        )
    )
    products.append(.executable(name: "LeylineApp", targets: ["LeylineApp"]))
#endif

let package = Package(
    name: "LeylineApp",
    platforms: [.macOS("26.0")],
    products: products,
    dependencies: [
        // The generated contract (`make proto`), its own package outside engine/. The versions
        // below are the engine's own pins, so every package resolves one graph.
        .package(name: "LeylineProto", path: "../swift/LeylineProto"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.9.2"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
