// DefaultDeviceRegistry: discovers RTL-SDR dongles by polling, hosts file playback devices, and
// hands out stable DeviceIDs keyed by USB identity so replugs keep their id.

import Foundation

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
    }

    public let persistPath: String?
    public let pollIntervalMs: Int

    private let hub = DeviceEventHub()
    private var entries: [DeviceID: Entry] = [:]
    private var idMap = DeviceIDMap()
    private var pollTask: Task<Void, Never>?
    private var started = false

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
        entries[id] = Entry(descriptor: descriptor, device: device, rtlIndex: nil, key: key)
        publish(.arrived(descriptor))
        return descriptor
    }

    /// Whether `id` names a hosted file-playback device that clients may detach: the entry exists,
    /// it is not a USB dongle (`rtlIndex == nil`) and its driver is `file`. Operator-configured
    /// virtual devices (rtl_tcp) are hosted the same way but are not client-detachable. Non-mutating,
    /// so callers can reject a request before touching any capture.
    public func isDetachableFileDevice(id: DeviceID) -> Bool {
        guard let entry = entries[id], entry.rtlIndex == nil else { return false }
        return entry.descriptor.driver == FilePlaybackDevice.driverName
    }

    /// Detaches any hosted virtual device (file playback or `attachVirtualDevice`).
    public func detachFileDevice(id: DeviceID) async throws {
        guard let entry = entries[id], entry.rtlIndex == nil else { throw EngineError.deviceNotFound(id.string) }
        entries[id] = nil
        await entry.device.close()
        publish(.removed(id))
    }

    // MARK: Virtual devices

    /// Hosts any non-USB `RadioDevice` (e.g. `RTLTCPDevice`). Identity is `(serial, driver, model)`
    /// of the device's own descriptor; the stable id is minted from that. Devices conforming to
    /// `VirtualDevice` get the registry id assigned and the state-change hook installed so their
    /// own `.disconnected` transitions publish `changed` like an unplug.
    public func attachVirtualDevice(_ device: any RadioDevice) throws -> DeviceDescriptor {
        let provisional = device.descriptor
        let key = DefaultDeviceRegistry.identityKey(serial: provisional.serial, manufacturer: provisional.driver, product: provisional.model)
        if let existing = entries.values.first(where: { $0.key == key && $0.rtlIndex == nil }) {
            return existing.descriptor
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
        entries[id] = Entry(descriptor: descriptor, device: device, rtlIndex: nil, key: key)
        publish(.arrived(descriptor))
        return descriptor
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
    public func markInUse(id: DeviceID, _ inUse: Bool) throws {
        guard var entry = entries[id] else { throw EngineError.deviceNotFound(id.string) }
        guard entry.descriptor.state != .disconnected else { throw EngineError.deviceDetached(id.string) }
        let state: DeviceState = inUse ? .inUse : .available
        guard entry.descriptor.state != state else { return }
        entry.descriptor.state = state
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

    /// Stops polling; hosted devices stay registered.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        started = false
    }

    /// One enumeration pass: diff `RTLSDRDevice.enumerate` against known dongles. The per-device
    /// `rtlsdr_open` probe (tuner type, gain table) runs only for identities never probed
    /// successfully: known dongles keep their cached probe, so idle dongles are not re-initialised
    /// every second and the poll never contends with a capture's own open. A dongle first seen while
    /// busy (degraded probe) is re-probed on later passes while idle and its descriptor refreshed.
    public func poll() {
        let claimed = Set(entries.values.compactMap { e -> UInt32? in
            e.descriptor.state == .inUse ? e.rtlIndex : nil
        })
        // Identity bases (serial/manufacturer/product) that must not be opened by the probe: in use,
        // or already carrying a real tuner/gain table.
        var probed = Set<String>()
        for e in entries.values where e.rtlIndex != nil {
            let base = DefaultDeviceRegistry.identityBase(of: e.key)
            let rtl = e.device as? RTLSDRDevice
            if e.descriptor.state == .inUse || rtl.map({ DefaultDeviceRegistry.isProbed($0.probe) }) == true {
                probed.insert(base)
            }
        }
        let probes = RTLSDRDevice.enumerate(claimed: claimed) { p in
            !probed.contains(DefaultDeviceRegistry.identityKey(serial: p.serial, manufacturer: p.manufacturer, product: p.product))
        }
        applyProbes(probes)
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
            (entry.device as? RTLSDRDevice)?.setState(.disconnected)
            publish(.removed(id))
        }
        // Arrived / changed.
        for (id, (probe, key, collided)) in present {
            if var entry = entries[id] {
                guard let rtl = entry.device as? RTLSDRDevice else { continue }
                if entry.descriptor.state != .inUse, !DefaultDeviceRegistry.isProbed(rtl.probe),
                   DefaultDeviceRegistry.isProbed(probe) {
                    rtl.updateProbe(probe)
                }
                var d = entry.descriptor.state == .inUse ? entry.descriptor : rtl.descriptor
                d.features["serial_collision"] = .flag(collided)
                if entry.descriptor.state == .inUse { continue }
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
                entries[id] = Entry(descriptor: d, device: device, rtlIndex: probe.index, key: key)
                publish(.arrived(d))
            }
        }
    }
}
