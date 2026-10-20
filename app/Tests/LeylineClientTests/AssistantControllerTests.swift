// SPDX-License-Identifier: Apache-2.0

// The controller's rules without a daemon: the watch resumes from the seq it holds after a
// dropped stream, an unknown conversation marks it lost, a view tool call is performed once and
// its answer sent again when it did not arrive, and another conversation is never answered.

import LeylineProto
import Synchronization
import XCTest

@testable import LeylineClient

/// `AssistantCalls` played by the test: replies it was given, every request it got, and watch
/// streams the test feeds by hand.
final class FakeAssistantCalls: AssistantCalls {
    struct State {
        var started = Leyline_V1_Conversation()
        var answers: [Leyline_V1_AnswerViewToolRequest] = []
        var resolves: [Leyline_V1_ResolveActionRequest] = []
        /// Thrown by the next `AnswerViewTool`s, one each, before one succeeds.
        var answerErrors: [LeylineError] = []
        var watches: [(id: String, since: UInt64)] = []
        var streams: [AsyncThrowingStream<Leyline_V1_Conversation, any Error>.Continuation] = []
    }

    let state = Mutex(State())

    init(started: Leyline_V1_Conversation) {
        state.withLock { $0.started = started }
    }

    func startConversation(_ request: Leyline_V1_StartConversationRequest) async throws
        -> Leyline_V1_Conversation
    {
        state.withLock { $0.started }
    }

    func sendMessage(_ request: Leyline_V1_SendMessageRequest) async throws
        -> Leyline_V1_Conversation
    {
        throw LeylineError(code: "FAILED_PRECONDITION", message: "not in this test")
    }

    func resolveAction(_ request: Leyline_V1_ResolveActionRequest) async throws
        -> Leyline_V1_Conversation
    {
        state.withLock { $0.resolves.append(request) }
        // The test reads the requests; the daemon's reply is not what it checks.
        throw LeylineError(code: "FAILED_PRECONDITION", message: "resolved")
    }

    func answerViewTool(_ request: Leyline_V1_AnswerViewToolRequest) async throws
        -> Leyline_V1_Conversation
    {
        let error: LeylineError? = state.withLock { s in
            s.answers.append(request)
            return s.answerErrors.isEmpty ? nil : s.answerErrors.removeFirst()
        }
        if let error { throw error }
        // The daemon's reply moves the conversation on; the test reads the requests instead.
        throw LeylineError(code: "FAILED_PRECONDITION", message: "answered")
    }

    func stopTurn(_ ref: Leyline_V1_ConversationRef) async throws -> Leyline_V1_Conversation {
        throw LeylineError(code: "FAILED_PRECONDITION", message: "not in this test")
    }

    func endConversation(_ ref: Leyline_V1_ConversationRef) async throws
        -> Leyline_V1_Conversation
    {
        throw LeylineError(code: "FAILED_PRECONDITION", message: "not in this test")
    }

    func conversation(_ id: String, sinceSeq: UInt64) -> AsyncThrowingStream<
        Leyline_V1_Conversation, any Error
    > {
        let (stream, continuation) = AsyncThrowingStream<Leyline_V1_Conversation, any Error>
            .makeStream()
        state.withLock { s in
            s.watches.append((id, sinceSeq))
            s.streams.append(continuation)
        }
        return stream
    }

    var watches: [(id: String, since: UInt64)] { state.withLock { $0.watches } }
    var answers: [Leyline_V1_AnswerViewToolRequest] { state.withLock { $0.answers } }
    var resolves: [Leyline_V1_ResolveActionRequest] { state.withLock { $0.resolves } }

    /// The newest watch stream.
    func stream() -> AsyncThrowingStream<Leyline_V1_Conversation, any Error>.Continuation? {
        state.withLock { $0.streams.last }
    }
}

@MainActor
final class CountingPerformer: ViewToolPerformer {
    var requests: [AppViewTools.Request] = []

    func perform(_ request: AppViewTools.Request) async -> ViewToolAnswer {
        requests.append(request)
        return ViewToolAnswer(text: "shown", json: #"{"place":"radio"}"#)
    }
}

final class AssistantControllerTests: XCTestCase {
    static func conversation(
        _ id: String = "conv_1", seq: UInt64,
        _ state: Leyline_V1_ConversationState = .conversationIdle
    ) -> Leyline_V1_Conversation {
        var c = Leyline_V1_Conversation()
        c.conversationID = id
        c.seq = seq
        c.state = state
        return c
    }

    /// Waiting on the app's `show_place` as call `c1`.
    static func waitingOnView(_ id: String = "conv_1", seq: UInt64) -> Leyline_V1_Conversation {
        var c = conversation(id, seq: seq, .conversationWaiting)
        c.pending.callID = "c1"
        c.pending.tool = "show_place"
        c.pending.argumentsJson = #"{"place":"radio"}"#
        c.pending.viewTool = true
        return c
    }

    @MainActor
    func started(_ fake: FakeAssistantCalls) async throws -> AssistantController {
        let controller = AssistantController(
            calls: fake, backoff: [.milliseconds(5)])
        let ok = await controller.start()
        XCTAssertTrue(ok)
        return controller
    }

