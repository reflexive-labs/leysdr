// SPDX-License-Identifier: GPL-3.0-or-later

// Files only the user can read: the key file, `ai.json`, the usage ledger and the assistant's
// conversations (docs/dev/engine-internals.md, "Credentials and usage" and "Assistant"). `Data.write(options: .atomic)` creates
// its temporary file with the process's umask, usually 0644, and the rename keeps that mode, so a
// rewrite would leave a file other users can read. This writes the temporary file itself, created
// 0600 by `open(2)`, then renames it over the old one (docs/dev/swift-style.md, "Foundation on two
// platforms"), so the file is never readable by anyone else, not even between a write and a
// `chmod`, and a crash mid-write leaves the previous file whole.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Why a private file could not be written. The message names the file and the system's reason.
struct PrivateFileError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// The suffix of the temporary file a write of `path` uses before the rename; one left by a crash
/// is swept by `sweepPrivateFileTemporaries(of:)`.
private let temporarySuffix = ".tmp-"

/// Writes `data` to `path` with mode 0600 through a temporary file and a rename. The parent
/// directory must exist.
func writePrivateFile(_ data: Data, to path: String) throws {
    let tmp = path + temporarySuffix + "\(getpid())"
    let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw PrivateFileError(message: "cannot write \(tmp): \(errnoText())") }
    // O_CREAT's mode only applies to a new file; one left behind by a crash keeps its own.
    _ = fchmod(fd, 0o600)
    let wrote = data.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }
    let synced = fsync(fd) == 0
    close(fd)
    guard wrote, synced else {
        let why = errnoText()
        unlink(tmp)
        throw PrivateFileError(message: "cannot write \(tmp): \(why)")
    }
    guard rename(tmp, path) == 0 else {
        let why = errnoText()
        unlink(tmp)
        throw PrivateFileError(message: "cannot replace \(path): \(why)")
    }
}

/// Removes temporary files a crashed write of `path` left beside it. A secret can be in one.
func sweepPrivateFileTemporaries(of path: String) {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent().path
    let prefix = url.lastPathComponent + temporarySuffix
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
    for name in names where name.hasPrefix(prefix) {
        unlink(dir + "/" + name)
    }
}

private func errnoText() -> String { String(cString: strerror(errno)) }
