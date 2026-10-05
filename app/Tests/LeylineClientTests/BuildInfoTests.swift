// SPDX-License-Identifier: Apache-2.0

// The about panel's build line: the `git describe` string bundle-app.sh stamps, and nothing for a
// bare executable or an unstamped Info.plist.

import XCTest

@testable import LeylineClient

final class BuildInfoTests: XCTestCase {
    func testTheAboutLineNamesTheStampedTree() {
        XCTAssertEqual(
            BuildInfo.aboutLine(info: ["LeylineBuild": "v0.1.0-3-gd34db33"]),
            "Build v0.1.0-3-gd34db33")
    }

    func testNoTreeIsNamedWithoutAStamp() {
        XCTAssertNil(BuildInfo.aboutLine(info: nil), "a bare executable")
        XCTAssertNil(BuildInfo.aboutLine(info: ["CFBundleVersion": "619"]))
        XCTAssertNil(BuildInfo.aboutLine(info: ["LeylineBuild": ""]))
        XCTAssertNil(BuildInfo.aboutLine(info: ["LeylineBuild": "__BUILD_DESCRIBE__"]))
    }
}
