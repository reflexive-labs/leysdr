// The don't-disturb policy (invariant 9). Jobs never touch captures; they ask for what they need
// and get a lease or a reason.

import EngineCore
import Foundation
import LeylineProto
import Logging

/// How long after somebody's last interactive write a capture still counts as in use.
let dontDisturbNs: UInt64 = 60_000_000_000

actor SessionCaptureAllocator: CaptureAllocator {
    private let store: SessionStore
    private let log = Logger(label: "leyline.jobs.allocator")
    /// Captures currently leased, so two sweeps never share a radio.
    private var leased: Set<CaptureID> = []

    init(store: SessionStore) { self.store = store }

    func allocate(_ request: AllocationRequest, for job: JobID) async -> AllocationResult {
        switch request {
        case .channel:
            // Watch jobs land here (Milestone D.15). A sweep is the only caller today.
            return .declined(code: "UNIMPLEMENTED", reason: "channel allocation arrives with watch jobs")
        case .exclusiveCapture(let range, let takeOver):
            return await allocateCapture(range: range, takeOver: takeOver, job: job)
        }
    }

    private func allocateCapture(range: ClosedRange<UInt64>, takeOver: Bool, job: JobID) async -> AllocationResult {
        let state = await store.snapshot(scope: .daemon)
        // A device that can hear any of the range. Prefer one with no capture at all: creating and
        // destroying is cleaner than borrowing and restoring, and it disturbs nobody.
        var candidates: [(Leyline_V1_DeviceDescriptor, Leyline_V1_Capture?)] = []
        for d in state.devices where d.state != .disconnected {
            // What a capture on this device can hear, not just where it can point: a capture
            // centred at the edge of the tuning range still covers half a span either side of it,
            // which is how a file device -- whose range is the single point its recording was made
            // at -- can serve a sweep at all. The same fractions the plan uses.
            let edge = SweepPlan.edgeFraction * Double(bestRate(d))
            let audible = d.tuningRanges.contains { r in
                Double(r.minHz) - edge <= Double(range.upperBound) && Double(r.maxHz) + edge >= Double(range.lowerBound)
            }
            guard audible else { continue }
            candidates.append((d, state.captures.first { $0.deviceID == d.deviceID }))
        }
        guard !candidates.isEmpty else {
            return .declined(code: "NO_DEVICE", reason: "no radio here can tune \(fmt(range.lowerBound)) to \(fmt(range.upperBound))")
        }
        candidates.sort { ($0.1 == nil ? 0 : 1) < ($1.1 == nil ? 0 : 1) }

        var lastReason = "the radio is in use"
        for (device, existing) in candidates {
            guard let deviceID = DeviceID(string: device.deviceID) else { continue }
            if let cap = existing {
                guard let id = CaptureID(string: cap.captureID) else { continue }
                if leased.contains(id) {
                    lastReason = "another scan already has \(device.model)"
                    continue
                }
                if !takeOver, let why = inUse(cap, state: state) {
                    lastReason = why
                    continue
                }
                guard let lease = await borrow(id, deviceID: deviceID, job: job) else { continue }
                return .capture(lease)
            }
            let rate = bestRate(device)
            do {
                let cap = try await store.createCapture(deviceID: deviceID, centerHz: startCentre(range, device: device, rate: rate),
                                                        sampleRate: rate, by: .daemon)
                guard let id = CaptureID(string: cap.captureID), let lease = await borrow(id, deviceID: deviceID, job: job, created: true) else {
                    continue
                }
                return .capture(lease)
            } catch {
                lastReason = (error as? EngineError)?.message ?? "\(error)"
                log.debug("scan could not open \(device.deviceID): \(lastReason)")
            }
        }
        return .declined(code: "DEVICE_BUSY", reason: lastReason)
    }

    /// The don't-disturb test. Returns a reason when the capture is somebody's, nil when it is free.
    private func inUse(_ cap: Leyline_V1_Capture, state: Leyline_V1_GetStateResponse) -> String? {
        let channels = state.channels.filter { $0.captureID == cap.captureID }
        if let ch = channels.first {
            return "\(who(ch.owner)) is listening on \(fmt(absolute(ch, cap)))"
        }
        if cap.activity.liveAudioSinks > 0 { return "audio is playing from this radio" }
        let now = UInt64(realtimeNs())
        let last = UInt64(max(0, cap.activity.lastInteractiveWriteNs))
        if last > 0, now > last, now - last < dontDisturbNs {
            return "somebody was tuning this radio \(Int((now - last) / 1_000_000_000)) s ago"
        }
        return nil
    }

    /// Names a client by what it is rather than by the label it chose: "ley is listening" reads as
    /// nonsense to somebody who typed `ley`.
    private func who(_ ci: Leyline_V1_ClientInfo) -> String {
        switch ci.kind {
        case "cli": return "a terminal"
        case "app": return "the app"
        case "mcp": return "an agent"
        case "job": return "another job"
        default: return ci.label.isEmpty ? "another client" : ci.label
        }
    }

    private func absolute(_ ch: Leyline_V1_Channel, _ cap: Leyline_V1_Capture) -> UInt64 {
        let hz = Int64(cap.centerHz) + ch.offsetHz
        return hz > 0 ? UInt64(hz) : cap.centerHz
    }

    private func borrow(_ id: CaptureID, deviceID: DeviceID, job: JobID, created: Bool = false) async -> SessionCaptureLease? {
        guard let engine = await store.captureEngine(id) else { return nil }
        let device = await store.registry.device(id: deviceID)
        let snap = await engine.snapshot
        leased.insert(id)
        let lease = SessionCaptureLease(captureID: id, engine: engine, store: store,
                                        sampleRateHz: snap.sampleRate, entryCenterHz: snap.centerHz,
                                        gainElements: device?.descriptor.gainElements ?? [],
                                        inFlight: device?.inFlightSamples ?? 0,
                                        createdByLease: created, job: job) { [weak self] in
            await self?.releaseLease(id)
        }
        await lease.pinGain()
        return lease
    }

    private func releaseLease(_ id: CaptureID) { leased.remove(id) }

    /// The fastest rate the device offers: fewer steps, and the detector's resolution comes from
    /// the bin count rather than the span.
    private func bestRate(_ d: Leyline_V1_DeviceDescriptor) -> UInt64 { d.sampleRates.max() ?? 0 }

    /// Where to point the radio when the allocator creates the capture. The sweep retunes from
    /// here immediately, so this only has to be somewhere the device accepts; aiming at the middle
    /// of the range and clamping to the nearest tunable point keeps the first hop short.
    private func startCentre(_ range: ClosedRange<UInt64>, device: Leyline_V1_DeviceDescriptor, rate _: UInt64) -> UInt64 {
        let want = range.lowerBound + (range.upperBound - range.lowerBound) / 2
        var best: UInt64?
        var bestDistance = UInt64.max
        for r in device.tuningRanges {
            let clamped = Swift.min(Swift.max(want, r.minHz), Swift.max(r.minHz, r.maxHz))
            let d = clamped > want ? clamped - want : want - clamped
            if d < bestDistance {
                bestDistance = d
                best = clamped
            }
        }
        return best ?? want
    }

    private func fmt(_ hz: UInt64) -> String { String(format: "%.3f MHz", Double(hz) / 1e6) }
}

