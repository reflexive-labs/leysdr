// SPDX-License-Identifier: GPL-3.0-or-later

// The daemon's single source of truth (docs/dev/engine-internals.md "SessionStore"): one actor owning
// devices, captures, channels, sinks, the event sequence and client presence. Every mutation goes
// through here and emits exactly one full-state event per changed object (AGENTS.md invariants 6, 7).

import EngineCore
import Foundation
import LeylineProto
import Logging

/// Scope a `WatchEvents` / `GetState` caller asked for.
enum EventScopeFilter: Sendable, Hashable {
    case daemon
    case capture(CaptureID)

    /// Fails with `CAPTURE_NOT_FOUND` for an unparsable capture id; existence is checked by the
    /// caller against the store (`SessionStore.validated(_:)`).
    init(_ scope: Leyline_V1_EventScope) throws {
        switch scope.scope {
        case .captureID(let s)?:
            guard let id = CaptureID(string: s) else { throw EngineError.captureNotFound(s) }
            self = .capture(id)
        case .daemon?, nil:
            self = .daemon
        }
    }

    /// Whether an event scoped to `captureID` (nil = daemon-wide) is delivered to this filter.
    func admits(_ captureID: CaptureID?) -> Bool {
        if case .capture(let want) = self, let have = captureID, have != want { return false }
        return true
    }
}

/// Objects torn down by the store that the bulk plane must stop streaming from.
enum TeardownScope: Sendable {
    case capture(CaptureID)
    case channel(ChannelID)
    /// The channel's audio descriptor is stale: its audio rate changed (a capture-rate
    /// write, a retune that re-plans the chain, or a mode/bandwidth/offset write), or the rate held
    /// while the mode or the full-scale deviation it answered moved (a bandwidth or mode write).
    /// Audio streams negotiated under the old descriptor end; the client re-subscribes for a fresh
    /// one.
    case channelAudioRate(ChannelID)
    /// The capture's sample rate changed. Audio streams derive their frame spans from it, and two
    /// capture rates can plan to the same audio rate, so they end on the capture rate itself rather
    /// than waiting for an audio rate to move.
    case captureRate(CaptureID)
}

/// `SinkFactory.systemAudio` with a caller-chosen id, so a sink rebuilt at a new audio rate keeps
/// the id clients hold.
func makeSystemAudioSink(id: SinkID, rate: UInt32, volume: Double, deviceUID: String?) throws -> any AudioSink {
    #if canImport(AVFoundation)
    return try CoreAudioSink(id: id, rate: rate, volume: volume, deviceUID: deviceUID)
    #else
    _ = (id, rate, volume, deviceUID)
    throw EngineError.platformUnsupported("system audio")
    #endif
}

/// Daemon identity reported in `GetState`.
struct DaemonInfo: Sendable {
    var version: String
    var pid: Int64
    var startedAtNs: Int64
    var socketPath: String
    /// The recording store's cap (`--recordings-cap`), so a client can show use against it.
    var recordingsCapBytes: UInt64 = 0

    var proto: Leyline_V1_DaemonInfo {
        var out = Leyline_V1_DaemonInfo()
        out.version = version
        out.pid = pid
        out.startedAtNs = startedAtNs
        out.socketPath = socketPath
        out.recordingsCapBytes = recordingsCapBytes
        return out
    }
}

