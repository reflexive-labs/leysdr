// SPDX-License-Identifier: GPL-3.0-or-later

// The usage ledger: reports summed per provider, model, feature, scope and UTC day, kept across a
// restart, trimmed to its retention, published as whole lines, and fed by decoders through their
// records (docs/dev/engine-internals.md, "Credentials and usage").

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

final class UsageLedgerTests: XCTestCase {
    /// 2026-10-14T12:00:00Z and the days around it.
    private static let noonNs: Int64 = 1_791_979_200 * 1_000_000_000
    private static let dayNs: Int64 = 86_400 * 1_000_000_000

    private func report(_ provider: String = "anthropic", model: String = "claude-sonnet-5-5",
                        feature: String = "assistant", conversation: String = "conv_1", job: String = "",
                        input: UInt64 = 0, output: UInt64 = 0, seconds: Double = 0, atNs: Int64) -> Leyline_V1_UsageReport
    {
        var r = Leyline_V1_UsageReport()
        r.provider = provider
        r.model = model
        r.feature = feature
        r.conversationID = conversation
        r.jobID = job
        r.requests = 1
        r.inputTokens = input
        r.outputTokens = output
        r.audioSeconds = seconds
        r.atNs = atNs
        return r
    }

    /// Lines summed by `yyyy-MM`, the way `ley ai usage --by month` folds them.
    private func inputTokensByMonth(_ lines: [Leyline_V1_UsageLine]) -> [String: UInt64] {
        lines.reduce(into: [:]) { $0[String($1.day.prefix(7)), default: 0] += $1.inputTokens }
    }

    func testReportsSumPerKeyAndUTCDayAndSurviveARestart() async throws {
        let dir = try makeTempDir("ledger")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = Ledger.path(inStore: dir)
        let ledger = Ledger(path: path)
        await ledger.load(nowNs: Self.noonNs)
        _ = await ledger.add(report(input: 100, output: 10, atNs: Self.noonNs))
        _ = await ledger.add(report(input: 50, output: 5, atNs: Self.noonNs + 3_600_000_000_000))
        // 23:59:59 UTC the day before is the day before, wherever the daemon is.
        _ = await ledger.add(report(input: 7, atNs: Self.noonNs - 12 * 3_600_000_000_000 - 1_000_000_000))
        _ = await ledger.add(report(model: "claude-haiku-5", input: 1, atNs: Self.noonNs))
        _ = await ledger.add(report(conversation: "conv_2", input: 2, atNs: Self.noonNs))
        // The month before.
        _ = await ledger.add(report(input: 1000, atNs: Self.noonNs - 20 * Self.dayNs))

        let lines = await ledger.lines()
        XCTAssertEqual(lines.map(\.day), ["2026-09-24", "2026-10-13", "2026-10-14", "2026-10-14", "2026-10-14"])
        let today = lines.first { $0.day == "2026-10-14" && $0.model == "claude-sonnet-5-5" && $0.scopeID == "conv_1" }
        XCTAssertEqual(today?.requests, 2)
        XCTAssertEqual(today?.inputTokens, 150)
        XCTAssertEqual(today?.outputTokens, 15)
        XCTAssertEqual(today?.lastAtNs, Self.noonNs + 3_600_000_000_000)
        XCTAssertEqual(inputTokensByMonth(lines), ["2026-09": 1000, "2026-10": 160])

        let reopened = Ledger(path: path)
        await reopened.load(nowNs: Self.noonNs)
        let again = await reopened.lines()
        XCTAssertEqual(again, lines, "the file folds back into the same lines")
    }

