// SPDX-License-Identifier: GPL-3.0-or-later

// The don't-disturb policy (invariant 9). Jobs never touch captures; they ask for what they need
// and get a lease or a reason.

import EngineCore
import Foundation
import LeylineProto
import Logging

/// How long after somebody's last interactive write a capture still counts as in use.
let dontDisturbNs: UInt64 = 60_000_000_000

/// The gain element a request means: the first the device lists when it names none (`common.proto`,
/// `GainWrite`), else the device's element whose name matches ignoring case, so `ley record --gain
/// vga=0` reaches the VGA. A name the device does not list comes back as given, for the device to
/// refuse. A gain write, a sweep's pin and a recording's gains all read it here, so a client that
/// names the element and one that does not reach the same stage.
func resolvedGainElement(_ requested: String, in elements: [GainElement]) -> String {
    if requested.isEmpty { return elements.first?.name ?? "" }
    return elements.first { $0.name.caseInsensitiveCompare(requested) == .orderedSame }?.name ?? requested
}

/// The refusal for a gain element the device does not list, with the ones it does, so the reader
/// can retype the name without a second command (`ley devices`).
func unknownGainElement(_ name: String, in elements: [GainElement], target: String) -> EngineError {
    guard !elements.isEmpty else {
        return EngineError(code: EngineError.Code.gainElementUnknown, message: "this radio reports no gain elements",
                           target: target)
    }
    let names = elements.map(\.name)
    let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
    return EngineError(code: EngineError.Code.gainElementUnknown,
                       message: "no gain element named \(name); this radio's are \(list)", target: target)
}

/// Puts a capture's gains back as they were before a job set its own, as a sweep's lease does on
/// release. Best effort: a radio that refuses a stage it accepted before stays where it is.
func restoreGainStates(_ gains: [GainState], on engine: any CaptureEngine) async {
    for g in gains {
        try? await engine.setGain(element: g.element, value: g.value)
    }
}

