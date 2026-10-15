// SPDX-License-Identifier: GPL-3.0-or-later

// ConversationStore without the socket: the state rule on its own, the idle sweep against a test
// clock, a worker that leaves between turns, the files and their retention, a missing `ley`, and
// the daemon's shutdown (docs/dev/engine-internals.md, "Assistant").

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
        return ConversationStore(credentials: credentials, spawner: spawner, directory: dir + "/data/conversations",
                                 timing: timing) { conversation, _ in
            published.add(conversation)
        }
    }

    /// Writes a conversation's file as a daemon would have kept it.
    private func keep(_ conversation: Leyline_V1_Conversation, in dir: String) throws {
        let path = dir + "/data/conversations/" + conversation.conversationID
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try conversation.jsonUTF8Data().write(to: URL(fileURLWithPath: path + "/conversation.json"))
    }

    /// A kept conversation whose last turn was `daysAgo` days ago.
    private func kept(_ n: Int, daysAgo: Double) -> Leyline_V1_Conversation {
        var conversation = Leyline_V1_Conversation()
        conversation.conversationID = String(format: "conv_%04d", n)
        conversation.state = .conversationIdle
        conversation.provider = "anthropic"
        conversation.startedAtNs = WallClock.realNowNs() - Int64((daysAgo + 1) * 86_400e9)
        conversation.lastTurnAtNs = WallClock.realNowNs() - Int64(daysAgo * 86_400e9)
        conversation.seq = 7
        return conversation
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

    func testATurnCutByARestartIsClosedWithTheNote() {
        var waiting = Leyline_V1_Conversation()
        var user = Leyline_V1_Turn()
        user.turnID = "t1"
        user.role = .user
        user.done = true
        waiting.turns = [user]
        waiting.fold(turn("t2", lastCall: .toolCallAwaitingApproval))
        waiting.turns[1].tools[0].state = .toolCallRunning
        waiting.closeAfterRestart()
        XCTAssertEqual(waiting.state, .conversationIdle)
        XCTAssertFalse(waiting.hasPending)
        XCTAssertTrue(waiting.turns[1].done)
        XCTAssertEqual(waiting.turns[1].text, "so far\n\n" + ConversationStore.restartNote)
        XCTAssertEqual(waiting.turns[1].tools.map(\.state), [.toolCallDone, .toolCallRefused])

        var unanswered = Leyline_V1_Conversation()
        unanswered.state = .conversationThinking
        unanswered.turns = [user]
        unanswered.closeAfterRestart()
        XCTAssertEqual(unanswered.state, .conversationIdle)
        XCTAssertEqual(unanswered.turns.map(\.turnID), ["t1", "t2"], "the note answers the user's turn")
        XCTAssertEqual(unanswered.turns[1].role, .assistant)
        XCTAssertEqual(unanswered.turns[1].text, ConversationStore.restartNote)
        XCTAssertTrue(unanswered.turns[1].done)
    }

    func testATextDeltaWritesNothingAndADoneTurnDoes() {
        var before = Leyline_V1_Conversation()
        before.fold(turn("t2"))
        var delta = before
        delta.turns[0].text += " and more"
        delta.seq += 1
        delta.lastTurnAtNs += 1
        XCTAssertEqual(ConversationStore.milestones(of: before), ConversationStore.milestones(of: delta))
        var call = before
        call.fold(turn("t2", lastCall: .toolCallRunning))
        XCTAssertNotEqual(ConversationStore.milestones(of: before), ConversationStore.milestones(of: call))
        var done = before
        done.fold(turn("t2", done: true))
        XCTAssertNotEqual(ConversationStore.milestones(of: before), ConversationStore.milestones(of: done))
    }

    // MARK: Lifetime

    func testThirtyIdleMinutesStopTheWorkerAndTheNextMessageResumesIt() async throws {
        let dir = try makeTempDir("conversations")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = TestClock()
        // A sweep that never comes round: the test calls stopIdleWorkers itself.
        let timing = ConversationStore.Timing(idleLimit: .seconds(30 * 60), sweepEvery: .seconds(3600), now: clock.now)
        let published = Published()
        let script = "text first\nend\n\ntext second\nend"
        let store = try await makeStore(in: dir, scripts: [script, script], timing: timing, published: published)
        let id = try await store.start(request(), by: client).conversationID
        _ = try await store.send(id, text: "hello", by: client)
        try await waitWhile(store, id) { $0 != .conversationIdle }
        let firstDump = await fakeWorkerDump(dir + "/dump.1")
        let first = try XCTUnwrap(firstDump)
        let pid = try XCTUnwrap(first["pid"].flatMap { Int32($0) })
        XCTAssertEqual(first["start.resume"], "false")
        XCTAssertEqual(first["start.transcript_path"], dir + "/data/conversations/\(id)/transcript.jsonl")
        clock.advance(by: .seconds(29 * 60))
        await store.stopIdleWorkers()
        XCTAssertEqual(kill(pid, 0), 0, "29 minutes is not idle enough")
        let idle = try await store.get(id)
        clock.advance(by: .seconds(60))
        await store.stopIdleWorkers()
        XCTAssertNotEqual(kill(pid, 0), 0, "the worker has gone")
        let after = try await store.get(id)
        XCTAssertEqual(after, idle, "the conversation is as it was: IDLE, same seq")
        XCTAssertNotEqual(published.conversations.last?.state, .conversationEnded)

        _ = try await store.send(id, text: "again", by: client)
        try await waitWhile(store, id) { $0 != .conversationIdle }
        let resumedDump = await fakeWorkerDump(dir + "/dump.2")
        let resumed = try XCTUnwrap(resumedDump)
        XCTAssertEqual(resumed["start.resume"], "true")
        XCTAssertEqual(resumed["start.transcript_path"], dir + "/data/conversations/\(id)/transcript.jsonl")
        XCTAssertEqual(resumed["start.conversation"], id)
        XCTAssertEqual(resumed["resumed.turns"], "1")
        XCTAssertEqual(resumed["last4"], "0042", "the key is read again for the new worker")
        let done = try await store.get(id)
        XCTAssertEqual(done.turns.map(\.turnID), ["t1", "t2", "t3", "t4"])
        XCTAssertEqual(done.turns.last?.text, "second", "the new worker goes on from the transcript")
        let seqs = published.conversations.map(\.seq)
        XCTAssertEqual(seqs.sorted(), Array(1...UInt64(seqs.count)), "every change is published once")
        await store.stopAll()
    }

    func testAWorkerThatLeavesBetweenTurnsLeavesItsConversationIdle() async throws {
        let dir = try makeTempDir("conversations")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = dir + "/ley"
        // A worker that exits cleanly before any turn; what the daemon wrote waits in the pipe.
        try "#!/bin/sh\nsleep 0.2\nexit 0\n".write(toFile: ley, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ley)
        let published = Published()
        let store = try await makeStore(in: dir, scripts: [], ley: ley, published: published)
        let started = try await store.start(request(), by: client)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let after = try await store.get(started.conversationID)
        XCTAssertEqual(after.state, .conversationIdle)
        XCTAssertEqual(after.seq, started.seq, "leaving between turns changes nothing a client sees")
        XCTAssertFalse(after.hasError)
    }

    // MARK: Files

    func testKeptConversationsLoadAndRetentionDropsTheOldest() async throws {
        let dir = try makeTempDir("conversations")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // 101 within the age limit, newest first by n, and one past it.
        for n in 1...101 { try keep(kept(n, daysAgo: Double(n) / 10), in: dir) }
        try keep(kept(500, daysAgo: 91), in: dir)
        var unreadable = kept(600, daysAgo: 1)
        unreadable.conversationID = "conv_elsewhere"
        try keep(unreadable, in: dir)
        try FileManager.default.moveItem(atPath: dir + "/data/conversations/conv_elsewhere",
                                         toPath: dir + "/data/conversations/conv_0600")
        let store = try await makeStore(in: dir, scripts: ["end"])
        await store.load()
        let listed = await store.list()
        XCTAssertEqual(listed.count, ConversationStore.keptConversations)
        let ids = Set(listed.map(\.conversationID))
        XCTAssertTrue(ids.contains("conv_0001") && ids.contains("conv_0100"))
        XCTAssertFalse(ids.contains("conv_0101"), "the 101st newest is dropped")
        XCTAssertFalse(ids.contains("conv_0500"), "one older than 90 days is dropped")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: dir + "/data/conversations")
        XCTAssertFalse(onDisk.contains("conv_0101"))
        XCTAssertFalse(onDisk.contains("conv_0500"))
        XCTAssertTrue(onDisk.contains("conv_0600"), "a file that is not the conversation it is filed under is left alone")
        let loaded = try await store.get("conv_0001")
        XCTAssertEqual(loaded.seq, 7, "seq goes on from the file")

        // A new conversation over the limit pushes the oldest out.
        let id = try await store.start(request(), by: client).conversationID
        let now = Set(await store.list().map(\.conversationID))
        XCTAssertEqual(now.count, ConversationStore.keptConversations)
        XCTAssertTrue(now.contains(id))
        XCTAssertFalse(now.contains("conv_0100"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/data/conversations/conv_0100"))
        let attributes = try FileManager.default.attributesOfItem(atPath: dir + "/data/conversations/\(id)/conversation.json")
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: dir + "/data/conversations")
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        await store.stopAll()
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

    func testTheDaemonsShutdownStopsEveryWorkerAndKeepsEveryConversation() async throws {
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
        let idle = try await daemon.conversations.get(ids[0])
        XCTAssertEqual(idle.state, .conversationIdle, "an idle conversation stays idle")
        let busy = try await daemon.conversations.get(ids[1])
        XCTAssertEqual(busy.state, .conversationThinking, "one on a turn is left for the next daemon to close")
        for n in 1...2 {
            let dump = await fakeWorkerDump(dir + "/dump.\(n)")
            let pid = try XCTUnwrap(dump?["pid"].flatMap { Int32($0) })
            XCTAssertNotEqual(kill(pid, 0), 0, "worker \(n) has gone")
        }
    }
}
