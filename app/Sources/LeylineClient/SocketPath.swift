// SPDX-License-Identifier: Apache-2.0

// Where the daemon listens (docs/dev/engine-internals.md, "Daemon lifecycle"). The same rule
// `ley` and `leylined` apply, so the three agree without configuration: `LEYLINE_SOCKET` wins,
// then the platform default.

import Foundation

public enum SocketPath {
    /// The socket this process should dial: `LEYLINE_SOCKET` when set, else the platform default.
    public static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let s = environment["LEYLINE_SOCKET"], !s.isEmpty { return s }
        #if os(macOS)
        let home = environment["HOME"] ?? NSHomeDirectory()
        return home + "/Library/Application Support/Leyline/leyline.sock"
        #else
        if let dir = environment["XDG_RUNTIME_DIR"], !dir.isEmpty { return dir + "/leyline.sock" }
        return "/tmp/leyline-\(getuid()).sock"
        #endif
    }
}
