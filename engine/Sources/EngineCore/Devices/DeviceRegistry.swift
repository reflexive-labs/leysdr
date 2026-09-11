// DefaultDeviceRegistry: discovers RTL-SDR dongles by polling, hosts file playback devices, and
// hands out stable DeviceIDs keyed by USB identity so replugs keep their id.

import Foundation
import Logging

/// Fan-out of `DeviceEvent`s to every `events()` subscriber. Lock-guarded so `events()` can be
/// called from any context (the protocol makes it non-async); the lock is never held across calls.
final class DeviceEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DeviceEvent>.Continuation] = [:]

    func subscribe() -> AsyncStream<DeviceEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DeviceEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
        }
        lock.lock(); continuations[id] = continuation; lock.unlock()
        return stream
    }

    func publish(_ event: DeviceEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for c in targets { c.yield(event) }
    }

    func finishAll() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in targets { c.finish() }
    }
}

/// Registry-side hooks every hosted virtual device implements: the registry assigns the stable id,
/// records externally decided `.inUse`/`.available` state and installs the state-change hook.
public protocol VirtualDevice: RadioDevice {
    func assignID(_ id: DeviceID)
    func setState(_ state: DeviceState)
    func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?)
}

/// Persisted identity → DeviceID map (JSON object of `"serial|manufacturer|product[#n]": "dev_..."`).
struct DeviceIDMap: Codable {
    var ids: [String: DeviceID] = [:]
}

