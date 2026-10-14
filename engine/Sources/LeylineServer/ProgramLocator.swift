// SPDX-License-Identifier: GPL-3.0-or-later

// How the daemon finds a program it runs by name: a decoder's bare `executable`, and `ley` for
// the workers (docs/dev/engine-internals.md, "Decoders" and "Credentials and usage"). Both look in
// `leylined`'s own directory before `PATH`, because an app bundle keeps every program the daemon
// spawns beside it in `Contents/Helpers`, and a program found there belongs to the same build.

import Foundation

struct ProgramLocator: Sendable {
    /// Searched first, in order: `leylined`'s directory unless a test says otherwise.
    var directories: [String]
    /// Searched after `directories`: the entries of `PATH` unless a test says otherwise.
    var searchPath: [String]

    init(directories: [String] = ProgramLocator.daemonDirectory(),
         searchPath: [String] = ProgramLocator.environmentPath())
    {
        self.directories = directories
        self.searchPath = searchPath
    }

    /// The directory of the running `leylined`, or nothing when it cannot be found.
    static func daemonDirectory() -> [String] {
        guard let exe = currentExecutablePath() else { return [] }
        return [URL(fileURLWithPath: exe).deletingLastPathComponent().path]
    }

    static func environmentPath() -> [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    /// The first executable file called `name` in the directories, then on the search path. A
    /// name with a slash in it is a path, not a name, and is not looked up.
    func find(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for dir in directories + searchPath where !dir.isEmpty {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `explicit` when one is given -- a flag or an environment variable naming the program --
    /// and it is an executable file; otherwise `find(name)`. An explicit path that is not
    /// executable finds nothing rather than falling back, so a mistyped flag is not hidden by
    /// another copy of the program.
    func find(_ name: String, explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty {
            return FileManager.default.isExecutableFile(atPath: explicit) ? explicit : nil
        }
        return find(name)
    }
}
