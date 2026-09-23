// SPDX-License-Identifier: GPL-3.0-or-later

// Delivery to a notification sink (docs/design/decoders.md, "Predicates and delivery"): a record
// that passes a job's predicate is handed here, and the sink is a webhook, a shell hook or a
// macOS user notification. This is off the hot path -- the runner fires it as a detached task so a
// slow webhook never stalls the reader -- so clarity wins over allocation counting. Every failure
// is logged and swallowed: if a failed delivery could fail the job, a job with a trigger would be
// less reliable than one without, and driver C needs the reverse.

import Foundation
import LeylineProto
import Logging
import SwiftProtobuf

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux.
#endif

struct Notifier: Sendable {
    /// A ceiling on any single delivery, so a hung webhook or shell hook cannot pile up.
    static let timeoutSeconds: Double = 10

    private let log = Logger(label: "leyline.decoders.notify")

    func fire(_ record: Leyline_V1_DecodeRecord, _ target: Leyline_V1_NotifyTarget) async {
        switch target.target {
        case .webhook(let url): await webhook(record, url)
        case .shell(let command): await shell(record, command)
        case .macosNotification: await macosNotification(record)
        case .none: break
        }
    }

    private func recordJSON(_ record: Leyline_V1_DecodeRecord) -> Data {
        (try? record.jsonUTF8Data()) ?? Data("{}".utf8)
    }

    // MARK: Webhook

    private func webhook(_ record: Leyline_V1_DecodeRecord, _ urlString: String) async {
        guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else {
            log.warning("webhook target is not an http(s) URL: \(urlString)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = recordJSON(record)
        request.timeoutInterval = Self.timeoutSeconds
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.warning("webhook \(urlString) answered \(http.statusCode) for \(record.recordID)")
            }
        } catch {
            log.warning("webhook \(urlString) failed for \(record.recordID): \(error)")
        }
    }

    // MARK: Shell hook

    private func shell(_ record: Leyline_V1_DecodeRecord, _ command: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // The promoted fields in the environment, so a hook can branch without parsing the JSON.
        var env = ProcessInfo.processInfo.environment
        env["LEYLINE_PROTOCOL"] = record.protocol
        env["LEYLINE_DEVICE_ID"] = record.deviceID
        env["LEYLINE_KIND"] = record.kind
        env["LEYLINE_RECORD_ID"] = record.recordID
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        do {
            try process.run()
        } catch {
            log.warning("shell hook could not start (\(command)): \(error)")
            return
        }
        // The record JSON on stdin, then close so the hook sees EOF and can finish. The throwing
        // write, not the legacy `write(_:)`: a hook that ignores stdin closes the pipe, and EPIPE
        // must be a caught error here, never the `try!` crash the deprecated call turns it into.
        let json = recordJSON(record)
        try? stdin.fileHandleForWriting.write(contentsOf: json)
        try? stdin.fileHandleForWriting.close()
        // A bounded wait: reap the hook if it finishes soon, otherwise leave it to run detached
        // rather than parking this task on a command that never exits.
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { process.waitUntilExit(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1e9))
                return false
            }
            let reaped = await group.next() ?? false
            group.cancelAll()
            if reaped, process.terminationStatus != 0 {
                log.warning("shell hook exited \(process.terminationStatus) for \(record.recordID)")
            }
        }
    }

    // MARK: macOS user notification

    private func macosNotification(_ record: Leyline_V1_DecodeRecord) async {
        let title = record.protocol.isEmpty ? "Leyline" : "Leyline: \(record.protocol)"
        let body = notificationBody(record)
        #if os(macOS)
        // osascript is the path that needs no bundle and no entitlements, which a daemon spawned by
        // launchd has neither of. NSUserNotification/UNUserNotificationCenter both require a bundle.
        let script = "display notification \(quote(body)) with title \(quote(title))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.warning("osascript notification failed for \(record.recordID): \(error)")
        }
        #else
        // No macOS notification centre here: a headless run logs the record at notice so it is not
        // silent (the design doc: UNIMPLEMENTED off macOS, the daemon logs instead).
        log.notice("notification (no macOS notification centre): \(title) -- \(body)")
        #endif
    }

    private func notificationBody(_ record: Leyline_V1_DecodeRecord) -> String {
        var parts: [String] = []
        if !record.deviceID.isEmpty { parts.append(record.deviceID) }
        if !record.kind.isEmpty { parts.append(record.kind) }
        return parts.isEmpty ? record.recordID : parts.joined(separator: " ")
    }

    /// An AppleScript string literal: wrap in quotes and escape backslashes and quotes.
    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
