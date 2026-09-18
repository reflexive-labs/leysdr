// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
// The leyline.v1 wire contract for Swift — SwiftPM package. Every file under
// Sources/LeylineProto is generated from proto/leyline/v1/*.proto by scripts/gen-proto.sh and is
// never hand-edited: change the .proto and run `make proto` (CLAUDE.md invariant 13).
//
// It is its own package, outside engine/, because the contract is Apache-2.0 and the engine is GPL
// (docs/decisions/D2-licensing.md): the licence boundary is a directory boundary, and both clients
// of the contract — the engine and the Mac app — depend on this one small path package rather
// than on each other, the way both Go clients import go/gen.
import PackageDescription

let package = Package(
    name: "LeylineProto",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LeylineProto", targets: ["LeylineProto"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: [
        .target(
            name: "LeylineProto",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/LeylineProto"
        ),
    ],
    swiftLanguageModes: [.v5]
)
