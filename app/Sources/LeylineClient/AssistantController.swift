// SPDX-License-Identifier: Apache-2.0

// The app's side of one assistant conversation: start it with the app's view tools, send what the
// person types, answer the questions they decide, stop a turn, end it, and keep the conversation
// current by watching it. The conversation is daemon state (`docs/design/ai.md`, "The assistant";
// invariant 7): this holds the newest copy the daemon sent, from the RPC replies, the watch and the
// mirror's events alike, and takes whichever has the higher `seq`. The watch resumes from the `seq`
// it holds after a dropped stream, as the mirror resumes from its own (invariant 6).
//
// A view tool call is answered here, once per call id: the call is parsed (`AppViewTools`), a
// performer the window provides does what it asks on the main actor, and the answer goes back with
// `AnswerViewTool`, again after a backoff when it did not reach the daemon. The performer is a
// protocol so the daemon-backed tests answer with one of their own, since the window is never
// compiled on Linux, and the RPCs are behind `AssistantCalls` so the rules here are tested without
// a daemon. Main-actor and free of UI frameworks for the same reason as `DaemonMirror`: the session
// copies `conversation` and `notice` out on `onChange`.

import Foundation
import LeylineProto

/// Performs a view tool call in the window and says what it did.
@MainActor
public protocol ViewToolPerformer: AnyObject {
    func perform(_ request: AppViewTools.Request) async -> ViewToolAnswer
}

/// The `Assistant` RPCs the controller makes. `DaemonConnection` is the one the app uses.
public protocol AssistantCalls: Sendable {
    func startConversation(_ request: Leyline_V1_StartConversationRequest) async throws
        -> Leyline_V1_Conversation
    func sendMessage(_ request: Leyline_V1_SendMessageRequest) async throws
        -> Leyline_V1_Conversation
    func resolveAction(_ request: Leyline_V1_ResolveActionRequest) async throws
        -> Leyline_V1_Conversation
    func answerViewTool(_ request: Leyline_V1_AnswerViewToolRequest) async throws
        -> Leyline_V1_Conversation
    func stopTurn(_ ref: Leyline_V1_ConversationRef) async throws -> Leyline_V1_Conversation
    func endConversation(_ ref: Leyline_V1_ConversationRef) async throws
        -> Leyline_V1_Conversation
    /// `WatchConversation` from `sinceSeq`, ending after `ENDED` or `FAILED`.
    func conversation(_ id: String, sinceSeq: UInt64) -> AsyncThrowingStream<
        Leyline_V1_Conversation, any Error
    >
}

extension DaemonConnection: AssistantCalls {
    public func startConversation(_ request: Leyline_V1_StartConversationRequest) async throws
        -> Leyline_V1_Conversation
    {
        try await assistant.startConversation(request)
    }

    public func sendMessage(_ request: Leyline_V1_SendMessageRequest) async throws
        -> Leyline_V1_Conversation
    {
        try await assistant.sendMessage(request)
    }

    public func resolveAction(_ request: Leyline_V1_ResolveActionRequest) async throws
        -> Leyline_V1_Conversation
    {
        try await assistant.resolveAction(request)
    }

    public func answerViewTool(_ request: Leyline_V1_AnswerViewToolRequest) async throws
        -> Leyline_V1_Conversation
    {
        try await assistant.answerViewTool(request)
    }

    public func stopTurn(_ ref: Leyline_V1_ConversationRef) async throws
        -> Leyline_V1_Conversation
    {
        try await assistant.stopTurn(ref)
    }

    public func endConversation(_ ref: Leyline_V1_ConversationRef) async throws
        -> Leyline_V1_Conversation
    {
        try await assistant.endConversation(ref)
    }
}

@MainActor
public final class AssistantController {
    /// The conversation this window started, as the daemon last sent it; nil before the first
    /// start and after `clear()`.
    public private(set) var conversation: Leyline_V1_Conversation? {
        didSet { onChange?(self) }
    }
    /// Why the last call failed, or that the daemon forgot the conversation; nil after a call
    /// that worked.
    public private(set) var notice: AssistantNotice? { didSet { onChange?(self) } }
    /// A start or a message is on its way: the field waits for the reply.
    public private(set) var sending = false { didSet { onChange?(self) } }
    /// The daemon no longer knows the conversation (a client deleted it, or the daemon's
    /// retention dropped it): it can only be replaced.
    public private(set) var isLost = false { didSet { onChange?(self) } }

    /// Called on the main actor after any of the above changes.
    public var onChange: (@MainActor (AssistantController) -> Void)?
    /// One line for the app's log, for each call and each view tool answered.
    public var log: (@MainActor (String) -> Void)?
    /// Does what a view tool asks. Weak: the window owns it, and a call that arrives with no
    /// window is answered as an error.
    public weak var performer: (any ViewToolPerformer)?

