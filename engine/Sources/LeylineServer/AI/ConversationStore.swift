// SPDX-License-Identifier: GPL-3.0-or-later

// The assistant's conversations: daemon state kept on disk, and one `ley worker assistant` for each
// conversation in use (docs/dev/engine-internals.md, "Assistant"; docs/design/ai.md, "The
// assistant").
//
// The worker runs the model and the tools; the daemon holds the conversation and derives its state
// from the turns the worker writes back (ai.proto, `ConversationState`): a turn whose last call
// waits on the user or a client makes it WAITING with that call as `pending`, a turn marked done
// makes it IDLE, anything else is THINKING. Clients only move it between those by what they send:
// a message, an approval, a view tool's answer, a stop, an end. Every change bumps the
// conversation's own `seq` and goes out whole (invariant 6), to `WatchConversation` streams and as
// `Event.conversation`.
//
// A conversation is kept, because the user asked for it and comes back to it (invariant 8):
// `<data>/conversations/<id>/conversation.json` holds it, rewritten whenever a turn is done, a call
// is asked or answered, or the state changes, but not on a text delta. Beside it the worker keeps
// its own model transcript, `transcript.jsonl`. It ends only when a client ends it, and stays
// readable until a client deletes it or the retention drops it (the newest `keptConversations`,
// none older than `keptDays`). After `idleLimit` with nothing asked its worker is stopped and the
// conversation stays IDLE; a worker that exits between turns leaves it the same way, and so does
// the daemon's shutdown. The next message starts a worker again, told to resume from its
// transcript. A worker that exits mid-turn, or stops reading, fails its own conversation and no
// other. At start every kept conversation is loaded without a worker, and one the last daemon left
// mid-turn has that turn closed with `restartNote`.

import EngineCore
import Foundation
import LeylineProto
import Logging
import SwiftProtobuf

