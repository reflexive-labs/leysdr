// SPDX-License-Identifier: GPL-3.0-or-later

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
        case .channel(let frequencyHz, let bandwidthHz, let mode, let deviceID, let takeOver):
            return await allocateChannel(frequencyHz: frequencyHz, bandwidthHz: bandwidthHz, mode: mode,
                                         deviceID: deviceID, takeOver: takeOver, job: job)
        case .captureIQ(let frequencyHz, let sampleRateHz, let deviceID, let takeOver):
            return await allocateCaptureIQ(frequencyHz: frequencyHz, sampleRateHz: sampleRateHz,
                                           deviceID: deviceID, takeOver: takeOver, job: job)
        case .exclusiveCapture(let range, let deviceID, let takeOver, let gain):
            return await allocateCapture(range: range, deviceID: deviceID, takeOver: takeOver, gain: gain, job: job)
        }
    }

    // MARK: One channel (decode jobs, and watch jobs from D.15)

    /// The order and the reasons are the design doc's (docs/design/decoders.md, "Decisions": "A
    /// decode job is a job"): a capture that already covers the frequency on any device, else a
    /// device with no capture, else a capture the don't-disturb test calls free, else a decline
    /// naming who has the radio.
    private func allocateChannel(frequencyHz: UInt64, bandwidthHz: UInt32, mode: DemodMode,
                                 deviceID wanted: DeviceID?, takeOver: Bool, job: JobID) async -> AllocationResult
    {
        let state = await store.snapshot(scope: .daemon)
        let bw = bandwidthHz == 0 ? mode.defaultBandwidthHz : bandwidthHz
        let owner = ClientContext.job(job)
        var sawDevice = false
        var lastReason = "no radio here can hear \(fmt(frequencyHz))"

        // 1. A capture that already covers the frequency. This disturbs nobody: the channel sits
        //    inside a span somebody is already listening to.
        for cap in state.captures {
            if let want = wanted, cap.deviceID != want.string { continue }
            guard let id = CaptureID(string: cap.captureID), !leased.contains(id) else { continue }
            sawDevice = true
            let offset = Int64(frequencyHz) - Int64(cap.centerHz)
            guard SessionStore.fits(offsetHz: offset, bandwidthHz: bw, sampleRate: cap.sampleRate) else { continue }
            if let lease = await open(captureID: id, offsetHz: offset, bandwidthHz: bw, mode: mode,
                                      frequencyHz: frequencyHz, owner: owner, createdCapture: false,
                                      restoreCenterHz: nil) {
                return .channel(lease)
            }
        }

        // 2. A radio with nothing on it. The capture is centred a quarter-span below the channel,
        //    so the channel sits clear of the tuner's own DC spike and inside the flat part of the
        //    passband.
        for device in state.devices where device.state != .disconnected {
            if let want = wanted, device.deviceID != want.string { continue }
            guard state.captures.first(where: { $0.deviceID == device.deviceID }) == nil else { continue }
            guard let deviceID = DeviceID(string: device.deviceID) else { continue }
            sawDevice = true
            let rate = defaultRate(device)
            guard let centre = channelCentre(frequencyHz: frequencyHz, bandwidthHz: bw, device: device, rate: rate) else {
                lastReason = "\(device.model) cannot tune \(fmt(frequencyHz))"
                continue
            }
            do {
                let id = try await store.createCapture(deviceID: deviceID, centerHz: centre, sampleRate: rate, by: .daemon).id
                if let lease = await open(captureID: id, offsetHz: Int64(frequencyHz) - Int64(centre), bandwidthHz: bw,
                                          mode: mode, frequencyHz: frequencyHz, owner: owner, createdCapture: true,
                                          restoreCenterHz: nil) {
                    return .channel(lease)
                }
                await store.destroyCapture(id: id, by: .daemon)
            } catch {
                lastReason = (error as? EngineError)?.message ?? "\(error)"
                log.debug("decode job could not open \(device.deviceID): \(lastReason)")
            }
        }

        // 3. A capture nobody is using, retuned. This is the first step that disturbs anything, so
        //    it is the last one tried.
        for cap in state.captures {
            if let want = wanted, cap.deviceID != want.string { continue }
            guard let id = CaptureID(string: cap.captureID), !leased.contains(id) else { continue }
            if !takeOver, let why = inUse(cap, state: state) {
                lastReason = why
                continue
            }
            guard let device = state.devices.first(where: { $0.deviceID == cap.deviceID }),
                  let centre = channelCentre(frequencyHz: frequencyHz, bandwidthHz: bw, device: device, rate: cap.sampleRate),
                  let engine = await store.captureEngine(id) else { continue }
            let before = cap.centerHz
            do {
                try await engine.retune(centerHz: centre)
            } catch {
                lastReason = (error as? EngineError)?.message ?? "\(error)"
                continue
            }
            await store.publishCapture(id)
            if let lease = await open(captureID: id, offsetHz: Int64(frequencyHz) - Int64(centre), bandwidthHz: bw,
                                      mode: mode, frequencyHz: frequencyHz, owner: owner, createdCapture: false,
                                      restoreCenterHz: before) {
                return .channel(lease)
            }
            try? await engine.retune(centerHz: before)
            await store.publishCapture(id)
        }
        return .declined(code: sawDevice ? EngineError.Code.deviceBusy : EngineError.Code.noDevice, reason: lastReason)
    }

    // MARK: One capture read as IQ (an IQ decode job, DecoderSignal SIGNAL_IQ)

    /// The same order and reasons as `allocateChannel` (docs/design/decoders.md, "Multiplexing"),
    /// but an IQ decoder receives the whole capture band, so "covers the frequency" is the capture
    /// span rather than a channel fit, and a created capture is centred on the frequency. The
    /// don't-disturb `inUse` check, the `take_over` semantics and the NO_DEVICE / DEVICE_BUSY
    /// declines are unchanged. IQ captures are shareable in principle, so a reused one is never
    /// added to the exclusive `leased` set; a sweep's capture (which is) is still left alone.
    private func allocateCaptureIQ(frequencyHz: UInt64, sampleRateHz wantedRate: UInt64,
                                   deviceID wanted: DeviceID?, takeOver: Bool, job: JobID) async -> AllocationResult
    {
        let state = await store.snapshot(scope: .daemon)
        var sawDevice = false
        var lastReason = "no radio here can hear \(fmt(frequencyHz))"

        // 1. A capture whose span already covers the frequency. This disturbs nobody: the decoder
        //    reads a band somebody is already listening to.
        for cap in state.captures {
            if let want = wanted, cap.deviceID != want.string { continue }
            guard let id = CaptureID(string: cap.captureID), !leased.contains(id) else { continue }
            sawDevice = true
            guard spanCovers(centerHz: cap.centerHz, rate: cap.sampleRate, frequencyHz: frequencyHz),
                  let engine = await store.captureEngine(id) else { continue }
            return .captureIQ(SessionCaptureIQLease(captureID: id, capture: engine, sampleRateHz: cap.sampleRate,
                                                    createdCapture: false, store: store))
        }

        // 2. A radio with nothing on it. The capture is centred on the frequency (clamped to a
        //    tunable point) so the whole band the decoder wants sits inside the span.
        for device in state.devices where device.state != .disconnected {
            if let want = wanted, device.deviceID != want.string { continue }
            guard state.captures.first(where: { $0.deviceID == device.deviceID }) == nil else { continue }
            guard let deviceID = DeviceID(string: device.deviceID) else { continue }
            sawDevice = true
            let rate = iqRate(wantedRate, device: device)
            guard let centre = iqCentre(frequencyHz: frequencyHz, device: device, rate: rate) else {
                lastReason = "\(device.model) cannot tune \(fmt(frequencyHz))"
                continue
            }
            do {
                let id = try await store.createCapture(deviceID: deviceID, centerHz: centre, sampleRate: rate, by: .daemon).id
                guard let engine = await store.captureEngine(id) else {
                    await store.destroyCapture(id: id, by: .daemon)
                    continue
                }
                return .captureIQ(SessionCaptureIQLease(captureID: id, capture: engine, sampleRateHz: rate,
                                                        createdCapture: true, store: store))
            } catch {
                lastReason = (error as? EngineError)?.message ?? "\(error)"
                log.debug("iq decode job could not open \(device.deviceID): \(lastReason)")
            }
        }

        // 3. A capture nobody is using, retuned onto the frequency. The first step that disturbs
        //    anything, so it is last. It is reused, not created, so the lease leaves it on release.
        for cap in state.captures {
            if let want = wanted, cap.deviceID != want.string { continue }
            guard let id = CaptureID(string: cap.captureID), !leased.contains(id) else { continue }
            if !takeOver, let why = inUse(cap, state: state) {
                lastReason = why
                continue
            }
            guard let device = state.devices.first(where: { $0.deviceID == cap.deviceID }),
                  let centre = iqCentre(frequencyHz: frequencyHz, device: device, rate: cap.sampleRate),
                  let engine = await store.captureEngine(id) else { continue }
            do {
                try await engine.retune(centerHz: centre)
            } catch {
                lastReason = (error as? EngineError)?.message ?? "\(error)"
                continue
            }
            await store.publishCapture(id)
            return .captureIQ(SessionCaptureIQLease(captureID: id, capture: engine, sampleRateHz: cap.sampleRate,
                                                    createdCapture: false, store: store))
        }
        return .declined(code: sawDevice ? EngineError.Code.deviceBusy : EngineError.Code.noDevice, reason: lastReason)
    }

    /// Whether a capture centred at `centerHz` running at `rate` covers `frequencyHz` at all: the
    /// frequency inside [centre - rate/2, centre + rate/2]. An IQ decoder takes the whole span, so
    /// this is the reuse test rather than the channel-fit `SessionStore.fits`.
    private func spanCovers(centerHz: UInt64, rate: UInt64, frequencyHz: UInt64) -> Bool {
        let half = Int64(rate / 2)
        let f = Int64(frequencyHz)
        return f >= Int64(centerHz) - half && f <= Int64(centerHz) + half
    }

    /// The rate for a created IQ capture: what the recipe asked for when the device offers it, else
    /// the device's default (`defaultRate`), matching what a channel job opens at.
    private func iqRate(_ wanted: UInt64, device: Leyline_V1_DeviceDescriptor) -> UInt64 {
        if wanted != 0, device.sampleRates.isEmpty || device.sampleRates.contains(wanted) { return wanted }
        return defaultRate(device)
    }

    /// Where to point an IQ capture: on the frequency, clamped to the nearest tunable point. A file
    /// device's range is the single point its recording was made at, and the frequency still falls
    /// inside the span there. nil when the frequency would fall outside the span even so.
    private func iqCentre(frequencyHz: UInt64, device: Leyline_V1_DeviceDescriptor, rate: UInt64) -> UInt64? {
        var best: UInt64?
        var bestDistance = UInt64.max
        for r in device.tuningRanges {
            let clamped = Swift.min(Swift.max(frequencyHz, r.minHz), Swift.max(r.minHz, r.maxHz))
            let d = clamped > frequencyHz ? clamped - frequencyHz : frequencyHz - clamped
            if d < bestDistance {
                bestDistance = d
                best = clamped
            }
        }
        guard let centre = best, spanCovers(centerHz: centre, rate: rate, frequencyHz: frequencyHz) else { return nil }
        return centre
    }

    /// Where to point a capture so the channel lands a quarter-span off centre, clamped to what the
    /// device can tune -- a file device's range is the single point its recording was made at, and
    /// the channel still fits inside the span. nil when the channel would fall outside it.
    private func channelCentre(frequencyHz: UInt64, bandwidthHz: UInt32,
                               device: Leyline_V1_DeviceDescriptor, rate: UInt64) -> UInt64?
    {
        let quarter = rate / 8
        let desired = frequencyHz > quarter ? frequencyHz - quarter : frequencyHz
        var best: UInt64?
        var bestDistance = UInt64.max
        for r in device.tuningRanges {
            let clamped = Swift.min(Swift.max(desired, r.minHz), Swift.max(r.minHz, r.maxHz))
            let d = clamped > desired ? clamped - desired : desired - clamped
            if d < bestDistance {
                bestDistance = d
                best = clamped
            }
        }
        guard let centre = best else { return nil }
        guard SessionStore.fits(offsetHz: Int64(frequencyHz) - Int64(centre), bandwidthHz: bandwidthHz, sampleRate: rate) else { return nil }
        return centre
    }

    private func open(captureID: CaptureID, offsetHz: Int64, bandwidthHz: UInt32, mode: DemodMode,
                      frequencyHz: UInt64, owner: ClientContext, createdCapture: Bool,
                      restoreCenterHz: UInt64?) async -> SessionChannelLease?
    {
        do {
            let proto = try await store.createChannel(captureID: captureID, offsetHz: offsetHz, bandwidthHz: bandwidthHz,
                                                      mode: ProtoMapping.demodMode(mode), persistent: true,
                                                      requiredHz: frequencyHz, by: owner)
            guard let channelID = ChannelID(string: proto.channelID),
                  let engine = await store.channelEngine(channelID) else { return nil }
            return SessionChannelLease(channelID: channelID, captureID: captureID, engine: engine, store: store,
                                       createdCapture: createdCapture, restoreCenterHz: restoreCenterHz, owner: owner)
        } catch {
            log.debug("decode job could not open a channel on \(captureID.string): \(error)")
            return nil
        }
    }

    private func allocateCapture(range: ClosedRange<UInt64>, deviceID wanted: DeviceID?, takeOver: Bool,
                                 gain: GainRequest?, job: JobID) async -> AllocationResult
    {
        let state = await store.snapshot(scope: .daemon)
        // A device that can hear any of the range. Prefer one with no capture at all: creating and
        // destroying is cleaner than borrowing and restoring, and it disturbs nobody.
        var candidates: [(Leyline_V1_DeviceDescriptor, Leyline_V1_Capture?)] = []
        for d in state.devices where d.state != .disconnected {
            if let want = wanted, d.deviceID != want.string { continue }
            // What a capture on this device can cover, not just where it can point: a capture
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
            if let want = wanted {
                return .declined(code: EngineError.Code.noDevice, reason: "\(want.string) cannot tune \(fmt(range.lowerBound)) to \(fmt(range.upperBound)), or is not here")
            }
            return .declined(code: EngineError.Code.noDevice, reason: "no radio here can tune \(fmt(range.lowerBound)) to \(fmt(range.upperBound))")
        }
        candidates.sort { ($0.1 == nil ? 0 : 1) < ($1.1 == nil ? 0 : 1) }

        var lastReason = "the radio is in use"
        for (device, existing) in candidates {
            guard let deviceID = DeviceID(string: device.deviceID) else { continue }
            if let cap = existing {
                guard let id = CaptureID(string: cap.captureID) else { continue }
                if !takeOver, let why = inUse(cap, state: state) {
                    lastReason = why
                    continue
                }
                // Claim before any await. `borrow` suspends three times, and an actor is
                // re-entrant at a suspension: checking here and inserting in there let two
                // simultaneous scans both pass the check and both walk the same tuner.
                guard leased.insert(id).inserted else {
                    lastReason = "another scan already has \(device.model)"
                    continue
                }
                guard let lease = await borrow(id, deviceID: deviceID, job: job, gain: gain) else {
                    leased.remove(id)
                    continue
                }
                return .capture(lease)
            }
            let rate = bestRate(device)
            // The device has no capture, so nothing to claim yet -- but two scans racing here would
            // both call createCapture and the loser gets DEVICE_BUSY from the store, which is the
            // right answer and is caught below.
            do {
                let id = try await store.createCapture(deviceID: deviceID, centerHz: startCentre(range, device: device, rate: rate),
                                                       sampleRate: rate, by: .daemon).id
                // Every path out of here from now on either returns the lease or destroys what was
                // just created: a capture this scan opened and then walked away from would hold the
                // device open with no job to cancel and nobody to close it.
                guard leased.insert(id).inserted else {
                    await store.destroyCapture(id: id, by: .daemon)
                    continue
                }
                guard let lease = await borrow(id, deviceID: deviceID, job: job, created: true, gain: gain) else {
                    leased.remove(id)
                    await store.destroyCapture(id: id, by: .daemon)
                    continue
                }
                return .capture(lease)
            } catch {
                lastReason = (error as? EngineError)?.message ?? "\(error)"
                log.debug("scan could not open \(device.deviceID): \(lastReason)")
            }
        }
        return .declined(code: EngineError.Code.deviceBusy, reason: lastReason)
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

    /// Describes a client by its kind rather than the label it chose: "ley is listening" makes no
    /// sense to a user who typed `ley`.
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

    private func borrow(_ id: CaptureID, deviceID: DeviceID, job: JobID, created: Bool = false,
                        gain: GainRequest? = nil) async -> SessionCaptureLease?
    {
        guard let engine = await store.captureEngine(id) else { return nil }
        let device = await store.registry.device(id: deviceID)
        let snap = await engine.snapshot
        let lease = SessionCaptureLease(captureID: id, engine: engine, store: store,
                                        sampleRateHz: snap.sampleRate, entryCenterHz: snap.centerHz,
                                        gainElements: device?.descriptor.gainElements ?? [],
                                        inFlight: device?.inFlightSamples ?? 0,
                                        createdByLease: created, job: job) { [weak self] in
            await self?.releaseLease(id)
        }
        await store.setSwept(id, true)
        await lease.pinGain(device: device, requested: gain)
        return lease
    }

    private func releaseLease(_ id: CaptureID) { leased.remove(id) }

    /// The fastest rate the device offers: fewer steps, and the detector's resolution comes from
    /// the bin count rather than the span.
    private func bestRate(_ d: Leyline_V1_DeviceDescriptor) -> UInt64 { d.sampleRates.max() ?? 0 }

    /// The rate a capture for one channel opens at: what `CreateCapture` picks for `sample_rate
    /// == 0`, the recording's own rate for a file and 2.4 MSPS for a dongle. Not the fastest the
    /// device offers, which a sweep wants: an RTL-SDR at 3.2 MSPS drops samples over USB, and the
    /// channel's audio rate follows the capture rate (49.2 kHz at 3.2 MSPS against the 48 kHz a
    /// decoder written for the default expects).
    private func defaultRate(_ d: Leyline_V1_DeviceDescriptor) -> UInt64 {
        if d.driver == "file" { return d.sampleRates.first ?? SessionStore.defaultSampleRate }
        if d.sampleRates.isEmpty || d.sampleRates.contains(SessionStore.defaultSampleRate) { return SessionStore.defaultSampleRate }
        return bestRate(d)
    }

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
    /// Why a requested gain could not be applied, for the job to fail with. A sweep that ran at
    /// some other gain than the one asked for would report a measurement nobody requested.
    private(set) var pinFailure: EngineError?
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
    /// measured against a moving reference is meaningless. `requested` sets where to pin: a
    /// level, or auto for where the driver settles; nil pins the gain the radio is on.
    func pinGain(device: (any RadioDevice)?, requested: GainRequest? = nil) async {
        entryGains = await engine.snapshot.gains
        if let requested {
            let element = requested.element.isEmpty ? (gainElements.first?.name ?? requested.element) : requested.element
            do {
                try await engine.setGain(element: element, value: requested.value)
                if requested.value == .auto {
                    // Give the driver's AGC a moment to settle before asking where it did.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            } catch {
                pinFailure = error as? EngineError ?? EngineError.invalidArgument("\(error)", target: element)
            }
        }
        for g in await engine.snapshot.gains where g.value == .auto {
            // Where AGC actually settled, so the sweep is exactly as sensitive as the radio was a
            // moment ago. Only when the driver cannot report it does this fall back to the middle
            // of the element's range, an estimate that can be 20 dB off on a quiet band.
            let level = await device?.settledGainDB(element: g.element) ?? midpoint(element: g.element)
            do {
                try await engine.setGain(element: g.element, value: .db(level))
            } catch {
                log.debug("scan could not pin \(g.element) gain: \(error)")
            }
        }
        pinned = await engine.snapshot.gains
    }

    /// Where to freeze when the driver does not report where auto settled: the middle of the
    /// element's range. Never the minimum, which deafens the radio.
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
        await store.setSwept(captureID, false)
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

/// One job's hold on one channel. Release destroys the channel, and whatever the allocator had to
/// build under it: a capture it created, or the centre frequency it retuned away from.
actor SessionChannelLease: ChannelLease {
    nonisolated let channelID: ChannelID
    nonisolated let captureID: CaptureID
    nonisolated let engine: any ChannelEngine

    private let store: SessionStore
    private let createdCapture: Bool
    private let restoreCenterHz: UInt64?
    private let owner: ClientContext
    private var released = false

    init(channelID: ChannelID, captureID: CaptureID, engine: any ChannelEngine, store: SessionStore,
         createdCapture: Bool, restoreCenterHz: UInt64?, owner: ClientContext)
    {
        self.channelID = channelID
        self.captureID = captureID
        self.engine = engine
        self.store = store
        self.createdCapture = createdCapture
        self.restoreCenterHz = restoreCenterHz
        self.owner = owner
    }

    func release() async {
        guard !released else { return }
        released = true
        try? await store.destroyChannelChecked(id: channelID, by: owner)
        // Only when nothing else is listening on it. Another job may have put its own channel in
        // the capture this one opened, and destroying the capture under that channel is worse than
        // letting the capture briefly outlive the job that created it.
        guard await store.channelEngines(captureID: captureID).isEmpty else { return }
        if createdCapture {
            await store.destroyCapture(id: captureID, by: .daemon)
        } else if let centre = restoreCenterHz, let capture = await store.captureEngine(captureID) {
            try? await capture.retune(centerHz: centre)
            await store.publishCapture(captureID)
        }
    }
}

/// One IQ decode job's hold on one capture, read as raw IQ with no channel under it
/// (docs/design/decoders.md, "Multiplexing"; DecoderSignal SIGNAL_IQ). Release destroys the capture
/// only when the lease created it; a borrowed one is left as it was found.
actor SessionCaptureIQLease: CaptureIQLease {
    nonisolated let captureID: CaptureID
    nonisolated let sampleRateHz: UInt64
    nonisolated let capture: any CaptureEngine

    private let store: SessionStore
    private let createdCapture: Bool
    private var released = false

    init(captureID: CaptureID, capture: any CaptureEngine, sampleRateHz: UInt64,
         createdCapture: Bool, store: SessionStore)
    {
        self.captureID = captureID
        self.capture = capture
        self.sampleRateHz = sampleRateHz
        self.createdCapture = createdCapture
        self.store = store
    }

    var centerHz: UInt64 { get async { await capture.snapshot.centerHz } }

    func release() async {
        guard !released else { return }
        released = true
        // A capture this lease created is destroyed; one it reused is left for its owner. Running two
        // IQ decoders that would share one created capture is not yet safe -- it needs capture
        // refcounting -- and is a follow-up (docs/design/decoders.md, "Multiplexing"); today the
        // creator destroys on release.
        if createdCapture {
            await store.destroyCapture(id: captureID, by: .daemon)
        }
    }
}
