// SPDX-License-Identifier: Apache-2.0

// The palette as docs/dev/app.md ("Palette and type") states it and as Theme.swift builds it, read
// as text: LeylineApp, where Theme lives, is never compiled on Linux, and this check should run
// there too. It holds the table and the code to one set of names and values.

import Foundation
import XCTest

final class PaletteTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The `| \`token\` | \`#RRGGBB\` | ... |` rows under "### Palette" in app.md, up to the next
    /// heading.
    private func documented() throws -> [String: UInt32] {
        let text = try String(
            contentsOf: Self.root.appendingPathComponent("docs/dev/app.md"), encoding: .utf8)
        var tokens: [String: UInt32] = [:]
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") {
                inside = line == "### Palette"
                continue
            }
            guard inside,
                let m = line.firstMatch(of: #/^\| `(\w+)` \| `#([0-9A-Fa-f]{6})` \|/#),
                let value = UInt32(m.2, radix: 16)
            else { continue }
            tokens[String(m.1)] = value
        }
        return tokens
    }

    /// Every `static let name = Color(hex: 0xRRGGBB)` in Theme.swift, and every
    /// `static let nameHex: UInt32 = 0xRRGGBB` under the name its colour takes.
    private func themed() throws -> [String: UInt32] {
        let text = try String(
            contentsOf: Self.root.appendingPathComponent("app/Sources/LeylineApp/Theme.swift"),
            encoding: .utf8)
        var tokens: [String: UInt32] = [:]
        for m in text.matches(of: #/static let (\w+) = Color\(hex: 0x([0-9A-Fa-f]{6})\)/#) {
            tokens[String(m.1)] = UInt32(m.2, radix: 16)
        }
        for m in text.matches(of: #/static let (\w+)Hex: UInt32 = 0x([0-9A-Fa-f]{6})\b/#) {
            tokens[String(m.1)] = UInt32(m.2, radix: 16)
        }
        return tokens
    }

    private func hex(_ value: UInt32) -> String { "#" + String(format: "%06X", value) }

    func testThePaletteTableAndThemeNameTheSameTokensWithTheSameValues() throws {
        let doc = try documented()
        let code = try themed()
        XCTAssertFalse(doc.isEmpty, "no rows read from app.md's Palette table")
        XCTAssertFalse(code.isEmpty, "no colours read from Theme.swift")
        for name in Set(doc.keys).union(code.keys).sorted() {
            switch (doc[name], code[name]) {
            case (let d?, let c?):
                XCTAssertEqual(
                    d, c, "\(name) is \(hex(d)) in app.md and \(hex(c)) in Theme.swift")
            case (_?, nil):
                XCTFail("\(name) is in app.md's Palette table and not in Theme.swift")
            case (nil, _?):
                XCTFail("\(name) is in Theme.swift and not in app.md's Palette table")
            case (nil, nil):
                break
            }
        }
    }
}