/// One job's hold on one capture.
actor SessionCaptureLease: CaptureLease {
    nonisolated let captureID: CaptureID
    nonisolated let sampleRateHz: UInt64
    nonisolated var spectrum: any SpectrumLadder { engine.spectrum }

    private let engine: DefaultCaptureEngine
    private let store: SessionStore
    private let inFlight: UInt64
    private let createdByLease: Bool
    private let job: JobID
    private let onRelease: @Sendable () async -> Void
    private var entryCenterHz: UInt64
    private var entryGains: [GainState] = []
    private var pinned: [GainState] = []
    private var released = false
    private let log = Logger(label: "leyline.jobs.lease")

    private let gainElements: [GainElement]

    init(captureID: CaptureID, engine: DefaultCaptureEngine, store: SessionStore,
         sampleRateHz: UInt64, entryCenterHz: UInt64, gainElements: [GainElement], inFlight: UInt64,
         createdByLease: Bool, job: JobID, onRelease: @escaping @Sendable () async -> Void)
    {
        self.captureID = captureID
        self.engine = engine
        self.store = store
        self.sampleRateHz = sampleRateHz
        self.entryCenterHz = entryCenterHz
        self.gainElements = gainElements
        self.inFlight = inFlight
        self.createdByLease = createdByLease
        self.job = job
        self.onRelease = onRelease
    }

    var centerHz: UInt64 { get async { await engine.snapshot.centerHz } }

    var pinnedGains: [GainState] { pinned }

    var sampleIndex: UInt64 { engine.stats.samplesProcessed }

    /// The settle window: what the driver has already asked for plus what is sitting in the
    /// capture's ring, both of which were captured before the retune and arrive after it.
    var settleSamples: UInt64 {
        let s = engine.stats
        let backlog = s.blocksReceived > s.blocksProcessed ? s.blocksReceived - s.blocksProcessed : 0
        return inFlight + backlog * UInt64(CaptureDSPCore.blockSize) + sampleRateHz / 200
    }

    /// Freezes the tuner's gain for the sweep. Under AGC the gain moves after every hop and SNR
    /// measured against a moving reference is not a number.
    func pinGain() async {
        entryGains = await engine.snapshot.gains
        for g in entryGains where g.value == .auto {
            let level = midpoint(element: g.element)
            do {
                try await engine.setGain(element: g.element, value: .db(level))
            } catch {
                log.debug("scan could not pin \(g.element) gain: \(error)")
            }
        }
        pinned = await engine.snapshot.gains
    }

    /// A gain to freeze at when the driver was in auto and will not say what it settled on: the
    /// middle of the element's range. Never the minimum, which deafens the radio.
    private func midpoint(element: String) -> Double {
        guard let d = gainElements.first(where: { $0.name == element }) else { return 0 }
        if !d.validDB.isEmpty {
            return d.validDB[d.validDB.count / 2]
        }
        return (d.minDB + d.maxDB) / 2
    }

    func retune(centerHz: UInt64) async throws {
        guard !released else { throw EngineError.captureNotFound(captureID.string) }
        try await engine.retune(centerHz: centerHz)
        await store.publishCapture(captureID)
    }

    func release() async {
        guard !released else { return }
        released = true
        if createdByLease {
            await store.destroyCapture(id: captureID, by: .daemon)
        } else {
            try? await engine.retune(centerHz: entryCenterHz)
            for g in entryGains {
                try? await engine.setGain(element: g.element, value: g.value)
            }
            await store.publishCapture(captureID)
        }
        await onRelease()
    }
}