actor SessionCaptureAllocator: CaptureAllocator {
    private let store: SessionStore
    private let log = Logger(label: "leyline.jobs.allocator")
    /// Captures currently leased, so two sweeps never share a radio.
    private var leased: Set<CaptureID> = []
    /// The jobs reading each capture as raw IQ (an IQ decode job, an IQ recording), in the order
    /// they took it. Such a capture is in use: retuning it moves the band under every one of them.
    private var iqReaders: [CaptureID: [JobID]] = [:]

    init(store: SessionStore) { self.store = store }

    func allocate(_ request: AllocationRequest, for job: JobID) async -> AllocationResult {
        switch request {
        case .channel(let frequencyHz, let bandwidthHz, let mode, let deviceID, let takeOver, let gains):
            return await allocateChannel(frequencyHz: frequencyHz, bandwidthHz: bandwidthHz, mode: mode,
                                         deviceID: deviceID, takeOver: takeOver, gains: gains, job: job)
        case .captureIQ(let frequencyHz, let sampleRateHz, let deviceID, let takeOver, let dedicated, let gains):
            return await allocateCaptureIQ(frequencyHz: frequencyHz, sampleRateHz: sampleRateHz,
                                           deviceID: deviceID, takeOver: takeOver, dedicated: dedicated,
                                           gains: gains, job: job)
        case .exclusiveCapture(let range, let deviceID, let takeOver, let gains):
            return await allocateCapture(range: range, deviceID: deviceID, takeOver: takeOver, gains: gains, job: job)
        }
    }

    // MARK: One channel (decode jobs, and watch jobs once they are built)

    /// The order and the reasons are the design doc's (docs/design/decoders.md, "Decisions": "A
    /// decode job is a job"): a capture that already covers the frequency on any device, else a
    /// device with no capture, else a capture the don't-disturb test calls free, else a decline
    /// naming who has the radio. `gains` go on a capture of step 2 or 3 and never on step 1's,
    /// whose gain is its owner's (`setGains`).
    private func allocateChannel(frequencyHz: UInt64, bandwidthHz: UInt32, mode: DemodMode,
                                 deviceID wanted: DeviceID?, takeOver: Bool, gains: [GainRequest],
                                 job: JobID) async -> AllocationResult
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
                                      restoreCenterHz: nil, gainOutcome: await leftAsFound(id, gains)) {
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
                let outcome = await setGains(gains, on: id)
                if let lease = await open(captureID: id, offsetHz: Int64(frequencyHz) - Int64(centre), bandwidthHz: bw,
                                          mode: mode, frequencyHz: frequencyHz, owner: owner, createdCapture: true,
                                          restoreCenterHz: nil, gainOutcome: outcome) {
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
            let entryGains = await engine.snapshot.gains
            let outcome = await setGains(gains, on: id)
            if let lease = await open(captureID: id, offsetHz: Int64(frequencyHz) - Int64(centre), bandwidthHz: bw,
                                      mode: mode, frequencyHz: frequencyHz, owner: owner, createdCapture: false,
                                      restoreCenterHz: before, gainOutcome: outcome,
                                      restoreGains: gains.isEmpty ? [] : entryGains) {
                return .channel(lease)
            }
            try? await engine.retune(centerHz: before)
            if !gains.isEmpty { await restoreGainStates(entryGains, on: engine) }
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
    ///
    /// `dedicated` (the manifest's `needs_dedicated_capture`) narrows step 1 to a capture centred on
    /// the frequency, within `centredToleranceHz`, at the rate the job would create one at; any
    /// other capture on the device is retuned (and set to that rate) by step 3 under the same
    /// don't-disturb and `take_over` rules, or the job is declined with the reason. A decoder that
    /// reads a wide signal (a 2 MHz Mode S frame) is clipped by an off-centre span. A device that
    /// cannot be centred there (a file radio, which plays what it recorded, or a tuner whose range
    /// stops short) is no candidate at all, and a capture that does not land where it was asked is
    /// put back as it was: steps 2 and 3 read where it ended up before they hand it over, and the
    /// decline says which radio cannot tune where, as `NO_DEVICE` when that is the last reason.
    ///
    /// `gains` are read as `allocateChannel` reads them: set on a capture of step 2 or 3, put back
    /// on release of step 3's, never set on step 1's.
    private func allocateCaptureIQ(frequencyHz: UInt64, sampleRateHz wantedRate: UInt64,
                                   deviceID wanted: DeviceID?, takeOver: Bool, dedicated: Bool,
                                   gains: [GainRequest], job: JobID) async -> AllocationResult
    {
        let state = await store.snapshot(scope: .daemon)
        var sawDevice = false
        var lastReason = "no radio here can hear \(fmt(frequencyHz))"
        // DEVICE_BUSY unless the last reason is that a radio cannot be centred there.
        var lastCode = EngineError.Code.deviceBusy

        // 1. A capture whose span already covers the frequency (centred on it, for a dedicated
        //    decoder). This disturbs nobody: the decoder reads a band somebody is already
        //    listening to.
        for cap in state.captures {
            if let want = wanted, cap.deviceID != want.string { continue }
            guard let id = CaptureID(string: cap.captureID), !leased.contains(id) else { continue }
            sawDevice = true
            if dedicated {
                guard let device = state.devices.first(where: { $0.deviceID == cap.deviceID }),
                      isCentred(centerHz: cap.centerHz, sampleRate: cap.sampleRate, on: frequencyHz,
                                rate: iqRate(wantedRate, device: device))
                else { continue }
            }
            guard spanCovers(centerHz: cap.centerHz, rate: cap.sampleRate, frequencyHz: frequencyHz),
                  let engine = await store.captureEngine(id) else { continue }
            return .captureIQ(iqLease(id, engine: engine, rate: cap.sampleRate, created: false, job: job,
                                      gainOutcome: await leftAsFound(id, gains)))
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
            if dedicated, !isCentred(centerHz: centre, sampleRate: rate, on: frequencyHz, rate: rate) {
                lastReason = cannotCentre(device, on: frequencyHz)
                lastCode = EngineError.Code.noDevice
                continue
            }
            do {
                let id = try await store.createCapture(deviceID: deviceID, centerHz: centre, sampleRate: rate, by: .daemon).id
                guard let engine = await store.captureEngine(id) else {
                    await store.destroyCapture(id: id, by: .daemon)
                    continue
                }
                if dedicated {
                    let made = await engine.snapshot
                    guard isCentred(centerHz: made.centerHz, sampleRate: made.sampleRate, on: frequencyHz, rate: rate) else {
                        await store.destroyCapture(id: id, by: .daemon)
                        lastReason = cannotCentre(device, on: frequencyHz)
                        lastCode = EngineError.Code.noDevice
                        continue
                    }
                }
                let outcome = await setGains(gains, on: id)
                return .captureIQ(iqLease(id, engine: engine, rate: rate, created: true, job: job, gainOutcome: outcome))
            } catch {
                lastReason = (error as? EngineError)?.message ?? "\(error)"
                lastCode = EngineError.Code.deviceBusy
                log.debug("iq decode job could not open \(device.deviceID): \(lastReason)")
            }
        }

        // 3. A capture nobody is using, retuned onto the frequency. The first step that disturbs
        //    anything, so it is last. It is reused, not created, so the lease leaves it on release.
        for cap in state.captures {
            if let want = wanted, cap.deviceID != want.string { continue }
            guard let id = CaptureID(string: cap.captureID), !leased.contains(id) else { continue }
            guard let device = state.devices.first(where: { $0.deviceID == cap.deviceID }) else { continue }
            // A dedicated decoder also needs its rate; any other takes the capture's.
            let rate = dedicated ? iqRate(wantedRate, device: device) : cap.sampleRate
            let centre = iqCentre(frequencyHz: frequencyHz, device: device, rate: rate)
            // A radio that cannot be centred there is no candidate, whoever is using it: taking it
            // over would only move it to where the decoder still cannot read.
            if dedicated, centre.map({ isCentred(centerHz: $0, sampleRate: rate, on: frequencyHz, rate: rate) }) != true {
                lastReason = cannotCentre(device, on: frequencyHz)
                lastCode = EngineError.Code.noDevice
                continue
            }
            if !takeOver, let why = inUse(cap, state: state) {
                lastReason = why
                lastCode = EngineError.Code.deviceBusy
                continue
            }
            guard let centre, let engine = await store.captureEngine(id) else { continue }
            do {
                if rate != cap.sampleRate { try await engine.setSampleRate(rate) }
                try await engine.retune(centerHz: centre)
            } catch {
                lastReason = (error as? EngineError)?.message ?? "\(error)"
                lastCode = EngineError.Code.deviceBusy
                await restore(engine, to: cap, id: id)
                continue
            }
            // The retune returned, but a dedicated decoder reads only a capture that is where it
            // asked: one that landed anywhere else is put back and declined, not handed over.
            if dedicated {
                let now = await engine.snapshot
                guard isCentred(centerHz: now.centerHz, sampleRate: now.sampleRate, on: frequencyHz, rate: rate) else {
                    lastReason = cannotCentre(device, on: frequencyHz)
                    lastCode = EngineError.Code.noDevice
                    await restore(engine, to: cap, id: id)
                    continue
                }
            }
            let entryGains = await engine.snapshot.gains
            let outcome = await setGains(gains, on: id)
            await store.publishCapture(id)
            return .captureIQ(iqLease(id, engine: engine, rate: rate, created: false, job: job, gainOutcome: outcome,
                                      restoreGains: gains.isEmpty ? [] : entryGains))
        }
        return .declined(code: sawDevice ? lastCode : EngineError.Code.noDevice, reason: lastReason)
    }

    /// Puts a capture a declined IQ job retuned back to the rate and centre it had, as a declined
    /// job must leave it: the rate can land and the retune fail, or both land somewhere else.
    private func restore(_ engine: any CaptureEngine, to cap: Leyline_V1_Capture, id: CaptureID) async {
        let now = await engine.snapshot
        if now.sampleRate != cap.sampleRate { try? await engine.setSampleRate(cap.sampleRate) }
        if now.centerHz != cap.centerHz { try? await engine.retune(centerHz: cap.centerHz) }
        await store.publishCapture(id)
    }

    /// Why `device` is no capture for a dedicated decoder on `frequencyHz`. A file radio says what
    /// it is, since nothing can move where its recording was made.
    private func cannotCentre(_ device: Leyline_V1_DeviceDescriptor, on frequencyHz: UInt64) -> String {
        let why = device.driver == FilePlaybackDevice.driverName ? " (a file radio plays what it recorded)" : ""
        return "\(device.model) cannot tune to \(fmt(frequencyHz))\(why)"
    }

    /// A lease on `id` for `job`, counted among the capture's IQ readers until it is released.
    private func iqLease(_ id: CaptureID, engine: any CaptureEngine, rate: UInt64, created: Bool,
                         job: JobID, gainOutcome: LeaseGainOutcome = .notAsked,
                         restoreGains: [GainState] = []) -> SessionCaptureIQLease
    {
        iqReaders[id, default: []].append(job)
        return SessionCaptureIQLease(captureID: id, capture: engine, sampleRateHz: rate, createdCapture: created,
                                     store: store, gainOutcome: gainOutcome, restoreGains: restoreGains) { [weak self] in
            await self?.releaseIQReader(id, job: job) ?? false
        }
    }

    /// Takes `job` off the capture's IQ readers, and says whether any other job still reads it.
    private func releaseIQReader(_ id: CaptureID, job: JobID) -> Bool {
        iqReaders[id]?.removeAll { $0 == job }
        if iqReaders[id]?.isEmpty == true { iqReaders[id] = nil }
        return iqReaders[id] != nil
    }

    // MARK: A decode job's gain

    /// Sets a decode job's gains on the capture the allocator created or retuned for it, one stage
    /// at a time in order, each read as a recording's are (`resolvedGainElement`). The first
    /// refusal stops the list; the job decides what a refusal means (a gain the job was sent fails
    /// it, a recipe's on a radio with no gain stages is no gain at all).
    private func setGains(_ requests: [GainRequest], on id: CaptureID) async -> LeaseGainOutcome {
        guard !requests.isEmpty else { return .notAsked }
        guard let engine = await store.captureEngine(id) else { return .refused(EngineError.captureNotFound(id.string)) }
        let elements = await store.deviceDescriptor(for: id)?.gainElements ?? []
        var outcome = LeaseGainOutcome.applied
        for request in requests {
            let element = resolvedGainElement(request.element, in: elements)
            guard elements.contains(where: { $0.name == element }) else {
                outcome = .refused(unknownGainElement(request.element, in: elements, target: id.string))
                break
            }
            do {
                try await engine.setGain(element: element, value: request.value)
            } catch {
                outcome = .refused(error as? EngineError ?? EngineError.invalidArgument("\(error)", target: element))
                break
            }
        }
        // The stages set before a refusal did move, so the capture event says where they are.
        await store.publishCapture(id)
        return outcome
    }

    /// The outcome for a capture of step 1, which already covered the frequency: its gain is its
    /// owner's, so nothing is set, and the job is told what it was left at.
    private func leftAsFound(_ id: CaptureID, _ requests: [GainRequest]) async -> LeaseGainOutcome {
        guard !requests.isEmpty else { return .notAsked }
        return .leftAsFound(await store.captureEngine(id)?.snapshot.gains ?? [])
    }

    /// How far a capture's centre may sit from where a dedicated IQ decoder would put it and still
    /// count as centred: a tuner's own step, not a fraction of the span.
    static let centredToleranceHz: UInt64 = 1_000

    /// Whether a capture at `centerHz` and `sampleRate` is the one a dedicated IQ decoder needs:
    /// at exactly `rate`, centred within `centredToleranceHz` of the frequency itself. Not of the
    /// nearest point the device tunes: a file radio's only point is where its recording was made,
    /// and a capture there is centred on whatever that was.
    private func isCentred(centerHz: UInt64, sampleRate: UInt64, on frequencyHz: UInt64, rate: UInt64) -> Bool {
        guard sampleRate == rate else { return false }
        let off = centerHz > frequencyHz ? centerHz - frequencyHz : frequencyHz - centerHz
        return off <= Self.centredToleranceHz
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
                      restoreCenterHz: UInt64?, gainOutcome: LeaseGainOutcome,
                      restoreGains: [GainState] = []) async -> SessionChannelLease?
    {
        do {
            let proto = try await store.createChannel(captureID: captureID, offsetHz: offsetHz, bandwidthHz: bandwidthHz,
                                                      mode: ProtoMapping.demodMode(mode), persistent: true,
                                                      requiredHz: frequencyHz, by: owner)
            guard let channelID = ChannelID(string: proto.channelID),
                  let engine = await store.channelEngine(channelID) else { return nil }
            return SessionChannelLease(channelID: channelID, captureID: captureID, engine: engine, store: store,
                                       createdCapture: createdCapture, restoreCenterHz: restoreCenterHz,
                                       restoreGains: restoreGains, gainOutcome: gainOutcome, owner: owner)
        } catch {
            log.debug("decode job could not open a channel on \(captureID.string): \(error)")
            return nil
        }
    }

    private func allocateCapture(range: ClosedRange<UInt64>, deviceID wanted: DeviceID?, takeOver: Bool,
                                 gains: [GainRequest], job: JobID) async -> AllocationResult
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
                guard let lease = await borrow(id, deviceID: deviceID, job: job, gains: gains) else {
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
                guard let lease = await borrow(id, deviceID: deviceID, job: job, created: true, gains: gains) else {
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
        if let id = CaptureID(string: cap.captureID), let reader = iqReaders[id]?.first {
            // An IQ decode job or an IQ recording has no channel to show it is there, and a
            // retune moves the whole band it reads.
            let job = state.jobs.first { $0.jobID == reader.string }
            switch job?.config {
            case .decode(let d)?: return "another job is reading this radio (decode \(d.decoder))"
            case .record?: return "another job is reading this radio (record)"
            default: return "another job is reading this radio"
            }
        }
        let now = UInt64(WallClock.realNowNs())
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
                        gains: [GainRequest] = []) async -> SessionCaptureLease?
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
        await lease.pinGain(device: device, requested: gains)
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
    /// measured against a moving reference is meaningless. `requested` sets where to pin, one
    /// stage at a time in order (`ScanConfig.gains`): a level, or auto for where the driver
    /// settles; empty pins the gain the radio is on. The first refusal stops the list and is kept
    /// in `pinFailure`, so the sweep fails rather than measuring at a gain nobody asked for; the
    /// stages set before it stay set until the lease restores the entry gain.
    func pinGain(device: (any RadioDevice)?, requested: [GainRequest] = []) async {
        entryGains = await engine.snapshot.gains
        var settling = false
        for request in requested {
            let element = resolvedGainElement(request.element, in: gainElements)
            guard gainElements.contains(where: { $0.name == element }) else {
                pinFailure = unknownGainElement(request.element, in: gainElements, target: captureID.string)
                break
            }
            do {
                try await engine.setGain(element: element, value: request.value)
                settling = settling || request.value == .auto
            } catch {
                pinFailure = error as? EngineError ?? EngineError.invalidArgument("\(error)", target: element)
                break
            }
        }
        if settling {
            // Give the driver's AGC a moment to settle before asking where it did.
            try? await Task.sleep(nanoseconds: 200_000_000)
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

    nonisolated let gainOutcome: LeaseGainOutcome

    private let store: SessionStore
    private let createdCapture: Bool
    private let restoreCenterHz: UInt64?
    /// The gains a retuned capture had before the job set its own, put back with the centre.
    private let restoreGains: [GainState]
    private let owner: ClientContext
    private var released = false

    init(channelID: ChannelID, captureID: CaptureID, engine: any ChannelEngine, store: SessionStore,
         createdCapture: Bool, restoreCenterHz: UInt64?, restoreGains: [GainState] = [],
         gainOutcome: LeaseGainOutcome = .notAsked, owner: ClientContext)
    {
        self.channelID = channelID
        self.captureID = captureID
        self.engine = engine
        self.store = store
        self.createdCapture = createdCapture
        self.restoreCenterHz = restoreCenterHz
        self.restoreGains = restoreGains
        self.gainOutcome = gainOutcome
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
        } else if restoreCenterHz != nil || !restoreGains.isEmpty, let capture = await store.captureEngine(captureID) {
            if let centre = restoreCenterHz { try? await capture.retune(centerHz: centre) }
            await restoreGainStates(restoreGains, on: capture)
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

    nonisolated let gainOutcome: LeaseGainOutcome

    private let store: SessionStore
    private let createdCapture: Bool
    /// The gains a retuned capture had before the job set its own, put back on release.
    private let restoreGains: [GainState]
    /// Takes the job off the allocator's readers of the capture, and says whether another job
    /// still reads it.
    private let onRelease: @Sendable () async -> Bool
    private var released = false

    init(captureID: CaptureID, capture: any CaptureEngine, sampleRateHz: UInt64,
         createdCapture: Bool, store: SessionStore, gainOutcome: LeaseGainOutcome = .notAsked,
         restoreGains: [GainState] = [], onRelease: @escaping @Sendable () async -> Bool = { false })
    {
        self.captureID = captureID
        self.capture = capture
        self.sampleRateHz = sampleRateHz
        self.createdCapture = createdCapture
        self.store = store
        self.gainOutcome = gainOutcome
        self.restoreGains = restoreGains
        self.onRelease = onRelease
    }

    var centerHz: UInt64 { get async { await capture.snapshot.centerHz } }

    func release() async {
        guard !released else { return }
        released = true
        let othersRead = await onRelease()
        // A capture this lease retuned gets its gain back, as a sweep's does, unless another IQ
        // job has joined it since: that job reads the band at the gain it found.
        if !createdCapture, !restoreGains.isEmpty, !othersRead {
            await restoreGainStates(restoreGains, on: capture)
            await store.publishCapture(captureID)
        }
        // A capture this lease created is destroyed; one it reused is left for its owner. Running two
        // IQ decoders that would share one created capture is not yet safe -- it needs capture
        // refcounting -- and is a follow-up (docs/design/decoders.md, "Multiplexing"); today the
        // creator destroys on release.
        if createdCapture {
            await store.destroyCapture(id: captureID, by: .daemon)
        }
    }
}