/// The engine's device registry. Polls `RTLSDRDevice.enumerate` every `pollIntervalMs` while
/// started, hosts `FilePlaybackDevice`s, and publishes `arrived` / `removed` / `changed`.
///
/// Identity: a device key is `(serial, manufacturer, product)`. Two dongles with identical strings
/// (Nooelec's `00000001`) are disambiguated by enumeration order (`#1`, `#2`, ...) and flagged with
/// `features["serial_collision"] = true` — their ids are stable only while both stay plugged in.
public actor DefaultDeviceRegistry: DeviceRegistry {
    private struct Entry {
        var descriptor: DeviceDescriptor
        var device: any RadioDevice
        /// USB index while the dongle is attached; nil for file devices.
        var rtlIndex: UInt32?
        var key: String
        /// How a hosted virtual device arrived; nil for a dongle in this machine's port, which
        /// nobody attached.
        var origin: VirtualDeviceOrigin?
        /// The dongle is claimed by another program (its probe `rtlsdr_open` failed): reported
        /// `.inUse` with feature `held_externally`, re-probed with backoff until it opens.
        var heldExternally = false
    }

    public let persistPath: String?
    public let pollIntervalMs: Int

    private let hub = DeviceEventHub()
    /// Every write bumps `tableGeneration`, which is how `poll` knows the table it diffed against
    /// is the table it is about to overwrite.
    private var entries: [DeviceID: Entry] = [:] {
        didSet { tableGeneration &+= 1 }
    }
    /// Count of writes to `entries`. Only `poll` reads it: it enumerates off the actor, so an
    /// attach, detach or claim can land while it is suspended.
    private var tableGeneration: UInt64 = 0
    private var idMap = DeviceIDMap()
    private var pollTask: Task<Void, Never>?
    private var started = false
    /// Hosted rtl_tcp devices with a reconnect attempt in flight (one per device at a time, so a
    /// poll never stacks attempts behind a 5 s connect timeout).
    private var reconnecting: Set<DeviceID> = []
    /// Devices with a reconnect attempt in flight (test hook).
    var reconnectingIDs: Set<DeviceID> { reconnecting }
    private static let logger = Logger(label: "leyline.registry")

    /// Poll counter; probe backoff deadlines are expressed in polls so tests can drive them.
    private var pollTick = 0
    /// Per-dongle re-probe schedule while another program holds it: the poll at which the next
    /// `rtlsdr_open` may be tried and the current delay (ms), doubling from `probeBackoffMinMs` to
    /// `probeBackoffMaxMs`. A failed open makes librtlsdr print to stderr, so once a second is too often.
    private var probeBackoff: [DeviceID: (retryAtTick: Int, delayMs: Int)] = [:]
    public static let probeBackoffMinMs = 2_000
    public static let probeBackoffMaxMs = 60_000

    /// - Parameters:
    ///   - persistPath: JSON file that keeps the identity → id map across daemon restarts. nil = memory only.
    ///   - pollIntervalMs: hot-plug enumeration period (docs: 1 s while idle).
    public init(persistPath: String? = nil, pollIntervalMs: Int = 1000) {
        self.persistPath = persistPath
        self.pollIntervalMs = max(10, pollIntervalMs)
        if let p = persistPath, let data = FileManager.default.contents(atPath: p),
           let map = try? JSONDecoder().decode(DeviceIDMap.self, from: data) {
            idMap = map
        }
    }

    // MARK: Identity

    static func identityKey(serial: String, manufacturer: String, product: String) -> String {
        "\(serial)|\(manufacturer)|\(product)"
    }

    /// Returns the stable id for a key, minting and persisting one on first sight.
    private func stableID(for key: String) -> DeviceID {
        if let id = idMap.ids[key] { return id }
        let id = DeviceID()
        idMap.ids[key] = id
        persist()
        return id
    }

    private func persist() {
        guard let p = persistPath else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(idMap) {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: p).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: p), options: .atomic)
        }
    }

    // MARK: DeviceRegistry

    public var devices: [DeviceDescriptor] {
        entries.values.map(\.descriptor).sorted { $0.id.string < $1.id.string }
    }

    public func device(id: DeviceID) -> (any RadioDevice)? { entries[id]?.device }

    public nonisolated func events() -> AsyncStream<DeviceEvent> { hub.subscribe() }

    private func publish(_ event: DeviceEvent) { hub.publish(event) }

    // MARK: File devices

    /// Hosts a `FilePlaybackDevice` for `path`. The id is stable per absolute path. Attaching a path
    /// that is already attached returns the existing descriptor.
    public func attachFileDevice(path: String, loop: Bool) throws -> DeviceDescriptor {
        try attachFileDevice(path: path, loop: loop, realtime: true)
    }

    /// `attachFileDevice` with pacing control (`realtime: false` is for tests and internal tooling).
    public func attachFileDevice(path: String, loop: Bool, realtime: Bool) throws -> DeviceDescriptor {
        let device = try FilePlaybackDevice(path: path, loop: loop, realtime: realtime)
        let provisional = device.descriptor
        let key = DefaultDeviceRegistry.identityKey(serial: provisional.serial, manufacturer: "file", product: provisional.model)
        if let existing = entries.values.first(where: { $0.key == key && $0.rtlIndex == nil }) {
            return existing.descriptor
        }
        let id = stableID(for: key)
        device.assignID(id)
        device.setOnStateChange { [weak self] state in
            guard let self else { return }
            // Fired from the playback thread at EOF; hop to the actor to publish.
            Task { await self.deviceStateChanged(id: id, state: state) }
        }
        let descriptor = device.descriptor
        entries[id] = Entry(descriptor: descriptor, device: device, rtlIndex: nil, key: key, origin: .client)
        publish(.arrived(descriptor))
        return descriptor
    }

    /// Whether `id` names a hosted virtual device rather than a dongle in this machine's port
    /// (`rtlIndex == nil`). A file the daemon plays and a radio served by rtl_tcp are both hosted and
    /// both leave the same way; a dongle leaves when someone pulls it. Non-mutating, so callers can
    /// reject a request before touching any capture.
    public func isDetachableVirtualDevice(id: DeviceID) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.rtlIndex == nil
    }

    /// How a hosted virtual device arrived, or nil for an id that is not hosted (a dongle, or no
    /// such device). A caller deciding whether a client may detach it needs both this and
    /// `isDetachableVirtualDevice`.
    public func virtualDeviceOrigin(id: DeviceID) -> VirtualDeviceOrigin? {
        guard let entry = entries[id], entry.rtlIndex == nil else { return nil }
        return entry.origin
    }

    /// Detaches any hosted virtual device (file playback or `attachVirtualDevice`).
    public func detachVirtualDevice(id: DeviceID) async throws {
        guard let entry = entries[id], entry.rtlIndex == nil else { throw EngineError.deviceNotFound(id.string) }
        entries[id] = nil
        await entry.device.close()
        publish(.removed(id))
    }

    // MARK: Virtual devices

    /// Hosts any non-USB `RadioDevice` (e.g. `RTLTCPDevice`). Identity is `(serial, driver, model)`
    /// of the device's own descriptor; the stable id is minted from that. Devices conforming to
    /// `VirtualDevice` get the registry id assigned and the state-change hook installed so their
    /// own `.disconnected` transitions publish `changed` like an unplug. `origin` records who asked
    /// for it; a client attaching an endpoint the operator's flag already hosts takes ownership of
    /// it, so the radio stays when the flag goes.
    public func attachVirtualDevice(_ device: any RadioDevice, origin: VirtualDeviceOrigin = .client) async throws -> VirtualAttachment {
        let provisional = device.descriptor
        let key = DefaultDeviceRegistry.identityKey(serial: provisional.serial, manufacturer: provisional.driver, product: provisional.model)
        if let (id, existing) = entries.first(where: { $0.value.key == key && $0.value.rtlIndex == nil }) {
            // Callers open before attaching, so a second instance of the same identity arrives with a
            // live socket and a reader thread that nothing else holds a reference to: close it here.
            if !(existing.device === device) { await device.close() }
            if origin == .client { claimVirtualDevice(id: id) }
            return VirtualAttachment(descriptor: existing.descriptor, alreadyHosted: true)
        }
        let id = stableID(for: key)
        if let v = device as? VirtualDevice {
            v.assignID(id)
            v.setOnStateChange { [weak self] state in
                guard let self else { return }
                // Fired from the device's I/O thread; hop to the actor to publish.
                Task { await self.deviceStateChanged(id: id, state: state) }
            }
        }
        let descriptor = device.descriptor
        entries[id] = Entry(descriptor: descriptor, device: device, rtlIndex: nil, key: key, origin: origin)
        publish(.arrived(descriptor))
        return VirtualAttachment(descriptor: descriptor, alreadyHosted: false)
    }

    /// Records that a client now owns a hosted virtual device the operator's command line brought
    /// up, so it stays when the flag goes and the client may detach it. Anything else -- a dongle, a
    /// device a client already owns -- is unchanged.
    public func claimVirtualDevice(id: DeviceID) {
        guard let entry = entries[id], entry.rtlIndex == nil, entry.origin == .operatorFlag else { return }
        entries[id]?.origin = .client
    }

    /// Records a state flip reported by a device (e.g. file playback reaching EOF → `.disconnected`).
    /// The entry stays so `device(id:)` keeps returning the same instance until it is detached.
    private func deviceStateChanged(id: DeviceID, state: DeviceState) {
        guard var entry = entries[id], entry.descriptor.state != state else { return }
        entry.descriptor.state = state
        entries[id] = entry
        publish(.changed(entry.descriptor))
    }

    /// Marks a device `.inUse` (a capture holds it) or back to `.available`; publishes `changed`.
    /// A capture that opens a dongle reported as held by another program proves the hold is over,
    /// so the external-hold flag and its re-probe schedule are cleared here too.
    public func markInUse(id: DeviceID, _ inUse: Bool) throws {
        guard var entry = entries[id] else { throw EngineError.deviceNotFound(id.string) }
        guard entry.descriptor.state != .disconnected else { throw EngineError.deviceDetached(id.string) }
        let state: DeviceState = inUse ? .inUse : .available
        let releasingHold = entry.heldExternally
        guard entry.descriptor.state != state || releasingHold else { return }
        entry.descriptor.state = state
        entry.heldExternally = false
        entry.descriptor.features["held_externally"] = nil
        probeBackoff[id] = nil
        entries[id] = entry
        if let v = entry.device as? VirtualDevice { v.setState(state) }
        if let r = entry.device as? RTLSDRDevice { r.setState(state) }
        publish(.changed(entry.descriptor))
    }

    // MARK: Hot-plug polling

    /// Starts the enumeration loop (one pass immediately, then every `pollIntervalMs`).
    public func start() {
        guard !started else { return }
        started = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(nanoseconds: UInt64(self.pollIntervalMs) * 1_000_000)
            }
        }
    }

    /// Stops polling and ends every `events()` subscription; hosted devices stay registered.
    /// Finishing the streams is the shutdown contract: a consumer may wait for its stream to end
    /// rather than relying on its own task being cancelled.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        started = false
        hub.finishAll()
    }

    /// One enumeration pass: diff `RTLSDRDevice.enumerate` against known dongles. The per-device
    /// `rtlsdr_open` probe (tuner type, gain table) runs only for identities never probed
    /// successfully: known dongles keep their cached probe, so idle dongles are not re-initialised
    /// every second and the poll never contends with a capture's own open. A dongle whose probe
    /// open fails (another program holds it) is reported `.inUse` and re-probed with backoff.
    public func poll() async {
        let gate = advanceTickAndProbeGate()
        let claimed = Set(entries.values.compactMap { e -> UInt32? in
            e.descriptor.state == .inUse && !e.heldExternally ? e.rtlIndex : nil
        })
        // libusb enumeration plus a probe `rtlsdr_open` blocks for hundreds of milliseconds, and
        // every caller of the registry queues behind the actor while it runs, so it goes off-actor
        // and only the diff comes back here.
        do {
            // An empty probe list is not a neutral pass: `applyProbes` reads it as every dongle
            // unplugged. A failed enumeration therefore leaves the known set untouched until the
            // next tick rather than announcing a device-loss storm.
            let generation = tableGeneration
            let probes = try await BlockingWork.run { RTLSDRDevice.enumerate(claimed: claimed, shouldOpen: gate) }
            // Someone attached, detached or claimed a device while the enumeration ran, so these
            // probes describe a table that no longer exists and `applyProbes` would diff them
            // against the wrong one -- announcing a removal for a dongle that just arrived, say.
            // Dropping the pass costs a second.
            if tableGeneration == generation { applyProbes(probes) }
        } catch {
            DefaultDeviceRegistry.logger.warning("device enumeration failed (\(error)); keeping the known dongles until the next poll")
        }
        reconnectDisconnectedRemotes()
    }

    /// Advances the poll counter and returns the predicate `enumerate` uses to decide which
    /// dongles may be opened for a probe this pass: not one of ours, not already probed, and not
    /// inside a backoff window after a failed open. The decision is per dongle, keyed by identity
    /// *and* USB index, so two dongles sharing a serial (`#n` collision keys) are gated on their
    /// own state: a held sibling inside its backoff never shadows the other one, and a probe with
    /// no matching entry (a new device) may always open. Split from `poll` so tests can drive it.
    func advanceTickAndProbeGate() -> @Sendable (RTLSDRProbe) -> Bool {
        pollTick += 1
        var skip = Set<String>()
        for (id, e) in entries {
            guard let index = e.rtlIndex else { continue }
            let base = DefaultDeviceRegistry.identityBase(of: e.key)
            let rtl = e.device as? RTLSDRDevice
            let closed: Bool
            if e.descriptor.state == .inUse && !e.heldExternally {
                closed = true
            } else if e.heldExternally {
                closed = probeBackoff[id].map { pollTick < $0.retryAtTick } ?? false
            } else {
                closed = rtl.map { DefaultDeviceRegistry.isProbed($0.probe) } ?? false
            }
            if closed { skip.insert(DefaultDeviceRegistry.probeSlot(base: base, index: index)) }
        }
        return { p in
            let base = DefaultDeviceRegistry.identityKey(serial: p.serial, manufacturer: p.manufacturer, product: p.product)
            return !skip.contains(DefaultDeviceRegistry.probeSlot(base: base, index: p.index))
        }
    }

    /// Gate key for one physical dongle: identity base plus USB index (the index is what tells two
    /// serial-collision siblings apart within a pass).
    private static func probeSlot(base: String, index: UInt32) -> String { "\(base)@\(index)" }

    /// Records that one of our captures failed to claim the dongle because another program has it
    /// (`RTLSDRDevice.open` threw DEVICE_BUSY): the same outcome as a failed probe, so the dongle
    /// reads `IN_USE` with `held_externally` and is re-probed with backoff until it opens again.
    /// No-op for virtual devices and for dongles one of our captures already holds.
    public func markHeldExternally(id: DeviceID) {
        guard var entry = entries[id], entry.rtlIndex != nil, let rtl = entry.device as? RTLSDRDevice,
              entry.descriptor.state != .disconnected,
              !(entry.descriptor.state == .inUse && !entry.heldExternally) else { return }
        let first = !entry.heldExternally
        entry.heldExternally = true
        let delay = scheduleReprobe(id: id)
        rtl.setState(.inUse)
        var d = entry.descriptor
        d.state = .inUse
        d.features["held_externally"] = .flag(true)
        let changed = d != entry.descriptor
        entry.descriptor = d
        entries[id] = entry
        if changed { publish(.changed(d)) }
        logProbeFailure(d, rc: -3, first: first, nextMs: delay)
    }

    /// Schedules the next probe attempt for a dongle whose open just failed.
    private func scheduleReprobe(id: DeviceID) -> Int {
        let previous = probeBackoff[id]?.delayMs
        let delay = previous.map { min($0 * 2, DefaultDeviceRegistry.probeBackoffMaxMs) } ?? DefaultDeviceRegistry.probeBackoffMinMs
        let ticks = max(1, (delay + pollIntervalMs - 1) / pollIntervalMs)
        probeBackoff[id] = (pollTick + ticks, delay)
        return delay
    }

    /// Link-loss recovery for hosted `RTLTCPDevice`s: every `.disconnected` entry gets one `open()`
    /// attempt per poll (bounded by the device's connect timeout; `RTLTCPDevice.open` runs its
    /// blocking connect through `BlockingWork`, so the task itself never parks a pool thread). On
    /// success the entry is `.available` again and `arrived` is published under the same id so
    /// `SessionStore` rebinds detached captures through its normal path; a failure is retried on
    /// the next poll.
    private func reconnectDisconnectedRemotes() {
        for (id, entry) in entries where entry.rtlIndex == nil && entry.descriptor.state == .disconnected {
            guard let remote = entry.device as? RTLTCPDevice, !reconnecting.contains(id) else { continue }
            reconnecting.insert(id)
            Task { [weak self] in
                let ok: Bool
                do { try await remote.open(); ok = true } catch { ok = false }
                await self?.reconnectFinished(id: id, device: remote, ok: ok)
            }
        }
    }

    /// Actor-side tail of a reconnect attempt. Publishes `arrived` only when the device is still
    /// `.available` now: a link that died between `open()` returning and this hop leaves the entry
    /// `.disconnected` for the next poll instead of announcing a device that is already gone.
    /// Internal so tests can drive the race directly.
    func reconnectFinished(id: DeviceID, device: RTLTCPDevice, ok: Bool) {
        reconnecting.remove(id)
        guard ok, var entry = entries[id], entry.device === device, entry.descriptor.state == .disconnected else { return }
        let current = device.descriptor
        guard current.state == .available else { return }
        entry.descriptor = current
        entries[id] = entry
        publish(.arrived(entry.descriptor))
    }

    /// Whether a probe carries real tuner data (the open succeeded).
    static func isProbed(_ p: RTLSDRProbe) -> Bool { p.tuner != "unknown" }

    /// Strips the `#n` serial-collision suffix from an entry key.
    static func identityBase(of key: String) -> String {
        guard let hash = key.lastIndex(of: "#") else { return key }
        return String(key[..<hash])
    }

    /// Diffs one set of enumeration probes against the known dongles (split from `poll` so tests can
    /// drive it without hardware).
    func applyProbes(_ probes: [RTLSDRProbe]) {
        var seen: [String: Int] = [:]
        var present: [DeviceID: (RTLSDRProbe, String, Bool)] = [:]
        for p in probes {
            let base = DefaultDeviceRegistry.identityKey(serial: p.serial, manufacturer: p.manufacturer, product: p.product)
            let n = seen[base, default: 0]
            seen[base] = n + 1
            let key = n == 0 ? base : "\(base)#\(n)"
            present[stableID(for: key)] = (p, key, n > 0)
        }
        // Removed: known dongles not enumerated this pass.
        for (id, entry) in entries where entry.rtlIndex != nil && present[id] == nil {
            entries[id] = nil
            probeBackoff[id] = nil
            (entry.device as? RTLSDRDevice)?.setState(.disconnected)
            publish(.removed(id))
        }
        // Arrived / changed.
        for (id, (probe, key, collided)) in present {
            if var entry = entries[id] {
                guard let rtl = entry.device as? RTLSDRDevice else { continue }
                let ours = entry.descriptor.state == .inUse && !entry.heldExternally
                if !ours, let rc = probe.openError {
                    // Still (or newly) claimed by another program.
                    let first = !entry.heldExternally
                    entry.heldExternally = true
                    let delay = scheduleReprobe(id: id)
                    rtl.setState(.inUse)
                    var d = rtl.descriptor
                    d.state = .inUse
                    d.features["serial_collision"] = .flag(collided)
                    d.features["held_externally"] = .flag(true)
                    if probe.index != entry.rtlIndex { rtl.setIndex(probe.index); entry.rtlIndex = probe.index }
                    let changed = d != entry.descriptor
                    entry.descriptor = d
                    entries[id] = entry
                    if changed { publish(.changed(d)) }
                    logProbeFailure(d, rc: rc, first: first, nextMs: delay)
                    continue
                }
                if entry.heldExternally, DefaultDeviceRegistry.isProbed(probe) {
                    // The other program let go: back to available with the real tuner/gain table.
                    entry.heldExternally = false
                    probeBackoff[id] = nil
                    rtl.setState(.available)
                    DefaultDeviceRegistry.logger.info("dongle \(entry.descriptor.serial) (\(entry.descriptor.model)) is available again")
                }
                if !ours, !DefaultDeviceRegistry.isProbed(rtl.probe), DefaultDeviceRegistry.isProbed(probe) {
                    rtl.updateProbe(probe)
                }
                var d = ours ? entry.descriptor : rtl.descriptor
                d.features["serial_collision"] = .flag(collided)
                if entry.heldExternally {
                    d.state = .inUse
                    d.features["held_externally"] = .flag(true)
                } else {
                    d.features["held_externally"] = nil
                }
                if ours {
                    // The descriptor is the capture's, so nothing is published, but the index still
                    // has to follow a re-enumeration: `poll` gates the probe open on it, and a stale
                    // one aims that open at the dongle we are streaming from.
                    if probe.index != entry.rtlIndex {
                        rtl.setIndex(probe.index)
                        entry.rtlIndex = probe.index
                        entries[id] = entry
                    }
                    continue
                }
                if probe.index != entry.rtlIndex || d != entry.descriptor {
                    rtl.setIndex(probe.index)
                    entry.rtlIndex = probe.index
                    entry.descriptor = d
                    entries[id] = entry
                    publish(.changed(d))
                }
            } else {
                let device = RTLSDRDevice(probe: probe, id: id)
                device.setOnStateChange { [weak self] state in
                    guard let self else { return }
                    // Fired from the USB thread when rtlsdr_read_async dies; hop to the actor to publish.
                    Task { await self.deviceStateChanged(id: id, state: state) }
                }
                var d = device.descriptor
                d.features["serial_collision"] = .flag(collided)
                var entry = Entry(descriptor: d, device: device, rtlIndex: probe.index, key: key)
                if let rc = probe.openError {
                    entry.heldExternally = true
                    let delay = scheduleReprobe(id: id)
                    device.setState(.inUse)
                    d.state = .inUse
                    d.features["held_externally"] = .flag(true)
                    entry.descriptor = d
                    logProbeFailure(d, rc: rc, first: true, nextMs: delay)
                }
                entries[id] = entry
                publish(.arrived(d))
            }
        }
    }

    private func logProbeFailure(_ d: DeviceDescriptor, rc: Int32, first: Bool, nextMs: Int) {
        if first {
            DefaultDeviceRegistry.logger.info("dongle \(d.serial) (\(d.model)) could not be opened (rtlsdr_open rc \(rc)): another program holds it (rtl_tcp, SDR++, GQRX?); reported IN_USE, re-checking in \(nextMs / 1000) s (backoff up to \(DefaultDeviceRegistry.probeBackoffMaxMs / 1000) s)")
        } else {
            DefaultDeviceRegistry.logger.debug("dongle \(d.serial) still held by another program (rtlsdr_open rc \(rc)); next check in \(nextMs / 1000) s")
        }
    }
}
