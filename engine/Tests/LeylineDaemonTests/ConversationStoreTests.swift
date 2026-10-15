// SPDX-License-Identifier: GPL-3.0-or-later

// ConversationStore without the socket: the state rule on its own, the idle limit against a test
// clock, a worker that leaves between turns, a missing `ley`, and the daemon's shutdown
// (docs/dev/engine-internals.md, "Assistant").

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import Synchronization
import XCTest

final class ConversationStoreTests: XCTestCase {
    private let client = ClientContext(id: "cli_test", kind: "cli", label: "xctest")

    /// Every conversation the store published, in the order it published them.
    private final class Published: Sendable {
        private let all = Mutex<[Leyline_V1_Conversation]>([])
        func add(_ conversation: Leyline_V1_Conversation) { all.withLock { $0.append(conversation) } }
        var conversations: [Leyline_V1_Conversation] { all.withLock { $0 } }
    }

    /// A store whose `ley` is the fake worker playing `scripts`, with an anthropic key.
    private func makeStore(in dir: String, scripts: [String], ley: String? = nil, timing: ConversationStore.Timing = .init(),
                           published: Published = Published()) async throws -> ConversationStore
    {
        let credentials = CredentialStore(path: dir + "/data/ai.json", secrets: FileSecrets(inData: dir + "/data"))
        _ = try await credentials.set(provider: "anthropic", secret: "sk-test-store-key-0042", label: "", endpoint: "")
        let path = try ley ?? writeFakeWorkerLey(in: dir, scripts: scripts)
        let spawner = WorkerProcess(leyPath: path, locator: ProgramLocator(directories: [], searchPath: []),
                                    socketPath: dir + "/d.sock")
        return ConversationStore(credentials: credentials, spawner: spawner, timing: timing) { conversation, _ in
            published.add(conversation)
        }
    }

    private func request(provider: String = "anthropic") -> Leyline_V1_StartConversationRequest {
        var request = Leyline_V1_StartConversationRequest()
        request.provider = provider
        return request
    }

    private func turn(_ id: String, done: Bool = false, lastCall: Leyline_V1_ToolCallState? = nil) -> Leyline_V1_Turn {
        var turn = Leyline_V1_Turn()
        turn.turnID = id
        turn.role = .assistant
        turn.text = "so far"
        turn.done = done
        if let lastCall {
            var first = Leyline_V1_ToolCall()
            first.callID = "call1"
            first.tool = "list_devices"
            first.state = .toolCallDone
            var last = Leyline_V1_ToolCall()
            last.callID = "call2"
            last.tool = "tune"
            last.argumentsJson = #"{"hz":1}"#
            last.reason = "taking over a radio asks"
            last.state = lastCall
            turn.tools = [first, last]
        }
        return turn
    }