    func testFiltersAndTheSinceDay() async throws {
        let dir = try makeTempDir("ledger")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ledger = Ledger(path: Ledger.path(inStore: dir))
        await ledger.load(nowNs: Self.noonNs)
        _ = await ledger.add(report(input: 1, atNs: Self.noonNs - 2 * Self.dayNs))
        _ = await ledger.add(report(input: 2, atNs: Self.noonNs))
        _ = await ledger.add(report("openai", model: "whisper-1", feature: "speech", conversation: "", job: "job_1",
                                    seconds: 12.5, atNs: Self.noonNs))
        var request = Leyline_V1_GetUsageRequest()
        // Late in the day before: that whole day is in, and nothing earlier.
        request.sinceNs = Self.noonNs - Self.dayNs + 11 * 3_600_000_000_000
        let recent = await ledger.lines(matching: request)
        XCTAssertEqual(recent.map(\.day), ["2026-10-14", "2026-10-14"])
        XCTAssertEqual(recent.map(\.provider), ["anthropic", "openai"], "sorted by day, then provider")
        request = .init()
        request.feature = "speech"
        let speech = await ledger.lines(matching: request)
        XCTAssertEqual(speech.count, 1)
        XCTAssertEqual(speech.first?.audioSeconds, 12.5)
        XCTAssertEqual(speech.first?.scopeID, "job_1")
        request = .init()
        request.scopeID = "conv_1"
        request.provider = "anthropic"
        let conversation = await ledger.lines(matching: request)
        XCTAssertEqual(conversation.count, 2)
    }

