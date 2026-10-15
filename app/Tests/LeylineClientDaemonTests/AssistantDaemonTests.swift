// SPDX-License-Identifier: Apache-2.0

// The assistant panel's calls against the real daemon, with the engine's scripted fake worker
// standing in for `ley worker assistant`: a conversation starts IDLE and reaches the mirror, a
// message brings the scripted text and a tool step, a question is answered with Allow, a view tool
// call is performed by the window's performer and answered with `AnswerViewTool` so the turn goes
// on, a turn is stopped and the conversation ended. A second case is the attribution story: another
// client labelled `assistant` sets the squelch on the app's channel, and the app's inspector note
// names it. The daemon's data directory is the test's own, so no key reaches the user's keychain.
// The fake worker is `leyline-fake-worker` beside LEYLINED_BIN (`make swift` builds both), and
// its script format is the one `engine/Sources/FakeWorker/main.swift` documents.

import Foundation
import LeylineClient
import LeylineProto
import XCTest

/// The window's part in a view tool call, played by the test: it records each request and
/// answers `show_band` the way `AppSession` does, from the capture the mirror holds.
@MainActor
final class RecordingPerformer: ViewToolPerformer {
    var requests: [AppViewTools.Request] = []
    let mirror: DaemonMirror
    let captureID: String

    init(mirror: DaemonMirror, captureID: String) {
        self.mirror = mirror
        self.captureID = captureID
    }

    func perform(_ request: AppViewTools.Request) async -> ViewToolAnswer {
        requests.append(request)
        guard case .showRange(let lowHz, let highHz, let label) = request else {
            return ViewToolAnswer(text: "not in this test", isError: true)
        }
        let cap = mirror.state.capture(captureID)
        return AppViewTools.showRange(
            lowHz: lowHz, highHz: highHz, label: label, centerHz: cap?.centerHz,
            sampleRate: cap?.sampleRate ?? 0
        ).answer
    }
}

final class AssistantDaemonTests: XCTestCase {
    /// One block per message, in order (the fake worker's format).
    static let script = """
        text Looking.
        tool get_state {}
        done get_state 1 capture, 1 channel
        end

        ask delete_recording {"recording":"job_1"} delete the recording and its files; this cannot be undone
        approved text Deleted.
        declined text Kept.
        end

        view show_band {"band":"2m"}
        text Shown.
        end

        text Working
        sleep 5000
        text never
        end

        """

    var daemon: DaemonUnderTest!
    var dir: String!

    override func setUp() async throws {
        guard let bin = Harness.daemonBinary else {
            throw XCTSkip("set LEYLINED_BIN to run the app's daemon-backed tests (make app-e2e)")
        }
        let worker = (bin as NSString).deletingLastPathComponent + "/leyline-fake-worker"
        guard FileManager.default.isExecutableFile(atPath: worker) else {
            throw XCTSkip("no leyline-fake-worker beside \(bin); make swift builds it")
        }
        let dir = "/tmp/ley-asst-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        self.dir = dir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Self.script.write(toFile: dir + "/script", atomically: true, encoding: .utf8)
        let ley = dir + "/ley"
        let wrapper = """
            #!/bin/sh
            FAKE_WORKER_SCRIPT="\(dir)/script" exec "\(worker)" "$@"

            """
        try wrapper.write(toFile: ley, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ley)
        daemon = try await Harness.start(arguments: ["--data", dir + "/data", "--ley", ley])
    }

