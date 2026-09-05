// Control-plane half of a capture. Owns the device session, the `CaptureDSPCore` and the channel
// engines; every configuration change ends in a table swap on the core.

import Foundation
import Synchronization

/// Default `CaptureEngine`: one device, one DSP thread, N channels, spectrum ladder, taps.
public actor DefaultCaptureEngine: CaptureEngine {
    public nonisolated let id: CaptureID
    private nonisolated let deviceIDBox: LockedValue<DeviceID>
    /// Hot-path core (ring, tables, DSP thread). Exposed for tests and the S2 harness.
    public nonisolated let core: CaptureDSPCore

    private var device: any RadioDevice
    private var centerHz: UInt64
    private var sampleRate: UInt64
    private var detached = false
    private var started = false
    private var streaming = false
    private var channelTable: [ChannelID: DefaultChannelEngine] = [:]
    private var channelOrder: [ChannelID] = []
    private var tapTable: [any CaptureTap] = []

    public init(id: CaptureID = CaptureID(), device: any RadioDevice, centerHz: UInt64, sampleRate: UInt64) {
        self.id = id
        self.device = device
        self.centerHz = centerHz
        self.sampleRate = sampleRate
        deviceIDBox = LockedValue(device.descriptor.id)
        core = CaptureDSPCore(captureID: id, sampleRate: sampleRate, centerHz: centerHz)
    }

    public nonisolated var deviceID: DeviceID { deviceIDBox.value }
    public nonisolated var spectrum: any SpectrumLadder { core.ladder }
    /// Anchors published so far and to come (first block, rate change, rebound). Single consumer.
    public nonisolated var anchorEvents: AsyncStream<CaptureAnchor> { core.anchorEvents }
    /// Ring/DSP counters.
    public nonisolated var stats: CaptureStats { core.stats }

    public var snapshot: CaptureSnapshot {
        CaptureSnapshot(centerHz: centerHz, sampleRate: sampleRate, detached: detached, anchor: core.anchor, gains: device.gains)
    }

    // MARK: Lifecycle

    /// Opens and configures the device, starts the DSP thread and streaming. Idempotent once started.
    public func start() async throws {
        guard !started else { return }
        try await device.open()
        try await device.tune(centerHz: centerHz)
        try await device.setSampleRate(sampleRate)
        core.startThread()
        try await beginStreaming()
        started = true
    }

    /// Stops streaming, closes the device, joins the DSP thread, closes channels and taps.
    public func stop() async {
        if streaming {
            await device.stopStreaming()
            streaming = false
        }
        if started { await device.close() }
        started = false
        core.setChannels([])
        core.setTaps([])
        core.stopThread()
        for id in channelOrder {
            await channelTable[id]?.close()
        }
        channelTable = [:]
        channelOrder = []
        let taps = tapTable
        tapTable = []
        for t in taps { await t.closeTap() }
        core.finish()
    }

    private func beginStreaming() async throws {
        let core = self.core
        core.expectNewAnchor()
        try await device.startStreaming(captureID: id) { buffer, time in core.deliver(buffer, at: time) }
        streaming = true
    }

    // MARK: Device control

    /// Retunes the device without restarting the stream; channels keep their absolute frequency.
    public func retune(centerHz: UInt64) async throws {
        guard !detached else { throw EngineError.deviceDetached(deviceID.description) }
        try await device.tune(centerHz: centerHz)
        self.centerHz = centerHz
        core.centerHz = centerHz
        for id in channelOrder {
            await channelTable[id]?.captureMoved(newCenterHz: centerHz)
        }
    }

    /// Restarts the stream at a new rate: the sample index continues, a new anchor is published,
    /// and every channel is re-planned.
    public func setSampleRate(_ hz: UInt64) async throws {
        guard !detached else { throw EngineError.deviceDetached(deviceID.description) }
        let wasStreaming = streaming
        if wasStreaming {
            await device.stopStreaming()
            streaming = false
        }
        try await device.setSampleRate(hz)
        sampleRate = hz
        core.sampleRate = hz
        for id in channelOrder {
            await channelTable[id]?.captureRateChanged(hz)
        }
        if wasStreaming { try await beginStreaming() }
    }

    public func setGain(element: String, value: GainValue) async throws {
        guard !detached else { throw EngineError.deviceDetached(deviceID.description) }
        try await device.setGain(element: element, value: value)
    }

    // MARK: Channels

    /// Creates a channel at the current rate/centre and registers its slot with the DSP thread.
    /// - Throws: `OFFSET_OUT_OF_CAPTURE`, `INVALID_ARGUMENT`, `MODE_UNSUPPORTED`.
    public func addChannel(_ config: ChannelConfig) async throws -> any ChannelEngine {
        let engine = try DefaultChannelEngine(captureID: id, captureRate: sampleRate, centerHz: centerHz, config: config)
        channelTable[engine.id] = engine
        channelOrder.append(engine.id)
        publishChannels()
        return engine
    }

    public func removeChannel(_ id: ChannelID) async {
        guard let engine = channelTable.removeValue(forKey: id) else { return }
        channelOrder.removeAll { $0 == id }
        publishChannels()
        await engine.close()
    }

    public func channel(id: ChannelID) async -> (any ChannelEngine)? { channelTable[id] }

    public var channels: [any ChannelEngine] { channelOrder.compactMap { channelTable[$0] } }

    private func publishChannels() {
        core.setChannels(channelOrder.compactMap { channelTable[$0]?.slot })
    }

    // MARK: Taps

    public func addTap(_ tap: any CaptureTap) async {
        tapTable.append(tap)
        core.setTaps(tapTable)
    }

    public func removeTap(id: StreamID) async {
        guard let i = tapTable.firstIndex(where: { $0.id == id }) else { return }
        let tap = tapTable.remove(at: i)
        core.setTaps(tapTable)
        await tap.closeTap()
    }

    // MARK: Device loss

    /// The device vanished: mark detached and stop the (dead) stream. Channels and index are kept.
    public func deviceLost() async {
        detached = true
        if streaming {
            await device.stopStreaming()
            streaming = false
        }
    }

    /// A matching device came back: adopt it, restore centre/rate, restart the stream with a new
    /// anchor. The `CaptureID` and sample index continue.
    public func deviceRebound(_ newDevice: any RadioDevice) async throws {
        device = newDevice
        deviceIDBox.value = newDevice.descriptor.id
        try await newDevice.open()
        try await newDevice.tune(centerHz: centerHz)
        try await newDevice.setSampleRate(sampleRate)
        if !core.isRunning { core.startThread() }
        try await beginStreaming()
        started = true
        detached = false
    }
}

/// A tiny lock-guarded box for values read from nonisolated accessors.
public final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    public init(_ value: T) { stored = value }

    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
