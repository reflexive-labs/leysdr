// The daemon's single source of truth (docs/engine-internals.md "SessionStore"): one actor owning
// devices, captures, channels, sinks, the event sequence and client presence. Every mutation goes
// through here and emits exactly one full-state event per changed object (CLAUDE.md invariants 6, 7).

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
}

/// Objects torn down by the store that the bulk plane must stop streaming from.
enum TeardownScope: Sendable {
    case capture(CaptureID)
    case channel(ChannelID)
    /// The channel's audio rate changed (capture rate write): audio streams negotiated at the old
    /// rate end; the client re-subscribes for a fresh descriptor.
    case channelAudioRate(ChannelID)
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

    var proto: Leyline_V1_DaemonInfo {
        var out = Leyline_V1_DaemonInfo()
        out.version = version
        out.pid = pid
        out.startedAtNs = startedAtNs
        out.socketPath = socketPath
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
    private let log = Logger(label: "leyline.store")

    private(set) var devices: [DeviceID: DeviceDescriptor] = [:]
    private(set) var captures: [CaptureID: CaptureEntry] = [:]
    /// Devices whose capture is still starting (see createCapture).
    private var startingDevices: Set<DeviceID> = []
    private(set) var channels: [ChannelID: ChannelEntry] = [:]
    private(set) var sinks: [SinkID: SinkEntry] = [:]
    private(set) var seq: UInt64 = 0
    private var subscribers: [UUID: Subscriber] = [:]
    private var presence: [String: Presence] = [:]
    private var deviceTask: Task<Void, Never>?
    /// Installed by the bulk plane so streams on destroyed objects end.
    private var teardownHook: (@Sendable (TeardownScope) async -> Void)?

    init(registry: DefaultDeviceRegistry, info: DaemonInfo, presenceGraceNs: UInt64 = 5_000_000_000) {
        self.registry = registry
        self.info = info
        self.presenceGraceNs = presenceGraceNs
    }

    func setTeardownHook(_ hook: @escaping @Sendable (TeardownScope) async -> Void) { teardownHook = hook }

    // MARK: Events

    /// Fan-out of full-state events. `bufferingNewest(256)`: a slow subscriber sees a seq gap and
    /// re-fetches `GetState`. The subscriber is registered synchronously on the actor before the
    /// stream is returned, so every event committed after this call returns is delivered
    /// ("WatchEvents then GetState" cannot miss one).
    func events(scope: EventScopeFilter) -> AsyncStream<Leyline_V1_Event> {
        let (stream, continuation) = AsyncStream<Leyline_V1_Event>.makeStream(bufferingPolicy: .bufferingNewest(256))
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

    /// Emits one event; `captureID` scopes it for capture-filtered watchers (nil = daemon-wide).
    @discardableResult
    private func emit(_ body: Leyline_V1_Event.OneOf_Body, captureID: CaptureID?, by: ClientContext) -> UInt64 {
        seq += 1
        var ev = Leyline_V1_Event()
        ev.seq = seq
        ev.causedBy = by.proto
        ev.body = body
        for sub in subscribers.values {
            if case .capture(let want) = sub.scope, let have = captureID, have != want { continue }
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
        if stillAbsent(clientID) { presence[clientID] = nil }
    }

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

    func detachFileDevice(id: DeviceID, by: ClientContext) async throws {
        guard devices[id] != nil else { throw EngineError.deviceNotFound(id.string) }
        for (capID, entry) in captures where entry.deviceID == id {
            await destroyCapture(id: capID, by: by)
        }
        try await registry.detachFileDevice(id: id)
        if var d = devices.removeValue(forKey: id) {
            d.state = .disconnected
            emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: by)
        }
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

    func createCapture(deviceID: DeviceID, centerHz: UInt64, sampleRate: UInt64, by: ClientContext) async throws -> Leyline_V1_Capture {
        guard let desc = devices[deviceID], let device = await registry.device(id: deviceID) else {
            throw EngineError.deviceNotFound(deviceID.string)
        }
        if desc.state == .disconnected { throw EngineError.deviceDetached(deviceID.string) }
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
        try await engine.start()
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
        return proto
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
        proto.state = .captureDetached
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
    func channelEngines(captureID: CaptureID?) -> [(ChannelID, any ChannelEngine)] {
        channels.compactMap { id, e in
            if let c = captureID, e.captureID != c { return nil }
            return (id, e.engine)
        }
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
        // DEMOD_MODE_UNSPECIFIED defaults to NFM (contract parity with the Go reference daemon).
        guard let m = ProtoMapping.demodMode(mode == .unspecified ? .nfm : mode) else {
            throw EngineError.modeUnsupported(String(describing: mode), target: captureID.string)
        }
        let bw = bandwidthHz == 0 ? m.defaultBandwidthHz : bandwidthHz
        let rate = await cap.engine.snapshot.sampleRate
        guard Self.fits(offsetHz: offsetHz, bandwidthHz: bw, sampleRate: rate) else {
            throw EngineError.offsetOutOfCapture(offsetHz, target: captureID.string)
        }
        let config = ChannelConfig(offsetHz: offsetHz, bandwidthHz: bw, mode: m, persistent: persistent,
                                   requiredHz: requiredHz == 0 ? nil : requiredHz)
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
        Double(abs(offsetHz)) + Double(bandwidthHz) / 2 <= Double(sampleRate) / 2
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
            if sa.volume == 0 { sa.volume = 1 }
            guard sa.volume >= 0, sa.volume <= 1 else { throw EngineError.invalidArgument("volume must be within 0..1", target: channelID.string) }
            sink = try SinkFactory.systemAudio(rate: entry.engine.audioRate, volume: sa.volume, deviceUID: sa.audioDeviceUid.isEmpty ? nil : sa.audioDeviceUid)
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
        sinks[sink.id] = SinkEntry(proto: proto, channelID: channelID, sink: sink, isSystemAudio: isSystemAudio)
        if isSystemAudio, var cap = captures[entry.captureID] {
            cap.meta.liveAudioSinks += 1
            captures[entry.captureID] = cap
            await emitCapture(entry.captureID, by: by)
        }
        emit(.sink(proto), captureID: entry.captureID, by: by)
        return proto
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
        emit(.sink(entry.proto), captureID: captureID, by: by)
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

    // MARK: Writes

    /// Applies one coalesced parameter write. Returns the rejection (nil = applied). Success emits
    /// the full state of every object the write touched.
    func applyWrite(_ w: Leyline_V1_ParamWrite, by: ClientContext) async -> EngineError? {
        do {
            switch w.param {
            case .centerHz(let hz)?:
                let (id, entry) = try captureTarget(w.targetID)
                guard let d = devices[entry.deviceID], d.canTune(hz) else { throw EngineError.freqOutOfRange(hz, target: w.targetID) }
                try await entry.engine.retune(centerHz: hz)
                touchActivity(id, by: by)
                await emitCapture(id, by: by)
                for (chanID, ch) in channels where ch.captureID == id { await emitChannel(chanID, by: by) }
            case .captureSampleRate(let hz)?:
                let (id, entry) = try captureTarget(w.targetID)
                guard let d = devices[entry.deviceID], d.sampleRates.isEmpty || d.sampleRates.contains(hz) else {
                    throw EngineError.rateUnsupported(hz, target: w.targetID)
                }
                let ratesBefore = channels.filter { $0.value.captureID == id }.mapValues { $0.engine.audioRate }
                try await entry.engine.setSampleRate(hz)
                touchActivity(id, by: by)
                await emitCapture(id, by: by)
                for (chanID, ch) in channels where ch.captureID == id {
                    if ch.engine.audioRate != ratesBefore[chanID] { await audioRateChanged(chanID, by: by) }
                    await emitChannel(chanID, by: by)
                }
            case .gain(let g)?:
                let (id, entry) = try captureTarget(w.targetID)
                guard let d = devices[entry.deviceID], let el = d.gainElement(named: g.element) else {
                    throw EngineError.gainElementUnknown(g.element, target: w.targetID)
                }
                func manual(_ db: Double) -> Double { el.validDB.isEmpty ? db : el.snapped(db) }
                let value: GainValue
                switch g.value {
                case .db(let db)?:
                    value = .db(manual(db))
                case .auto(true)?:
                    guard el.supportsAuto else { throw EngineError.gainElementUnknown(g.element, target: w.targetID) }
                    value = .auto
                case .auto(false)?:
                    // Manual, level unchanged: the confirmed manual level, else the driver's current
                    // manual level, else a mid-range default (never the minimum — that deafens the radio).
                    let current = await entry.engine.snapshot.gains.first { $0.element == g.element }?.value
                    if let db = entry.manualGainDB[g.element] {
                        value = .db(db)
                    } else if case .db(let db)? = current {
                        value = .db(db)
                    } else {
                        let sorted = el.validDB.sorted()
                        value = .db(manual(sorted.isEmpty ? (el.minDB + el.maxDB) / 2 : sorted[sorted.count / 2]))
                    }
                case nil: throw EngineError.invalidArgument("gain value is required", target: w.targetID)
                }
                try await entry.engine.setGain(element: g.element, value: value)
                if case .db(let db) = value { captures[id]?.manualGainDB[g.element] = db }
                touchActivity(id, by: by)
                await emitCapture(id, by: by)
            case .offsetHz?, .bandwidthHz?, .mode?, .squelchDb?:
                guard let chanID = ChannelID(string: w.targetID), let entry = channels[chanID] else {
                    throw EngineError.channelNotFound(w.targetID)
                }
                var config = await entry.engine.config
                let rate = await captures[entry.captureID]?.engine.snapshot.sampleRate ?? 0
                switch w.param {
                case .offsetHz(let off)?:
                    guard Self.fits(offsetHz: off, bandwidthHz: config.bandwidthHz, sampleRate: rate) else {
                        throw EngineError.offsetOutOfCapture(off, target: w.targetID)
                    }
                    config.offsetHz = off
                case .bandwidthHz(let bw)?:
                    guard bw > 0, Self.fits(offsetHz: config.offsetHz, bandwidthHz: bw, sampleRate: rate) else {
                        throw EngineError(code: "OFFSET_OUT_OF_CAPTURE", message: "bandwidth \(bw) Hz does not fit the capture", target: w.targetID)
                    }
                    config.bandwidthHz = bw
                case .mode(let m)?:
                    guard let mode = ProtoMapping.demodMode(m) else {
                        throw EngineError.modeUnsupported(String(describing: m), target: w.targetID)
                    }
                    config.mode = mode
                case .squelchDb(let db)?:
                    guard db.isNaN || (db <= 0 && db >= -200) else {
                        throw EngineError.invalidArgument("squelch must be a dBFS value <= 0 or NaN", target: w.targetID)
                    }
                    config.squelchDB = db
                default: break
                }
                try await entry.engine.update(config)
                touchActivity(entry.captureID, by: by)
                await emitCapture(entry.captureID, by: by)
                await emitChannel(chanID, by: by)
            case .sinkVolume(let v)?:
                guard let sinkID = SinkID(string: w.targetID), var entry = sinks[sinkID], entry.isSystemAudio else {
                    throw EngineError(code: "SINK_NOT_FOUND", message: "no such system-audio sink", target: w.targetID)
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
            return EngineError(code: "INTERNAL", message: String(describing: error), target: w.targetID)
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
