// SPDX-License-Identifier: GPL-3.0-or-later

// `ley worker check` as the daemon runs it: how `ley` is found, what it is given, and how its
// answer, its silence and its absence become a check (docs/dev/engine-internals.md, "Credentials
// and usage"). A shell script stands in for `ley`.

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

final class WorkerProcessTests: XCTestCase {
    private let secret = "sk-test-SECRETMARKER9f3"
    /// Finds nothing anywhere, so only an explicit path can supply `ley`.
    private let nowhere = ProgramLocator(directories: [], searchPath: [])

    private func worker(_ ley: String?, locator: ProgramLocator? = nil, timeout: Double = 30) -> WorkerProcess {
        WorkerProcess(leyPath: ley, locator: locator ?? nowhere, socketPath: "/tmp/test.sock", checkTimeoutSeconds: timeout)
    }

    func testAScriptedAnswerBecomesTheOutcomeAndTheWorkerGetsTheKeyOnStdin() async throws {
        let dir = try makeTempDir("worker")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = try writeScriptedLey(in: dir, """
        read key
        echo "$key" > "\(dir)/ley.stdin"
        printf '%s\\n' '{"outcome": "rejected", "message": "invalid x-api-key"}'
        """)
        let check = await worker(ley).check(provider: "anthropic", endpoint: "https://gw.example", secret: secret)
        XCTAssertEqual(check.outcome, .rejected)
        XCTAssertEqual(check.message, "invalid x-api-key")
        XCTAssertGreaterThan(check.atNs, 0)
        let args = try String(contentsOfFile: dir + "/ley.args", encoding: .utf8)
        XCTAssertEqual(args, "worker check --provider anthropic --endpoint https://gw.example\n")
        XCTAssertFalse(args.contains("SECRETMARKER"), "the key is never an argument")
        XCTAssertEqual(try String(contentsOfFile: dir + "/ley.stdin", encoding: .utf8), secret + "\n")
        XCTAssertEqual(try String(contentsOfFile: dir + "/ley.socket", encoding: .utf8), "/tmp/test.sock\n",
                       "the worker reports usage to the daemon that ran it")
    }

    func testAWorkerThatEchoesTheKeyHasItReplaced() async throws {
        let dir = try makeTempDir("worker")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = try writeScriptedLey(in: dir, """
        read key
        echo "stderr says $key" >&2
        printf '{"outcome": "accepted", "message": "hello %s"}\\n' "$key"
        """)
        let check = await worker(ley).check(provider: "anthropic", endpoint: "", secret: secret)
        XCTAssertEqual(check.outcome, .accepted)
        XCTAssertEqual(check.message, "hello [key]")
    }

    func testSilenceOrAFailedExitIsUnavailable() async throws {
        let dir = try makeTempDir("worker")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = try writeScriptedLey(in: dir, """
        read key
        echo "ley: unknown command worker" >&2
        exit 1
        """)
        let check = await worker(ley).check(provider: "anthropic", endpoint: "", secret: secret)
        XCTAssertEqual(check.outcome, .unavailable)
        XCTAssertTrue(check.message.contains("without an answer"), check.message)
        XCTAssertTrue(check.message.contains("unknown command worker"), "the worker's own words say why: \(check.message)")
    }

    func testAnAnswerThatIsNotTheJSONLineIsUnavailable() async throws {
        let dir = try makeTempDir("worker")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = try writeScriptedLey(in: dir, "read key\necho hello")
        let check = await worker(ley).check(provider: "anthropic", endpoint: "", secret: secret)
        XCTAssertEqual(check.outcome, .unavailable)
    }

    func testAWorkerThatHangsIsUnavailableAfterTheTimeout() async throws {
        let dir = try makeTempDir("worker")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = try writeScriptedLey(in: dir, "read key\nsleep 30")
        let started = ContinuousClock.now
        let check = await worker(ley, timeout: 0.5).check(provider: "anthropic", endpoint: "", secret: secret)
        XCTAssertEqual(check.outcome, .unavailable)
        XCTAssertTrue(check.message.contains("no answer"), check.message)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    }

    func testNoLeyIsUnavailableAndSaysSo() async throws {
        let check = await worker(nil).check(provider: "anthropic", endpoint: "", secret: secret)
        XCTAssertEqual(check.outcome, .unavailable)
        XCTAssertTrue(check.message.contains("no ley executable"), check.message)
        let named = await worker("/nonexistent/ley").check(provider: "anthropic", endpoint: "", secret: secret)
        XCTAssertEqual(named.outcome, .unavailable)
        XCTAssertTrue(named.message.contains("/nonexistent/ley"), named.message)
    }

    func testLeyIsFoundBesideTheDaemonBeforePath() throws {
        let beside = try makeTempDir("beside")
        let onPath = try makeTempDir("path")
        defer {
            try? FileManager.default.removeItem(atPath: beside)
            try? FileManager.default.removeItem(atPath: onPath)
        }
        try writeScriptedLey(in: onPath, "exit 0")
        let locator = ProgramLocator(directories: [beside], searchPath: [onPath])
        XCTAssertEqual(locator.find("ley"), onPath + "/ley")
        try writeScriptedLey(in: beside, "exit 0")
        XCTAssertEqual(locator.find("ley"), beside + "/ley")
        XCTAssertEqual(locator.find("ley", explicit: onPath + "/ley"), onPath + "/ley", "an explicit path wins")
        XCTAssertNil(locator.find("ley", explicit: onPath + "/missing"), "a wrong explicit path does not fall back")
    }
}