    func testReportsPastTheRetentionAreDroppedAtStart() async throws {
        let dir = try makeTempDir("ledger")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = Ledger.path(inStore: dir)
        let writer = Ledger(path: path)
        await writer.load(nowNs: Self.noonNs)
        _ = await writer.add(report(input: 1, atNs: Self.noonNs - 401 * Self.dayNs))
        _ = await writer.add(report(input: 2, atNs: Self.noonNs - 399 * Self.dayNs))
        try "not a report\n".appendLine(to: path)

        let reader = Ledger(path: path)
        await reader.load(nowNs: Self.noonNs)
        let lines = await reader.lines()
        XCTAssertEqual(lines.map(\.inputTokens), [2])
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1, "the file is rewritten without what was dropped: \(text)")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "the rewrite keeps the ledger private")
    }

    // MARK: Over the socket

    func testReportUsagePublishesTheLineAndGetUsageAgreesAcrossARestart() async throws {
        let dir = try makeTempDir("usage-daemon")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(dir: dir) { c in
            var key = Leyline_V1_SetCredentialRequest()
            key.provider = "anthropic"
            key.secret = "sk-test-0000-abcd"
            _ = try await c.credentials.setCredential(key, metadata: testMetadata)
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            _ = try await c.usage.reportUsage(self.report(input: 100, output: 10, atNs: 0), metadata: testMetadata)
            _ = try await c.usage.reportUsage(self.report(input: 50, output: 5, atNs: 0), metadata: testMetadata)
            let published = await events.waitFor { if case .usage(let l)? = $0.body { return l.requests == 2 } else { return false } }
            guard case .usage(let line)? = published?.body else { return XCTFail("no usage event with both reports") }
            XCTAssertEqual(line.inputTokens, 150)
            XCTAssertEqual(line.scopeID, "conv_1")
            XCTAssertEqual(line.day, Ledger.utcDay(WallClock.nowNs()))
            let got = try await c.usage.getUsage(Leyline_V1_GetUsageRequest(), metadata: testMetadata)
            XCTAssertEqual(got.lines, [line], "the event and GetUsage agree")
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.usage, [line], "GetState carries the lines")
            XCTAssertEqual(state.ai.credentials.first?.lastUsedAtNs, line.lastAtNs, "the key is marked used")
            let marked = await events.waitFor { if case .ai(let s)? = $0.body { return s.credentials.first?.lastUsedAtNs ?? 0 > 0 } else { return false } }
            XCTAssertNotNil(marked, "marking the key used is a change on the event plane")
            await events.stop()

            var bad = self.report(atNs: 0)
            bad.model = ""
            do {
                _ = try await c.usage.reportUsage(bad, metadata: testMetadata)
                XCTFail("a report without a model was taken")
            } catch {
                XCTAssertEqual(errorCode(error).code, EngineError.Code.invalidArgument)
            }
            var both = self.report(job: "job_1", atNs: 0)
            both.conversationID = "conv_1"
            do {
                _ = try await c.usage.reportUsage(both, metadata: testMetadata)
                XCTFail("a report with two scopes was taken")
            } catch {
                XCTAssertEqual(errorCode(error).code, EngineError.Code.invalidArgument)
            }
            // A key check is made for no job and no conversation, and still marks the key used.
            let check = self.report(model: "/v1/models", feature: "check", conversation: "", atNs: 0)
            _ = try await c.usage.reportUsage(check, metadata: testMetadata)
            var checks = Leyline_V1_GetUsageRequest()
            checks.feature = "check"
            let checkLines = try await c.usage.getUsage(checks, metadata: testMetadata).lines
            XCTAssertEqual(checkLines.map(\.scopeID), [""])
            XCTAssertEqual(checkLines.first?.requests, 1)
        }
        try await withDaemon(dir: dir) { c in
            let got = try await c.usage.getUsage(Leyline_V1_GetUsageRequest(), metadata: testMetadata)
            XCTAssertEqual(got.lines.map(\.inputTokens), [0, 150], "the ledger survives a restart, the check sorted first by model")
        }
    }

    func testADecodersUsageIsCountedUnderItsJob() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "speechy", credentialProvider: "fakeprov")
        // The plugin inherits the in-process daemon's environment, which is this test's.
        setenv("FAKE_DECODER_USAGE", ",fake-model,0.5", 1)
        defer { unsetenv("FAKE_DECODER_USAGE") }
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            var key = Leyline_V1_SetCredentialRequest()
            key.provider = "fakeprov"
            key.secret = "fk-test-0000"
            _ = try await c.credentials.setCredential(key, metadata: testMetadata)
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("nfm_tone.cf32")
            attach.loop = true
            _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var config = Leyline_V1_DecodeConfig()
            config.decoder = "speechy"
            config.frequencyHz = decodeFrequencyHz
            var start = Leyline_V1_StartJobRequest()
            start.decode = config
            let job = try await c.jobs.startJob(start, metadata: testMetadata)

            var request = Leyline_V1_GetUsageRequest()
            request.scopeID = job.jobID
            var lines: [Leyline_V1_UsageLine] = []
            for _ in 0..<200 {
                lines = try await c.usage.getUsage(request, metadata: testMetadata).lines
                if (lines.first?.requests ?? 0) >= 3 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(lines.count, 1)
            let line = try XCTUnwrap(lines.first)
            XCTAssertEqual(line.feature, "speech", "the daemon names the feature, whatever the plugin wrote")
            XCTAssertEqual(line.provider, "fakeprov", "an empty provider is the manifest's")
            XCTAssertEqual(line.model, "fake-model")
            XCTAssertGreaterThanOrEqual(line.requests, 3)
            XCTAssertEqual(line.audioSeconds, Double(line.requests) * 0.5, accuracy: 1e-9)

            var subscription = Leyline_V1_RecordSubscription()
            subscription.jobID = job.jobID
            subscription.sinceSeq = 0
            let record = try await c.decoders.subscribeRecords(subscription, metadata: testMetadata) { response in
                for try await rec in response.messages { return rec }
                return Leyline_V1_DecodeRecord()
            }
            XCTAssertEqual(record.usage.jobID, job.jobID, "the record carries the usage as the ledger counted it")
            XCTAssertEqual(record.usage.feature, "speech")
            _ = try await c.jobs.cancelJob({ var r = Leyline_V1_JobRef(); r.jobID = job.jobID; return r }(), metadata: testMetadata)
        }
    }
}

private extension String {
    func appendLine(to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