    override func tearDown() async throws {
        if let daemon { Harness.stop(daemon) }
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    /// A key and the assistant's model, added through the contract as Settings adds them; the
    /// fake worker's `worker check` accepts any key.
    nonisolated static func chooseModel(_ c: DaemonConnection) async throws {
        var key = Leyline_V1_SetCredentialRequest()
        key.provider = "anthropic"
        key.secret = "sk-ant-test-0042"
        _ = try await c.credentials.setCredential(key)
        var fm = Leyline_V1_FeatureModel()
        fm.feature = "assistant"
        fm.provider = "anthropic"
        fm.model = "claude-test"
        _ = try await c.credentials.setFeatureModel(fm)
    }

    @MainActor
    func testAConversationRunsFromTheAppsCalls() async throws {
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }
        let presence = Task { for try await _ in app.events() {} }
        defer { presence.cancel() }
        let (capture, _) = try await ClientDaemonTests.tuneFixture(app, on: daemon)

        let assistant = AssistantController(connection: app)
        defer { assistant.close() }
        let performer = RecordingPerformer(mirror: mirror, captureID: capture.captureID)
        assistant.performer = performer

        // No key yet: the start is refused with words that point to Settings.
        let refused = await assistant.start()
        XCTAssertFalse(refused)
        XCTAssertEqual(
            assistant.notice?.pointsToSettings, true, "\(String(describing: assistant.notice))")
        XCTAssertNil(assistant.conversation)

        try await Self.chooseModel(app)
        let started = await assistant.start()
        XCTAssertTrue(started, "\(String(describing: assistant.notice))")
        let id = try XCTUnwrap(assistant.conversationID)
        XCTAssertEqual(assistant.conversation?.state, .conversationIdle)
        XCTAssertEqual(
            assistant.conversation?.viewTools.map(\.name),
            ["show_band", "select_recording", "show_place"])
        await assertEventually("the conversation never reached the mirror") {
            mirror.state.conversations.contains { $0.conversationID == id }
        }

        // A message: the scripted text and a tool step.
        let sent = await assistant.send("what's on?")
        XCTAssertTrue(sent, "\(String(describing: assistant.notice))")
        await assertEventually("the first turn never finished") {
            assistant.conversation?.state == .conversationIdle
                && assistant.conversation?.turns.count == 2
        }
        var view = ConversationView(try XCTUnwrap(assistant.conversation))
        XCTAssertEqual(view.turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(view.turns[0].text, "what's on?")
        XCTAssertTrue(view.turns[1].text.contains("Looking."), view.turns[1].text)
        XCTAssertEqual(view.turns[1].steps.map(\.line), ["\u{2192} get_state"])
        XCTAssertEqual(view.turns[1].steps.first?.stateWord, "done")
        XCTAssertEqual(view.turns[1].steps.first?.resultFirstLine, "1 capture, 1 channel")

        // A question: the pending card, then Allow.
        _ = await assistant.send("delete job_1")
        await assertEventually("the assistant never asked") {
            assistant.conversation?.state == .conversationWaiting
        }
        view = ConversationView(try XCTUnwrap(assistant.conversation))
        let question = try XCTUnwrap(view.pending)
        XCTAssertFalse(question.isViewTool)
        XCTAssertEqual(question.question, "The assistant wants to delete_recording job_1.")
        XCTAssertEqual(
            question.reason, "delete the recording and its files; this cannot be undone")
        await assistant.resolve(callID: question.callID, approve: true)
        await assertEventually("the approved turn never finished") {
            assistant.conversation?.state == .conversationIdle
        }
        view = ConversationView(try XCTUnwrap(assistant.conversation))
        XCTAssertTrue(view.turns[3].text.contains("Deleted."), view.turns[3].text)
        XCTAssertFalse(view.turns[3].text.contains("Kept."))

        // A view tool: the window's performer runs it and the answer lets the turn go on.
        _ = await assistant.send("show me 2 m")
        await assertEventually("the view tool's turn never finished") {
            assistant.conversation?.state == .conversationIdle
                && assistant.conversation?.turns.count == 6
        }
        XCTAssertEqual(
            performer.requests,
            [.showRange(lowHz: 144_000_000, highHz: 148_000_000, label: "2 m amateur")])
        view = ConversationView(try XCTUnwrap(assistant.conversation))
        let step = try XCTUnwrap(view.turns[5].steps.first)
        XCTAssertEqual(step.tool, "show_band")
        XCTAssertEqual(step.stateWord, "done")
        XCTAssertTrue(step.resultText.hasPrefix("The waterfall shows "), step.resultText)
        XCTAssertTrue(step.resultJSON.contains(#""place":"radio""#), step.resultJSON)
        XCTAssertTrue(view.turns[5].text.contains("Shown."), view.turns[5].text)

        // Stop: the sleeping turn is closed before its last line.
        _ = await assistant.send("keep going")
        await assertEventually("the turn never started") {
            assistant.conversation?.turns.last?.text.contains("Working") == true
        }
        XCTAssertTrue(ConversationView(try XCTUnwrap(assistant.conversation)).isThinking)
        await assistant.stopTurn()
        await assertEventually("the stopped turn never closed") {
            assistant.conversation?.state == .conversationIdle
                && assistant.conversation?.turns.last?.done == true
        }
        XCTAssertFalse(assistant.conversation?.turns.last?.text.contains("never") ?? true)

        // End: ENDED here and in the mirror.
        await assistant.end()
        XCTAssertEqual(assistant.conversation?.state, .conversationEnded)
        XCTAssertTrue(assistant.needsStart)
        await assertEventually("the mirror never saw the end") {
            mirror.state.conversations.first { $0.conversationID == id }?.state
                == .conversationEnded
        }
        XCTAssertNil(assistant.notice)
    }

    @MainActor
    func testTheAssistantsSquelchChangeIsAttributedInTheAppsMirror() async throws {
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }
        let presence = Task { for try await _ in app.events() {} }
        defer { presence.cancel() }
        let (_, channel) = try await ClientDaemonTests.tuneFixture(app, on: daemon)
        await assertEventually("the channel never reached the mirror") {
            mirror.state.channel(channel.channelID) != nil
        }

        // The worker's tool server dials as kind `mcp`, label `assistant`
        // (`docs/dev/assistant.md`, "The tools"); this connection stands in for it.
        let worker = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "mcp", label: "assistant"))
        defer { worker.close() }
        try await Harness.setSquelch(-45, channel: channel.channelID, via: worker, mirror: mirror)

        XCTAssertEqual(mirror.state.lastCausedBy[channel.channelID]?.label, "assistant")
        let note = ChangeNote.latest(
            for: try XCTUnwrap(mirror.state.channel(channel.channelID)), in: mirror.state,
            selfClientID: app.identity.id)
        XCTAssertEqual(note?.text, "The assistant set the squelch to -45 dBFS.")

        // The app's own write back takes the note away.
        try await Harness.setSquelch(-50, channel: channel.channelID, via: app, mirror: mirror)
        XCTAssertNil(
            ChangeNote.latest(
                for: try XCTUnwrap(mirror.state.channel(channel.channelID)), in: mirror.state,
                selfClientID: app.identity.id))
    }
}
