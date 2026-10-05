// SPDX-License-Identifier: Apache-2.0

// When the app's updater runs. Sparkle itself is linked by `LeylineApp` alone (`Updater.swift`);
// the rule is here so the Linux tests reach it.

import Foundation

/// Whether the app starts Sparkle's updater (docs/plans/distribution.md, "Sparkle"). Only a
/// bundle can be updated, and only one that names the key updates are signed with: Sparkle refuses
/// to start without `SUPublicEDKey`, with an alert at every launch. A run with `LEYLINE_SOCKET` or
/// a stage file (the screenshots, the e2e suite) checks for nothing either.
public enum AppUpdates {
    public static func shouldStart(
        bundlePath: String, publicKey: String?, environment: [String: String]
    ) -> Bool {
        guard bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".app/") else { return false }
        guard let publicKey, !publicKey.isEmpty else { return false }
        for key in ["LEYLINE_SOCKET", ShotStage.environmentKey] {
            if let v = environment[key], !v.isEmpty { return false }
        }
        return true
    }
}
