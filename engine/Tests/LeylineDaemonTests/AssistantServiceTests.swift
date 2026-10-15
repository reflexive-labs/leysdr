// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Assistant over the socket, with the scripted fake worker standing in for `ley worker
// assistant` (docs/dev/engine-internals.md, "Assistant"): how a conversation starts, what each
// client action and each worker message does to its state, what ends or fails it, and that the key
// reaches the worker on stdin and nowhere else.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import SwiftProtobuf
import XCTest

final class AssistantServiceTests: XCTestCase {
    /// The suffix is what every assertion greps for, so it must appear nowhere else.
    static let secret = "sk-test-SECRETMARKER9f3"
    static let marker = "SECRETMARKER"

    // MARK: Helpers

    /// A daemon whose `ley` is the fake worker playing `scripts`, with an anthropic key added
    /// through the real RPC and, unless `chooseModel` is false, the assistant feature on it.
    private func withAssistant(scripts: [String], chooseModel: Bool = true, addKey: Bool = true,
                               timing: ConversationStore.Timing? = nil,
                               _ body: @escaping @Sendable (DaemonClients, String) async throws -> Void) async throws
    {
        let dir = try makeTempDir("assistant")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = try writeFakeWorkerLey(in: dir, scripts: scripts)
        try await withDaemon(leyPath: ley, conversationTiming: timing) { c in
            if addKey {
                var key = Leyline_V1_SetCredentialRequest()
                key.provider = "anthropic"
                key.secret = Self.secret
                _ = try await c.credentials.setCredential(key, metadata: testMetadata)
            }
            if chooseModel {
                var feature = Leyline_V1_FeatureModel()
                feature.feature = "assistant"
                feature.provider = "anthropic"
                feature.model = "claude-test"
                _ = try await c.credentials.setFeatureModel(feature, metadata: testMetadata)
            }
            try await body(c, dir)
        }
    }

    private func start(_ c: DaemonClients, viewTools: [String] = []) async throws -> Leyline_V1_Conversation {
        var request = Leyline_V1_StartConversationRequest()
        request.viewTools = viewTools.map {
            var tool = Leyline_V1_ViewTool()
            tool.name = $0
            tool.description_p = "moves the client's own view"
            tool.inputSchemaJson = #"{"type": "object"}"#
            return tool
        }
        return try await c.assistant.startConversation(request, metadata: testMetadata)
    }

    private func send(_ c: DaemonClients, _ id: String, _ text: String) async throws -> Leyline_V1_Conversation {
        var request = Leyline_V1_SendMessageRequest()
        request.conversationID = id
        request.text = text
        return try await c.assistant.sendMessage(request, metadata: testMetadata)
    }

    private func resolve(_ c: DaemonClients, _ id: String, call: String, approve: Bool) async throws -> Leyline_V1_Conversation {
        var request = Leyline_V1_ResolveActionRequest()
        request.conversationID = id
        request.callID = call
        request.approve = approve
        return try await c.assistant.resolveAction(request, metadata: testMetadata)
    }

    private func ref(_ id: String) -> Leyline_V1_ConversationRef {
        var ref = Leyline_V1_ConversationRef()
        ref.conversationID = id
        return ref
    }

