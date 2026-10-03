// SPDX-License-Identifier: GPL-3.0-or-later

// Captures: creating and destroying them, sweeps, and the capture events.

import EngineCore
import Foundation
import LeylineProto
import Logging

extension SessionStore {
    // MARK: Captures

    /// RTL-SDR default rate when `sample_rate == 0` (file devices use the recording's rate).
    static let defaultSampleRate: UInt64 = 2_400_000

    func captureProto(_ id: CaptureID) async -> Leyline_V1_Capture? {
        guard let entry = captures[id] else { return nil }
        let snap = await entry.engine.snapshot
        return ProtoMapping.capture(id: id, deviceID: entry.deviceID, snapshot: snap, meta: entry.meta)
    }

    func emitCapture(_ id: CaptureID, by: ClientContext) async {
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

    func refuseIfSwept(_ id: CaptureID) throws {
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
    func touchActivity(_ id: CaptureID, by: ClientContext) {
        guard by.isInteractive, var entry = captures[id] else { return }
        entry.meta.lastInteractiveWriteNs = WallClock.realNowNs()
        captures[id] = entry
    }
}