    @MainActor
    func testTheWatchResumesFromTheHeldSeqAfterADrop() async throws {
        let fake = FakeAssistantCalls(started: Self.conversation(seq: 1))
        let controller = try await started(fake)
        defer { controller.close() }
        await assertSoon("the first watch never opened") { fake.watches.count == 1 }
        XCTAssertEqual(fake.watches.first?.since, 1)

        fake.stream()?.yield(Self.conversation(seq: 4, .conversationThinking))
        await assertSoon("the watch's state never landed") { controller.conversation?.seq == 4 }
        fake.stream()?.finish(throwing: LeylineError(code: "UNAVAILABLE", message: "gone"))

        await assertSoon("the watch never dialled again") { fake.watches.count == 2 }
        XCTAssertEqual(fake.watches.last?.since, 4, "resumed from the seq it held")
        XCTAssertFalse(controller.isLost)

        // An older copy (a late mirror event) never replaces a newer one.
        controller.absorb(Self.conversation(seq: 3, .conversationIdle))
        XCTAssertEqual(controller.conversation?.seq, 4)
    }

    @MainActor
    func testAnUnknownConversationIsLost() async throws {
        let fake = FakeAssistantCalls(started: Self.conversation(seq: 1))
        let controller = try await started(fake)
        defer { controller.close() }
        await assertSoon("the watch never opened") { fake.watches.count == 1 }
        fake.stream()?.finish(
            throwing: LeylineError(code: "INVALID_ARGUMENT", message: "no conversation conv_1"))
        await assertSoon("the conversation was never marked lost") { controller.isLost }
        XCTAssertEqual(controller.notice?.text, AssistantWords.forgotten)
        XCTAssertTrue(controller.needsStart, "a lost conversation can only be replaced")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fake.watches.count, 1, "a lost conversation is not watched again")
    }

    @MainActor
    func testAViewToolIsPerformedOnceAndItsAnswerSentAgainAfterAFailure() async throws {
        let fake = FakeAssistantCalls(started: Self.conversation(seq: 1))
        fake.state.withLock {
            $0.answerErrors = [LeylineError(code: "UNAVAILABLE", message: "daemon away")]
        }
        let controller = try await started(fake)
        defer { controller.close() }
        let performer = CountingPerformer()
        controller.performer = performer

        // The same state from the watch and from the mirror, then a newer copy still waiting.
        controller.absorb(Self.waitingOnView(seq: 2))
        controller.absorb(Self.waitingOnView(seq: 2))
        controller.absorb(Self.waitingOnView(seq: 3))

        await assertSoon("the answer was never sent again") { fake.answers.count == 2 }
        XCTAssertEqual(performer.requests, [.showPlace(.radio)], "performed once")
        XCTAssertEqual(fake.answers.map(\.callID), ["c1", "c1"])
        XCTAssertEqual(fake.answers.last?.resultText, "shown")
        XCTAssertEqual(fake.answers.last?.resultJson, #"{"place":"radio"}"#)
        XCTAssertFalse(fake.answers.last?.isError ?? true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fake.answers.count, 2, "an answer the daemon took is not sent again")
    }

    @MainActor
    func testTheScopeLeavesResolve() async throws {
        let fake = FakeAssistantCalls(started: Self.conversation(seq: 1))
        let controller = try await started(fake)
        defer { controller.close() }
        await controller.resolve(callID: "c2", approve: true, scope: .conversation)
        await controller.resolve(callID: "c3", approve: true)
        await controller.resolve(callID: "c4", approve: false, scope: .conversation)
        let sent = fake.resolves
        XCTAssertEqual(sent.map(\.callID), ["c2", "c3", "c4"])
        XCTAssertEqual(sent.map(\.conversationID), ["conv_1", "conv_1", "conv_1"])
        XCTAssertEqual(sent.map(\.approve), [true, true, false])
        XCTAssertEqual(
            sent.map(\.scope), [.conversation, .unspecified, .unspecified],
            "unset is once, and a decline carries no scope")
    }

    @MainActor
    func testAnotherConversationIsNeverAnswered() async throws {
        let fake = FakeAssistantCalls(started: Self.conversation(seq: 1))
        let controller = try await started(fake)
        defer { controller.close() }
        let performer = CountingPerformer()
        controller.performer = performer

        controller.absorb(Self.waitingOnView("conv_other", seq: 9))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.conversation?.conversationID, "conv_1")
        XCTAssertEqual(controller.conversation?.seq, 1)
        XCTAssertTrue(performer.requests.isEmpty)
        XCTAssertTrue(fake.answers.isEmpty)
    }

    @MainActor
    func testABadViewToolInputIsAnsweredAsAnErrorWithoutTheWindow() async throws {
        let fake = FakeAssistantCalls(started: Self.conversation(seq: 1))
        let controller = try await started(fake)
        defer { controller.close() }
        let performer = CountingPerformer()
        controller.performer = performer
        var c = Self.waitingOnView(seq: 2)
        c.pending.argumentsJson = #"{"place":"kitchen"}"#
        controller.absorb(c)
        await assertSoon("the error was never answered") { fake.answers.count == 1 }
        XCTAssertTrue(fake.answers[0].isError)
        XCTAssertEqual(fake.answers[0].resultText, "place must be radio or library")
        XCTAssertTrue(performer.requests.isEmpty)
    }
}

/// Polls `condition` on the main actor for up to two seconds.
@MainActor
func assertSoon(
    _ message: String, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let end = clock.now + .seconds(2)
    while clock.now < end, !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(condition(), message, file: file, line: line)
}