    /// Waits up to five seconds while the conversation's state satisfies `busy`.
    private func waitWhile(_ store: ConversationStore, _ id: String,
                           _ busy: (Leyline_V1_ConversationState) -> Bool) async throws
    {
        for _ in 0..<250 {
            guard busy(try await store.get(id).state) else { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: The state rule

    func testTheStateFollowsTheTurnTheWorkerWrote() {
        var conversation = Leyline_V1_Conversation()
        conversation.fold(turn("t2"))
        XCTAssertEqual(conversation.state, .conversationThinking)
        XCTAssertFalse(conversation.hasPending)

        conversation.fold(turn("t2", lastCall: .toolCallAwaitingApproval))
        XCTAssertEqual(conversation.state, .conversationWaiting)
        XCTAssertEqual(conversation.pending.callID, "call2")
        XCTAssertEqual(conversation.pending.tool, "tune")
        XCTAssertEqual(conversation.pending.argumentsJson, #"{"hz":1}"#)
        XCTAssertEqual(conversation.pending.reason, "taking over a radio asks")
        XCTAssertFalse(conversation.pending.viewTool)
        XCTAssertEqual(conversation.turns.count, 1, "a turn with a known id replaces it")

        conversation.fold(turn("t2", lastCall: .toolCallAwaitingClient))
        XCTAssertTrue(conversation.pending.viewTool)

        conversation.fold(turn("t2", lastCall: .toolCallRunning))
        XCTAssertEqual(conversation.state, .conversationThinking, "only the last call decides")
        XCTAssertFalse(conversation.hasPending)

        conversation.fold(turn("t2", done: true, lastCall: .toolCallAwaitingApproval))
        XCTAssertEqual(conversation.state, .conversationIdle, "a done turn is idle whatever its calls say")
        XCTAssertFalse(conversation.hasPending)

        conversation.fold(turn("t9"))
        XCTAssertEqual(conversation.turns.map(\.turnID), ["t2", "t9"], "a turn with an unknown id is appended")
    }

    func testTheNextUserTurnIsOnePastTheHighest() {
        XCTAssertEqual(ConversationStore.nextTurnID(after: []), "t1")
        XCTAssertEqual(ConversationStore.nextTurnID(after: [turn("t1"), turn("t2")]), "t3")
        XCTAssertEqual(ConversationStore.nextTurnID(after: [turn("t1"), turn("t5")]), "t6")
        XCTAssertEqual(ConversationStore.nextTurnID(after: [turn("t1"), turn("answer")]), "t3",
                       "an id the daemon cannot read still counts as a turn")
    }

    func testReplayIsEveryVersionAfterTheClientsOrTheCurrentState() {
        let versions = (1...100).map { seq -> Leyline_V1_Conversation in
            var conversation = Leyline_V1_Conversation()
            conversation.seq = UInt64(seq)
            return conversation
        }
        let kept = Array(versions.suffix(ConversationStore.keptVersions))
        let current = versions[99]
        XCTAssertEqual(ConversationStore.replay(kept, current: current, sinceSeq: 0).map(\.seq), [100])
        XCTAssertEqual(ConversationStore.replay(kept, current: current, sinceSeq: 100).map(\.seq), [])
        XCTAssertEqual(ConversationStore.replay(kept, current: current, sinceSeq: 97).map(\.seq), [98, 99, 100])
        XCTAssertEqual(ConversationStore.replay(kept, current: current, sinceSeq: 36).count, 64, "the oldest kept version")
        XCTAssertEqual(ConversationStore.replay(kept, current: current, sinceSeq: 35).map(\.seq), [100],
                       "older than what is kept gets the current state")
        XCTAssertEqual(ConversationStore.replay(kept, current: current, sinceSeq: 500).map(\.seq), [100])
    }

    func testAStoppedTurnIsDoneWithNothingRunningOrWaiting() {
        var conversation = Leyline_V1_Conversation()
        conversation.fold(turn("t2", lastCall: .toolCallAwaitingApproval))
        conversation.turns[0].tools[0].state = .toolCallRunning
        var other = conversation
        other.closeStoppedTurn("t5")
        XCTAssertEqual(other.turns, conversation.turns, "a turn that is not the one stopped is left alone")
        conversation.closeStoppedTurn("t2")
        XCTAssertEqual(conversation.state, .conversationIdle)
        XCTAssertFalse(conversation.hasPending)
        XCTAssertEqual(conversation.turns[0].done, true)
        XCTAssertEqual(conversation.turns[0].tools.map(\.state), [.toolCallDone, .toolCallRefused])
        XCTAssertEqual(conversation.turns[0].tools[0].resultText, "stopped")
        XCTAssertTrue(conversation.turns[0].tools[0].isError)
    }

    // MARK: Lifetime

    func testAConversationIdleForThirtyMinutesEnds() async throws {
        let dir = try makeTempDir("conversations")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = TestClock()
        // A sweep that never comes round: the test calls endIdle itself.
        let timing = ConversationStore.Timing(idleLimit: .seconds(30 * 60), sweepEvery: .seconds(3600), now: clock.now)
        let published = Published()
        let store = try await makeStore(in: dir, scripts: ["end"], timing: timing, published: published)
        let id = try await store.start(request(), by: client).conversationID
        _ = try await store.send(id, text: "hello", by: client)
        try await waitWhile(store, id) { $0 != .conversationIdle }
        clock.advance(by: .seconds(29 * 60))
        await store.endIdle()
        let early = try await store.get(id)
        XCTAssertEqual(early.state, .conversationIdle, "29 minutes is not idle enough")
        clock.advance(by: .seconds(60))
        await store.endIdle()
        let ended = try await store.get(id)
        XCTAssertEqual(ended.state, .conversationEnded)
        XCTAssertEqual(published.conversations.last?.state, .conversationEnded, "the end is published")
        let seqs = published.conversations.map(\.seq)
        XCTAssertEqual(seqs.sorted(), Array(1...UInt64(seqs.count)), "every change is published once")
    }

    func testAWorkerThatLeavesBetweenTurnsEndsItsConversation() async throws {
        let dir = try makeTempDir("conversations")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = dir + "/ley"
        // A worker that exits cleanly before any turn; what the daemon wrote waits in the pipe.
        try "#!/bin/sh\nsleep 0.2\nexit 0\n".write(toFile: ley, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ley)
        let store = try await makeStore(in: dir, scripts: [], ley: ley)
        let id = try await store.start(request(), by: client).conversationID
        try await waitWhile(store, id) { $0 == .conversationIdle }
        let ended = try await store.get(id)
        XCTAssertEqual(ended.state, .conversationEnded)
        XCTAssertFalse(ended.hasError, "leaving between turns is not a failure")
    }

    func testOnlyTheThirtyTwoLastFinishedAreKept() async throws {
        let dir = try makeTempDir("conversations")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let forgotten = Mutex<[String]>([])
        let credentials = CredentialStore(path: dir + "/data/ai.json", secrets: FileSecrets(inData: dir + "/data"))
        _ = try await credentials.set(provider: "anthropic", secret: "sk-test-store-key-0042", label: "", endpoint: "")
        let spawner = WorkerProcess(leyPath: try writeFakeWorkerLey(in: dir, scripts: ["end"]),
                                    locator: ProgramLocator(directories: [], searchPath: []), socketPath: dir + "/d.sock")
        let store = ConversationStore(credentials: credentials, spawner: spawner,
                                      forget: { id in forgotten.withLock { $0.append(id) } }) { _, _ in }
        // Started newest-last but ended oldest-last: the first one started is the last to finish,
        // so the rule must go by when each finished, not when it began.
        var ids: [String] = []
        for _ in 0...ConversationStore.keptFinished {
            ids.append(try await store.start(request(), by: client).conversationID)
        }
        for id in ids.dropFirst() { _ = try await store.end(id, by: client) }
        _ = try await store.end(ids[0], by: client)
        let listed = await store.list()
        XCTAssertEqual(listed.count, ConversationStore.keptFinished)
        XCTAssertEqual(forgotten.withLock { $0 }, [ids[1]], "the one that finished first is forgotten")
        XCTAssertTrue(listed.contains { $0.conversationID == ids[0] })
        for call in ["get", "end", "stop"] {
            do {
                switch call {
                case "get": _ = try await store.get(ids[1])
                case "end": _ = try await store.end(ids[1], by: client)
                default: _ = try await store.stopTurn(ids[1], by: client)
                }
                XCTFail("\(call) found a forgotten conversation")
            } catch let error as EngineError {
                XCTAssertEqual(error.code, EngineError.Code.invalidArgument, call)
            }
        }
    }

    func testNoLeyIsProviderUnavailableAndSaysSo() async throws {
        let dir = try makeTempDir("conversations")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try await makeStore(in: dir, scripts: [], ley: dir + "/missing-ley")
        do {
            _ = try await store.start(request(), by: client)
            XCTFail("started without a ley")
        } catch let error as EngineError {
            XCTAssertEqual(error.code, EngineError.Code.providerUnavailable)
            XCTAssertTrue(error.message.contains("missing-ley"), error.message)
        }
        let listed = await store.list()
        XCTAssertTrue(listed.isEmpty)
    }

    func testTheDaemonsShutdownEndsEveryConversationAndItsWorker() async throws {
        let dir = try makeTempDir("conversations")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = try writeFakeWorkerLey(in: dir, scripts: ["text thinking\nsleep 10000\nend"])
        let kept = Mutex<(daemon: Daemon?, ids: [String])>((nil, []))
        try await withDaemon(leyPath: ley) { c in
            var key = Leyline_V1_SetCredentialRequest()
            key.provider = "anthropic"
            key.secret = "sk-test-shutdown-0042"
            _ = try await c.credentials.setCredential(key, metadata: testMetadata)
            var request = Leyline_V1_StartConversationRequest()
            request.provider = "anthropic"
            let idle = try await c.assistant.startConversation(request, metadata: testMetadata).conversationID
            let busy = try await c.assistant.startConversation(request, metadata: testMetadata).conversationID
            var message = Leyline_V1_SendMessageRequest()
            message.conversationID = busy
            message.text = "think"
            _ = try await c.assistant.sendMessage(message, metadata: testMetadata)
            kept.withLock { $0 = (c.daemon, [idle, busy]) }
        }
        let (stopped, ids) = kept.withLock { $0 }
        let daemon = try XCTUnwrap(stopped)
        for id in ids {
            let conversation = try await daemon.conversations.get(id)
            XCTAssertEqual(conversation.state, .conversationEnded, "\(id) ends with the daemon, whatever it was doing")
        }
        for n in 1...2 {
            let dump = await fakeWorkerDump(dir + "/dump.\(n)")
            let pid = try XCTUnwrap(dump?["pid"].flatMap { Int32($0) })
            XCTAssertNotEqual(kill(pid, 0), 0, "worker \(n) has gone")
        }
    }
}
