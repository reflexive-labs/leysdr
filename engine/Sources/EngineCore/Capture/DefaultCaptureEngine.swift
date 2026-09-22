// SPDX-License-Identifier: GPL-3.0-or-later

// Control-plane half of a capture. Owns the device session, the `CaptureDSPCore` and the channel
// engines; every configuration change ends in a table swap on the core.

import Foundation
import Logging
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
    private static let logger = Logger(label: "leyline.capture")

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
    ///
    /// A failure after `open()` unwinds completely (stream stopped, DSP thread joined, device closed)
    /// so the device can be handed out again and a later `start()` begins from scratch.
    public func start() async throws {
        guard !started else { return }
        try await device.open()
        // Marked started as soon as the device is open, before the awaits below: a `stop()` that
        // interleaves must see a capture that owns an open device, and `beginStreaming` reads this
        // flag to know whether the engine still wants a stream. The catch clears it again.
        started = true
        do {
            // Keep frequency last. HackRF Pro firmware 2026.01.3 can leave the RF tuner at the
            // wrong offset when its sample clock changes, even though both libhackrf calls report
            // success. Configuring rate -> frequency makes the final write repair that offset;
            // frequency -> rate was the cause of apparently strong but wholly garbled NFM audio.
            // This matches hackrf_transfer's ordering and is harmless for other RadioDevices.
            try await device.setSampleRate(sampleRate)
            try await device.tune(centerHz: centerHz)
            core.startThread()
            try await beginStreaming()
        } catch {
            if streaming {
                await device.stopStreaming()
                streaming = false
            }
            core.stopThread()
            await device.close()
            started = false
            throw error
        }
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
        // The channel resets below touch state the DSP thread owns, so wait for the blocks the
        // stopped device left behind to finish going through it. A quiet ring returns at once; a
        // busy one can outlast the wait, which is bounded and reports that it gave up.
        let drained = await core.drainPending()
        // Each await here is a seam another actor method can slip through: `stop()` and
        // `setSampleRate` both reach the same device. If the engine no longer wants a stream, or
        // someone else already started one, leave the device alone.
        guard started, !streaming else { return }
        core.expectNewAnchor()
        if drained || !core.isRunning {
            // No DSP thread means nothing is in flight, whatever the drain said.
            for id in channelOrder {
                await channelTable[id]?.captureStreamRestarted()
                guard started, !streaming else { return }
            }
        } else {
            DefaultCaptureEngine.logger.warning("channel reset skipped: a block is still in flight after the drain deadline; resetting a channel under the DSP thread would race it")
        }
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

    /// Restarts the stream at a new rate: the ring backlog is drained, the sample index continues
    /// (the core rebases the device's restarted index), a new anchor is published, and every
    /// channel is re-planned.
    public func setSampleRate(_ hz: UInt64) async throws {
        guard !detached else { throw EngineError.deviceDetached(deviceID.description) }
        let wasStreaming = streaming
        if wasStreaming {
            await device.stopStreaming()
            streaming = false
            // Let the DSP thread finish the old-rate backlog before the new plan is installed.
            await core.drainPending()
        }
        do {
            try await device.setSampleRate(hz)
        } catch {
            // The device refused the rate: put the stream back at the old rate so the capture
            // stays live, or report it detached if the device will not stream any more.
            if wasStreaming { await restoreStreamingOrDetach() }
            throw error
        }
        sampleRate = hz
        core.sampleRate = hz
        for id in channelOrder {
            await channelTable[id]?.captureRateChanged(hz)
        }
        if wasStreaming {
            do {
                try await beginStreaming()
            } catch {
                await restoreStreamingOrDetach()
                throw error
            }
        }
    }

    /// One attempt to bring the stream back after a failed rate change; on failure the capture is
    /// marked detached so `snapshot` tells the truth about a device that no longer streams.
    private func restoreStreamingOrDetach() async {
        do {
            try await beginStreaming()
        } catch {
            detached = true
        }
    }

    public func setGain(element: String, value: GainValue) async throws {
        guard !detached else { throw EngineError.deviceDetached(deviceID.description) }
        try await device.setGain(element: element, value: value)
    }

    // MARK: Channels

    /// Creates a channel at the current rate/centre and registers its slot with the DSP thread.
    /// - Throws: `OFFSET_OUT_OF_CAPTURE`, `INVALID_ARGUMENT`, `MODE_UNSUPPORTED`.
    public func addChannel(_ config: ChannelConfig) async throws -> any ChannelEngine {
        let engine = try DefaultChannelEngine(captureID: id, captureRate: sampleRate, centerHz: centerHz, config: config,
                                              floor: core.floor)
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
        // Preserve start()'s rate-before-frequency invariant after a hot-plug rebound. In
        // particular, do not let restoring the sample clock be the last write to a HackRF Pro.
        try await newDevice.setSampleRate(sampleRate)
        try await newDevice.tune(centerHz: centerHz)
        if !core.isRunning { core.startThread() }
        // Marked before the restart for the same reason `start()` does it: the engine owns an open
        // device from here, and `beginStreaming` leaves the device alone unless the engine wants a
        // stream. A throw leaves it set, which is what `stop()` needs to close the device it opened.
        started = true
        try await beginStreaming()
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