actor ConversationStore {
    /// When an idle conversation's worker is stopped, and the clock that says so: a test passes a
    /// clock of its own and a short sweep (`DecodeRunner` takes its timings the same way).
    struct Timing: Sendable {
        var idleLimit: Duration = .seconds(30 * 60)
        var sweepEvery: Duration = .seconds(30)
        var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    }

    /// Publishes a conversation on the event plane, caused by a client (`SessionStore.publishConversation`).
    typealias Publisher = @Sendable (Leyline_V1_Conversation, ClientContext) async -> Void
    /// Hears that a conversation has been deleted (`SessionStore.forgetConversation`).
    typealias Forgetter = @Sendable (String) async -> Void

    /// How many conversations are kept, newest last turn first; older ones are deleted.
    static let keptConversations = 100
    /// Conversations whose last turn is older than this are deleted when the daemon starts.
    static let keptDays: Int64 = 90
    /// What closes a turn the last daemon was on when it stopped.
    static let restartNote = "(the daemon restarted during this turn)"
    /// The files in a conversation's directory.
    static let conversationFile = "conversation.json"
    static let transcriptFile = "transcript.jsonl"
    /// How many versions of each conversation `WatchConversation` can replay.
    static let keptVersions = 64
    /// How long `StopTurn` waits for the worker to mark the turn done before it answers anyway.
    static let stopWaitSeconds: Double = 2

    private struct Entry {
        var conversation: Leyline_V1_Conversation
        /// The running worker; nil before the first message after a load, after the idle sweep
        /// and once the conversation has finished.
        var worker: AssistantWorker?
        /// The key, kept while a worker runs only to replace it in what the worker writes back.
        var secret: String
        /// When the conversation last became IDLE; nil in any other state.
        var idleSince: ContinuousClock.Instant?
        var watchers: [UUID: AsyncStream<Leyline_V1_Conversation>.Continuation] = [:]
        /// The newest `keptVersions` states, oldest first, for `watch(_:sinceSeq:)` to replay.
        /// In memory only, so a loaded conversation replays nothing older than its load; emptied
        /// when the conversation finishes, since nothing follows to replay.
        var history: [Leyline_V1_Conversation] = []
        /// Assistant turns a `StopTurn` closed: the worker's later writes to them are ignored.
        var closedTurns: Set<String> = []
        /// The seq of the state last written to disk; a text delta leaves it behind.
        var savedSeq: UInt64 = 0
    }

    private let credentials: CredentialStore
    private let spawner: WorkerProcess
    /// `<data>/conversations`: one directory per conversation.
    private let directory: String
    private let publish: Publisher
    private let forget: Forgetter
    private let timing: Timing
    private var entries: [String: Entry] = [:]
    private var sweeper: Task<Void, Never>?
    private var closed = false
    private let log = Logger(label: "leyline.assistant")

    init(credentials: CredentialStore, spawner: WorkerProcess, directory: String, timing: Timing = Timing(),
         forget: @escaping Forgetter = { _ in }, publish: @escaping Publisher)
    {
        self.credentials = credentials
        self.spawner = spawner
        self.directory = directory
        self.timing = timing
        self.forget = forget
        self.publish = publish
    }

    /// `<data>/conversations`, where the conversations of a data directory are kept.
    static func directory(inData dataPath: String) -> String { dataPath + "/conversations" }

    // MARK: Loading

    /// Loads every kept conversation, each without a worker, before the daemon serves. One the last
    /// daemon left THINKING or WAITING has its last turn closed with `restartNote` and goes IDLE
    /// (`closeAfterRestart`); those beyond the newest `keptConversations`, or whose last turn is
    /// older than `keptDays`, are deleted. A file that cannot be read is left where it is and the
    /// conversation is not listed.
    func load() {
        guard ensurePrivateDirectory(directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = true
        var found: [Leyline_V1_Conversation] = []
        for name in names where name.hasPrefix("conv_") {
            let path = directory + "/" + name + "/" + Self.conversationFile
            sweepPrivateFileTemporaries(of: path)
            guard let data = FileManager.default.contents(atPath: path) else {
                log.warning("\(directory)/\(name) has no \(Self.conversationFile); leaving it out")
                continue
            }
            guard let conversation = try? Leyline_V1_Conversation(jsonUTF8Bytes: data, options: options),
                  conversation.conversationID == name
            else {
                log.warning("\(path) is not a conversation; leaving it out")
                continue
            }
            found.append(conversation)
        }
        let cutoff = WallClock.realNowNs() - Self.keptDays * 86_400 * 1_000_000_000
        let newestFirst = found.sorted { Self.lastActivity($0) > Self.lastActivity($1) }
        for (rank, conversation) in newestFirst.enumerated() {
            let id = conversation.conversationID
            guard rank < Self.keptConversations, Self.lastActivity(conversation) >= cutoff else {
                log.info("\(id) is past the retention (the newest \(Self.keptConversations), none older than \(Self.keptDays) days); deleting it")
                removeFiles(of: id)
                continue
            }
            var entry = Entry(conversation: conversation, worker: nil, secret: "")
            if conversation.state == .conversationThinking || conversation.state == .conversationWaiting {
                entry.conversation.closeAfterRestart()
                entry.conversation.seq += 1
                save(entry.conversation)
                log.info("\(id) was on a turn when the last daemon stopped; that turn is closed")
            }
            entry.savedSeq = entry.conversation.seq
            entries[id] = entry
        }
        if !entries.isEmpty {
            log.info("loaded \(entries.count == 1 ? "1 conversation" : "\(entries.count) conversations") from \(directory)")
        }
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
        // The lookups above suspend, and `stopAll` may have run meanwhile. Nothing suspends from
        // here until the conversation is in `entries`, where a later `stopAll` finds it.
        guard !closed else { throw EngineError.failedPrecondition("the daemon is stopping") }
        let worker: AssistantWorker
        do {
            worker = try spawn(id, credential: credential, model: model, viewTools: request.viewTools, resume: false)
        } catch {
            removeFiles(of: id)
            throw error
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
        let started = await commit(id, by: client) { _ in }
        await trimToRetention()
        return started
    }

    /// Adds the user's turn and hands it to the worker, starting one told to resume from the
    /// transcript when the conversation has none. FAILED_PRECONDITION unless IDLE; a worker that
    /// cannot start fails the call as it fails `start`, and the conversation is left as it was.
    func send(_ id: String, text: String, by client: ClientContext) async throws -> Leyline_V1_Conversation {
        var current = try entry(id)
        try Self.requireIdle(current.conversation)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.invalidArgument("the message is empty", target: id) }
        if current.worker == nil {
            try await resumeWorker(id)
            // The key lookup suspended, and another client may have moved the conversation on.
            current = try entry(id)
            try Self.requireIdle(current.conversation)
        }
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
        return ended
    }

    /// Ends the conversation if it is still going, so its watchers and the event plane see it
    /// ENDED, then forgets it and removes its files. INVALID_ARGUMENT for an unknown id.
    func delete(_ id: String, by client: ClientContext) async throws {
        _ = try await end(id, by: client)
        // Ending suspends; a second delete may have removed it meanwhile.
        guard entries[id] != nil else { return }
        remove(id)
        await forget(id)
        log.info("deleted \(id) for \(client.kind) \(client.label)")
    }

    /// Stops every worker and ends every watch, for the daemon's shutdown. Each conversation is
    /// written as it stands; one stopped mid-turn is closed when the next daemon loads it. Nothing
    /// starts afterwards.
    func stopAll() async {
        closed = true
        sweeper?.cancel()
        var workers: [AssistantWorker] = []
        for id in Array(entries.keys) {
            guard var e = entries[id] else { continue }
            if let worker = e.worker { workers.append(worker) }
            e.worker = nil
            e.secret = ""
            for watcher in e.watchers.values { watcher.finish() }
            e.watchers = [:]
            // The text so far too, so the next daemon's seq is never behind what a client saw.
            if e.savedSeq != e.conversation.seq {
                save(e.conversation)
                e.savedSeq = e.conversation.seq
            }
            entries[id] = e
        }
        await withTaskGroup(of: Void.self) { group in
            for worker in workers {
                group.addTask { await worker.stop() }
            }
        }
    }

    /// Stops the worker of every conversation that has been IDLE for `idleLimit`. The conversation
    /// stays IDLE, and the next message starts a worker again. The sweep calls it; so can a test.
    func stopIdleWorkers() async {
        for id in Array(entries.keys) {
            // Checked one at a time: stopping a worker suspends, and a message may arrive meanwhile.
            guard let e = entries[id], e.worker != nil, let since = e.idleSince,
                  timing.now() - since >= timing.idleLimit else { continue }
            log.info("\(id) sat idle for \(timing.idleLimit); stopping its worker")
            await stopWorker(of: id)
        }
    }

    // MARK: The worker's side

    /// Folds one message from the worker. A conversation that has finished takes nothing more, and
    /// nothing is taken from a worker that is no longer the conversation's.
    func apply(_ message: Leyline_V1_WorkerMessage, to id: String, from worker: AssistantWorker? = nil) async {
        guard let current = entries[id], !Self.isFinished(current.conversation.state) else { return }
        if let worker, current.worker !== worker { return }
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
        case nil:
            return
        }
    }

    /// The worker has exited. Between turns the conversation stays IDLE without one, and the next
    /// message starts another; mid-turn it fails. A worker the store stopped itself is no longer
    /// the conversation's by the time it exits, and its exit changes nothing.
    func workerExited(_ id: String, worker: AssistantWorker, status: Int32) async {
        guard let current = entries[id], current.worker === worker else { return }
        entries[id]?.worker = nil
        entries[id]?.secret = ""
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
            log.info("\(id): the worker exited between turns with status \(status); the next message starts another")
        default:
            break
        }
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
    }

    // MARK: Internals

    /// Applies `mutate`, bumps `seq`, feeds the watchers and publishes the event. The change and
    /// the watchers happen before the one suspension, so every watcher sees the changes in order;
    /// the event plane drops a publish that a newer one overtook (`publishConversation`).
    private func commit(_ id: String, by client: ClientContext,
                        _ mutate: (inout Entry) -> Void) async -> Leyline_V1_Conversation
    {
        guard var e = entries[id] else { return Leyline_V1_Conversation() }
        let before = e.conversation
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
        }
        entries[id] = e
        if before.seq == 0 || Self.milestones(of: before) != Self.milestones(of: conversation) {
            save(conversation)
            entries[id]?.savedSeq = conversation.seq
        }
        await publish(conversation, client)
        return conversation
    }

    /// Reads what the worker writes and notices when it exits.
    private func follow(_ worker: AssistantWorker, of id: String) {
        Task { [weak self] in
            for await message in worker.messages {
                await self?.apply(message, to: id, from: worker)
            }
            var status: Int32 = -1
            for await code in worker.exits { status = code }
            await self?.workerExited(id, worker: worker, status: status)
        }
    }

    /// Creates the conversation's directory and starts its worker with the key and `WorkerStart`,
    /// told to resume from the transcript or to begin it. Nothing here suspends, so a caller that
    /// checked the store's state just before still holds it after.
    private func spawn(_ id: String, credential: Leyline_V1_SetCredentialRequest, model: String,
                       viewTools: [Leyline_V1_ViewTool], resume: Bool) throws -> AssistantWorker
    {
        let dir = directory + "/" + id
        guard ensurePrivateDirectory(directory), ensurePrivateDirectory(dir) else {
            throw EngineError.internalError("cannot create \(dir) for the conversation", target: id)
        }
        var start = Leyline_V1_WorkerStart()
        start.conversationID = id
        start.provider = credential.provider
        start.model = model
        start.endpoint = credential.endpoint
        start.viewTools = viewTools
        start.socket = spawner.socketPath
        start.transcriptPath = dir + "/" + Self.transcriptFile
        start.resume = resume
        let worker = try spawner.startAssistant(credential: credential, start: start) { [weak self] error in
            Task { await self?.writeFailed(id, error) }
        }
        follow(worker, of: id)
        startSweeping()
        return worker
    }

    /// Starts a worker for a kept conversation that has none (loaded at start, or stopped by the
    /// idle sweep), with the key as it stands now. A worker another message started meanwhile is
    /// kept.
    private func resumeWorker(_ id: String) async throws {
        guard !closed else { throw EngineError.failedPrecondition("the daemon is stopping", target: id) }
        let conversation = try entry(id).conversation
        let credential = try await key(for: conversation.provider)
        guard !closed else { throw EngineError.failedPrecondition("the daemon is stopping", target: id) }
        guard try entry(id).worker == nil else { return }
        let worker = try spawn(id, credential: credential, model: conversation.model,
                               viewTools: conversation.viewTools, resume: true)
        entries[id]?.worker = worker
        entries[id]?.secret = credential.secret
        log.info("\(id): started a worker to resume it")
    }

    private func startSweeping() {
        guard sweeper == nil else { return }
        let every = timing.sweepEvery
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                await self?.stopIdleWorkers()
            }
        }
    }

    /// Stops the conversation's worker, which is no longer the conversation's from here on, so
    /// its exit changes nothing.
    private func stopWorker(of id: String) async {
        guard let worker = entries[id]?.worker else { return }
        entries[id]?.worker = nil
        entries[id]?.secret = ""
        await worker.stop()
    }

    private func removeWatcher(_ id: String, _ key: UUID) {
        entries[id]?.watchers[key] = nil
    }

    /// Deletes the conversations beyond the newest `keptConversations` by last turn, after a new
    /// one. One whose worker runs is never among them.
    private func trimToRetention() async {
        let excess = entries.count - Self.keptConversations
        guard excess > 0 else { return }
        let oldest = entries.filter { $0.value.worker == nil }
            .sorted { Self.lastActivity($0.value.conversation) < Self.lastActivity($1.value.conversation) }
            .prefix(excess).map(\.key)
        for id in oldest {
            log.info("\(id) is older than the newest \(Self.keptConversations) conversations; deleting it")
            remove(id)
            await forget(id)
        }
    }

    /// Forgets a conversation and removes its files. Its watchers' streams end.
    private func remove(_ id: String) {
        if let e = entries[id] {
            for watcher in e.watchers.values { watcher.finish() }
        }
        entries[id] = nil
        removeFiles(of: id)
    }

    private func removeFiles(of id: String) {
        let dir = directory + "/" + id
        guard FileManager.default.fileExists(atPath: dir) else { return }
        do {
            try FileManager.default.removeItem(atPath: dir)
        } catch {
            log.error("cannot remove \(dir): \(error)")
        }
    }

    /// Writes `conversation.json` for the conversation, 0600 in a 0700 directory. A failure is
    /// logged and the conversation goes on in memory.
    private func save(_ conversation: Leyline_V1_Conversation) {
        let dir = directory + "/" + conversation.conversationID
        let path = dir + "/" + Self.conversationFile
        guard ensurePrivateDirectory(directory), ensurePrivateDirectory(dir) else { return }
        do {
            var data = try conversation.jsonUTF8Data()
            data.append(0x0a)
            try writePrivateFile(data, to: path)
        } catch {
            log.error("cannot write \(path): \(error)")
        }
    }

    /// Creates `path` 0700, or sets it back to 0700 if it exists with another mode: what is kept
    /// there is readable by the user only. False, logged, when it cannot be made.
    private func ensurePrivateDirectory(_ path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // A directory that already existed keeps its mode through createDirectory.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return true
        } catch {
            log.error("cannot create \(path): \(error)")
            return false
        }
    }

    /// What a save waits for: the conversation without its seq, its last-turn time and the text of
    /// a turn still being written, so a text delta alone writes nothing.
    static func milestones(of conversation: Leyline_V1_Conversation) -> Leyline_V1_Conversation {
        var out = conversation
        out.seq = 0
        out.lastTurnAtNs = 0
        for i in out.turns.indices where !out.turns[i].done {
            out.turns[i].text = ""
        }
        return out
    }

    /// When the conversation was last used: its last turn, or its start when it has none.
    static func lastActivity(_ conversation: Leyline_V1_Conversation) -> Int64 {
        conversation.lastTurnAtNs != 0 ? conversation.lastTurnAtNs : conversation.startedAtNs
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
        let ai = await credentials.snapshot()
        let chosen = ai.features.first { $0.feature == "assistant" }
        if provider.isEmpty {
            guard let chosen, !chosen.provider.isEmpty else {
                throw EngineError.failedPrecondition(
                    ProviderDefaults.missingModelMessage("assistant", keys: ai.credentials), target: "assistant")
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

    private static func requireIdle(_ conversation: Leyline_V1_Conversation) throws {
        guard conversation.state == .conversationIdle else {
            throw EngineError.failedPrecondition("\(describe(conversation.state)); a message can be sent when it is idle",
                                                 target: conversation.conversationID)
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

    /// Closes the turn a daemon that stopped was on, for the next daemon's load: the assistant's last
    /// turn is marked done with `restartNote` after its text, a call still waiting on someone is
    /// REFUSED and one still running is DONE as an error, "stopped". When the worker had not
    /// written its turn yet, a done turn with the note alone answers the user's. The conversation
    /// is IDLE.
    mutating func closeAfterRestart() {
        let note = ConversationStore.restartNote
        let now = WallClock.nowNs()
        if let last = turns.indices.last, turns[last].role == .assistant {
            let id = turns[last].turnID
            closeStoppedTurn(id)
            turns[last].text = turns[last].text.isEmpty ? note : turns[last].text + "\n\n" + note
        } else {
            var turn = Leyline_V1_Turn()
            turn.turnID = ConversationStore.nextTurnID(after: turns)
            turn.role = .assistant
            turn.text = note
            turn.atNs = now
            turn.done = true
            turns.append(turn)
        }
        lastTurnAtNs = now
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
