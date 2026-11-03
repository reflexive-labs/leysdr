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

    init(store: SessionStore) { self.store = store }

    func allocate(_ request: AllocationRequest, for job: JobID) async -> AllocationResult {
        switch request {
        case .channel(let frequencyHz, let bandwidthHz, let mode, let deviceID, let takeOver, let gains):
            return await allocateChannel(frequencyHz: frequencyHz, bandwidthHz: bandwidthHz, mode: mode,
                                         deviceID: deviceID, takeOver: takeOver, gains: gains, job: job)
        case .captureIQ(let frequencyHz, let sampleRateHz, let deviceID, let takeOver, let dedicated, let follows, let gains):
            return await allocateCaptureIQ(frequencyHz: frequencyHz, sampleRateHz: sampleRateHz,
                                           deviceID: deviceID, takeOver: takeOver, dedicated: dedicated,
                                           followsRetune: follows, gains: gains, job: job)
        case .exclusiveCapture(let range, let deviceID, let takeOver, let gains):
            return await allocateCapture(range: range, deviceID: deviceID, takeOver: takeOver, gains: gains, job: job)
        }
    }

    /// The plan for `request` as things stand, without carrying it out (`Control.Plan`).
    func plan(_ request: PlanRequest) async -> Plan {
        CapturePlanner.plan(request, state: await store.snapshot(scope: .daemon))
    }

    /// Where a walk stands while the allocator carries it out: the reason and code the decline
    /// will give if nothing lands.
    private struct Progress {
        var reason: String
        var code = EngineError.Code.deviceBusy

        init(_ walk: PlanWalk) { reason = walk.firstReason }

        mutating func pass(_ step: PlanWalk.Step) {
            guard case .pass(let why, let c, _) = step else { return }
            reason = why
            if let c { code = c }
        }

        mutating func failed(_ why: String, code c: String? = nil) {
            reason = why
            if let c { code = c }
        }

        func declined(_ walk: PlanWalk) -> AllocationResult {
            .declined(code: walk.sawDevice ? code : EngineError.Code.noDevice, reason: reason)
        }
    }

    // MARK: One channel (decode jobs, audio recordings)

    /// Carries out `CapturePlanner`'s walk for a channel: each attempt in order until one lands.
    /// `gains` go on a capture the job created or retuned and never on a shared one, whose gain is
    /// its owner's (`setGains`).
    private func allocateChannel(frequencyHz: UInt64, bandwidthHz: UInt32, mode: DemodMode,
                                 deviceID wanted: DeviceID?, takeOver: Bool, gains: [GainRequest],
                                 job: JobID) async -> AllocationResult
    {
        let state = await store.snapshot(scope: .daemon)
        let bw = bandwidthHz == 0 ? mode.defaultBandwidthHz : bandwidthHz
        let walk = CapturePlanner.walk(.channel(frequencyHz: frequencyHz, bandwidthHz: bw, mode: mode,
                                                deviceID: wanted?.string, takeOver: takeOver), state: state)
        let owner = ClientContext.job(job)
        var progress = Progress(walk)
        for step in walk.steps {
            guard case .attempt(let plan) = step else {
                progress.pass(step)
                continue
            }
            switch plan {
            case .share(let captureID):
                // Nothing moves, so this disturbs nobody: the channel sits inside a span somebody
                // is already listening to.
                guard let id = CaptureID(string: captureID), await !store.isSwept(id),
                      let cap = state.captures.first(where: { $0.captureID == captureID }) else { continue }
                if let lease = await open(captureID: id, offsetHz: Int64(frequencyHz) - Int64(cap.centerHz), bandwidthHz: bw,
                                          mode: mode, frequencyHz: frequencyHz, owner: owner,
                                          gainOutcome: await leftAsFound(id, gains)) {
                    return .channel(lease)
                }
            case .create(let device, let centre, let rate):
                guard let deviceID = DeviceID(string: device) else { continue }
                do {
                    let id = try await store.createCapture(deviceID: deviceID, centerHz: centre, sampleRate: rate, by: .daemon).id
                    await store.holdByClaims(id)
                    let outcome = await setGains(gains, on: id)
                    if let lease = await open(captureID: id, offsetHz: Int64(frequencyHz) - Int64(centre), bandwidthHz: bw,
                                              mode: mode, frequencyHz: frequencyHz, owner: owner, gainOutcome: outcome) {
                        return .channel(lease)
                    }
                    await store.destroyCapture(id: id, by: .daemon)
                } catch {
                    progress.failed((error as? EngineError)?.message ?? "\(error)")
                    log.debug("decode job could not open \(device): \(progress.reason)")
                }
            case .retune(let captureID, let centre, _, _):
                guard let id = CaptureID(string: captureID), await !store.isSwept(id),
                      let cap = state.captures.first(where: { $0.captureID == captureID }),
                      let engine = await store.captureEngine(id) else { continue }
                let before = cap.centerHz
                await store.willMove(id, by: owner)
                do {
                    try await engine.retune(centerHz: centre)
                } catch {
                    await store.moveFailed(id, by: owner)
                    progress.failed((error as? EngineError)?.message ?? "\(error)")
                    continue
                }
                await store.publishCapture(id, by: owner)
                let entryGains = await engine.snapshot.gains
                let outcome = await setGains(gains, on: id)
                if let lease = await open(captureID: id, offsetHz: Int64(frequencyHz) - Int64(centre), bandwidthHz: bw,
                                          mode: mode, frequencyHz: frequencyHz, owner: owner, gainOutcome: outcome) {
                    // Where the job found the capture, for the return when it lets go (CL-4).
                    if let claim = await store.channelClaim(lease.channelID, on: id) {
                        await store.noteReturnPoint(.init(claim: claim, mover: owner, centerHz: before, sampleRate: cap.sampleRate,
                                                          gains: gains.isEmpty ? [] : entryGains,
                                                          gainsLeft: await engine.snapshot.gains), on: id)
                    }
                    return .channel(lease)
                }
                await store.willMove(id, by: owner)
                try? await engine.retune(centerHz: before)
                if !gains.isEmpty { await restoreGainStates(entryGains, on: engine) }
                await store.publishCapture(id, by: owner)
            case .decline:
                continue
            }
        }
        return progress.declined(walk)
    }

    // MARK: One capture read as IQ (an IQ decode job, an IQ recording)

    /// Carries out the planner's walk for an IQ reader. A shared capture gets the job's IQ claim;
    /// a sweep's is never offered. A created or retuned capture is read back before it is handed
    /// over: a dedicated decoder reads only one that landed centred at its rate, and one that did
    /// not is destroyed or put back as it was, with "<model> cannot tune to <f>" as the reason and
    /// `NO_DEVICE` as the code. `gains` are read as `allocateChannel` reads them.
    private func allocateCaptureIQ(frequencyHz: UInt64, sampleRateHz wantedRate: UInt64,
                                   deviceID wanted: DeviceID?, takeOver: Bool, dedicated: Bool, followsRetune: Bool,
                                   gains: [GainRequest], job: JobID) async -> AllocationResult
    {
        let state = await store.snapshot(scope: .daemon)
        let walk = CapturePlanner.walk(.iq(frequencyHz: frequencyHz, sampleRateHz: wantedRate, deviceID: wanted?.string,
                                           takeOver: takeOver, dedicated: dedicated), state: state)
        func need(centre: UInt64) -> SessionStore.ClaimNeed {
            iqNeed(frequencyHz, centre: centre, dedicated: dedicated, followsRetune: followsRetune)
        }
        var progress = Progress(walk)
        for step in walk.steps {
            guard case .attempt(let plan) = step else {
                progress.pass(step)
                continue
            }
            switch plan {
            case .share(let captureID):
                guard let id = CaptureID(string: captureID), await !store.isSwept(id),
                      let cap = state.captures.first(where: { $0.captureID == captureID }),
                      let engine = await store.captureEngine(id) else { continue }
                return .captureIQ(await iqLease(id, engine: engine, rate: cap.sampleRate, job: job,
                                                need: need(centre: cap.centerHz),
                                                gainOutcome: await leftAsFound(id, gains)))
            case .create(let device, let centre, let rate):
                guard let deviceID = DeviceID(string: device),
                      let descriptor = state.devices.first(where: { $0.deviceID == device }) else { continue }
                do {
                    let id = try await store.createCapture(deviceID: deviceID, centerHz: centre, sampleRate: rate, by: .daemon).id
                    await store.holdByClaims(id)
                    guard let engine = await store.captureEngine(id) else {
                        await store.destroyCapture(id: id, by: .daemon)
                        continue
                    }
                    if dedicated {
                        let made = await engine.snapshot
                        guard CapturePlanner.isCentred(centerHz: made.centerHz, sampleRate: made.sampleRate,
                                                       on: frequencyHz, rate: rate) else {
                            await store.destroyCapture(id: id, by: .daemon)
                            progress.failed(CapturePlanner.cannotCentre(descriptor, on: frequencyHz), code: EngineError.Code.noDevice)
                            continue
                        }
                    }
                    let outcome = await setGains(gains, on: id)
                    let made = await engine.snapshot
                    return .captureIQ(await iqLease(id, engine: engine, rate: rate, job: job,
                                                    need: need(centre: made.centerHz), gainOutcome: outcome))
                } catch {
                    progress.failed((error as? EngineError)?.message ?? "\(error)", code: EngineError.Code.deviceBusy)
                    log.debug("iq decode job could not open \(device): \(progress.reason)")
                }
            case .retune(let captureID, let centre, let rate, _):
                guard let id = CaptureID(string: captureID), await !store.isSwept(id),
                      let cap = state.captures.first(where: { $0.captureID == captureID }),
                      let descriptor = state.devices.first(where: { $0.deviceID == cap.deviceID }),
                      let engine = await store.captureEngine(id) else { continue }
                await store.willMove(id, by: .job(job))
                do {
                    if rate != cap.sampleRate { try await engine.setSampleRate(rate) }
                    try await engine.retune(centerHz: centre)
                } catch {
                    progress.failed((error as? EngineError)?.message ?? "\(error)", code: EngineError.Code.deviceBusy)
                    await restore(engine, to: cap, id: id, job: job)
                    continue
                }
                // The retune returned, but a dedicated decoder reads only a capture that is where it
                // asked: one that landed anywhere else is put back and declined, not handed over.
                if dedicated {
                    let now = await engine.snapshot
                    guard CapturePlanner.isCentred(centerHz: now.centerHz, sampleRate: now.sampleRate,
                                                   on: frequencyHz, rate: rate) else {
                        progress.failed(CapturePlanner.cannotCentre(descriptor, on: frequencyHz), code: EngineError.Code.noDevice)
                        await restore(engine, to: cap, id: id, job: job)
                        continue
                    }
                }
                let landed = await engine.snapshot
                let entryGains = landed.gains
                let outcome = await setGains(gains, on: id)
                await store.publishCapture(id, by: .job(job))
                let found = SessionStore.ReturnPoint(claim: ClaimID(), mover: .job(job), centerHz: cap.centerHz,
                                                     sampleRate: cap.sampleRate, gains: gains.isEmpty ? [] : entryGains,
                                                     gainsLeft: await engine.snapshot.gains)
                return .captureIQ(await iqLease(id, engine: engine, rate: rate, job: job,
                                                need: need(centre: landed.centerHz), gainOutcome: outcome, found: found))
            case .decline:
                continue
            }
        }
        return progress.declined(walk)
    }

    /// Puts a capture a declined IQ job retuned back to the rate and centre it had, as a declined
    /// job must leave it: the rate can land and the retune fail, or both land somewhere else.
    private func restore(_ engine: any CaptureEngine, to cap: Leyline_V1_Capture, id: CaptureID, job: JobID) async {
        let now = await engine.snapshot
        await store.willMove(id, by: .job(job))
        if now.sampleRate != cap.sampleRate { try? await engine.setSampleRate(cap.sampleRate) }
        if now.centerHz != cap.centerHz { try? await engine.retune(centerHz: cap.centerHz) }
        await store.publishCapture(id, by: .job(job))
    }

    /// A lease on `id` for `job`, with the job's IQ claim on the capture until it is released:
    /// such a capture is in use, since retuning it moves the band under every job reading it.
    /// `found` is where a job that moved the capture found it, which the capture returns to when
    /// the claim goes (CL-4).
    private func iqLease(_ id: CaptureID, engine: any CaptureEngine, rate: UInt64,
                         job: JobID, need: SessionStore.ClaimNeed,
                         gainOutcome: LeaseGainOutcome = .notAsked,
                         found: SessionStore.ReturnPoint? = nil) async -> SessionCaptureIQLease
    {
        // Every IQ reader reads at the rate it was handed: a decoder's descriptor and a
        // recording's manifest both name it.
        let claim = await store.addClaim(on: id, holder: .job(job), kind: .claimIq, priority: .priorityJob,
                                         need: need, sampleRateHz: rate)
        if let claim, var point = found {
            point.claim = claim
            await store.noteReturnPoint(point, on: id)
        }
        return SessionCaptureIQLease(captureID: id, capture: engine, sampleRateHz: rate, gainOutcome: gainOutcome) { [store] in
            guard let claim else { return }
            await store.releaseClaim(claim, on: id)
        }
    }

    /// What an IQ job needs: a dedicated decoder, the capture centred on its frequency; an IQ
    /// recording, its frequency anywhere in the span (a retune that keeps it starts a new part);
    /// any other IQ decoder, the centre it was handed (`centre`), which its plugin's descriptor
    /// names and which it holds the capture to (`IQDecodeRunner.followCapture`).
    private func iqNeed(_ frequencyHz: UInt64, centre: UInt64, dedicated: Bool, followsRetune: Bool) -> SessionStore.ClaimNeed {
        if dedicated { return .centred(frequencyHz: frequencyHz, toleranceHz: Self.centredToleranceHz) }
        if followsRetune { return .covers(frequencyHz: frequencyHz, bandwidthHz: 0) }
        return .centred(frequencyHz: centre, toleranceHz: 0)
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

    /// The outcome for a shared capture, which already covered the frequency: its gain is its
    /// owner's, so nothing is set, and the job is told what it was left at.
    private func leftAsFound(_ id: CaptureID, _ requests: [GainRequest]) async -> LeaseGainOutcome {
        guard !requests.isEmpty else { return .notAsked }
        return .leftAsFound(await store.captureEngine(id)?.snapshot.gains ?? [])
    }

    /// How far a capture's centre may sit from where a dedicated IQ decoder would put it and still
    /// count as centred (`CapturePlanner.centredToleranceHz`).
    static let centredToleranceHz: UInt64 = CapturePlanner.centredToleranceHz

    private func open(captureID: CaptureID, offsetHz: Int64, bandwidthHz: UInt32, mode: DemodMode,
                      frequencyHz: UInt64, owner: ClientContext, gainOutcome: LeaseGainOutcome) async -> SessionChannelLease?
    {
        do {
            let proto = try await store.createChannel(captureID: captureID, offsetHz: offsetHz, bandwidthHz: bandwidthHz,
                                                      mode: ProtoMapping.demodMode(mode), persistent: true,
                                                      requiredHz: frequencyHz, by: owner)
            guard let channelID = ChannelID(string: proto.channelID),
                  let engine = await store.channelEngine(channelID) else { return nil }
            return SessionChannelLease(channelID: channelID, captureID: captureID, engine: engine, store: store,
                                       gainOutcome: gainOutcome, owner: owner)
        } catch {
            log.debug("decode job could not open a channel on \(captureID.string): \(error)")
            return nil
        }
    }

    // MARK: A whole radio (scans and monitors)

    /// Carries out the planner's walk for a sweep: an idle radio's new capture, else a free one
    /// borrowed, each claimed for the sweep before it is handed over.
    private func allocateCapture(range: ClosedRange<UInt64>, deviceID wanted: DeviceID?, takeOver: Bool,
                                 gains: [GainRequest], job: JobID) async -> AllocationResult
    {
        let state = await store.snapshot(scope: .daemon)
        let walk = CapturePlanner.walk(.sweep(rangeHz: range, deviceID: wanted?.string, takeOver: takeOver), state: state)
        var progress = Progress(walk)
        for step in walk.steps {
            guard case .attempt(let plan) = step else {
                progress.pass(step)
                continue
            }
            switch plan {
            case .retune(let captureID, _, _, _):
                guard let id = CaptureID(string: captureID),
                      let cap = state.captures.first(where: { $0.captureID == captureID }),
                      let deviceID = DeviceID(string: cap.deviceID) else { continue }
                // Claim before `borrow`. It suspends three times, and an actor is re-entrant at a
                // suspension: checking here and claiming in there let two simultaneous scans both
                // pass the check and both walk the same tuner. The store checks and claims in one
                // step.
                let claim: ClaimID
                switch await store.claimSweep(on: id, job: job, range: range) {
                case .claimed(let c): claim = c
                case .taken:
                    let model = state.devices.first { $0.deviceID == cap.deviceID }?.model ?? cap.deviceID
                    progress.failed("another scan already has \(model)")
                    continue
                case .gone: continue
                }
                guard let lease = await borrow(id, deviceID: deviceID, job: job, claim: claim, gains: gains) else {
                    await store.releaseClaim(claim, on: id)
                    continue
                }
                return .capture(lease)
            case .create(let device, let centre, let rate):
                guard let deviceID = DeviceID(string: device) else { continue }
                // The device has no capture, so nothing to claim yet -- but two scans racing here
                // would both call createCapture and the loser gets DEVICE_BUSY from the store,
                // which is the right answer and is caught below.
                do {
                    let id = try await store.createCapture(deviceID: deviceID, centerHz: centre, sampleRate: rate, by: .daemon).id
                    await store.holdByClaims(id)
                    // Every path out of here from now on either returns the lease or destroys what
                    // was just created: a capture this scan opened and then walked away from would
                    // hold the device open with no job to cancel and nobody to close it.
                    guard case .claimed(let claim) = await store.claimSweep(on: id, job: job, range: range) else {
                        await store.destroyCapture(id: id, by: .daemon)
                        continue
                    }
                    guard let lease = await borrow(id, deviceID: deviceID, job: job, claim: claim, gains: gains) else {
                        await store.destroyCapture(id: id, by: .daemon)
                        continue
                    }
                    return .capture(lease)
                } catch {
                    progress.failed((error as? EngineError)?.message ?? "\(error)")
                    log.debug("scan could not open \(device): \(progress.reason)")
                }
            case .share, .decline:
                continue
            }
        }
        return progress.declined(walk)
    }

    /// The sweep's lease on a capture it holds by `claim`. The capture returns to where the sweep
    /// found it, gains included, when the claim goes (CL-4); one the allocator made for the sweep
    /// is destroyed instead.
    private func borrow(_ id: CaptureID, deviceID: DeviceID, job: JobID, claim: ClaimID,
                        gains: [GainRequest] = []) async -> SessionCaptureLease?
    {
        guard let engine = await store.captureEngine(id) else { return nil }
        let device = await store.registry.device(id: deviceID)
        let snap = await engine.snapshot
        let lease = SessionCaptureLease(captureID: id, engine: engine, store: store, sampleRateHz: snap.sampleRate,
                                        gainElements: device?.descriptor.gainElements ?? [],
                                        inFlight: device?.inFlightSamples ?? 0, job: job) { [store] in
            await store.releaseClaim(claim, on: id)
        }
        await lease.pinGain(device: device, requested: gains)
        await store.noteReturnPoint(.init(claim: claim, mover: .job(job), centerHz: snap.centerHz, sampleRate: snap.sampleRate,
                                          gains: snap.gains, gainsLeft: await lease.pinnedGains), on: id)
        return lease
    }
}

