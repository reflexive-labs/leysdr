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

/// Current CLOCK_REALTIME in nanoseconds.
func realtimeNs() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
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

    private struct Presence {
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
    private let remembered: RememberedDevices?
    private let log = Logger(label: "leyline.store")

    private(set) var devices: [DeviceID: DeviceDescriptor] = [:]
    private(set) var captures: [CaptureID: CaptureEntry] = [:]
    /// Devices whose capture is still starting (see createCapture).
    private var startingDevices: Set<DeviceID> = []
    /// rtl_tcp endpoints (`host:port`) with an attach in flight: the connect takes seconds, and a
    /// second attach of the same endpoint joins the first rather than opening a second socket.
    private var attachingRemotes: [String: Task<DeviceDescriptor, any Error>] = [:]
    private(set) var channels: [ChannelID: ChannelEntry] = [:]
    private(set) var sinks: [SinkID: SinkEntry] = [:]
    /// Recordings the daemon is playing through its own audio device (docs/design/recording.md,
    /// "Playing a recording back"). Daemon state like everything else here, so a second client
    /// sees one and the app renders its position; owned by the client that started it.
    private(set) var playbacks: [PlaybackID: PlaybackEntry] = [:]
    /// How often a playing playback is published with its position: four times a second, so a
    /// client renders elapsed time from the event plane and does not poll `GetState` for it.
    static let playbackInterval: Duration = .milliseconds(250)
    /// What a playback's audio goes to. The daemon's audio device; a test on a host with none
    /// swaps in a sink that discards the audio (`setPlaybackSinkFactory`).
    private var playbackSink: PlaybackSinkFactory = systemPlaybackSink
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
    private var presence: [String: Presence] = [:]
    private var deviceTask: Task<Void, Never>?
    /// Installed by the bulk plane so streams on destroyed objects end.
    private var teardownHook: (@Sendable (TeardownScope) async -> Void)?
    /// Installed by the job store; nil until jobs exist.
    private var jobsProvider: (@Sendable () async -> [Leyline_V1_Job])?
    private var clientGoneHook: (@Sendable (String) async -> Void)?
    /// Captures a sweep currently holds. Invariant 9 puts jobs behind the allocator; this is the
    /// other half of it -- without it a client can join a capture that is walking a band, and its
    /// channel is dragged across megahertz with no explanation.
    private var swept: Set<CaptureID> = []

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
    private func emit(_ body: Leyline_V1_Event.OneOf_Body, captureID: CaptureID?, by: ClientContext) -> UInt64 {
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

    // MARK: Devices

    /// Starts mirroring the registry: hot-plug arrivals/removals become device events, captures are
    /// detached on loss and rebound on replug (stable ids by serial).
    func startDeviceMirror() async {
        for d in await registry.devices { devices[d.id] = d }
        let events = registry.events()
        deviceTask = Task { [weak self] in
            for await ev in events {
                guard let self else { return }
                await self.applyDeviceEvent(ev)
            }
        }
    }

    private func applyDeviceEvent(_ ev: DeviceEvent) async {
        switch ev {
        case .arrived(let d):
            // attachFileDevice already mirrored and announced its own device; skip the duplicate.
            if devices[d.id] != d {
                devices[d.id] = d
                emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: .daemon)
            }
            for (capID, entry) in captures where entry.deviceID == d.id {
                let detached = await entry.engine.snapshot.detached
                if detached, let device = await registry.device(id: d.id) {
                    do {
                        try await entry.engine.deviceRebound(device)
                        try? await registry.markInUse(id: d.id, true)
                        await emitCapture(capID, by: .daemon)
                    } catch {
                        log.warning("rebind of \(capID) to \(d.id) failed: \(error)")
                        if let e = error as? EngineError, e.code == EngineError.Code.deviceBusy {
                            await registry.markHeldExternally(id: d.id)
                        }
                    }
                }
            }
        case .changed(let d):
            let before = devices[d.id]
            devices[d.id] = d
            if before != d { emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: .daemon) }
            if d.state == .disconnected { await captureDeviceLost(d.id) }
        case .removed(let id):
            guard var d = devices[id] else { return }
            d.state = .disconnected
            if captures.values.contains(where: { $0.deviceID == id }) {
                devices[id] = d
            } else {
                devices[id] = nil
            }
            emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: .daemon)
            await captureDeviceLost(id)
        }
    }

    private func captureDeviceLost(_ deviceID: DeviceID) async {
        for (capID, entry) in captures where entry.deviceID == deviceID {
            let detached = await entry.engine.snapshot.detached
            if !detached {
                await entry.engine.deviceLost()
                await emitCapture(capID, by: .daemon)
            }
        }
    }

    func listDevices() -> [DeviceDescriptor] {
        devices.values.sorted { $0.id.string < $1.id.string }
    }

    func attachFileDevice(path: String, loop: Bool, by: ClientContext) async throws -> DeviceDescriptor {
        let d = try await registry.attachFileDevice(path: path, loop: loop)
        if devices[d.id] == nil {
            devices[d.id] = d
            emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: by)
        }
        return d
    }

    /// Attaches a dongle served by rtl_tcp and remembers the endpoint, so the radio is reattached
    /// when the daemon restarts. One endpoint is one radio: an endpoint already hosted hands back
    /// the device hosting it, and one another attach is still connecting to joins that attempt, so
    /// a second socket is never opened. A radio the operator's `--rtltcp` flag brought up becomes
    /// the client's, so it outlives the flag and can be detached. A server that cannot be reached is
    /// `DEVICE_IO` naming the endpoint, with nothing remembered.
    func attachRemoteDevice(host: String, port: UInt16, by: ClientContext) async throws -> DeviceDescriptor {
        let endpoint = "\(host):\(port)"
        if let existing = devices.values.first(where: { $0.driver == RTLTCPDevice.driverName && $0.serial == endpoint }) {
            await registry.claimVirtualDevice(id: existing.id)
            let saved = RememberedDevices.Endpoint(host: host, port: port)
            await remembered?.remember(saved)
            // A detach that landed while this was suspended takes precedence: remove the line
            // again so the next daemon does not bring back a radio a client detached.
            if devices[existing.id] == nil { await remembered?.forget(saved) }
            return existing
        }
        if let inFlight = attachingRemotes[endpoint] { return try await inFlight.value }
        let attach = Task<DeviceDescriptor, any Error> {
            defer { attachingRemotes[endpoint] = nil }
            return try await hostRemoteDevice(host: host, port: port, by: by)
        }
        attachingRemotes[endpoint] = attach
        return try await attach.value
    }

    /// The connect half of `attachRemoteDevice`, as one task per endpoint.
    private func hostRemoteDevice(host: String, port: UInt16, by: ClientContext) async throws -> DeviceDescriptor {
        let device = RTLTCPDevice(host: host, port: port)
        do {
            try await device.open()
        } catch {
            await device.close()
            throw error
        }
        let attachment: VirtualAttachment
        do {
            attachment = try await registry.attachVirtualDevice(device, origin: .client)
        } catch {
            // Nothing else holds the connection and its reader thread once hosting has failed.
            await device.close()
            throw error
        }
        let d = attachment.descriptor
        if devices[d.id] == nil {
            devices[d.id] = d
            emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: by)
        }
        let saved = RememberedDevices.Endpoint(host: host, port: port)
        await remembered?.remember(saved)
        // A detach that landed while the endpoint was being remembered takes precedence: remove the
        // line again so the next daemon does not bring back a radio a client detached.
        if devices[d.id] == nil { await remembered?.forget(saved) }
        return d
    }

    /// Detaches a device a client attached, file or remote radio, with any capture on it. Validates
    /// before mutating: unknown ids are `DEVICE_NOT_FOUND`, a dongle in this machine's port and a
    /// radio the daemon's own command line asked for are `INVALID_ARGUMENT`, a device whose capture
    /// is still starting is `DEVICE_BUSY`, and in every case no capture on that device is touched.
    /// An rtl_tcp endpoint is forgotten here, so it does not come back at the next start.
    ///
    /// `fileOnly` is `DetachFileDevice`, which accepts only a file device: any other device is
    /// `INVALID_ARGUMENT` there, whatever it is.
    func detachDevice(id: DeviceID, by: ClientContext, fileOnly: Bool = false) async throws {
        guard let d = devices[id] else { throw EngineError.deviceNotFound(id.string) }
        if fileOnly, d.driver != FilePlaybackDevice.driverName {
            throw EngineError.invalidArgument("\(d.model) is not a file the daemon plays; DetachDevice takes any device a client attached", target: id.string)
        }
        guard await registry.isDetachableVirtualDevice(id: id) else {
            throw EngineError.invalidArgument("\(d.model) is a radio plugged into this machine, not a device a client attached; unplug it", target: id.string)
        }
        if await registry.virtualDeviceOrigin(id: id) == .operatorFlag {
            throw EngineError.invalidArgument("\(d.model) is configured with --rtltcp on the daemon's command line; remove the flag", target: id.string)
        }
        // A capture opening this device holds it across an await; closing it under a starting
        // engine would leave the engine with a device nothing owns. The window is seconds at most.
        if startingDevices.contains(id) { throw EngineError.deviceStarting(id.string) }
        for (capID, entry) in captures where entry.deviceID == id {
            await destroyCapture(id: capID, by: by)
        }
        // Everything above suspends, so a second detach can have finished meanwhile: report the
        // device as gone rather than tear it down twice. Dropping it from the table here,
        // before anything else suspends, is also what an attach racing this detach looks for: it
        // re-checks the table after its own awaits and takes its `devices.json` line back out.
        guard var gone = devices.removeValue(forKey: id) else { throw EngineError.deviceNotFound(id.string) }
        try await registry.detachVirtualDevice(id: id)
        if d.driver == RTLTCPDevice.driverName, let endpoint = RememberedDevices.Endpoint(serial: d.serial) {
            await remembered?.forget(endpoint)
        }
        gone.state = .disconnected
        emit(.device(ProtoMapping.descriptor(gone)), captureID: nil, by: by)
    }

    // MARK: Captures

    /// RTL-SDR default rate when `sample_rate == 0` (file devices use the recording's rate).
    static let defaultSampleRate: UInt64 = 2_400_000

    func captureProto(_ id: CaptureID) async -> Leyline_V1_Capture? {
        guard let entry = captures[id] else { return nil }
        let snap = await entry.engine.snapshot
        return ProtoMapping.capture(id: id, deviceID: entry.deviceID, snapshot: snap, meta: entry.meta)
    }

    private func emitCapture(_ id: CaptureID, by: ClientContext) async {
        guard let p = await captureProto(id) else { return }
        emit(.capture(p), captureID: id, by: by)
    }

    func captureEngine(_ id: CaptureID) -> DefaultCaptureEngine? { captures[id]?.engine }

    /// Returns the id beside the proto: a caller that has to undo the create can act on the id the
    /// store minted instead of parsing one back out of the message.
    func createCapture(deviceID: DeviceID, centerHz: UInt64, sampleRate: UInt64,
                       by: ClientContext) async throws -> (id: CaptureID, proto: Leyline_V1_Capture) {
        guard let desc = devices[deviceID], let device = await registry.device(id: deviceID) else {
            throw EngineError.deviceNotFound(deviceID.string)
        }
        if desc.state == .disconnected { throw EngineError.deviceDetached(deviceID.string) }
        if let existing = captures.first(where: { $0.value.deviceID == deviceID })?.key, swept.contains(existing) {
            // Name what holds it: a bare "the radio is busy" sends the user looking for another
            // client.
            throw EngineError.deviceSweeping(deviceID.string)
        }
        if captures.values.contains(where: { $0.deviceID == deviceID }) || startingDevices.contains(deviceID) {
            throw EngineError.deviceBusy(deviceID.string)
        }
        guard desc.canTune(centerHz) else { throw EngineError.freqOutOfRange(centerHz, target: deviceID.string) }
        var rate = sampleRate
        if rate == 0 {
            rate = desc.driver == "file" ? (desc.sampleRates.first ?? Self.defaultSampleRate) : Self.defaultSampleRate
        }
        guard desc.sampleRates.isEmpty || desc.sampleRates.contains(rate) else {
            throw EngineError.rateUnsupported(rate, target: deviceID.string)
        }
        let engine = DefaultCaptureEngine(device: device, centerHz: centerHz, sampleRate: rate)
        // Reserve the device across the suspension: `engine.start()` opens hardware (or a network
        // source) and can take seconds, during which a second CreateCapture would otherwise pass
        // the one-capture-per-device check and race the device open.
        startingDevices.insert(deviceID)
        defer { startingDevices.remove(deviceID) }
        do {
            try await engine.start()
        } catch {
            // `start()` already unwound the device; `stop()` finishes the engine so nothing
            // (anchor stream, DSP thread) outlives the failed create.
            await engine.stop()
            if let e = error as? EngineError {
                if e.code == EngineError.Code.deviceBusy {
                    // The dongle's open failed on a USB claim: another program has it. Tell the
                    // registry so the device reads IN_USE and is re-probed with backoff.
                    await registry.markHeldExternally(id: deviceID)
                } else if e.code == EngineError.Code.deviceIO, desc.features["held_externally"] == .flag(true) {
                    // The registry already knows another program has this dongle; report that
                    // instead of surfacing librtlsdr's claim failure.
                    throw EngineError.deviceHeldByOtherProgram(deviceID.string)
                }
            }
            throw error
        }
        let id = engine.id
        var entry = CaptureEntry(engine: engine, deviceID: deviceID,
                                 meta: .init(createdBy: by.proto, lastInteractiveWriteNs: 0, liveAudioSinks: 0), anchorTask: nil)
        let anchors = engine.anchorEvents
        entry.anchorTask = Task { [weak self] in
            for await a in anchors {
                guard let self else { return }
                await self.anchorArrived(id, a)
            }
        }
        captures[id] = entry
        if var d = devices[deviceID], d.state != .inUse {
            d.state = .inUse
            devices[deviceID] = d
            emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: by)
        }
        try? await registry.markInUse(id: deviceID, true)
        let proto = await captureProto(id)!
        emit(.capture(proto), captureID: id, by: by)
        emit(.anchor(proto.anchor), captureID: id, by: by)
        return (id, proto)
    }

    /// Emits a job's full state on the event stream. Jobs are daemon state like captures and
    /// channels, so clients render them by subscription rather than by polling GetJob (invariant 7),
    /// and `Job` is already a whole-object message so nothing here is a delta (invariant 6).
    /// Daemon-scoped: a job is not tied to one capture's lifetime.
    func publishJob(_ job: Leyline_V1_Job) {
        emit(.job(job), captureID: nil, by: .daemon)
    }

    /// The descriptor of the device a capture is running on.
    func deviceDescriptor(for id: CaptureID) -> DeviceDescriptor? {
        guard let entry = captures[id] else { return nil }
        return devices[entry.deviceID]
    }

    /// Marks a capture as held by a sweep. Set and cleared by the capture lease.
    func setSwept(_ id: CaptureID, _ on: Bool) {
        if on { swept.insert(id) } else { swept.remove(id) }
    }

    private func refuseIfSwept(_ id: CaptureID) throws {
        if swept.contains(id) {
            throw EngineError.deviceSweeping(id.string)
        }
    }

    /// Installed by the job store so `GetState` carries the job table.
    func setJobsProvider(_ provider: @escaping @Sendable () async -> [Leyline_V1_Job]) {
        jobsProvider = provider
    }

    /// Re-emits a capture's full state. The capture allocator's lease uses this after retuning or
    /// restoring, because it deliberately bypasses `applyWrite` -- the write coalescer keeps
    /// last-value-per-parameter on a 20 ms tick and would silently eat sweep steps.
    func publishCapture(_ id: CaptureID) async {
        await emitCapture(id, by: .daemon)
    }

    private func anchorArrived(_ id: CaptureID, _ anchor: CaptureAnchor) {
        guard captures[id] != nil else { return }
        emit(.anchor(ProtoMapping.anchor(anchor, captureID: id)), captureID: id, by: .daemon)
    }

    func destroyCapture(id: CaptureID, by: ClientContext) async {
        guard let entry = captures[id] else { return }
        for (chanID, ch) in channels where ch.captureID == id {
            await destroyChannel(id: chanID, by: by, engineAlreadyClosed: true)
        }
        await teardownHook?(.capture(id))
        await entry.engine.stop()
        entry.anchorTask?.cancel()
        let snap = await entry.engine.snapshot
        captures[id] = nil
        var proto = ProtoMapping.capture(id: id, deviceID: entry.deviceID, snapshot: snap, meta: entry.meta)
        // Terminal event: state unset is the tombstone Channel and Sink use, and it is the only
        // thing that separates a destroy from an unplugged dongle, which stays CAPTURE_DETACHED and
        // rebinds. A client that cannot tell them apart keeps a dead radio in its mirror.
        proto.state = .unspecified
        emit(.capture(proto), captureID: id, by: by)
        try? await registry.markInUse(id: entry.deviceID, false)
        if var d = devices[entry.deviceID] {
            if d.state == .inUse {
                d.state = .available
                devices[entry.deviceID] = d
                emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: by)
            } else if d.state == .disconnected, await registry.device(id: d.id) == nil {
                devices[entry.deviceID] = nil
            }
        }
    }

    func destroyCaptureChecked(id: CaptureID, by: ClientContext) async throws {
        guard captures[id] != nil else { throw EngineError.captureNotFound(id.string) }
        // Ending a capture a sweep holds would stop the engine under the lease, and the sweep would
        // report the radio as gone. The internal `destroyCapture` stays unguarded: the lease itself
        // uses it to put down a capture it created.
        try refuseIfSwept(id)
        await destroyCapture(id: id, by: by)
    }

    /// Records interactive activity on a capture (writes from non-job clients).
    private func touchActivity(_ id: CaptureID, by: ClientContext) {
        guard by.isInteractive, var entry = captures[id] else { return }
        entry.meta.lastInteractiveWriteNs = realtimeNs()
        captures[id] = entry
    }

    // MARK: Channels

    func channelEngine(_ id: ChannelID) -> (any ChannelEngine)? { channels[id]?.engine }

    /// Channel engines in scope, for telemetry fan-in.
    /// The capture engines in a scope: one, or every capture the daemon holds.
    func captureEngines(captureID: CaptureID?) -> [(CaptureID, DefaultCaptureEngine)] {
        captures.compactMap { id, e in
            if let c = captureID, id != c { return nil }
            return (id, e.engine)
        }
    }

    func channelEngines(captureID: CaptureID?) -> [(ChannelID, any ChannelEngine)] {
        channels.compactMap { id, e in
            if let c = captureID, e.captureID != c { return nil }
            return (id, e.engine)
        }
    }

    /// The capture a channel sits in. A record job borrowing somebody's channel needs it to date
    /// the samples and to find the anchor (invariant 5).
    func channelCapture(_ id: ChannelID) -> CaptureID? { channels[id]?.captureID }

    /// Re-emits a channel after something changed it that was not a client write: the squelch a
    /// record job set on the channel the allocator built for it, say.
    func publishChannel(_ id: ChannelID) async {
        guard let entry = channels[id] else { return }
        await emitChannel(id, by: entry.owner)
    }

    func channelProto(_ id: ChannelID) async -> Leyline_V1_Channel? {
        guard let entry = channels[id] else { return nil }
        let config = await entry.engine.config
        let state = await entry.engine.state
        return ProtoMapping.channel(id: id, captureID: entry.captureID, config: config, state: state, owner: entry.owner.proto)
    }

    private func emitChannel(_ id: ChannelID, by: ClientContext) async {
        guard let p = await channelProto(id) else { return }
        emit(.channel(p), captureID: CaptureID(string: p.captureID), by: by)
    }

    func createChannel(captureID: CaptureID, offsetHz: Int64, bandwidthHz: UInt32, mode: Leyline_V1_DemodMode,
                       persistent: Bool, requiredHz: UInt64, by: ClientContext) async throws -> Leyline_V1_Channel {
        guard let cap = captures[captureID] else { throw EngineError.captureNotFound(captureID.string) }
        try refuseIfSwept(captureID)
        // DEMOD_MODE_UNSPECIFIED defaults to NFM (contract parity with the Go reference daemon).
        guard let m = ProtoMapping.demodMode(mode == .unspecified ? .nfm : mode) else {
            throw EngineError.modeUnsupported(String(describing: mode), target: captureID.string)
        }
        let bw = bandwidthHz == 0 ? m.defaultBandwidthHz : bandwidthHz
        let rate = await cap.engine.snapshot.sampleRate
        guard Self.fits(offsetHz: offsetHz, bandwidthHz: bw, sampleRate: rate) else {
            throw EngineError.offsetOutOfCapture(offsetHz, target: captureID.string)
        }
        // Sub-audible detection is on for NFM, which is the only mode CTCSS is sent under. It costs
        // the DSP thread two decimation stages -- about 0.6 Mmult/s -- and never gates audio.
        // Making it a per-channel request is a control-plane change (Channel field 12 is the
        // contract for it); until then, the mode is the answer.
        let config = ChannelConfig(offsetHz: offsetHz, bandwidthHz: bw, mode: m, persistent: persistent,
                                   requiredHz: requiredHz == 0 ? nil : requiredHz,
                                   subAudibleDetect: m == .nfm)
        let engine = try await cap.engine.addChannel(config)
        channels[engine.id] = ChannelEntry(engine: engine, captureID: captureID, owner: by)
        touchActivity(captureID, by: by)
        await emitCapture(captureID, by: by)
        let proto = await channelProto(engine.id)!
        emit(.channel(proto), captureID: captureID, by: by)
        return proto
    }

    /// `|offset| + bw/2 <= Fs/2`.
    static func fits(offsetHz: Int64, bandwidthHz: UInt32, sampleRate: UInt64) -> Bool {
        // `magnitude`, not `abs`: `abs(Int64.min)` traps.
        Double(offsetHz.magnitude) + Double(bandwidthHz) / 2 <= Double(sampleRate) / 2
    }

    func destroyChannelChecked(id: ChannelID, by: ClientContext) async throws {
        guard channels[id] != nil else { throw EngineError.channelNotFound(id.string) }
        await destroyChannel(id: id, by: by, engineAlreadyClosed: false)
    }

    /// Removes a channel, its sinks and its bulk streams; emits a terminal (state UNSPECIFIED) event.
    private func destroyChannel(id: ChannelID, by: ClientContext, engineAlreadyClosed: Bool) async {
        guard let entry = channels[id] else { return }
        for (sinkID, s) in sinks where s.channelID == id {
            await detachSink(id: sinkID, by: by)
        }
        await teardownHook?(.channel(id))
        let config = await entry.engine.config
        if !engineAlreadyClosed, let cap = captures[entry.captureID] {
            await cap.engine.removeChannel(id)
        }
        channels[id] = nil
        let proto = ProtoMapping.channel(id: id, captureID: entry.captureID, config: config, state: nil, owner: entry.owner.proto)
        emit(.channel(proto), captureID: entry.captureID, by: by)
    }

    // MARK: Sinks

    func attachSink(channelID: ChannelID, request: Leyline_V1_Sink, by: ClientContext) async throws -> Leyline_V1_Sink {
        guard let entry = channels[channelID] else { throw EngineError.channelNotFound(channelID.string) }
        var proto = request
        proto.sinkID = ""
        proto.channelID = channelID.string
        let sink: any AudioSink
        var isSystemAudio = false
        switch request.kind {
        case .systemAudio(var sa)?:
            // Proto3 presence: an absent volume means full (1.0); an explicit 0 means muted.
            let volume = sa.hasVolume ? sa.volume : 1.0
            guard volume >= 0, volume <= 1 else { throw EngineError.invalidArgument("volume must be within 0..1", target: channelID.string) }
            sa.volume = volume
            sink = try SinkFactory.systemAudio(rate: entry.engine.audioRate, volume: volume, deviceUID: sa.audioDeviceUid.isEmpty ? nil : sa.audioDeviceUid)
            proto.systemAudio = sa
            isSystemAudio = true
        case .stream?:
            throw EngineError.unimplemented("attaching a stream sink directly (use Bulk.Subscribe on the channel)")
        case .file?:
            throw EngineError.unimplemented("file sinks")
        case nil:
            throw EngineError.invalidArgument("sink kind is required", target: channelID.string)
        }
        try await entry.engine.attach(sink)
        proto.sinkID = sink.id.string
        proto.state = .sinkActive
        sinks[sink.id] = SinkEntry(proto: proto, channelID: channelID, sink: sink, isSystemAudio: isSystemAudio)
        if isSystemAudio, var cap = captures[entry.captureID] {
            cap.meta.liveAudioSinks += 1
            captures[entry.captureID] = cap
            await emitCapture(entry.captureID, by: by)
        }
        emit(.sink(proto), captureID: entry.captureID, by: by)
        return proto
    }

    // MARK: Playing a recording back

    /// Opens the file, starts the audio device and publishes the playback. The caller has already
    /// resolved the uri to a path; this handles the audio output.
    func startPlayback(path: String, resourceURI: String, volume: Double, deviceUID: String?,
                       by client: ClientContext) async throws -> Leyline_V1_Playback
    {
        let id = PlaybackID()
        let engine = try PlaybackEngine(id: id, path: path, resourceURI: resourceURI, volume: volume,
                                        deviceUID: deviceUID, makeSink: playbackSink) { [weak self] ended in
            // The file ran out: the playback goes the way a stopped one does, so a client watching
            // its own sees the same tombstone either way.
            await self?.endPlayback(ended, by: .daemon)
        }
        playbacks[id] = PlaybackEntry(engine: engine, owner: client)
        await engine.start()
        let proto = await playbackProto(id)!
        emit(.playback(proto), captureID: nil, by: client)
        playbacks[id]?.ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.playbackInterval)
                guard let self, !Task.isCancelled else { return }
                guard await self.publishPlayback(id) else { return }
            }
        }
        return proto
    }

    /// Publishes a playing playback's full state with its current position, as the daemon does
    /// on `playbackInterval` (invariant 6: the whole object every time, never a delta). False once
    /// the playback has ended, which stops the ticker.
    private func publishPlayback(_ id: PlaybackID) async -> Bool {
        guard let entry = playbacks[id], var proto = await playbackProto(id, entry: entry) else { return false }
        // Checked again after the await: an `endPlayback` that ran meanwhile has already emitted the
        // tombstone, and a playing event after it would bring the playback back in every mirror.
        guard playbacks[id] != nil else { return false }
        // A paused playback's position does not move, and `setPlaybackPaused` already published
        // it: repeating it four times a second would only push real events out of the replay
        // window. The ticker keeps running and speaks again on resume.
        if proto.paused { return true }
        proto.state = .playbackPlaying
        emit(.playback(proto), captureID: nil, by: .daemon)
        return true
    }

    /// Pauses or resumes a playback and publishes its full state at once, caused by `by`. Any
    /// client may, as any client may stop one (`stopPlaybackChecked`); the event names who did.
    /// Asking for the state it is already in publishes nothing new and is not an error.
    func setPlaybackPaused(id: PlaybackID, paused: Bool, by: ClientContext) async throws -> Leyline_V1_Playback {
        guard let entry = playbacks[id] else {
            throw EngineError(code: EngineError.Code.sinkNotFound, message: "no such playback", target: id.string)
        }
        let was = await entry.engine.paused
        await entry.engine.setPaused(paused)
        guard var proto = await playbackProto(id, entry: entry) else {
            throw EngineError(code: EngineError.Code.sinkNotFound, message: "no such playback", target: id.string)
        }
        // The playback may have ended during the awaits above, and its tombstone is already out.
        guard playbacks[id] != nil else {
            proto.state = .unspecified
            return proto
        }
        if was != paused { emit(.playback(proto), captureID: nil, by: by) }
        return proto
    }

    func stopPlaybackChecked(id: PlaybackID, by: ClientContext) async throws {
        guard playbacks[id] != nil else {
            throw EngineError(code: EngineError.Code.sinkNotFound, message: "no such playback", target: id.string)
        }
        await endPlayback(id, by: by)
    }

    /// Ends a playback and emits the tombstone: the same message with `state` unset, so a client
    /// can tell "it finished" from "somebody stopped it" by who caused the event.
    private func endPlayback(_ id: PlaybackID, by: ClientContext) async {
        guard let entry = playbacks.removeValue(forKey: id) else { return }
        entry.ticker?.cancel()
        await entry.engine.stop()
        var proto = await playbackProto(id, entry: entry) ?? Leyline_V1_Playback()
        proto.playbackID = id.string
        proto.state = .unspecified
        emit(.playback(proto), captureID: nil, by: by)
    }

    func playbackProto(_ id: PlaybackID, entry: PlaybackEntry? = nil) async -> Leyline_V1_Playback? {
        guard let entry = entry ?? playbacks[id] else { return nil }
        var p = Leyline_V1_Playback()
        p.playbackID = id.string
        p.resourceUri = await entry.engine.resourceURI
        p.path = entry.engine.path
        p.sampleRate = entry.engine.sampleRate
        p.samples = entry.engine.frames
        p.position = await entry.engine.position
        p.paused = await entry.engine.paused
        p.volume = entry.engine.volume
        p.createdBy = entry.owner.proto
        p.state = .playbackPlaying
        return p
    }

    /// Every playback, for `GetState`.
    func playbackProtos() async -> [Leyline_V1_Playback] {
        var out: [Leyline_V1_Playback] = []
        for id in playbacks.keys.sorted(by: { $0.string < $1.string }) {
            if let p = await playbackProto(id) { out.append(p) }
        }
        return out
    }

    /// Ends every playback of a part of `recordingURI` (`ley://recordings/<id>`), each with its
    /// tombstone caused by `by`, as `StopPlayback` ends one. `DeleteResource` calls it before the
    /// directory goes, so nothing is left playing a file that no longer exists.
    func stopPlaybacks(of recordingURI: String, by: ClientContext) async {
        let prefix = recordingURI + "/"
        let doomed = playbacks.filter { $0.value.engine.resourceURI == recordingURI || $0.value.engine.resourceURI.hasPrefix(prefix) }
        for id in doomed.keys.sorted(by: { $0.string < $1.string }) {
            log.info("stopping playback \(id.string): \(recordingURI) is being deleted")
            await endPlayback(id, by: by)
        }
    }

    /// Ends every playback a departing client started: a playback belongs to the client that
    /// started it, so Ctrl-C in `ley play` stops it.
    private func reapPlaybacks(clientID: String) async {
        for (id, entry) in playbacks where entry.owner.id == clientID {
            log.info("stopping playback \(id.string) of absent client \(clientID)")
            await endPlayback(id, by: .daemon)
        }
    }

    func detachSinkChecked(id: SinkID, by: ClientContext) async throws {
        guard sinks[id] != nil else { throw EngineError.sinkNotFound(id.string) }
        await detachSink(id: id, by: by)
    }

    private func detachSink(id: SinkID, by: ClientContext) async {
        guard let entry = sinks.removeValue(forKey: id) else { return }
        let captureID = channels[entry.channelID]?.captureID
        if let ch = channels[entry.channelID] { await ch.engine.detach(id) }
        await entry.sink.closeSink()
        if entry.isSystemAudio, let capID = captureID, var cap = captures[capID], cap.meta.liveAudioSinks > 0 {
            cap.meta.liveAudioSinks -= 1
            captures[capID] = cap
            await emitCapture(capID, by: by)
        }
        // Terminal event: state unset marks it gone, the same tombstone destroyChannel
        // uses. Without it a detach is byte-identical to the attach that preceded it.
        var terminal = entry.proto
        terminal.state = .unspecified
        emit(.sink(terminal), captureID: captureID, by: by)
    }

    /// A channel's decimation chain was re-planned at a new audio rate: system-audio sinks are
    /// rebuilt at the new rate under their existing ids (a sink that cannot be rebuilt is detached)
    /// and bulk audio streams negotiated at the old rate are ended.
    private func audioRateChanged(_ chanID: ChannelID, by: ClientContext) async {
        guard let ch = channels[chanID] else { return }
        let rate = ch.engine.audioRate
        for (sinkID, entry) in sinks where entry.channelID == chanID && entry.isSystemAudio {
            await ch.engine.detach(sinkID)
            await entry.sink.closeSink()
            let sa = entry.proto.systemAudio
            do {
                let rebuilt = try makeSystemAudioSink(id: sinkID, rate: rate, volume: sa.volume, deviceUID: sa.audioDeviceUid.isEmpty ? nil : sa.audioDeviceUid)
                try await ch.engine.attach(rebuilt)
                sinks[sinkID]?.sink = rebuilt
            } catch {
                log.error("system audio sink \(sinkID) could not follow the new audio rate \(rate): \(error)")
                await detachSink(id: sinkID, by: by)
            }
        }
        await teardownHook?(.channelAudioRate(chanID))
    }

    /// Whether a channel write made the audio descriptor a client holds stale with the audio rate
    /// unchanged: the mode moved, or the full-scale deviation the descriptor answered for it did.
    /// A squelch or offset write moves neither.
    static func audioDescriptorMoved(from before: ChannelConfig, to after: ChannelConfig) -> Bool {
        before.mode != after.mode
            || DemodulatorFactory.fullScaleDeviationHz(mode: before.mode, bandwidthHz: before.bandwidthHz)
            != DemodulatorFactory.fullScaleDeviationHz(mode: after.mode, bandwidthHz: after.bandwidthHz)
    }

    /// Snapshot of every channel's audio rate on a capture, taken before a write that may re-plan chains.
    private func audioRates(captureID: CaptureID) -> [ChannelID: UInt32] {
        channels.filter { $0.value.captureID == captureID }.mapValues { $0.engine.audioRate }
    }

    /// After a retune or rate change: rebuilds sinks for every channel whose audio rate moved
    /// (see `audioRateChanged`) and emits the full state of every channel on the capture.
    private func reconcileAudioRates(captureID: CaptureID, before: [ChannelID: UInt32], by: ClientContext) async {
        for (chanID, ch) in channels where ch.captureID == captureID {
            if ch.engine.audioRate != before[chanID] { await audioRateChanged(chanID, by: by) }
            await emitChannel(chanID, by: by)
        }
    }

    // MARK: Writes

    /// Applies one coalesced parameter write. Returns the rejection (nil = applied). Success emits
    /// the full state of every object the write touched.
    func applyWrite(_ w: Leyline_V1_ParamWrite, by: ClientContext) async -> EngineError? {
        do {
            switch w.param {
            case .centerHz(let hz)?:
                let (id, entry) = try captureTarget(w.targetID)
                // A sweep is stepping this capture; a client write here would conflict with its
                // retunes. The lease is the only tuning path while it is held.
                try refuseIfSwept(id)
                guard let d = devices[entry.deviceID], d.canTune(hz) else { throw EngineError.freqOutOfRange(hz, target: w.targetID) }
                // A retune can bring a channel back into capture after a rate change: its chain is
                // re-planned at the current rate only then, so audio rates are reconciled here too.
                let ratesBefore = audioRates(captureID: id)
                try await entry.engine.retune(centerHz: hz)
                touchActivity(id, by: by)
                await emitCapture(id, by: by)
                await reconcileAudioRates(captureID: id, before: ratesBefore, by: by)
            case .captureSampleRate(let hz)?:
                let (id, entry) = try captureTarget(w.targetID)
                try refuseIfSwept(id)
                guard let d = devices[entry.deviceID], d.sampleRates.isEmpty || d.sampleRates.contains(hz) else {
                    throw EngineError.rateUnsupported(hz, target: w.targetID)
                }
                let ratesBefore = audioRates(captureID: id)
                do {
                    try await entry.engine.setSampleRate(hz)
                } catch {
                    // A failed rate change still moved the engine: it is either detached (the
                    // restore failed too) or streaming again at whatever rate the device ended up
                    // on, with its channels re-planned accordingly. Publish that state before the
                    // rejection so watchers never need a GetState to learn the capture's state.
                    touchActivity(id, by: by)
                    await emitCapture(id, by: by)
                    await reconcileAudioRates(captureID: id, before: ratesBefore, by: by)
                    await teardownHook?(.captureRate(id))
                    throw error
                }
                touchActivity(id, by: by)
                await emitCapture(id, by: by)
                await reconcileAudioRates(captureID: id, before: ratesBefore, by: by)
                // Whatever the channels re-planned to, the capture rate itself moved: bulk audio
                // scales its frame spans by it, so those streams end even when no audio rate did.
                await teardownHook?(.captureRate(id))
            case .gain(let g)?:
                let (id, entry) = try captureTarget(w.targetID)
                // The lease pins gain for the length of a sweep so every dB it reports is measured
                // against one sensitivity; a write here would move the reference mid-sweep and be
                // silently undone when the lease restores what it pinned.
                try refuseIfSwept(id)
                // Argument shape first, then the element: a NaN/inf level is malformed whatever
                // the device offers (`snapped` would otherwise search the table with NaN).
                if case .db(let db)? = g.value, !db.isFinite {
                    throw EngineError.invalidArgument("gain db must be finite", target: w.targetID)
                }
                // An empty element is the first the device lists (`common.proto`, `GainWrite`), the
                // rule the scan allocator already applies; the confirmed level and the manual level
                // are kept under the resolved name, so a client that names it and one that does not
                // read the same state back.
                guard let d = devices[entry.deviceID] else {
                    throw EngineError.gainElementUnknown(g.element, target: w.targetID)
                }
                let element = resolvedGainElement(g.element, in: d.gainElements)
                guard let el = d.gainElement(named: element) else {
                    throw unknownGainElement(element, in: d.gainElements, target: w.targetID)
                }
                func manual(_ db: Double) -> Double { el.validDB.isEmpty ? db : el.snapped(db) }
                let value: GainValue
                switch g.value {
                case .db(let db)?:
                    value = .db(manual(db))
                case .auto(true)?:
                    guard el.supportsAuto else { throw EngineError.gainElementUnknown(element, target: w.targetID) }
                    value = .auto
                case .auto(false)?:
                    // Manual, level unchanged: the confirmed manual level, else the driver's current
                    // manual level, else a mid-range default (never the minimum — that deafens the radio).
                    let current = await entry.engine.snapshot.gains.first { $0.element == element }?.value
                    if let db = entry.manualGainDB[element] {
                        value = .db(db)
                    } else if case .db(let db)? = current {
                        value = .db(db)
                    } else {
                        let sorted = el.validDB.sorted()
                        value = .db(manual(sorted.isEmpty ? (el.minDB + el.maxDB) / 2 : sorted[sorted.count / 2]))
                    }
                case nil: throw EngineError.invalidArgument("gain value is required", target: w.targetID)
                }
                try await entry.engine.setGain(element: element, value: value)
                if case .db(let db) = value { captures[id]?.manualGainDB[element] = db }
                touchActivity(id, by: by)
                await emitCapture(id, by: by)
            case .offsetHz?, .bandwidthHz?, .mode?, .squelchDb?:
                guard let chanID = ChannelID(string: w.targetID), let entry = channels[chanID] else {
                    throw EngineError.channelNotFound(w.targetID)
                }
                var config = await entry.engine.config
                let before = config
                let rate = await captures[entry.captureID]?.engine.snapshot.sampleRate ?? 0
                // A channel the capture has moved away from is already outside: non-offset writes
                // are stored for the rebuild on re-entry, so they skip the offset-vs-bandwidth check.
                let outOfCapture = await entry.engine.state == .outOfCapture
                switch w.param {
                case .offsetHz(let off)?:
                    guard Self.fits(offsetHz: off, bandwidthHz: config.bandwidthHz, sampleRate: rate) else {
                        throw EngineError.offsetOutOfCapture(off, target: w.targetID)
                    }
                    config.offsetHz = off
                case .bandwidthHz(let bw)?:
                    guard bw > 0, UInt64(bw) <= rate else {
                        throw EngineError.invalidArgument("bandwidth \(bw) Hz must be in 1...\(rate)", target: w.targetID)
                    }
                    guard outOfCapture || Self.fits(offsetHz: config.offsetHz, bandwidthHz: bw, sampleRate: rate) else {
                        throw EngineError(code: EngineError.Code.offsetOutOfCapture, message: "bandwidth \(bw) Hz does not fit the capture", target: w.targetID)
                    }
                    config.bandwidthHz = bw
                case .mode(let m)?:
                    guard let mode = ProtoMapping.demodMode(m) else {
                        throw EngineError.modeUnsupported(String(describing: m), target: w.targetID)
                    }
                    config.mode = mode
                    // The tone detector is decided by the mode: on for NFM, the only mode CTCSS is
                    // sent under, and off otherwise. It was decided at creation only, so a channel
                    // that started as WFM or AM and was written to NFM never looked for a tone
                    // (the Mac app keeps one channel across bands and writes the mode).
                    config.subAudibleDetect = mode == .nfm
                case .squelchDb(let db)?:
                    guard db.isNaN || (db <= 0 && db >= -200) else {
                        throw EngineError.invalidArgument("squelch must be a dBFS value <= 0 or NaN", target: w.targetID)
                    }
                    config.squelchDB = db
                default: break
                }
                let audioRateBefore = entry.engine.audioRate
                try await entry.engine.update(config)
                // A channel write re-plans the chain, and a channel the capture had moved away from
                // is re-planned at the capture's current rate -- which can move its audio rate. Every
                // stream negotiated at the old one is then stale, so reconcile
                // exactly as a capture-rate change does: system-audio sinks are rebuilt and bulk
                // streams -- both taps -- end for a fresh subscription.
                if entry.engine.audioRate != audioRateBefore {
                    await audioRateChanged(chanID, by: by)
                } else if Self.audioDescriptorMoved(from: before, to: config) {
                    // The rate held, but the descriptor did not: a bandwidth write rescales an NFM
                    // detector to the channel it now has, and a mode write changes what the taps
                    // carry and what full scale means. A stream negotiated before it would convert
                    // to hertz with a full-scale value the daemon has already replaced, so it ends
                    // the same way, and only the bulk streams: system-audio sinks play at the rate
                    // they have.
                    await teardownHook?(.channelAudioRate(chanID))
                }
                touchActivity(entry.captureID, by: by)
                await emitCapture(entry.captureID, by: by)
                await emitChannel(chanID, by: by)
            case .sinkVolume(let v)?:
                guard let sinkID = SinkID(string: w.targetID), var entry = sinks[sinkID], entry.isSystemAudio else {
                    throw EngineError(code: EngineError.Code.sinkNotFound, message: "no such system-audio sink", target: w.targetID)
                }
                guard v >= 0, v <= 1 else { throw EngineError.invalidArgument("volume must be within 0..1", target: w.targetID) }
                #if canImport(AVFoundation)
                (entry.sink as? CoreAudioSink)?.volume = v
                #endif
                entry.proto.systemAudio.volume = v
                sinks[sinkID] = entry
                emit(.sink(entry.proto), captureID: channels[entry.channelID]?.captureID, by: by)
            case nil:
                throw EngineError.invalidArgument("param is required", target: w.targetID)
            }
            return nil
        } catch let e as EngineError {
            return e
        } catch {
            return EngineError.internalError(String(describing: error), target: w.targetID)
        }
    }

    private func captureTarget(_ id: String) throws -> (CaptureID, CaptureEntry) {
        guard let capID = CaptureID(string: id), let entry = captures[capID] else { throw EngineError.captureNotFound(id) }
        return (capID, entry)
    }

    /// A rejected write becomes a `WriteRejected` event tagged for the client.
    func emitWriteRejected(tag: UInt64, error: EngineError, by: ClientContext) {
        var wr = Leyline_V1_WriteRejected()
        wr.tag = tag
        wr.error = ProtoMapping.errorDetail(error)
        emit(.writeRejected(wr), captureID: nil, by: by)
    }

    // MARK: Snapshot

    func snapshot(scope: EventScopeFilter) async -> Leyline_V1_GetStateResponse {
        // Read the seq before any actor hop: the object reads below suspend, and a commit that
        // lands in between must look *newer* than this snapshot (duplicate replay is harmless
        // because events carry full state; a stale object tagged with a newer seq is not).
        let at = seq
        var out = Leyline_V1_GetStateResponse()
        out.daemon = info.proto
        let capFilter: CaptureID? = { if case .capture(let c) = scope { return c } else { return nil } }()
        out.devices = listDevices().map(ProtoMapping.descriptor)
        for id in captures.keys.sorted(by: { $0.string < $1.string }) where capFilter == nil || capFilter == id {
            if let p = await captureProto(id) { out.captures.append(p) }
        }
        for id in channels.keys.sorted(by: { $0.string < $1.string }) where capFilter == nil || channels[id]?.captureID == capFilter {
            if let p = await channelProto(id) { out.channels.append(p) }
        }
        for id in sinks.keys.sorted(by: { $0.string < $1.string }) {
            guard let s = sinks[id] else { continue }
            if let c = capFilter, channels[s.channelID]?.captureID != c { continue }
            out.sinks.append(s.proto)
        }
        // Daemon-scoped only: a job is not tied to one capture's lifetime, and a capture-filtered
        // reader asked about that capture.
        if capFilter == nil, let provider = jobsProvider {
            out.jobs = await provider()
        }
        // A playback is not tied to a capture either: it is a file playing, with no radio in it.
        if capFilter == nil {
            out.playbacks = await playbackProtos()
        }
        out.eventSeq = at
        return out
    }

    /// Graceful shutdown: every capture stopped (devices closed), subscribers finished.
    func shutdown() async {
        deviceTask?.cancel()
        for id in Array(captures.keys) { await destroyCapture(id: id, by: .daemon) }
        for p in presence.values { p.grace?.cancel() }
        presence.removeAll()
        finishSubscribers()
    }
}
