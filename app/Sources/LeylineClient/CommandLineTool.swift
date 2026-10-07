// SPDX-License-Identifier: Apache-2.0

// Installing the `ley` command carried by the Mac app. The app owns the confirmation and macOS
// authorization UI; the path checks and the narrowly-scoped shell command are here so Linux tests
// prove what the privileged operation may replace.

import Foundation

public enum CommandLineTool {
    public static let destinationPath = "/usr/local/bin/ley"

    public enum Status: Sendable, Equatable {
        case unavailable
        case missing
        case installed
        case replaceable
        case conflict
    }

    /// Whether the bundle's command needs installing. A symlink from an older Leyline app is safe
    /// to replace; any other occupant of `/usr/local/bin/ley` belongs to someone else.
    public static func status(
        sourcePath: String, destinationPath: String = destinationPath,
        fileManager: FileManager = .default
    ) -> Status {
        guard fileManager.fileExists(atPath: sourcePath) else { return .unavailable }
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: destinationPath) {
            if target == sourcePath { return .installed }
            return target.hasSuffix("/Leyline.app/Contents/Helpers/ley")
                ? .replaceable : .conflict
        }
        return fileManager.fileExists(atPath: destinationPath) ? .conflict : .missing
    }

    /// The command macOS runs after administrator approval. It creates one parent directory and
    /// one symlink, and refuses a regular file or a symlink that did not come from Leyline.
    public static func installCommand(
        sourcePath: String, destinationPath: String = destinationPath
    ) -> String {
        let parent = (destinationPath as NSString).deletingLastPathComponent
        let source = shellWord(sourcePath)
        let destination = shellWord(destinationPath)
        let directory = shellWord(parent)
        return "set -eu; source=\(source); destination=\(destination); "
            + "[ -x \"$source\" ] || { echo 'the bundled ley command is not executable' >&2; exit 72; }; "
            + "if [ -L \"$destination\" ]; then current=$(/usr/bin/readlink \"$destination\"); "
            + "case \"$current\" in \"$source\"|*/Leyline.app/Contents/Helpers/ley) ;; "
            + "*) echo 'another symlink already uses /usr/local/bin/ley' >&2; exit 73 ;; esac; "
            + "elif [ -e \"$destination\" ]; then "
            + "echo 'another file already uses /usr/local/bin/ley' >&2; exit 73; fi; "
            + "/bin/mkdir -p \(directory); /bin/ln -sfn \"$source\" \"$destination\""
    }

    private static func shellWord(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
