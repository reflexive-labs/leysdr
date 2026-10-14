// SPDX-License-Identifier: GPL-3.0-or-later

// The usage ledger (docs/dev/engine-internals.md, "Credentials and usage"): what every provider
// call used, in the provider's own units, as the worker or plugin that made it reported.
//
// `<store>/usage.jsonl` holds one `UsageReport` per line in proto3 JSON, appended as each arrives,
// so a crash loses at most the report being written and the file can be read with `jq`. At start
// it is folded into `UsageLine`s, one per provider, model, feature, scope and UTC day -- UTC
// because that is how the providers' consoles count, so the two can be compared -- and reports
// older than `retentionDays` are dropped and the file rewritten without them. There is no price
// anywhere: the same model costs different amounts through different routes, and the provider's
// console is where cost lives.

import EngineCore
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import LeylineProto
import Logging
import SwiftProtobuf

actor Ledger {
    /// How long a report is kept: a little over a year, so this month can be set beside the same
    /// month last year.
    static let retentionDays: Int64 = 400

    private struct Key: Hashable {
        var provider: String
        var model: String
        var feature: String
        var scopeID: String
        var day: String
    }

    private let path: String
    private var lines: [Key: Leyline_V1_UsageLine] = [:]
    /// Counts reports folded in, so a publisher can tell a line it holds is no longer the newest
    /// (`SessionStore.publishUsage`).
    private var version: UInt64 = 0
    private var loaded = false
    private let log = Logger(label: "leyline.usage")

    init(path: String) {
        self.path = path
    }

    /// `usage.jsonl` in a record store directory.
    static func path(inStore storePath: String) -> String { storePath + "/usage.jsonl" }

    /// Reads and folds the file, dropping what is older than `retentionDays` before `nowNs`. Runs
    /// once; every other call loads first if this has not run.
    func load(nowNs: Int64 = WallClock.realNowNs()) {
        guard !loaded else { return }
        loaded = true
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let oldest = nowNs - Self.retentionDays * 86_400 * 1_000_000_000
        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = true
        var kept: [Substring] = []
        var dropped = 0
        var unreadable = 0
        let text = String(decoding: data, as: UTF8.self)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let report = try? Leyline_V1_UsageReport(jsonString: String(raw), options: options) else {
                unreadable += 1
                continue
            }
            if report.atNs < oldest {
                dropped += 1
                continue
            }
            kept.append(raw)
            fold(report)
        }
        if unreadable > 0 { log.warning("\(path): \(unreadable) lines are not usage reports; skipping them") }
        if dropped > 0 || unreadable > 0 { rewrite(kept) }
    }

    /// Adds one report: appended to the file, folded into its line. The report's own time decides
    /// the day, and a report with none is stamped now. Returns the whole line after the report,
    /// with the ledger's version for the publisher.
    func add(_ incoming: Leyline_V1_UsageReport) -> (line: Leyline_V1_UsageLine, version: UInt64) {
        load()
        var report = incoming
        if report.atNs == 0 { report.atNs = WallClock.nowNs() }
        append(report)
        let line = fold(report)
        return (line, version)
    }

    /// The lines a `GetUsage` asks for, sorted by day, then provider, model, feature and scope.
    /// `since_ns` is compared at the ledger's grain: a line is in when its UTC day is the day
    /// `since_ns` falls on or later, so a day is never cut in half.
    func lines(matching request: Leyline_V1_GetUsageRequest = .init()) -> [Leyline_V1_UsageLine] {
        load()
        let sinceDay = request.sinceNs > 0 ? Self.utcDay(request.sinceNs) : ""
        return lines.values.filter { line in
            (sinceDay.isEmpty || line.day >= sinceDay)
                && (request.provider.isEmpty || line.provider == request.provider)
                && (request.feature.isEmpty || line.feature == request.feature)
                && (request.scopeID.isEmpty || line.scopeID == request.scopeID)
        }.sorted {
            ($0.day, $0.provider, $0.model, $0.feature, $0.scopeID) < ($1.day, $1.provider, $1.model, $1.feature, $1.scopeID)
        }
    }

    /// The UTC calendar day `ns` (CLOCK_REALTIME) falls on, as `yyyy-MM-dd`.
    static func utcDay(_ ns: Int64) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: Double(ns) / 1e9)
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A line's identity as text, for the publisher's per-line version.
    static func key(of line: Leyline_V1_UsageLine) -> String {
        [line.provider, line.model, line.feature, line.scopeID, line.day].joined(separator: "\u{1f}")
    }

    @discardableResult
    private func fold(_ report: Leyline_V1_UsageReport) -> Leyline_V1_UsageLine {
        let scopeID = report.jobID.isEmpty ? report.conversationID : report.jobID
        let key = Key(provider: report.provider, model: report.model, feature: report.feature, scopeID: scopeID,
                      day: Self.utcDay(report.atNs))
        var line = lines[key] ?? {
            var fresh = Leyline_V1_UsageLine()
            fresh.provider = key.provider
            fresh.model = key.model
            fresh.feature = key.feature
            fresh.scopeID = key.scopeID
            fresh.day = key.day
            return fresh
        }()
        line.requests += report.requests
        line.inputTokens += report.inputTokens
        line.outputTokens += report.outputTokens
        line.cacheReadTokens += report.cacheReadTokens
        line.cacheWriteTokens += report.cacheWriteTokens
        line.audioSeconds += report.audioSeconds
        line.lastAtNs = max(line.lastAtNs, report.atNs)
        lines[key] = line
        version += 1
        return line
    }

    /// One report on the end of the file, written with one `write(2)` so it reaches the kernel
    /// before the report is acknowledged. A failure costs a log line: the report is still in the
    /// lines for as long as the daemon runs.
    private func append(_ report: Leyline_V1_UsageReport) {
        do {
            var data = try report.jsonUTF8Data()
            data.append(0x0a)
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw EngineError.internalError(String(cString: strerror(errno))) }
            defer { close(fd) }
            let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard wrote == data.count else { throw EngineError.internalError(String(cString: strerror(errno))) }
        } catch {
            log.error("cannot append to \(path): \(error)")
        }
    }

    private func rewrite(_ kept: [Substring]) {
        var text = kept.joined(separator: "\n")
        if !text.isEmpty { text += "\n" }
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            log.error("cannot rewrite \(path): \(error)")
        }
    }
}