/// One job's hold on one capture.
actor SessionCaptureLease: CaptureLease {
    nonisolated let captureID: CaptureID
    nonisolated let sampleRateHz: UInt64
    nonisolated var spectrum: any SpectrumLadder { engine.spectrum }

    private let engine: DefaultCaptureEngine
    private let store: SessionStore
    private let inFlight: UInt64
    private let job: JobID
    private let onRelease: @Sendable () async -> Void
    private var pinned: [GainState] = []
    /// Why a requested gain could not be applied, for the job to fail with. A sweep that ran at
    /// some other gain than the one asked for would report a measurement nobody requested.
    private(set) var pinFailure: EngineError?
    private var released = false
    private let log = Logger(label: "leyline.jobs.lease")

    private let gainElements: [GainElement]

    init(captureID: CaptureID, engine: DefaultCaptureEngine, store: SessionStore,
         sampleRateHz: UInt64, gainElements: [GainElement], inFlight: UInt64,
         job: JobID, onRelease: @escaping @Sendable () async -> Void)
    {
        self.captureID = captureID
        self.engine = engine
        self.store = store
        self.sampleRateHz = sampleRateHz
        self.gainElements = gainElements
        self.inFlight = inFlight
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
    /// stages set before it stay set until the capture returns to where the sweep found it.
    func pinGain(device: (any RadioDevice)?, requested: [GainRequest] = []) async {
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
        await store.willMove(captureID, by: .job(job))
        do {
            try await engine.retune(centerHz: centerHz)
        } catch {
            await store.moveFailed(captureID, by: .job(job))
            throw error
        }
        await store.publishCapture(captureID, by: .job(job))
    }

    /// Releases the sweep's claim. The store puts the capture back where the sweep found it, gains
    /// included, before the claim leaves the ledger, so the return cannot land on top of
    /// somebody's write; a capture the allocator made for the sweep is destroyed instead (CL-4).
    func release() async {
        guard !released else { return }
        released = true
        await onRelease()
    }
}

/// One job's hold on one channel. Release destroys the channel, and with it the channel's claim:
/// the store then destroys a capture the allocator made that nothing else holds, or returns one
/// the job moved to where the job found it (`SessionStore+Returns.swift`).
actor SessionChannelLease: ChannelLease {
    nonisolated let channelID: ChannelID
    nonisolated let captureID: CaptureID
    nonisolated let engine: any ChannelEngine

    nonisolated let gainOutcome: LeaseGainOutcome

    private let store: SessionStore
    private let owner: ClientContext
    private var released = false

    init(channelID: ChannelID, captureID: CaptureID, engine: any ChannelEngine, store: SessionStore,
         gainOutcome: LeaseGainOutcome = .notAsked, owner: ClientContext)
    {
        self.channelID = channelID
        self.captureID = captureID
        self.engine = engine
        self.store = store
        self.gainOutcome = gainOutcome
        self.owner = owner
    }

    func release() async {
        guard !released else { return }
        released = true
        try? await store.destroyChannelChecked(id: channelID, by: owner)
    }
}

/// One IQ decode job's hold on one capture, read as raw IQ with no channel under it
/// (docs/design/decoders.md, "Multiplexing"; DecoderSignal SIGNAL_IQ). Release gives up the job's
/// IQ claim; what becomes of the capture is the claims' business (DEC-19): one the allocator made
/// lives while any other claim holds it, and one the job moved returns when nothing is in the way.
actor SessionCaptureIQLease: CaptureIQLease {
    nonisolated let captureID: CaptureID
    nonisolated let sampleRateHz: UInt64
    nonisolated let capture: any CaptureEngine

    nonisolated let gainOutcome: LeaseGainOutcome

    /// Takes the job's claim off the capture.
    private let onRelease: @Sendable () async -> Void
    private var released = false

    init(captureID: CaptureID, capture: any CaptureEngine, sampleRateHz: UInt64,
         gainOutcome: LeaseGainOutcome = .notAsked, onRelease: @escaping @Sendable () async -> Void = {})
    {
        self.captureID = captureID
        self.capture = capture
        self.sampleRateHz = sampleRateHz
        self.gainOutcome = gainOutcome
        self.onRelease = onRelease
    }

    var centerHz: UInt64 { get async { await capture.snapshot.centerHz } }

    func release() async {
        guard !released else { return }
        released = true
        await onRelease()
    }
}
