// SPDX-License-Identifier: Apache-2.0

// The build the about panel names. `scripts/bundle-app.sh` stamps two numbers into Info.plist:
// `CFBundleVersion`, the commit count Sparkle compares, which the standard panel already shows
// beside the version, and `LeylineBuild`, the `git describe` string, which names the tree a bug
// report came from (docs/plans/distribution.md, "Sparkle"). The rule is here so the Linux tests
// reach it; `LeylineApp` shows the panel.

public enum BuildInfo {
    /// The Info.plist key holding the `git describe` string.
    public static let key = "LeylineBuild"

    /// The about panel's line naming the tree, or nil when there is none to name: a bare
    /// executable (`make app-run`) has no Info.plist, and an unstamped copy still holds the
    /// `__BUILD_DESCRIBE__` placeholder.
    public static func aboutLine(info: [String: Any]?) -> String? {
        guard let build = info?[key] as? String, !build.isEmpty, !build.hasPrefix("__") else {
            return nil
        }
        return "Build \(build)"
    }
}