    /// The conversation once `until` holds, read from the daemon's store every 20 ms.
    private func conversation(_ c: DaemonClients, _ id: String, within seconds: Double = 5,
                              until: (Leyline_V1_Conversation) -> Bool) async throws -> Leyline_V1_Conversation
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var latest = try await c.daemon.conversations.get(id)
        while !until(latest), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            latest = try await c.daemon.conversations.get(id)
        }
        XCTAssertTrue(until(latest), "the conversation never got there; it is \(latest.state) with \(latest.turns.count) turns")
        return latest
    }

    /// The error code and the text a client sees of a call that must fail.
    private func failure(_ body: () async throws -> Void) async -> (code: String, text: String) {
        do {
            try await body()
            XCTFail("the call succeeded")
            return ("", "")
        } catch {
            let (code, detail) = errorCode(error)
            let trailer = (try? detail?.jsonString()) ?? ""
            return (code, "\(error) \(trailer)")
        }
    }

    // MARK: Starting

    func testStartWithoutAKeyIsCredentialMissingNamingTheCommand() async throws {
        try await withAssistant(scripts: ["end"], chooseModel: false, addKey: false) { c, _ in
            let unnamed = await self.failure { _ = try await self.start(c) }
            XCTAssertEqual(unnamed.code, EngineError.Code.credentialMissing)
            XCTAssertTrue(unnamed.text.contains("ley ai add"), unnamed.text)
            var request = Leyline_V1_StartConversationRequest()
            request.provider = "anthropic"
            let named = await self.failure { _ = try await c.assistant.startConversation(request, metadata: testMetadata) }
            XCTAssertEqual(named.code, EngineError.Code.credentialMissing)
            XCTAssertTrue(named.text.contains("ley ai add anthropic"), named.text)
            let listed = try await c.assistant.listConversations(Leyline_V1_ListConversationsRequest(), metadata: testMetadata)
            XCTAssertTrue(listed.conversations.isEmpty, "a refused start leaves nothing behind")
        }
    }

    func testAKeyLastCheckedRejectedIsCredentialRejected() async throws {
        try await withAssistant(scripts: ["end"]) { c, _ in
            let listed = await c.daemon.credentials.credential("anthropic")
            let key = try XCTUnwrap(listed)
            var check = Leyline_V1_CredentialCheck()
            check.outcome = .rejected
            check.message = "invalid x-api-key"
            _ = await c.daemon.credentials.recordCheck(provider: "anthropic", addedAtNs: key.addedAtNs, check)
            let refused = await self.failure { _ = try await self.start(c) }
            XCTAssertEqual(refused.code, EngineError.Code.credentialRejected)
            XCTAssertTrue(refused.text.contains("invalid x-api-key"), refused.text)
        }
    }

    func testStartReturnsIdleAndTheKeyReachesTheWorkerOnStdinOnly() async throws {
        try await withAssistant(scripts: ["end"]) { c, dir in
            let started = try await self.start(c, viewTools: ["move_view"])
            XCTAssertTrue(started.conversationID.hasPrefix("conv_"), started.conversationID)
            XCTAssertEqual(started.state, .conversationIdle)
            XCTAssertEqual(started.provider, "anthropic")
            XCTAssertEqual(started.model, "claude-test", "the assistant feature's model")
            XCTAssertEqual(started.startedBy.label, "xctest")
            XCTAssertGreaterThan(started.startedAtNs, 0)
            XCTAssertEqual(started.viewTools.map(\.name), ["move_view"])
            XCTAssertGreaterThan(started.seq, 0)
            let written = await fakeWorkerDump(dir + "/dump.1")
            let dump = try XCTUnwrap(written, "the worker never wrote its dump")
            XCTAssertEqual(dump["last4"], "R9f3", "the worker read the key first")
            XCTAssertEqual(dump["argv"], "worker assistant --conversation \(started.conversationID)")
            XCTAssertEqual(dump["start.conversation"], started.conversationID)
            XCTAssertEqual(dump["start.provider"], "anthropic")
            XCTAssertEqual(dump["start.model"], "claude-test")
            XCTAssertEqual(dump["start.socket"], c.socketPath)
            XCTAssertEqual(dump["start.view_tools"], "move_view")
            XCTAssertEqual(dump["env.LEYLINE_KEY_ON_STDIN"], "1")
            XCTAssertEqual(dump["env.LEYLINE_SOCKET"], c.socketPath)
            for (name, value) in dump {
                XCTAssertFalse(value.contains(Self.marker), "the key reached the worker's \(name)")
            }
        }
    }

    // MARK: Turns

    func testATextTurnArrivesOnWatchAndADoneTurnIsIdle() async throws {
        try await withAssistant(scripts: ["text hello there\nsleep 300\ntext and more\nend"]) { c, _ in
            let started = try await self.start(c)
            let watch = await ConversationWatch.start(c, started.conversationID, sinceSeq: 0)
            let sent = try await self.send(c, started.conversationID, "what is on 146.52?")
            XCTAssertEqual(sent.state, .conversationThinking)
            XCTAssertEqual(sent.turns.map(\.turnID), ["t1"])
            XCTAssertEqual(sent.turns.first?.role, .user)
            let partial = await watch.waitFor { $0.turns.count == 2 && $0.turns[1].text == "hello there" }
            XCTAssertEqual(partial?.state, .conversationThinking)
            XCTAssertEqual(partial?.turns[1].done, false)
            let finished = await watch.waitFor { $0.state == .conversationIdle && $0.turns.count == 2 }
            XCTAssertEqual(finished?.turns[1].turnID, "t2")
            XCTAssertEqual(finished?.turns[1].role, .assistant)
            XCTAssertEqual(finished?.turns[1].text, "hello there and more")
            XCTAssertEqual(finished?.turns[1].done, true)
            XCTAssertGreaterThan(finished?.lastTurnAtNs ?? 0, 0)
            let seqs = await watch.seen.map(\.seq)
            XCTAssertEqual(seqs, seqs.sorted(), "watch delivers changes in order")
            await watch.stop()
        }
    }

    func testAnApprovedAskRunsAndTheTurnEnds() async throws {
        let script = """
        ask delete_recording {"id":"rec_1"} deleting a recording asks every time
        approved done delete_recording deleted
        declined text left it alone
        end
        """
        try await withAssistant(scripts: [script]) { c, _ in
            let id = try await self.start(c).conversationID
            _ = try await self.send(c, id, "delete rec_1")
            let waiting = try await self.conversation(c, id) { $0.state == .conversationWaiting }
            XCTAssertTrue(waiting.hasPending)
            XCTAssertEqual(waiting.pending.tool, "delete_recording")
            XCTAssertEqual(waiting.pending.argumentsJson, #"{"id":"rec_1"}"#)
            XCTAssertEqual(waiting.pending.reason, "deleting a recording asks every time")
            XCTAssertFalse(waiting.pending.viewTool)
            let call = waiting.pending.callID

            let wrong = await self.failure { _ = try await self.resolve(c, id, call: "call999", approve: true) }
            XCTAssertEqual(wrong.code, EngineError.Code.failedPrecondition)
            var answer = Leyline_V1_AnswerViewToolRequest()
            answer.conversationID = id
            answer.callID = call
            let notAView = await self.failure { _ = try await c.assistant.answerViewTool(answer, metadata: testMetadata) }
            XCTAssertEqual(notAView.code, EngineError.Code.failedPrecondition, "an approval is not a view tool's to answer")
            let busy = await self.failure { _ = try await self.send(c, id, "and another thing") }
            XCTAssertEqual(busy.code, EngineError.Code.failedPrecondition)

            let resolved = try await self.resolve(c, id, call: call, approve: true)
            XCTAssertEqual(resolved.state, .conversationThinking)
            XCTAssertFalse(resolved.hasPending)
            XCTAssertEqual(resolved.turns.last?.tools.first?.state, .toolCallRunning)
            let done = try await self.conversation(c, id) { $0.state == .conversationIdle }
            XCTAssertEqual(done.turns.last?.tools.first?.state, .toolCallDone)
            XCTAssertEqual(done.turns.last?.tools.first?.resultText, "deleted")
            XCTAssertEqual(done.turns.last?.text, "", "the declined branch did not run")
            let late = await self.failure { _ = try await self.resolve(c, id, call: call, approve: true) }
            XCTAssertEqual(late.code, EngineError.Code.failedPrecondition, "a resolved call cannot be resolved again")
        }
    }

    func testADeclinedAskIsRefused() async throws {
        let script = """
        ask delete_recording {"id":"rec_1"} deleting a recording asks every time
        approved done delete_recording deleted
        declined text left it alone
        end
        """
        try await withAssistant(scripts: [script]) { c, _ in
            let id = try await self.start(c).conversationID
            _ = try await self.send(c, id, "delete rec_1")
            let waiting = try await self.conversation(c, id) { $0.state == .conversationWaiting }
            let declined = try await self.resolve(c, id, call: waiting.pending.callID, approve: false)
            XCTAssertEqual(declined.turns.last?.tools.first?.state, .toolCallRefused)
            let done = try await self.conversation(c, id) { $0.state == .conversationIdle }
            XCTAssertEqual(done.turns.last?.tools.first?.state, .toolCallRefused)
            XCTAssertEqual(done.turns.last?.text, "left it alone")
        }
    }

    func testAViewToolWaitsForTheClientsAnswer() async throws {
        try await withAssistant(scripts: ["view move_view {\"hz\":146520000}\ntext moved it\nend"]) { c, _ in
            let id = try await self.start(c, viewTools: ["move_view"]).conversationID
            _ = try await self.send(c, id, "show me 146.52")
            let waiting = try await self.conversation(c, id) { $0.state == .conversationWaiting }
            XCTAssertTrue(waiting.pending.viewTool)
            XCTAssertEqual(waiting.pending.tool, "move_view")
            XCTAssertEqual(waiting.turns.last?.tools.last?.state, .toolCallAwaitingClient)
            let notAnApproval = await self.failure {
                _ = try await self.resolve(c, id, call: waiting.pending.callID, approve: true)
            }
            XCTAssertEqual(notAnApproval.code, EngineError.Code.failedPrecondition)
            var answer = Leyline_V1_AnswerViewToolRequest()
            answer.conversationID = id
            answer.callID = waiting.pending.callID
            answer.resultText = "the view is on 146.520 MHz"
            answer.resultJson = #"{"hz":146520000}"#
            let answered = try await c.assistant.answerViewTool(answer, metadata: testMetadata)
            XCTAssertEqual(answered.state, .conversationThinking)
            let done = try await self.conversation(c, id) { $0.state == .conversationIdle }
            XCTAssertEqual(done.turns.last?.tools.last?.state, .toolCallDone)
            XCTAssertEqual(done.turns.last?.tools.last?.resultText, "the view is on 146.520 MHz")
            XCTAssertEqual(done.turns.last?.tools.last?.resultJson, #"{"hz":146520000}"#)
            XCTAssertEqual(done.turns.last?.text, "moved it")
        }
    }

    func testSendingWhileThinkingIsRefusedAndStopTurnEndsTheTurn() async throws {
        try await withAssistant(scripts: ["text working on it\nsleep 10000\ntext never said\nend\n\ntext second\nend"]) { c, _ in
            let id = try await self.start(c).conversationID
            _ = try await self.send(c, id, "scan the band")
            _ = try await self.conversation(c, id) { $0.turns.last?.text == "working on it" }
            let busy = await self.failure { _ = try await self.send(c, id, "are you done?") }
            XCTAssertEqual(busy.code, EngineError.Code.failedPrecondition)
            let stopped = try await c.assistant.stopTurn(self.ref(id), metadata: testMetadata)
            XCTAssertEqual(stopped.state, .conversationIdle, "the worker marks the turn done at once")
            XCTAssertEqual(stopped.turns.last?.done, true)
            XCTAssertEqual(stopped.turns.last?.text, "working on it")
            let again = try await c.assistant.stopTurn(self.ref(id), metadata: testMetadata)
            XCTAssertEqual(again.state, .conversationIdle, "stopping an idle conversation changes nothing")
            _ = try await self.send(c, id, "next")
            let next = try await self.conversation(c, id) { $0.state == .conversationIdle && $0.turns.count == 4 }
            XCTAssertEqual(next.turns.map(\.turnID), ["t1", "t2", "t3", "t4"])
            XCTAssertEqual(next.turns.last?.text, "second")
        }
    }

    // MARK: Failing and ending

    func testAWorkerFailureFailsTheConversationWithItsMessage() async throws {
        try await withAssistant(scripts: ["text one moment\nfail the provider said no"]) { c, _ in
            let id = try await self.start(c).conversationID
            let watch = await ConversationWatch.start(c, id, sinceSeq: 0)
            _ = try await self.send(c, id, "hello")
            let failed = try await self.conversation(c, id) { $0.state == .conversationFailed }
            XCTAssertEqual(failed.error.code, "INTERNAL")
            XCTAssertEqual(failed.error.message, "the provider said no")
            XCTAssertFalse(failed.hasPending)
            let after = await self.failure { _ = try await self.send(c, id, "hello again") }
            XCTAssertEqual(after.code, EngineError.Code.failedPrecondition)
            let watchEnded = await watch.waitUntilFinished()
            XCTAssertTrue(watchEnded, "the watch ends after it delivers FAILED")
            let last = await watch.seen.last
            XCTAssertEqual(last?.state, .conversationFailed)
        }
    }

    func testAWorkerThatExitsMidTurnFailsOnlyItsOwnConversation() async throws {
        try await withAssistant(scripts: ["text starting\nexit 3", "text still here\nend"]) { c, _ in
            let crashing = try await self.start(c).conversationID
            let steady = try await self.start(c).conversationID
            _ = try await self.send(c, crashing, "go")
            let failed = try await self.conversation(c, crashing) { $0.state == .conversationFailed }
            XCTAssertEqual(failed.error.code, EngineError.Code.internalError)
            XCTAssertTrue(failed.error.message.contains("the assistant stopped unexpectedly (status 3)"), failed.error.message)
            let untouched = try await c.daemon.conversations.get(steady)
            XCTAssertEqual(untouched.state, .conversationIdle)
            _ = try await self.send(c, steady, "go")
            let fine = try await self.conversation(c, steady) { $0.state == .conversationIdle && $0.turns.count == 2 }
            XCTAssertEqual(fine.turns.last?.text, "still here")
        }
    }

    func testEndConversationEndsItAndStopsTheWorker() async throws {
        try await withAssistant(scripts: ["end"]) { c, dir in
            let id = try await self.start(c).conversationID
            let written = await fakeWorkerDump(dir + "/dump.1")
            let dump = try XCTUnwrap(written)
            let pid = try XCTUnwrap(dump["pid"].flatMap { Int32($0) })
            XCTAssertEqual(kill(pid, 0), 0, "the worker is running")
            let watch = await ConversationWatch.start(c, id, sinceSeq: 0)
            let ended = try await c.assistant.endConversation(self.ref(id), metadata: testMetadata)
            XCTAssertEqual(ended.state, .conversationEnded)
            XCTAssertNotEqual(kill(pid, 0), 0, "the worker has gone by the time the reply arrives")
            let watchEnded = await watch.waitUntilFinished()
            XCTAssertTrue(watchEnded, "the watch ends after it delivers ENDED")
            let again = try await c.assistant.endConversation(self.ref(id), metadata: testMetadata)
            XCTAssertEqual(again.seq, ended.seq, "ending an ended conversation changes nothing")
            let refused = await self.failure { _ = try await self.send(c, id, "hello") }
            XCTAssertEqual(refused.code, EngineError.Code.failedPrecondition)
            let listed = try await c.assistant.listConversations(Leyline_V1_ListConversationsRequest(), metadata: testMetadata)
            XCTAssertEqual(listed.conversations.first?.state, .conversationEnded, "an ended conversation stays listed")
            let unknown = await self.failure { _ = try await c.assistant.endConversation(self.ref("conv_nope"), metadata: testMetadata) }
            XCTAssertEqual(unknown.code, EngineError.Code.invalidArgument)
        }
    }

    func testIdleTimeoutEndsTheConversationAndTheEventSaysSo() async throws {
        let clock = TestClock()
        let timing = ConversationStore.Timing(idleLimit: .seconds(30 * 60), sweepEvery: .milliseconds(20), now: clock.now)
        try await withAssistant(scripts: ["end"], timing: timing) { c, _ in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            let id = try await self.start(c).conversationID
            clock.advance(by: .seconds(29 * 60))
            try await Task.sleep(nanoseconds: 200_000_000)
            let early = try await c.daemon.conversations.get(id)
            XCTAssertEqual(early.state, .conversationIdle, "29 minutes is not idle enough")
            clock.advance(by: .seconds(60))
            let ended = await events.waitFor {
                if case .conversation(let conv)? = $0.body { return conv.conversationID == id && conv.state == .conversationEnded }
                return false
            }
            XCTAssertNotNil(ended, "Event.conversation carries the end")
            XCTAssertEqual(ended?.causedBy.kind, "daemon")
            await events.stop()
        }
    }

    // MARK: Listing and watching

    func testGetStateAndListConversationsListThemNewestFirst() async throws {
        try await withAssistant(scripts: ["end"]) { c, _ in
            let first = try await self.start(c).conversationID
            let second = try await self.start(c).conversationID
            let listed = try await c.assistant.listConversations(Leyline_V1_ListConversationsRequest(), metadata: testMetadata)
            XCTAssertEqual(listed.conversations.map(\.conversationID), [second, first])
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(Set(state.conversations.map(\.conversationID)), [first, second])
        }
    }

    func testWatchSendsTheCurrentStateFirstUnlessTheClientHasIt() async throws {
        try await withAssistant(scripts: ["end"]) { c, _ in
            let id = try await self.start(c).conversationID
            _ = try await self.send(c, id, "hello")
            let current = try await self.conversation(c, id) { $0.state == .conversationIdle && $0.turns.count == 2 }

            let fresh = await ConversationWatch.start(c, id, sinceSeq: 0)
            let stale = await ConversationWatch.start(c, id, sinceSeq: 1)
            let caughtUp = await ConversationWatch.start(c, id, sinceSeq: current.seq)
            let freshFirst = await fresh.seen.first
            let staleFirst = await stale.seen.first
            XCTAssertEqual(freshFirst?.seq, current.seq, "since_seq 0 gets the current state first")
            XCTAssertEqual(staleFirst?.seq, current.seq, "a stale since_seq gets the current state, not history")
            try await Task.sleep(nanoseconds: 200_000_000)
            let quiet = await caughtUp.seen
            XCTAssertTrue(quiet.isEmpty, "a client that has the current state gets nothing older")
            _ = try await c.assistant.endConversation(self.ref(id), metadata: testMetadata)
            let next = await caughtUp.waitFor { $0.state == .conversationEnded }
            XCTAssertEqual(next?.seq, current.seq + 1)
            let delivered = await caughtUp.seen
            XCTAssertEqual(delivered.count, 1)
            for watch in [fresh, stale, caughtUp] { await watch.stop() }
        }
    }

    // MARK: The key

    func testTheKeyIsInNoReplyEventOrLogLine() async throws {
        let script = """
        text checking
        ask delete_recording {"id":"rec_1"} deleting a recording asks every time
        approved done delete_recording deleted
        end

        fail the provider said no
        """
        try await withAssistant(scripts: [script]) { c, _ in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            var seen: [String] = []
            var id = ""
            let log = try await LogCapture.shared.capture {
                let started = try await self.start(c)
                id = started.conversationID
                seen.append(try started.jsonString())
                seen.append(try await self.send(c, id, "delete rec_1").jsonString())
                let waiting = try await self.conversation(c, id) { $0.state == .conversationWaiting }
                seen.append(try await self.resolve(c, id, call: waiting.pending.callID, approve: true).jsonString())
                _ = try await self.conversation(c, id) { $0.state == .conversationIdle }
                seen.append(try await self.send(c, id, "again").jsonString())
                _ = try await self.conversation(c, id) { $0.state == .conversationFailed }
                seen.append(try await c.assistant.listConversations(Leyline_V1_ListConversationsRequest(), metadata: testMetadata).jsonString())
                seen.append(try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata).jsonString())
                let refused = await self.failure { _ = try await self.send(c, id, "once more") }
                seen.append(refused.text)
                _ = await events.waitFor {
                    if case .conversation(let conv)? = $0.body { return conv.state == .conversationFailed }
                    return false
                }
            }
            await events.stop()
            for event in await events.events { seen.append(try event.jsonString()) }
            for text in seen { XCTAssertFalse(text.contains(Self.marker), "the key reached a client: \(text)") }
            XCTAssertTrue(log.contains("leyline.assistant.\(id)"), "the worker's stderr is logged under its conversation")
            XCTAssertTrue(log.contains("fake worker up for \(id)"))
            XCTAssertFalse(log.contains(Self.marker), "the key reached the log")
        }
    }
}

