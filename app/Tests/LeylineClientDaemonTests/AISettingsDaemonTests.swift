// SPDX-License-Identifier: Apache-2.0

// Settings, AI against the real daemon: a key added over the contract reaches the mirror with
// its last four characters and never its text, a removed key leaves it, a feature's model round
// trips, and usage reported over the socket folds into the pane's table. The daemon's check
// worker is a script that accepts the test's key, as `go/internal/e2e/ai_test.go` scripts it,
// and its data directory is the test's own, so no key reaches the user's keychain or files.
// The calls are the ones `AppSession` makes; the session itself is macOS-only.

import Foundation
import LeylineClient
import LeylineProto
import XCTest

final class AISettingsDaemonTests: XCTestCase {
    /// In the key, so a leak into the mirror is found by substring.
    static let canary = "SECRETMARKER7e1"
    static let key = "sk-ant-test-" + canary + "-0042"
    /// `<ley> worker check --provider P` with the key on stdin: accepted for the test's key.
    static let worker = """
        #!/bin/sh
        read -r key
        case "$key" in
          "\(key)") echo '{"outcome":"accepted","message":""}' ;;
          *) echo '{"outcome":"rejected","message":"the worker was handed a key the test never gave"}' ;;
        esac

        """

    var daemon: DaemonUnderTest!
    var dir: String!

    override func setUp() async throws {
        let dir = "/tmp/ley-ai-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        self.dir = dir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ley = dir + "/ley"
        try Self.worker.write(toFile: ley, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ley)
        daemon = try await Harness.start(arguments: ["--data", dir + "/data", "--ley", ley])
    }

    override func tearDown() async throws {
        if let daemon { Harness.stop(daemon) }
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    @MainActor
    func testAKeyReachesTheMirrorAsItsLastFourAndLeavesOnRemove() async throws {
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }
        XCTAssertFalse(
            AISettings.hasAnyAI(mirror.state.ai), "a fresh daemon holds no key, so no AI can run")

        var add = Leyline_V1_SetCredentialRequest()
        add.provider = "anthropic"
        add.secret = Self.key
        add.label = "home"
        let stored = try await app.credentials.setCredential(add)
        XCTAssertEqual(stored.lastFour, "0042")
        XCTAssertEqual(
            AISettings.addedWords(stored),
            "Anthropic key \u{2026}0042 added; the provider accepted it.",
            "the scripted worker accepts the key: \(stored.lastCheck.message)")
        // The pane's line after Add is `addedWords`; the key's text is never in it.
        XCTAssertFalse(AISettings.addedWords(stored).contains(Self.canary))

        await assertEventually("the key never reached the mirror") {
            mirror.state.ai.credentials.count == 1
        }
        let row = try XCTUnwrap(AISettings.keyRows(mirror.state.ai, now: Date()).first)
        XCTAssertEqual(row.provider, "anthropic")
        XCTAssertEqual(row.label, "home")
        XCTAssertEqual(row.maskedKey, "\u{2026}0042")
        XCTAssertEqual(row.outcome, .accepted)
        XCTAssertTrue(AISettings.hasAnyAI(mirror.state.ai))
        XCTAssertFalse(
            mirror.state.ai.textFormatString().contains(Self.canary),
            "the mirror holds the key's text")

        var ref = Leyline_V1_CredentialRef()
        ref.provider = "anthropic"
        let checked = try await app.credentials.checkCredential(ref)
        XCTAssertEqual(KeyOutcome(checked.lastCheck), .accepted)
        XCTAssertFalse(AISettings.checkedWords(checked).contains(Self.canary))

        _ = try await app.credentials.deleteCredential(ref)
        await assertEventually("the removed key stayed in the mirror") {
            mirror.state.ai.credentials.isEmpty
        }
        XCTAssertFalse(AISettings.hasAnyAI(mirror.state.ai))
        let log = daemon.logText()
        XCTAssertFalse(log.isEmpty, "the harness captured no daemon log to search")
        XCTAssertFalse(log.contains(Self.canary), "the daemon logged the key's text")
    }

    @MainActor
    func testAFeaturesModelRoundTrips() async throws {
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }

        var fm = Leyline_V1_FeatureModel()
        fm.feature = "assistant"
        fm.provider = "anthropic"
        fm.model = "claude-sonnet-5-5"
        let got = try await app.credentials.setFeatureModel(fm)
        XCTAssertEqual(got, fm)

        await assertEventually("the model never reached the mirror") {
            mirror.state.ai.features.contains { $0.feature == "assistant" }
        }
        let row = try XCTUnwrap(AISettings.featureRows(mirror.state.ai).first)
        XCTAssertEqual(row.provider, "anthropic")
        XCTAssertEqual(row.model, "claude-sonnet-5-5")
        XCTAssertEqual(row.missingKey, "No Anthropic key is set yet; add one under Keys.")
        XCTAssertFalse(
            AISettings.hasAnyAI(mirror.state.ai), "a model chosen without its key enables nothing")
    }

    @MainActor
    func testReportedUsageFoldsIntoThePanesTable() async throws {
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }

        // What a worker sends after each response, over the socket like any client.
        let worker = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "cli", label: "test-worker"))
        defer { worker.close() }
        let now = Date()
        for (scope, input) in [("conv_a", UInt64(1200)), ("conv_b", UInt64(800))] {
            var r = Leyline_V1_UsageReport()
            r.provider = "anthropic"
            r.model = "claude-sonnet-5-5"
            r.feature = "assistant"
            r.conversationID = scope
            r.requests = 1
            r.inputTokens = input
            r.outputTokens = 100
            r.atNs = Int64(now.timeIntervalSince1970 * 1e9)
            _ = try await worker.usage.reportUsage(r)
        }

        await assertEventually("the usage never reached the mirror") {
            UsageFold(lines: mirror.state.usage, by: .day).total.requests == 2
        }
        let byDay = UsageFold(
            lines: mirror.state.usage, by: .day, sinceDay: UsageFold.sinceDay(now: now))
        XCTAssertEqual(byDay.rows.count, 1, "two conversations on one day are one row")
        XCTAssertEqual(byDay.rows.first?.inputTokens, 2000)
        XCTAssertEqual(byDay.total.outputTokens, 200)
        let byMonth = UsageFold(lines: mirror.state.usage, by: .month)
        XCTAssertEqual(byMonth.rows.map(\.period), [String(byDay.rows[0].period.prefix(7))])
        XCTAssertEqual(byMonth.total.requests, 2)
    }
}
