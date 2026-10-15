// SPDX-License-Identifier: GPL-3.0-or-later

// The assistant's conversations: daemon state in memory, one `ley worker assistant` per live
// conversation (docs/dev/engine-internals.md, "Assistant"; docs/design/ai.md, "The assistant").
//
// The worker runs the model and the tools; the daemon holds the conversation and derives its state
// from the turns the worker writes back (ai.proto, `ConversationState`): a turn whose last call
// waits on the user or a client makes it WAITING with that call as `pending`, a turn marked done
// makes it IDLE, anything else is THINKING. Clients only move it between those by what they send:
// a message, an approval, a view tool's answer, a stop, an end. Every change bumps the
// conversation's own `seq` and goes out whole (invariant 6), to `WatchConversation` streams and as
// `Event.conversation`.
//
// A conversation is not kept (invariant 8): it ends when a client ends it, after `idleLimit` with
// nothing asked, when its worker exits between turns, and when the daemon stops. A worker that
// exits mid-turn, or stops reading, fails its own conversation and no other. Ended and failed
// conversations stay listed, the `keptFinished` that finished last, so a client that comes back
// sees how one finished; an older one is forgotten and its id is then unknown.

import EngineCore
import Foundation
import LeylineProto
import Logging

actor ConversationStore {
    /// When an idle conversation ends, and the clock that says so: a test passes a clock of its
    /// own and a short sweep (`DecodeRunner` takes its timings the same way).
    struct Timing: Sendable {
        var idleLimit: Duration = .seconds(30 * 60)
        var sweepEvery: Duration = .seconds(30)
        var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    }

    /// Publishes a conversation on the event plane, caused by a client (`SessionStore.publishConversation`).
    typealias Publisher = @Sendable (Leyline_V1_Conversation, ClientContext) async -> Void
    /// Hears that a finished conversation has been forgotten (`SessionStore.forgetConversation`).
    typealias Forgetter = @Sendable (String) async -> Void

    /// Finished conversations kept for listing; older ones are forgotten.
    static let keptFinished = 32
    /// How many versions of each conversation `WatchConversation` can replay.
    static let keptVersions = 64
    /// How long `StopTurn` waits for the worker to mark the turn done before it answers anyway.
    static let stopWaitSeconds: Double = 2

    private struct Entry {
        var conversation: Leyline_V1_Conversation
        var worker: AssistantWorker?
        /// The key, kept only to replace it in what the worker writes back.
        var secret: String
        /// When the conversation last became IDLE; nil in any other state.
        var idleSince: ContinuousClock.Instant?
        var watchers: [UUID: AsyncStream<Leyline_V1_Conversation>.Continuation] = [:]
        /// The newest `keptVersions` states, oldest first, for `watch(_:sinceSeq:)` to replay.
        /// Emptied when the conversation finishes: nothing follows to replay.
        var history: [Leyline_V1_Conversation] = []
        /// When the conversation ended or failed, which orders the forgetting.
        var finishedAt: ContinuousClock.Instant?
        /// Assistant turns a `StopTurn` closed: the worker's later writes to them are ignored.
        var closedTurns: Set<String> = []
    }

    private let credentials: CredentialStore
    private let spawner: WorkerProcess
    private let publish: Publisher
    private let forget: Forgetter
    private let timing: Timing
    private var entries: [String: Entry] = [:]
    private var sweeper: Task<Void, Never>?
    private var closed = false
    private let log = Logger(label: "leyline.assistant")

    init(credentials: CredentialStore, spawner: WorkerProcess, timing: Timing = Timing(),
         forget: @escaping Forgetter = { _ in }, publish: @escaping Publisher)
    {
        self.credentials = credentials
        self.spawner = spawner
        self.timing = timing
        self.forget = forget
        self.publish = publish
    }

    // MARK: Reads

    /// Every conversation the daemon holds, newest first.
    func list() -> [Leyline_V1_Conversation] {
        entries.values.map(\.conversation).sorted { $0.startedAtNs != $1.startedAtNs
            ? $0.startedAtNs > $1.startedAtNs : $0.conversationID > $1.conversationID }
    }

    func get(_ id: String) throws -> Leyline_V1_Conversation {
        try entry(id).conversation
    }

    /// The conversation as it changes, after what the client already has (`replay`). The stream
    /// ends after it delivers ENDED or FAILED.
    func watch(_ id: String, sinceSeq: UInt64) throws -> AsyncStream<Leyline_V1_Conversation> {
        let found = try entry(id)
        let current = found.conversation
        let (stream, continuation) = AsyncStream<Leyline_V1_Conversation>.makeStream(
            bufferingPolicy: .bufferingNewest(2 * Self.keptVersions))
        for version in Self.replay(found.history, current: current, sinceSeq: sinceSeq) { continuation.yield(version) }
        if Self.isFinished(current.state) {
            continuation.finish()
            return stream
        }
        let key = UUID()
        entries[id]?.watchers[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeWatcher(id, key) }
        }
        return stream
    }

    // MARK: Client actions

    /// Resolves the provider and model, spawns the worker with the key and `WorkerStart`, and
    /// returns the conversation IDLE.
    func start(_ request: Leyline_V1_StartConversationRequest, by client: ClientContext) async throws -> Leyline_V1_Conversation {
        guard !closed else { throw EngineError.failedPrecondition("the daemon is stopping") }
        try Self.validate(request.viewTools)
        let (provider, model) = try await resolveModel(request)
        let credential = try await key(for: provider)
        let id = "conv_" + ULID().string
        var start = Leyline_V1_WorkerStart()
        start.conversationID = id
        start.provider = provider
        start.model = model
        start.endpoint = credential.endpoint
        start.viewTools = request.viewTools
        start.socket = spawner.socketPath
        // The lookups above suspend, and `endAll` may have run meanwhile. Nothing suspends from here
        // until the conversation is in `entries`, where a later `endAll` finds it.
        guard !closed else { throw EngineError.failedPrecondition("the daemon is stopping") }
        let worker = try spawner.startAssistant(credential: credential, start: start) { [weak self] error in
            Task { await self?.writeFailed(id, error) }
        }

        var conversation = Leyline_V1_Conversation()
        conversation.conversationID = id
        conversation.state = .conversationIdle
        conversation.provider = provider
        conversation.model = model
        conversation.startedBy = client.proto
        conversation.startedAtNs = WallClock.nowNs()
        conversation.viewTools = request.viewTools
        entries[id] = Entry(conversation: conversation, worker: worker, secret: credential.secret)
        log.info("started \(id) on \(provider) \(model.isEmpty ? "(the worker's default model)" : model) for \(client.kind) \(client.label)")
        follow(worker, of: id)
        startSweeping()
        return await commit(id, by: client) { _ in }
    }

    /// Adds the user's turn and hands it to the worker. FAILED_PRECONDITION unless IDLE.
    func send(_ id: String, text: String, by client: ClientContext) async throws -> Leyline_V1_Conversation {
        let current = try entry(id)
        guard current.conversation.state == .conversationIdle else {
            throw EngineError.failedPrecondition("\(Self.describe(current.conversation.state)); a message can be sent when it is idle", target: id)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.invalidArgument("the message is empty", target: id) }
        let turnID = Self.nextTurnID(after: current.conversation.turns)
        var event = Leyline_V1_WorkerEvent()
        event.user.turnID = turnID
        event.user.text = trimmed
        try write(event, to: current)
        return await commit(id, by: client) { e in
            var turn = Leyline_V1_Turn()
            turn.turnID = turnID
            turn.role = .user
            turn.text = trimmed
            turn.atNs = WallClock.nowNs()
            turn.done = true
            e.conversation.turns.append(turn)
            e.conversation.lastTurnAtNs = turn.atNs
            e.conversation.state = .conversationThinking
            e.conversation.clearPending()
        }
    }

    /// Approves or refuses the pending call. FAILED_PRECONDITION unless WAITING on that call for
    /// approval. The call shows RUNNING or REFUSED until the worker's next turn says otherwise.
    func resolve(_ id: String, callID: String, approve: Bool, by client: ClientContext) async throws -> Leyline_V1_Conversation {
        let current = try waiting(id, on: callID, viewTool: false)
        var event = Leyline_V1_WorkerEvent()
        event.resolved.callID = callID
        event.resolved.approved = approve
        try write(event, to: current)
        log.info("\(id): \(client.kind) \(client.label) \(approve ? "approved" : "declined") call \(callID)")
        return await commit(id, by: client) { e in
            e.conversation.updateCall(callID) { $0.state = approve ? .toolCallRunning : .toolCallRefused }
            e.conversation.state = .conversationThinking
            e.conversation.clearPending()
        }
    }

    /// Answers the pending view tool call. FAILED_PRECONDITION unless WAITING on that call.
    func answerView(_ request: Leyline_V1_AnswerViewToolRequest, by client: ClientContext) async throws -> Leyline_V1_Conversation {
        let id = request.conversationID
        let current = try waiting(id, on: request.callID, viewTool: true)
        var event = Leyline_V1_WorkerEvent()
        event.viewAnswer.callID = request.callID
        event.viewAnswer.resultText = request.resultText
        event.viewAnswer.resultJson = request.resultJson
        event.viewAnswer.isError = request.isError
        try write(event, to: current)
        return await commit(id, by: client) { e in
            e.conversation.updateCall(request.callID) {
                $0.state = .toolCallDone
                $0.resultText = request.resultText
                $0.resultJson = request.resultJson
                $0.isError = request.isError
            }
            e.conversation.state = .conversationThinking
            e.conversation.clearPending()
        }
    }

    /// Asks the worker to stop the running turn and waits up to `stopWaitSeconds` for the
    /// conversation to leave THINKING and WAITING, then closes that turn whatever the worker did
    /// (`closeStoppedTurn`), unless a newer turn has begun meanwhile. A later write from the worker
    /// to the closed turn is ignored. An IDLE conversation is returned as it is; an ended or failed
    /// one is FAILED_PRECONDITION.
    func stopTurn(_ id: String, by client: ClientContext) async throws -> Leyline_V1_Conversation {
        let current = try entry(id)
        switch current.conversation.state {
        case .conversationThinking, .conversationWaiting:
            break
        case .conversationIdle:
            return current.conversation
        default:
            throw EngineError.failedPrecondition("\(Self.describe(current.conversation.state)); there is no turn to stop", target: id)
        }
        // The turn being stopped: the assistant's newest, or the one it has yet to write for the
        // user's newest (`t<n+1>`, the worker protocol's numbering).
        let turns = current.conversation.turns
        let answering = turns.last(where: { $0.role == .user })?.turnID
        let target = turns.last?.role == .assistant ? turns.last!.turnID : Self.nextTurnID(after: turns)
        var event = Leyline_V1_WorkerEvent()
        event.stop = Leyline_V1_WorkerStop()
        try write(event, to: current)
        log.info("\(id): \(client.kind) \(client.label) stopped turn \(target)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.stopWaitSeconds))
        while ContinuousClock.now < deadline, let state = entries[id]?.conversation.state,
              state == .conversationThinking || state == .conversationWaiting
        {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let after = entries[id]?.conversation, !Self.isFinished(after.state) else { return try entry(id).conversation }
        entries[id]?.closedTurns.insert(target)
        let last = after.turns.last
        let stillOnIt = (last?.role == .assistant && last?.turnID == target)
            || (last?.role == .user && last?.turnID == answering)
        guard stillOnIt else { return after }
        var closedTurn = after
        closedTurn.closeStoppedTurn(target)
        guard closedTurn != after else { return after }
        return await commit(id, by: client) { $0.conversation.closeStoppedTurn(target) }
    }

    /// Ends the conversation and stops its worker: stdin closed, then `SIGTERM` and `SIGKILL`
    /// (`AssistantWorker.stop`). Returns once the worker has gone. Ending an ended or failed
    /// conversation returns it unchanged.
    func end(_ id: String, by client: ClientContext) async throws -> Leyline_V1_Conversation {
        let current = try entry(id)
        guard !Self.isFinished(current.conversation.state) else { return current.conversation }
        let ended = await commit(id, by: client) { e in
            e.conversation.state = .conversationEnded
            e.conversation.clearPending()
        }
        log.info("ended \(id) for \(client.kind) \(client.label)")
        await stopWorker(of: id)
        await forgetOldFinished()
        return ended
    }

    /// Ends every live conversation, for the daemon's shutdown. Nothing starts afterwards.
    func endAll() async {
        closed = true
        sweeper?.cancel()
        let live = entries.filter { !Self.isFinished($0.value.conversation.state) }.map(\.key)
        await withTaskGroup(of: Void.self) { group in
            for id in live {
                group.addTask { _ = try? await self.end(id, by: .daemon) }
            }
        }
    }

    /// Ends every conversation that has been IDLE for `idleLimit`. The sweep calls it; so can a test.
    func endIdle() async {
        let now = timing.now()
        let stale = entries.filter { entry in
            guard let since = entry.value.idleSince else { return false }
            return now - since >= timing.idleLimit
        }.map(\.key)
        for id in stale {
            log.info("\(id) sat idle for \(timing.idleLimit); ending it")
            _ = try? await end(id, by: .daemon)
        }
    }

    // MARK: The worker's side

    /// Folds one message from the worker. A conversation that has finished takes nothing more.
    func apply(_ message: Leyline_V1_WorkerMessage, to id: String) async {
        guard let current = entries[id], !Self.isFinished(current.conversation.state) else { return }
        switch message.message {
        case .turn(let raw)?:
            let turn = Self.redacted(raw, secret: current.secret)
            if current.closedTurns.contains(turn.turnID) {
                log.info("\(id): the worker wrote to \(turn.turnID) after it was stopped; ignoring it")
                return
            }
            if let existing = current.conversation.turns.first(where: { $0.turnID == turn.turnID }), existing.role == .user {
                log.warning("\(id): the worker wrote a turn as \(turn.turnID), which is the user's; ignoring it")
                return
            }
            _ = await commit(id, by: .daemon) { e in e.conversation.fold(turn) }
        case .failure(let failure)?:
            var error = failure.error
            if error.code.isEmpty { error.code = EngineError.Code.internalError }
            error.code = WorkerProcess.redacting(current.secret, in: error.code)
            error.message = WorkerProcess.redacting(current.secret, in: error.message)
            error.target = error.target.isEmpty ? id : WorkerProcess.redacting(current.secret, in: error.target)
            log.warning("\(id) failed: \(error.code): \(error.message)")
            _ = await commit(id, by: .daemon) { e in
                e.conversation.state = .conversationFailed
                e.conversation.error = error
                e.conversation.clearPending()
            }
            await stopWorker(of: id)
            await forgetOldFinished()
        case nil:
            return
        }
    }

    /// The worker has exited. Between turns that ends the conversation; mid-turn it fails it.
    func workerExited(_ id: String, status: Int32) async {
        guard let current = entries[id] else { return }
        entries[id]?.worker = nil
        switch current.conversation.state {
        case .conversationThinking, .conversationWaiting:
            log.warning("\(id): the worker exited mid-turn with status \(status)")
            _ = await commit(id, by: .daemon) { e in
                e.conversation.state = .conversationFailed
                e.conversation.error = ProtoMapping.errorDetail(
                    .internalError("the assistant stopped unexpectedly (status \(status))", target: id))
                e.conversation.clearPending()
            }
        case .conversationIdle:
            log.info("\(id): the worker exited between turns with status \(status); ending it")
            _ = await commit(id, by: .daemon) { e in e.conversation.state = .conversationEnded }
        default:
            break
        }
        await forgetOldFinished()
    }

    /// A write did not reach the worker: it stopped reading, or its stdin closed under it. The
    /// conversation fails and the worker is stopped.
    func writeFailed(_ id: String, _ error: EngineError) async {
        guard let current = entries[id], !Self.isFinished(current.conversation.state) else { return }
        log.warning("\(id): \(error.message); failing it")
        _ = await commit(id, by: .daemon) { e in
            e.conversation.state = .conversationFailed
            e.conversation.error = ProtoMapping.errorDetail(EngineError(code: error.code, message: error.message, target: id))
            e.conversation.clearPending()
        }
        await stopWorker(of: id)
        await forgetOldFinished()
    }

    // MARK: Internals

    /// Applies `mutate`, bumps `seq`, feeds the watchers and publishes the event. The change and
    /// the watchers happen before the one suspension, so every watcher sees the changes in order;
    /// the event plane drops a publish that a newer one overtook (`publishConversation`).
    private func commit(_ id: String, by client: ClientContext,
                        _ mutate: (inout Entry) -> Void) async -> Leyline_V1_Conversation
    {
        guard var e = entries[id] else { return Leyline_V1_Conversation() }
        mutate(&e)
        e.conversation.seq += 1
        if e.conversation.state == .conversationIdle {
            if e.idleSince == nil { e.idleSince = timing.now() }
        } else {
            e.idleSince = nil
        }
        let conversation = e.conversation
        e.history.append(conversation)
        if e.history.count > Self.keptVersions { e.history.removeFirst(e.history.count - Self.keptVersions) }
        for watcher in e.watchers.values { watcher.yield(conversation) }
        if Self.isFinished(conversation.state) {
            for watcher in e.watchers.values { watcher.finish() }
            e.watchers = [:]
            e.secret = ""
            e.history = []
            e.finishedAt = timing.now()
        }
        entries[id] = e
        await publish(conversation, client)
        return conversation
    }

    /// Reads what the worker writes and notices when it exits.
    private func follow(_ worker: AssistantWorker, of id: String) {
        Task { [weak self] in
            for await message in worker.messages {
                await self?.apply(message, to: id)
            }
            var status: Int32 = -1
            for await code in worker.exits { status = code }
            await self?.workerExited(id, status: status)
        }
    }

    private func startSweeping() {
        guard sweeper == nil else { return }
        let every = timing.sweepEvery
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                await self?.endIdle()
            }
        }
    }

    private func stopWorker(of id: String) async {
        guard let worker = entries[id]?.worker else { return }
        entries[id]?.worker = nil
        await worker.stop()
    }

    private func removeWatcher(_ id: String, _ key: UUID) {
        entries[id]?.watchers[key] = nil
    }

    /// Forgets the finished conversations beyond the `keptFinished` that finished last. Called
    /// after a worker has been stopped, so one whose worker is still going is never dropped with it.
    private func forgetOldFinished() async {
        let finished = entries.compactMap { id, e -> (id: String, at: ContinuousClock.Instant)? in
            guard let at = e.finishedAt, e.worker == nil else { return nil }
            return (id, at)
        }
        guard finished.count > Self.keptFinished else { return }
        let oldest = finished.sorted { $0.at < $1.at }.prefix(finished.count - Self.keptFinished)
        for (id, _) in oldest {
            entries[id] = nil
            await forget(id)
        }
    }

    /// What a watcher that has `sinceSeq` is sent before the live changes: 0 is the current state
    /// alone; a seq still in `history` is every version after it; a seq older than that, or newer
    /// than the conversation (a client that kept one across a daemon restart), is the current
    /// state; the current seq is nothing.
    static func replay(_ history: [Leyline_V1_Conversation], current: Leyline_V1_Conversation,
                       sinceSeq: UInt64) -> [Leyline_V1_Conversation]
    {
        if sinceSeq == current.seq { return [] }
        guard sinceSeq != 0, sinceSeq < current.seq else { return [current] }
        let newer = history.filter { $0.seq > sinceSeq }
        guard newer.first?.seq == sinceSeq + 1 else { return [current] }
        return newer
    }

    private func entry(_ id: String) throws -> Entry {
        guard let e = entries[id] else {
            throw EngineError.invalidArgument("there is no conversation called \(id); ListConversations lists them", target: id)
        }
        return e
    }

    private func waiting(_ id: String, on callID: String, viewTool: Bool) throws -> Entry {
        let current = try entry(id)
        let pending = current.conversation.pending
        guard current.conversation.state == .conversationWaiting, current.conversation.hasPending,
              pending.callID == callID, pending.viewTool == viewTool
        else {
            let what = viewTool ? "a view tool's answer" : "an approval"
            throw EngineError.failedPrecondition("\(id) is not waiting on \(what) for call \(callID)", target: id)
        }
        return current
    }

    private func write(_ event: Leyline_V1_WorkerEvent, to entry: Entry) throws {
        guard let worker = entry.worker else {
            throw EngineError.internalError("the assistant's worker has gone", target: entry.conversation.conversationID)
        }
        worker.send(event)
    }

    /// Resolves the request's provider and model: the request's own, else the `assistant`
    /// feature's; FAILED_PRECONDITION when neither names a provider. A model left empty is the
    /// worker's default for the provider.
    private func resolveModel(_ request: Leyline_V1_StartConversationRequest) async throws -> (String, String) {
        var provider = request.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        var model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = await credentials.snapshot().features.first { $0.feature == "assistant" }
        if provider.isEmpty {
            guard let chosen, !chosen.provider.isEmpty else {
                throw EngineError.failedPrecondition(
                    "no model is chosen for the assistant; choose one with ley ai use assistant <provider> <model>",
                    target: "assistant")
            }
            provider = chosen.provider
            if model.isEmpty { model = chosen.model }
        } else if model.isEmpty, let chosen, chosen.provider == provider {
            model = chosen.model
        }
        return (provider, model)
    }

    /// The provider's key for the worker's stdin. `CREDENTIAL_MISSING` without one,
    /// `CREDENTIAL_REJECTED` when its last check was refused.
    private func key(for provider: String) async throws -> Leyline_V1_SetCredentialRequest {
        guard let listed = await credentials.credential(provider) else { throw EngineError.credentialMissing(provider) }
        if listed.lastCheck.outcome == .rejected {
            throw EngineError.credentialRejected(provider, providerMessage: listed.lastCheck.message)
        }
        return try await credentials.pluginCredential(provider)
    }

    private static func validate(_ tools: [Leyline_V1_ViewTool]) throws {
        var names: Set<String> = []
        for tool in tools {
            guard !tool.name.isEmpty else { throw EngineError.invalidArgument("a view tool has no name", target: "view_tools") }
            guard names.insert(tool.name).inserted else {
                throw EngineError.invalidArgument("two view tools are called \(tool.name)", target: tool.name)
            }
        }
    }

    static func isFinished(_ state: Leyline_V1_ConversationState) -> Bool {
        state == .conversationEnded || state == .conversationFailed
    }

    /// The next user turn's id: one past the highest `tN` so far, whatever ids the worker chose.
    static func nextTurnID(after turns: [Leyline_V1_Turn]) -> String {
        let highest = turns.compactMap { $0.turnID.hasPrefix("t") ? Int($0.turnID.dropFirst()) : nil }.max() ?? 0
        return "t\(max(highest, turns.count) + 1)"
    }

    private static func describe(_ state: Leyline_V1_ConversationState) -> String {
        switch state {
        case .conversationThinking: "the assistant is on a turn"
        case .conversationWaiting: "the assistant is waiting for an answer to a call"
        case .conversationEnded: "the conversation has ended"
        case .conversationFailed: "the conversation has failed"
        default: "the conversation is idle"
        }
    }

    /// The turn with the key replaced wherever the worker could have echoed it.
    private static func redacted(_ turn: Leyline_V1_Turn, secret: String) -> Leyline_V1_Turn {
        guard !secret.isEmpty else { return turn }
        var out = turn
        out.turnID = WorkerProcess.redacting(secret, in: turn.turnID)
        out.text = WorkerProcess.redacting(secret, in: turn.text)
        for i in out.tools.indices {
            out.tools[i].callID = WorkerProcess.redacting(secret, in: out.tools[i].callID)
            out.tools[i].tool = WorkerProcess.redacting(secret, in: out.tools[i].tool)
            out.tools[i].argumentsJson = WorkerProcess.redacting(secret, in: out.tools[i].argumentsJson)
            out.tools[i].resultText = WorkerProcess.redacting(secret, in: out.tools[i].resultText)
            out.tools[i].resultJson = WorkerProcess.redacting(secret, in: out.tools[i].resultJson)
            out.tools[i].reason = WorkerProcess.redacting(secret, in: out.tools[i].reason)
        }
        return out
    }
}

extension Leyline_V1_Conversation {
    /// Replaces the assistant turn with this one's id, or appends it, and derives the state: a
    /// done turn is IDLE, a turn whose last call waits on someone is WAITING on that call, any
    /// other is THINKING.
    mutating func fold(_ incoming: Leyline_V1_Turn) {
        var turn = incoming
        turn.role = .assistant
        if turn.atNs == 0 { turn.atNs = WallClock.nowNs() }
        if let i = turns.firstIndex(where: { $0.turnID == turn.turnID }) {
            turns[i] = turn
        } else {
            turns.append(turn)
        }
        lastTurnAtNs = WallClock.nowNs()
        if turn.done {
            state = .conversationIdle
            clearPending()
        } else if let call = turn.tools.last,
                  call.state == .toolCallAwaitingApproval || call.state == .toolCallAwaitingClient
        {
            state = .conversationWaiting
            var pending = Leyline_V1_PendingAction()
            pending.callID = call.callID
            pending.tool = call.tool
            pending.argumentsJson = call.argumentsJson
            pending.reason = call.reason
            pending.viewTool = call.state == .toolCallAwaitingClient
            self.pending = pending
        } else {
            state = .conversationThinking
            clearPending()
        }
    }

    /// Ends the stopped turn `turnID`: when it is the newest turn and the assistant's, it is marked
    /// done, a call still waiting on someone is REFUSED and one still running is DONE as an error,
    /// "stopped". The conversation is IDLE.
    mutating func closeStoppedTurn(_ turnID: String) {
        if let last = turns.indices.last, turns[last].role == .assistant, turns[last].turnID == turnID {
            turns[last].done = true
            for c in turns[last].tools.indices {
                switch turns[last].tools[c].state {
                case .toolCallAwaitingApproval, .toolCallAwaitingClient:
                    turns[last].tools[c].state = .toolCallRefused
                case .toolCallRunning:
                    turns[last].tools[c].state = .toolCallDone
                    turns[last].tools[c].isError = true
                    turns[last].tools[c].resultText = "stopped"
                default:
                    break
                }
            }
        }
        state = .conversationIdle
        clearPending()
    }

    /// Changes the call `callID` in whichever turn holds it, newest first.
    mutating func updateCall(_ callID: String, _ change: (inout Leyline_V1_ToolCall) -> Void) {
        for t in turns.indices.reversed() {
            if let c = turns[t].tools.firstIndex(where: { $0.callID == callID }) {
                change(&turns[t].tools[c])
                return
            }
        }
    }
}
