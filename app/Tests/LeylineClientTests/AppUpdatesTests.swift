// SPDX-License-Identifier: Apache-2.0

// When the app starts Sparkle's updater: only in a bundle that names the update key, and never in
// a staged or test run.

import XCTest

@testable import LeylineClient

final class AppUpdatesTests: XCTestCase {
    private func starts(
        _ path: String = "/Applications/Leyline.app", key: String? = "abc=",
        env: [String: String] = [:]
    ) -> Bool {
        AppUpdates.shouldStart(bundlePath: path, publicKey: key, environment: env)
    }

    func testOnlyABundleWithAKeyChecksForUpdates() {
        XCTAssertTrue(starts())
        XCTAssertFalse(starts("/src/leysdr/app/.build/debug"), "a bare executable")
        XCTAssertFalse(starts(key: nil))
        XCTAssertFalse(starts(key: ""))
    }

    func testStagedAndTestRunsCheckForNothing() {
        XCTAssertFalse(starts(env: ["LEYLINE_SOCKET": "/tmp/s.sock"]))
        XCTAssertFalse(starts(env: ["LEYLINE_APP_STAGE": "/tmp/stage.json"]))
        XCTAssertTrue(starts(env: ["LEYLINE_SOCKET": ""]))
    }
}