/// One actor owns the session tables. See the file header.
actor SessionStore {
    struct CaptureEntry {
        var engine: DefaultCaptureEngine
        var deviceID: DeviceID
        var meta: ProtoMapping.CaptureMeta
        var anchorTask: Task<Void, Never>?
        /// Last confirmed manual dB per gain element: `GainWrite{auto:false}` means "manual, keep
        /// the previous level" (contract parity with the Go reference), and drivers forget it in auto.
        var manualGainDB: [String: Double] = [:]
    }

    struct ChannelEntry {
        var engine: any ChannelEngine
        var captureID: CaptureID
        var owner: ClientContext
    }

    struct SinkEntry {
        var proto: Leyline_V1_Sink
        var channelID: ChannelID
        var sink: any AudioSink
        var isSystemAudio: Bool
    }

    struct PlaybackEntry {
        var engine: PlaybackEngine
        var owner: ClientContext
        /// Republishes the playback while it plays (`playbackInterval`); cancelled when it ends.
        var ticker: Task<Void, Never>?
    }

    struct Presence {
        var open: Int = 0
        var grace: Task<Void, Never>?
    }

    private struct Subscriber {
        var scope: EventScopeFilter
        var continuation: AsyncStream<Leyline_V1_Event>.Continuation
    }

    let registry: DefaultDeviceRegistry
    let info: DaemonInfo
    /// Grace period after a client's presence ends before its non-persistent channels are reaped.
    let presenceGraceNs: UInt64
    /// The attach list on disk; nil when nothing is remembered across restarts (tests).
    let remembered: RememberedDevices?
    let log = Logger(label: "leyline.store")

    var devices: [DeviceID: DeviceDescriptor] = [:]
    var captures: [CaptureID: CaptureEntry] = [:]
    /// Devices whose capture is still starting (see createCapture).
    var startingDevices: Set<DeviceID> = []
    /// rtl_tcp endpoints (`host:port`) with an attach in flight: the connect takes seconds, and a
    /// second attach of the same endpoint joins the first rather than opening a second socket.
    var attachingRemotes: [String: Task<DeviceDescriptor, any Error>] = [:]
    var channels: [ChannelID: ChannelEntry] = [:]
    var sinks: [SinkID: SinkEntry] = [:]
    /// Recordings the daemon is playing through its own audio device (docs/design/recording.md,
    /// "Playing a recording back"). Daemon state like everything else here, so a second client
    /// sees one and the app renders its position; owned by the client that started it.
    var playbacks: [PlaybackID: PlaybackEntry] = [:]
    /// How often a playing playback is published with its position: four times a second, so a
    /// client renders elapsed time from the event plane and does not poll `GetState` for it.
    static let playbackInterval: Duration = .milliseconds(250)
    /// What a playback's audio goes to. The daemon's audio device; a test on a host with none
    /// swaps in a sink that discards the audio (`setPlaybackSinkFactory`).
    var playbackSink: PlaybackSinkFactory = systemPlaybackSink
    private(set) var seq: UInt64 = 0
    private var subscribers: [UUID: Subscriber] = [:]
    /// The most recent `eventHistoryLimit` events, oldest first, for `since_seq` replay.
    private var history: [RetainedEvent] = []
    /// How many events `WatchEvents(since_seq)` can replay: matches the subscriber buffer, so a
    /// client that fell that far behind re-fetches `GetState` either way.
    static let eventHistoryLimit = 256

    private struct RetainedEvent {
        var captureID: CaptureID?
        var event: Leyline_V1_Event
    }
    var presence: [String: Presence] = [:]
    var deviceTask: Task<Void, Never>?
    /// Installed by the bulk plane so streams on destroyed objects end.
    var teardownHook: (@Sendable (TeardownScope) async -> Void)?
    /// Installed by the job store; nil until jobs exist.
    var jobsProvider: (@Sendable () async -> [Leyline_V1_Job])?
    private var clientGoneHook: (@Sendable (String) async -> Void)?
    /// Captures a sweep currently holds. Invariant 9 puts jobs behind the allocator; this is the
    /// other half of it -- without it a client can join a capture that is walking a band, and its
    /// channel is dragged across megahertz with no explanation.
    var swept: Set<CaptureID> = []

    init(registry: DefaultDeviceRegistry, info: DaemonInfo, presenceGraceNs: UInt64 = 5_000_000_000,
         remembered: RememberedDevices? = nil) {
        self.registry = registry
        self.info = info
        self.presenceGraceNs = presenceGraceNs
        self.remembered = remembered
    }

    func setTeardownHook(_ hook: @escaping @Sendable (TeardownScope) async -> Void) { teardownHook = hook }

    func setPlaybackSinkFactory(_ factory: @escaping PlaybackSinkFactory) { playbackSink = factory }

    // MARK: Events

    /// Fan-out of full-state events. `bufferingNewest(256)`: a slow subscriber sees a seq gap and
    /// re-fetches `GetState`. The subscriber is registered synchronously on the actor before the
    /// stream is returned, so every event committed after this call returns is delivered
    /// ("WatchEvents then GetState" cannot miss one). `sinceSeq` (the seq of a `GetState`
    /// snapshot) first replays the retained events newer than it that match `scope`, in order, so
    /// "GetState then WatchEvents" cannot miss one either; a snapshot older than the retained
    /// window shows up as a seq gap on the first delivered event.
    func events(scope: EventScopeFilter, sinceSeq: UInt64? = nil) -> AsyncStream<Leyline_V1_Event> {
        let (stream, continuation) = AsyncStream<Leyline_V1_Event>.makeStream(bufferingPolicy: .bufferingNewest(Self.eventHistoryLimit))
        if let since = sinceSeq {
            for kept in history where kept.event.seq > since && scope.admits(kept.captureID) {
                continuation.yield(kept.event)
            }
        }
        addSubscriber(key: UUID(), scope: scope, continuation: continuation)
        return stream
    }

    /// Throws `CAPTURE_NOT_FOUND` when a capture-scoped filter names a capture the store does not have.
    func validated(_ scope: EventScopeFilter) throws -> EventScopeFilter {
        if case .capture(let id) = scope, captures[id] == nil { throw EngineError.captureNotFound(id.string) }
        return scope
    }

    private func addSubscriber(key: UUID, scope: EventScopeFilter, continuation: AsyncStream<Leyline_V1_Event>.Continuation) {
        subscribers[key] = Subscriber(scope: scope, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscriber(key: key) }
        }
    }

    private func removeSubscriber(key: UUID) { subscribers[key] = nil }

    /// How many `events(...)` subscriptions are registered right now. Nothing in the daemon reads it;
    /// it is the observable side of the subscription so a caller can wait for its watch to be live
    /// before making the change it expects an event for.
    var subscriberCount: Int { subscribers.count }

    /// Emits one event; `captureID` scopes it for capture-filtered watchers (nil = daemon-wide).
    @discardableResult
    func emit(_ body: Leyline_V1_Event.OneOf_Body, captureID: CaptureID?, by: ClientContext) -> UInt64 {
        seq += 1
        var ev = Leyline_V1_Event()
        ev.seq = seq
        ev.causedBy = by.proto
        ev.body = body
        history.append(RetainedEvent(captureID: captureID, event: ev))
        if history.count > Self.eventHistoryLimit { history.removeFirst(history.count - Self.eventHistoryLimit) }
        for sub in subscribers.values where sub.scope.admits(captureID) {
            sub.continuation.yield(ev)
        }
        return seq
    }

    func finishSubscribers() {
        for sub in subscribers.values { sub.continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: Presence

    /// Marks `client` present for the life of a streaming RPC. Pair with `streamClosed`.
    func streamOpened(_ client: ClientContext) {
        var p = presence[client.id] ?? Presence()
        p.open += 1
        p.grace?.cancel()
        p.grace = nil
        presence[client.id] = p
    }

    func streamClosed(_ client: ClientContext) {
        guard var p = presence[client.id] else { return }
        p.open = max(0, p.open - 1)
        if p.open == 0 { p.grace = armGrace(client.id) }
        presence[client.id] = p
    }

    /// A unary call keeps its client present for one grace period.
    func touchUnary(_ client: ClientContext) {
        var p = presence[client.id] ?? Presence()
        if p.open == 0 {
            p.grace?.cancel()
            p.grace = armGrace(client.id)
        }
        presence[client.id] = p
    }

    private func armGrace(_ clientID: String) -> Task<Void, Never> {
        let grace = presenceGraceNs
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: grace)
            guard !Task.isCancelled, let self else { return }
            await self.reap(clientID: clientID)
        }
    }

    /// Tears down the non-persistent channels (and their sinks) of an absent client.
    private func reap(clientID: String) async {
        guard let p = presence[clientID], p.open == 0 else { return }
        let victims = channels.filter { $0.value.owner.id == clientID }
        for (id, entry) in victims {
            // Each await below is an actor hop; the client may reconnect (streamOpened) or touch a
            // unary in between, in which case it is present again and keeps what is left.
            guard stillAbsent(clientID) else { return }
            let persistent = await entry.engine.config.persistent
            if persistent { continue }
            guard stillAbsent(clientID), channels[id] != nil else { return }
            log.info("reaping channel \(id) of absent client \(clientID)")
            await destroyChannel(id: id, by: .daemon, engineAlreadyClosed: false)
        }
        if stillAbsent(clientID) {
            await reapPlaybacks(clientID: clientID)
            guard stillAbsent(clientID) else { return }
            // A sweep with no reader only ties up the radio. The CLI cancels its own scan on
            // Ctrl-C; this is the backstop for a hard kill.
            await clientGoneHook?(clientID)
            // Re-guarded like every other await in this function: the hook waits on a sweep's
            // teardown, and a client that reconnected while it ran is present again and keeps
            // its presence entry.
            guard stillAbsent(clientID) else { return }
            presence[clientID] = nil
        }
    }

    /// Installed by the job store: ends the jobs a departing client owned.
    func setClientGoneHook(_ hook: @escaping @Sendable (String) async -> Void) { clientGoneHook = hook }

    /// True while `clientID` has no open stream and this reap's grace task was not cancelled by a
    /// reconnect (`streamOpened`) or a newer unary call (`touchUnary` re-arms the grace). `reap`
    /// runs inside the grace task, so `Task.isCancelled` is that task's flag.
    private func stillAbsent(_ clientID: String) -> Bool {
        guard let p = presence[clientID], p.open == 0 else { return false }
        return !Task.isCancelled
    }
}
