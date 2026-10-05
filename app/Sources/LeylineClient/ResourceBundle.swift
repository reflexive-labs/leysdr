// SPDX-License-Identifier: Apache-2.0

// Where the target's resource bundle (the band table's seed file) is found. SwiftPM's generated
// `Bundle.module` looks beside the app's root (`Leyline.app/<bundle>`) and then at the absolute
// path of the build that compiled it, and calls `fatalError` when neither exists. A distributed
// app carries the bundle in `Contents/Resources` (scripts/bundle-app.sh), which the accessor never
// looks in, so on any Mac but the build machine it would stop the app at launch. The lookup below
// tries the places a bundle really sits first and touches `Bundle.module` only where its build
// path can exist (docs/dev/release-checklist.md, "Acceptance, on a second Mac").

import Foundation

enum ResourceBundle {
    /// The bundle SwiftPM writes for LeylineClient: `<package>_<target>`, with `.bundle` on
    /// macOS and `.resources` on Linux.
    static let name = "LeylineApp_LeylineClient"
    static let extensions = ["bundle", "resources"]

    /// The directories to look in, in order: the app's `Contents/Resources`, the app's root,
    /// beside the executable (`swift run`, a Linux test binary), and beside the bundle this code
    /// was loaded from (a macOS `.xctest` bundle in `.build/<triple>/<config>`).
    static var searchDirectories: [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        dirs.append(Bundle.main.bundleURL)
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            dirs.append(exe.deletingLastPathComponent())
        }
        dirs.append(Bundle(for: Token.self).bundleURL.deletingLastPathComponent())
        return dirs
    }

    /// The first `<dir>/<name>.<ext>` among `directories` that holds `file`, and the file's URL.
    static func find(_ file: String, in directories: [URL]) -> URL? {
        let fm = FileManager.default
        for dir in directories {
            for ext in extensions {
                let url = dir.appendingPathComponent("\(name).\(ext)").appendingPathComponent(file)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// `Bundle.module`'s build path lies under this package's `.build`, which exists only on a
    /// machine holding the source tree that compiled this binary. Anywhere else the accessor
    /// finds nothing and stops the process, so it is not called.
    static var buildTreeExists: Bool {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LeylineClient
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: package.appendingPathComponent(".build").path)
    }

    /// The URL of `<resource>.<ext>` in the resource bundle, or nil when no bundle holding it
    /// can be found.
    static func url(forResource resource: String, withExtension ext: String) -> URL? {
        if let url = find("\(resource).\(ext)", in: searchDirectories) { return url }
        guard buildTreeExists else { return nil }
        return Bundle.module.url(forResource: resource, withExtension: ext)
    }

    private final class Token {}
}
