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
// `AnswerViewTool`. The performer is a protocol so the daemon-backed tests answer with one of
// their own, since the window is never compiled on Linux. Main-actor and free of UI frameworks for
// the same reason as `DaemonMirror`: the session copies `conversation` and `notice` out on
// `onChange`.

import Foundation
import LeylineProto

/// Performs a view tool call in the window and says what it did.
@MainActor
public protocol ViewToolPerformer: AnyObject {
    func perform(_ request: AppViewTools.Request) async -> ViewToolAnswer
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
    /// The daemon no longer knows the conversation (it restarted, or forgot a finished one): it
    /// can only be replaced.
    public private(set) var isLost = false { didSet { onChange?(self) } }

    /// Called on the main actor after any of the above changes.
    public var onChange: (@MainActor (AssistantController) -> Void)?
    /// One line for the app's log, for each call and each view tool answered.
    public var log: (@MainActor (String) -> Void)?
    /// Does what a view tool asks. Weak: the window owns it, and a call that arrives with no
    /// window is answered as an error.
    public weak var performer: (any ViewToolPerformer)?

    public let connection: DaemonConnection
    public let viewTools: [Leyline_V1_ViewTool]
    private let backoff: [Duration]
    private var watching: Task<Void, Never>?
    /// View tool calls already answered or being answered, so a state seen twice (from the watch
    /// and from the mirror) runs the call once.
    private var answered: Set<String> = []

    /// `backoff` is how long the watch waits after a dropped stream, the last entry repeating.
    public init(
        connection: DaemonConnection, viewTools: [Leyline_V1_ViewTool] = AppViewTools.declarations,
        backoff: [Duration] = [.milliseconds(250), .seconds(1), .seconds(2), .seconds(5)]
    ) {
        self.connection = connection
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
            let c = try await connection.assistant.startConversation(req)
            watching?.cancel()
            answered = []
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
            absorb(try await connection.assistant.sendMessage(req))
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
        await call(.resolve) { try await self.connection.assistant.resolveAction(req) }
    }

    /// Ends the running turn; the conversation goes on, waiting for the next message.
    public func stopTurn() async {
        guard let id = conversationID else { return }
        var ref = Leyline_V1_ConversationRef()
        ref.conversationID = id
        log?("stop \(id)")
        await call(.stop) { try await self.connection.assistant.stopTurn(ref) }
    }

    /// Ends the conversation and its worker; the transcript stays until `clear()`.
    public func end() async {
        guard let id = conversationID, !needsStart else { return }
        var ref = Leyline_V1_ConversationRef()
        ref.conversationID = id
        log?("end \(id)")
        await call(.end) { try await self.connection.assistant.endConversation(ref) }
    }

    /// New conversation: ends the one shown, if it is still going, and empties the panel.
    public func clear() async {
        await end()
        watching?.cancel()
        watching = nil
        answered = []
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
    /// call it carries.
    public func absorb(_ c: Leyline_V1_Conversation) {
        guard let held = conversation, c.conversationID == held.conversationID, c.seq > held.seq
        else { return }
        conversation = c
        answerViewTool()
    }

    // MARK: Internals

    /// One unary call whose reply is the conversation. A `FAILED_PRECONDITION` means the
    /// conversation moved on first (another client answered, the turn ended): the watch brings
    /// the state that shows how, and nothing is said.
    private func call(
        _ action: AssistantAction,
        _ rpc: @escaping @MainActor () async throws -> Leyline_V1_Conversation
    ) async {
        do {
            absorb(try await rpc())
            notice = nil
        } catch {
            let e = LeylineError(error)
            if e.code == "FAILED_PRECONDITION", action != .start {
                log?("\(action.words): the conversation had moved on (\(e.message))")
                return
            }
            fail(action, error)
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

    /// Follows the conversation until it ends or fails, resuming from the held `seq` after a
    /// dropped stream. An unknown id ends the watch: the daemon restarted and the conversation,
    /// which is never kept, went with it.
    private func watch(_ id: String) {
        watching?.cancel()
        watching = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let since = self?.heldSeq(id) else { return }
                guard let stream = self?.connection.conversation(id, sinceSeq: since) else {
                    return
                }
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

    /// Runs the view tool call the conversation is waiting on, once, and sends the answer.
    private func answerViewTool() {
        guard let c = conversation, c.state == .conversationWaiting, c.hasPending,
            c.pending.viewTool, !c.pending.callID.isEmpty,
            !answered.contains(c.pending.callID)
        else { return }
        let pending = c.pending
        answered.insert(pending.callID)
        Task { await self.perform(pending, in: c.conversationID) }
    }

    private func perform(_ pending: Leyline_V1_PendingAction, in id: String) async {
        let answer: ViewToolAnswer
        switch AppViewTools.parse(tool: pending.tool, argumentsJSON: pending.argumentsJson) {
        case .failure(let e):
            answer = e.answer
        case .success(let request):
            if let performer {
                answer = await performer.perform(request)
            } else {
                answer = ViewToolAnswer(
                    text: "The app's window is closed, so nothing could be shown.", isError: true)
            }
        }
        log?(
            "view tool \(pending.tool) \(pending.callID): \(answer.isError ? "error: " : "")\(AssistantWords.firstLine(answer.text))"
        )
        var req = Leyline_V1_AnswerViewToolRequest()
        req.conversationID = id
        req.callID = pending.callID
        req.resultText = answer.text
        req.resultJson = answer.json
        req.isError = answer.isError
        await call(.answerViewTool) { try await self.connection.assistant.answerViewTool(req) }
    }
}
