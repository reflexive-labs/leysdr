// SPDX-License-Identifier: Apache-2.0

// The palette as docs/dev/app.md ("Palette and type") states it and as Theme.swift builds it, read
// as text by both tests: LeylineApp, where Theme lives, is never compiled on Linux, and these
// checks should run there too. The first test holds the table and the code to one set of names and
// values; the second holds every ink to a WCAG contrast floor on the grounds it is drawn on.

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

    /// The grounds text is drawn on, by app.md's roles: the window and the charts, the titlebar
    /// and transport bar, the sidebar, a control or selected row in the chrome, a selected sidebar
    /// row. Every ink may stand on any of them.
    private static let grounds = ["ground", "chrome", "panel", "raised", "selected"]

    /// WCAG's floor for each ink: 4.5:1 for text read as text, 3:1 for the faint inks the table
    /// gives to units, section headers and footnotes. `inkDisabled` is exempt, as WCAG exempts
    /// inactive controls.
    private static let floors: [(ink: String, floor: Double)] = [
        ("ink", 4.5), ("inkSecondary", 4.5), ("inkTertiary", 4.5),
        ("inkMuted", 3), ("inkFaint", 3), ("inkFaintest", 3),
    ]

    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testEveryInkMeetsItsContrastFloorOnEveryGround() throws {
        let code = try themed()
        for (ink, floor) in Self.floors {
            let fore = try XCTUnwrap(code[ink], "\(ink) is not in Theme.swift")
            for ground in Self.grounds {
                let back = try XCTUnwrap(code[ground], "\(ground) is not in Theme.swift")
                let ratio = contrast(fore, back)
                XCTAssertGreaterThanOrEqual(
                    ratio, floor,
                    "\(ink) on \(ground) is \(String(format: "%.2f", ratio)):1, under its floor of "
                        + "\(floor):1")
            }
        }
    }
}