    public let calls: any AssistantCalls
    public let viewTools: [Leyline_V1_ViewTool]
    private let backoff: [Duration]
    private var watching: Task<Void, Never>?
    /// View tool calls performed, by call id, with the answer the window gave: a state seen twice
    /// (from the watch and from the mirror) runs the call once, and an answer that did not reach
    /// the daemon is sent again without running the call again.
    private var answers: [String: ViewToolAnswer] = [:]
    /// The call ids whose answer is on its way, or waiting out a backoff before it is sent again.
    private var answering: Set<String> = []
    /// How many times each call's answer failed to reach the daemon, for the backoff.
    private var answerFailures: [String: Int] = [:]

    /// `backoff` is how long the watch waits after a dropped stream, and an answer after a failed
    /// send, the last entry repeating.
    public init(
        calls: any AssistantCalls, viewTools: [Leyline_V1_ViewTool] = AppViewTools.declarations,
        backoff: [Duration] = [.milliseconds(250), .seconds(1), .seconds(2), .seconds(5)]
    ) {
        self.calls = calls
        self.viewTools = viewTools
        self.backoff = backoff
    }

    public var conversationID: String? { conversation?.conversationID }

    /// Whether a message now starts a new conversation rather than continuing this one.
    public var needsStart: Bool {
        guard let c = conversation, !isLost else { return true }
        return c.state == .conversationEnded || c.state == .conversationFailed
    }

    /// `StartConversation` with the app's view tools and no provider or model, so the daemon uses
    /// the assistant feature's (`ley ai use assistant`, or the Settings pane). Returns whether a
    /// conversation started; when it did not, `notice` says why.
    @discardableResult
    public func start() async -> Bool {
        var req = Leyline_V1_StartConversationRequest()
        req.viewTools = viewTools
        sending = true
        defer { sending = false }
        do {
            let c = try await calls.startConversation(req)
            watching?.cancel()
            forgetAnswers()
            isLost = false
            notice = nil
            conversation = c
            log?("started \(c.conversationID) on \(c.provider) \(c.model)")
            watch(c.conversationID)
            return true
        } catch {
            fail(.start, error)
            return false
        }
    }

