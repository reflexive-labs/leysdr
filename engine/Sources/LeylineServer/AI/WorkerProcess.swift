// SPDX-License-Identifier: GPL-3.0-or-later

// The `ley` workers the daemon spawns to call a provider (docs/dev/engine-internals.md,
// "Credentials and usage"). The daemon makes no model call itself: provider SDKs, HTTP clients and
// prompts stay out of the process that carries the hot path (invariant 4), and a provider can be
// added or changed with a `ley` release rather than a daemon one.
//
// A worker reads the key from stdin, never from an argument (visible in `ps`) or the environment
// (inherited by anything the worker runs). Whatever the worker writes back -- its answer's message
// and its stderr -- has the secret replaced before it reaches a log line or a `CredentialCheck`,
// so a worker that echoes its input cannot put the key on the event plane. The forms replaced are
// the secret as it stands, JSON-escaped, and percent-encoded (`redacting(_:in:)`); a worker that
// transforms it any other way -- base64, a hash, a prefix cut short -- is not caught.

import EngineCore
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import LeylineProto
import Logging

struct WorkerProcess: Sendable {
    /// How long a check may take before it is abandoned and reported `UNAVAILABLE`: long enough
    /// for one slow HTTPS round trip to a provider, short enough that `ley ai add` is not left
    /// hanging on a dead network.
    static let checkTimeoutSeconds: Double = 30

    /// `--ley` or `LEYLINE_LEY`: the `ley` to run, ahead of any search.
    var leyPath: String?
    /// Where `ley` is looked for when nothing names it: beside `leylined`, then `PATH`.
    var locator: ProgramLocator
    /// The daemon's socket, passed to the worker as `LEYLINE_SOCKET` so its `ReportUsage` reaches
    /// this daemon and not the user's default one.
    var socketPath: String
    var checkTimeoutSeconds: Double = WorkerProcess.checkTimeoutSeconds

    /// Runs `ley worker check --provider P [--endpoint E]` with `secret` on stdin and reads the one
    /// JSON line it answers with, `{"outcome": "accepted"|"rejected"|"unavailable", "message":
    /// "…"}`. Never throws: a worker that cannot be found, started or understood, or that does not
    /// answer in time, is `UNAVAILABLE` with the reason, which says nothing about the key itself.
    func check(provider: String, endpoint: String, secret: String) async -> Leyline_V1_CredentialCheck {
        guard let ley = locator.find("ley", explicit: leyPath) else {
            if let leyPath, !leyPath.isEmpty {
                return Self.unavailable("the ley named by --ley or LEYLINE_LEY (\(leyPath)) is not an executable file, so the key could not be checked")
            }
            return Self.unavailable("no ley executable was found beside leylined, on PATH or by --ley, so the key could not be checked")
        }
        var args = ["worker", "check", "--provider", provider]
        if !endpoint.isEmpty { args += ["--endpoint", endpoint] }
        var environment = ProcessInfo.processInfo.environment
        environment["LEYLINE_SOCKET"] = socketPath
        let child = ChildProcess(executable: ley, args: args, environment: environment)
        let log = Logger(label: "leyline.worker.check")
        do {
            try child.run { log.info("\(Self.redacting(secret, in: $0))") }
        } catch {
            return Self.unavailable("\(ley) could not be started: \(error)")
        }
        let stdin = child.input.fileHandleForWriting
        try? stdin.write(contentsOf: Data((secret + "\n").utf8))
        try? stdin.close()

        let answer = await Self.firstLine(of: child, timeoutSeconds: checkTimeoutSeconds)
        defer { Task { if !(await child.waitForExit(seconds: 2)) { await child.terminate() } } }
        switch answer {
        case .timedOut:
            await child.terminate()
            return Self.unavailable("ley worker check gave no answer within \(Int(checkTimeoutSeconds)) s")
        case .nothing:
            _ = await child.waitForExit(seconds: 1)
            let status = child.process.isRunning ? "" : " (status \(child.process.terminationStatus))"
            let said = await child.lastErrorLine().map { ": " + Self.redacting(secret, in: $0) } ?? ""
            return Self.unavailable("ley worker check exited\(status) without an answer\(said)")
        case .line(let text):
            // Decoded first and redacted after, on the message alone: replacing text inside the raw
            // line could cut through the JSON around a short secret.
            var check = Self.parse(text)
            check.message = Self.redacting(secret, in: check.message)
            return check
        }
    }

    /// The worker's answer line as a check, stamped now.
    static func parse(_ line: String) -> Leyline_V1_CredentialCheck {
        struct Answer: Decodable {
            var outcome: String
            var message: String?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(line.utf8)) else {
            return unavailable("ley worker check answered with something other than its JSON line")
        }
        var check = Leyline_V1_CredentialCheck()
        check.message = answer.message ?? ""
        check.atNs = WallClock.nowNs()
        switch answer.outcome {
        case "accepted": check.outcome = .accepted
        case "rejected": check.outcome = .rejected
        case "unavailable": check.outcome = .unavailable
        default:
            return unavailable("ley worker check answered with an outcome this daemon does not know: \(answer.outcome)")
        }
        return check
    }

    static func unavailable(_ message: String) -> Leyline_V1_CredentialCheck {
        var check = Leyline_V1_CredentialCheck()
        check.outcome = .unavailable
        check.message = message
        check.atNs = WallClock.nowNs()
        return check
    }

    /// `text` with every occurrence of the secret replaced, for anything a worker or plugin wrote:
    /// the secret as it stands, as a JSON string carries it (with and without `/` escaped), and
    /// percent-encoded as a URL carries it. Longer forms go first, so a form that contains another
    /// is replaced whole.
    static func redacting(_ secret: String, in text: String) -> String {
        guard !secret.isEmpty else { return text }
        var forms: Set<String> = [secret]
        if let json = try? JSONEncoder().encode(secret), let quoted = String(data: json, encoding: .utf8),
           quoted.count >= 2
        {
            let plain = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "\\/", with: "/")
            forms.insert(plain)
            forms.insert(plain.replacingOccurrences(of: "/", with: "\\/"))
        }
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { forms.insert(encoded) }
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { forms.insert(encoded) }
        var out = text
        for form in forms.sorted(by: { $0.count > $1.count }) where !form.isEmpty {
            out = out.replacingOccurrences(of: form, with: "[key]")
        }
        return out
    }

    private enum Answer: Sendable {
        case line(String)
        case nothing
        case timedOut
    }

    /// The first line the child writes on stdout, read on a thread of its own, or what happened
    /// instead. A child that is killed on the timeout closes stdout, which ends the thread.
    private static func firstLine(of child: ChildProcess, timeoutSeconds: Double) async -> Answer {
        let (lines, continuation) = AsyncStream<Answer>.makeStream()
        let outFD = child.output.fileHandleForReading.fileDescriptor
        Thread.detachNewThread {
            var line = [UInt8]()
            var byte: UInt8 = 0
            while true {
                let got = read(outFD, &byte, 1)
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { break }
                if byte == UInt8(ascii: "\n") { break }
                line.append(byte)
            }
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            continuation.yield(text.isEmpty ? .nothing : .line(text))
            continuation.finish()
        }
        return await withTaskGroup(of: Answer.self) { group in
            group.addTask {
                for await answer in lines { return answer }
                return .nothing
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1e9))
                return .timedOut
            }
            let first = await group.next() ?? .nothing
            group.cancelAll()
            return first
        }
    }
}