/// Collects one `WatchConversation` stream.
actor ConversationWatch {
    private(set) var seen: [Leyline_V1_Conversation] = []
    private(set) var finished = false
    private var task: Task<Void, Never>?

    private func append(_ conversation: Leyline_V1_Conversation) { seen.append(conversation) }
    private func finish() { finished = true }
    private func setTask(_ t: Task<Void, Never>) { task = t }

    func stop() { task?.cancel() }

    /// Starts watching and returns once the daemon holds the watcher: after the first state for a
    /// client that is behind, after a short settle for one that is current.
    static func start(_ c: DaemonClients, _ id: String, sinceSeq: UInt64) async -> ConversationWatch {
        let watch = ConversationWatch()
        var request = Leyline_V1_WatchConversationRequest()
        request.conversationID = id
        request.sinceSeq = sinceSeq
        let t = Task {
            try? await c.assistant.watchConversation(request, metadata: testMetadata) { response in
                for try await conversation in response.messages { await watch.append(conversation) }
            }
            await watch.finish()
        }
        await watch.setTask(t)
        let current = try? await c.daemon.conversations.get(id)
        if current?.seq != sinceSeq {
            _ = await watch.waitFor { _ in true }
        } else {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return watch
    }

    func waitFor(timeoutMs: Int = 5000, _ pred: (Leyline_V1_Conversation) -> Bool) async -> Leyline_V1_Conversation? {
        for _ in 0..<(timeoutMs / 20) {
            if let c = seen.first(where: pred) { return c }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return seen.first(where: pred)
    }

    func waitUntilFinished(timeoutMs: Int = 5000) async -> Bool {
        for _ in 0..<(timeoutMs / 20) where !finished {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return finished
    }
}
