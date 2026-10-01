// SPDX-License-Identifier: GPL-3.0-or-later

// Discovery reads files and executes nothing (docs/design/decoders.md, "Decisions": "Manifest: a
// file, not a flag"), so a broken plugin produces a log line and never breaks the registry.

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

final class DecoderRegistryTests: XCTestCase {
    func testScanReadsGoodManifestsAndSkipsTheRest() throws {
        let dir = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeFakePlugin(in: dir, name: "fake")
        // Does not parse.
        try writeFakePlugin(in: dir, name: "broken", json: "{ this is not json")
        // Parses, but points at an executable that cannot be found.
        try writeFakePlugin(in: dir, name: "missing", executable: "/nowhere/leydec-missing")

        let found = DecoderRegistry(searchPath: [dir]).scan()
        XCTAssertEqual(found.map(\.manifest.name), ["fake"])
        XCTAssertEqual(found[0].executablePath, fakeDecoderPath())
        XCTAssertEqual(found[0].directory, dir + "/fake")
        XCTAssertEqual(found[0].manifest.recipe.frequenciesHz, [146_000_000])
        XCTAssertEqual(found[0].manifest.input.tap, .tapAudio)
    }

    func testFirstDirectoryWins() throws {
        let first = try makeTempDir("decoders-a")
        let second = try makeTempDir("decoders-b")
        defer {
            try? FileManager.default.removeItem(atPath: first)
            try? FileManager.default.removeItem(atPath: second)
        }
        try writeFakePlugin(in: first, name: "fake", recipe: (144_390_000, 15_000))
        try writeFakePlugin(in: second, name: "fake", recipe: (433_920_000, 15_000))

        let registry = DecoderRegistry(searchPath: [first, second])
        XCTAssertEqual(registry.scan().count, 1)
        XCTAssertEqual(registry.find("fake")?.manifest.recipe.frequenciesHz, [144_390_000])
        XCTAssertNil(registry.find("nobody"))
    }

    func testAMissingSearchPathIsNotFatal() throws {
        let dir = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeFakePlugin(in: dir, name: "fake")
        let registry = DecoderRegistry(searchPath: ["/nowhere/at/all", dir])
        XCTAssertEqual(registry.scan().map(\.manifest.name), ["fake"])
    }
}