    /// Sends `text` as the person's next message, starting a conversation first when there is
    /// none to continue. Returns whether the daemon took it, so the field keeps the text when it
    /// did not.
    @discardableResult
    public func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if needsStart, !(await start()) { return false }
        guard let id = conversationID else { return false }
        var req = Leyline_V1_SendMessageRequest()
        req.conversationID = id
        req.text = trimmed
        sending = true
        defer { sending = false }
        do {
            absorb(try await calls.sendMessage(req))
            notice = nil
            return true
        } catch {
            fail(.send, error)
            return false
        }
    }

    /// Allow or Decline on the question the assistant is waiting on.
    public func resolve(callID: String, approve: Bool) async {
        guard let id = conversationID else { return }
        var req = Leyline_V1_ResolveActionRequest()
        req.conversationID = id
        req.callID = callID
        req.approve = approve
        log?("\(approve ? "allowed" : "declined") \(callID)")
        let calls = calls
        let request = req
        await call(.resolve) { try await calls.resolveAction(request) }
    }

    /// Ends the running turn; the conversation goes on, waiting for the next message.
    public func stopTurn() async {
        guard let id = conversationID else { return }
        var ref = Leyline_V1_ConversationRef()
        ref.conversationID = id
        log?("stop \(id)")
        let calls = calls
        let request = ref
        await call(.stop) { try await calls.stopTurn(request) }
    }

    /// Ends the conversation and its worker; the transcript stays until `clear()`.
    public func end() async {
        guard let id = conversationID, !needsStart else { return }
        var ref = Leyline_V1_ConversationRef()
        ref.conversationID = id
        log?("end \(id)")
        let calls = calls
        let request = ref
        await call(.end) { try await calls.endConversation(request) }
    }

    /// New conversation: ends the one shown, if it is still going, and empties the panel.
    public func clear() async {
        await end()
        watching?.cancel()
        watching = nil
        forgetAnswers()
        isLost = false
        notice = nil
        conversation = nil
    }

    /// Stops watching, for a window that closes or a test that ends. The conversation goes on in
    /// the daemon until it is ended or idles out.
    public func close() {
        watching?.cancel()
        watching = nil
    }

    /// Takes a copy of the conversation from anywhere (an RPC's reply, the watch, the mirror's
    /// event) when it is this window's and newer than the one held, then answers a view tool
    /// call it carries. Another conversation, `ley ask`'s say, is not this window's to answer.
    public func absorb(_ c: Leyline_V1_Conversation) {
        guard let held = conversation, c.conversationID == held.conversationID, c.seq > held.seq
        else { return }
        conversation = c
        answerViewTool()
    }

    // MARK: Internals

    /// One unary call whose reply is the conversation. A `FAILED_PRECONDITION` means the
    /// conversation moved on first (another client answered, the turn ended): the watch brings
    /// the state that shows how, and nothing is said. Returns whether the call reached the
    /// daemon, which includes that refusal.
    @discardableResult
    private func call(
        _ action: AssistantAction,
        _ rpc: @escaping @Sendable () async throws -> Leyline_V1_Conversation
    ) async -> Bool {
        do {
            absorb(try await rpc())
            notice = nil
            return true
        } catch {
            let e = LeylineError(error)
            if e.code == "FAILED_PRECONDITION", action != .start {
                log?("\(action.words): the conversation had moved on (\(e.message))")
                return true
            }
            fail(action, error)
            return false
        }
    }

    private func fail(_ action: AssistantAction, _ error: any Error) {
        let e = LeylineError(error)
        if e.code == "INVALID_ARGUMENT", action != .start, conversation != nil {
            forgotten()
            return
        }
        log?("could not \(action.words): \(e.code) \(e.message)")
        notice = AssistantWords.failed(action, e)
    }

    private func forgotten() {
        log?("the daemon no longer knows \(conversationID ?? "the conversation")")
        isLost = true
        notice = AssistantNotice(text: AssistantWords.forgotten)
        close()
    }

    private func forgetAnswers() {
        answers = [:]
        answering = []
        answerFailures = [:]
    }

    /// Follows the conversation until it ends or fails, resuming from the held `seq` after a
    /// dropped stream, a daemon restart included, since the daemon keeps the conversation. An
    /// unknown id ends the watch: the conversation was deleted.
    private func watch(_ id: String) {
        watching?.cancel()
        watching = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let since = self?.heldSeq(id) else { return }
                guard let stream = self?.calls.conversation(id, sinceSeq: since) else { return }
                do {
                    for try await c in stream {
                        self?.absorb(c)
                        attempt = 0
                    }
                    // The daemon ends the stream after ENDED or FAILED; any other end is the
                    // daemon going away, and the watch dials again.
                    if self?.needsStart ?? true { return }
                } catch {
                    if Task.isCancelled { return }
                    if LeylineError(error).code == "INVALID_ARGUMENT" {
                        self?.forgotten()
                        return
                    }
                }
                guard let wait = self?.delay(after: attempt) else { return }
                attempt += 1
                do { try await Task.sleep(for: wait) } catch { return }
            }
        }
    }

    private func delay(after attempt: Int) -> Duration {
        backoff[min(attempt, backoff.count - 1)]
    }

    /// The `seq` held for `id`, or nil when the window has moved on to another conversation.
    private func heldSeq(_ id: String) -> UInt64? {
        guard let c = conversation, c.conversationID == id else { return nil }
        return c.seq
    }

    /// Answers the view tool call the conversation is waiting on, unless its answer is already
    /// on its way. The call is performed the first time only; a retry sends the answer kept.
    private func answerViewTool() {
        guard let c = conversation, c.state == .conversationWaiting, c.hasPending,
            c.pending.viewTool, !c.pending.callID.isEmpty,
            !answering.contains(c.pending.callID)
        else { return }
        let pending = c.pending
        answering.insert(pending.callID)
        Task { await self.answer(pending, in: c.conversationID) }
    }

    private func answer(_ pending: Leyline_V1_PendingAction, in id: String) async {
        let answer: ViewToolAnswer
        if let kept = answers[pending.callID] {
            answer = kept
        } else {
            answer = await perform(pending)
            answers[pending.callID] = answer
            log?(
                "view tool \(pending.tool) \(pending.callID): \(answer.isError ? "error: " : "")\(AssistantWords.firstLine(answer.text))"
            )
        }
        var req = Leyline_V1_AnswerViewToolRequest()
        req.conversationID = id
        req.callID = pending.callID
        req.resultText = answer.text
        req.resultJson = answer.json
        req.isError = answer.isError
        let calls = calls
        let request = req
        if await call(.answerViewTool, { try await calls.answerViewTool(request) }) { return }
        // The answer did not reach the daemon: after a backoff, the call the conversation then
        // waits on is answered, which is this one unless it has moved on.
        let failures = answerFailures[pending.callID, default: 0]
        answerFailures[pending.callID] = failures + 1
        try? await Task.sleep(for: delay(after: failures))
        answering.remove(pending.callID)
        guard conversationID == id else { return }
        answerViewTool()
    }

    private func perform(_ pending: Leyline_V1_PendingAction) async -> ViewToolAnswer {
        switch AppViewTools.parse(tool: pending.tool, argumentsJSON: pending.argumentsJson) {
        case .failure(let e):
            return e.answer
        case .success(let request):
            guard let performer else {
                return ViewToolAnswer(
                    text: "The app's window is closed, so nothing could be shown.", isError: true)
            }
            return await performer.perform(request)
        }
    }
}
