// SPDX-License-Identifier: Apache-2.0

// The app's log: one line per thing the window did, to a file, to stderr and to the unified log
// under `com.leyline.app`, so an oddity can be read back after the fact rather than described
// from memory. `LEYLINE_APP_LOG` names the file; the default is `~/Library/Logs/Leyline/app.log`.
// `make app-run` points it at `tmp/leyline-app.log` in the checkout, which the container's bind
// mount sees (docs/dev/app.md, "Logs"). The file is rotated once at launch when it passes 5 MB.

import Foundation
import os

final class AppLog: @unchecked Sendable {
    static let shared = AppLog()
    static let pathEnv = "LEYLINE_APP_LOG"
    static let rotateAt = 5 * 1024 * 1024

    let path: String
    private let lock = NSLock()
    private let handle: FileHandle?
    private let logger = Logger(subsystem: "com.leyline.app", category: "app")
    private let stamp: ISO8601DateFormatter

    private init() {
        let env = ProcessInfo.processInfo.environment
        if let p = env[Self.pathEnv], !p.isEmpty {
            path = p
        } else {
            let home = env["HOME"] ?? NSHomeDirectory()
            path = home + "/Library/Logs/Leyline/app.log"
        }
        stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int), size > Self.rotateAt
        {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    /// `area` is the part of the window that logs (`session`, `tune`, `feed`, `waterfall`);
    /// the message is one sentence with the numbers in it.
    func log(_ area: String, _ message: String) {
        // Both writes happen under the lock: stderr outside it let two lines interleave.
        lock.lock()
        let line = Data("\(stamp.string(from: Date())) \(area): \(message)\n".utf8)
        handle?.write(line)
        FileHandle.standardError.write(line)
        lock.unlock()
        logger.log("\(area, privacy: .public): \(message, privacy: .public)")
    }
}

func log(_ area: String, _ message: String) { AppLog.shared.log(area, message) }
