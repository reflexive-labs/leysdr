// SPDX-License-Identifier: GPL-3.0-or-later

// Starting a record job (docs/design/recording.md). A recording is a job's output: the refusals
// happen here, where the caller can be told, and everything that can take a radio's time happens
// in the task, where a failure is a FAILED job with a reason rather than an RPC error.

import EngineCore
import Foundation
import LeylineProto

extension JobStore {
    /// The gate's defaults, chosen rather than measured (docs/design/recording.md, "Open
    /// questions"): 500 ms covers the squelch's own attack and a syllable, and 5 s is the guess at
    /// a pause between overs that the repeater's tail does not cover. `--pre` and `--hang`
    /// override both.
    static let defaultPreRollMs: UInt32 = 500
    static let defaultHangMs: UInt32 = 5000
    /// An IQ recording is cut into parts by default because it is large: 19.2 MB/s at 2.4 MSPS.
    /// Audio keeps one part unless asked otherwise.
    static let defaultIQPartMs: Int64 = 60_000

    func startRecord(config: Leyline_V1_RecordConfig, by client: ClientContext) async throws -> Leyline_V1_Job {
        if config.startAtNs != 0 {
            throw EngineError.unimplemented("a recording scheduled for later")
        }
        let iq = config.mode == .rawIq
        let gated = config.gate == .squelch
        if gated, iq {
            throw EngineError.invalidArgument(
                "a squelch gate needs a channel's squelch, and an IQ recording has no channel; record audio, or record IQ continuously",
                target: "")
        }
        if config.stopAfterQuietMs != 0, !gated {
            throw EngineError.invalidArgument(
                "stop-after-quiet needs a squelch gate: without one nothing is watching the squelch", target: "")
        }
        if config.durationMs < 0 {
            throw EngineError.invalidArgument("a recording's duration cannot be negative; 0 records until cancelled", target: "")
        }
        // The channel form: the job borrows what somebody is listening to, with its mode,
        // bandwidth and squelch, and ends when that channel does.
        var borrowed: (id: ChannelID, engine: any ChannelEngine, captureID: CaptureID)?
        if !config.channelID.isEmpty {
            guard let id = ChannelID(string: config.channelID), let engine = await store.channelEngine(id) else {
                throw EngineError.channelNotFound(config.channelID)
            }
            let captureID = await store.channelCapture(id)
            guard let captureID else { throw EngineError.channelNotFound(config.channelID) }
            if gated, await engine.config.squelchDB.isNaN {
                throw EngineError.failedPrecondition(
                    "squelch is off on \(config.channelID); set one with ley set squelch", target: config.channelID)
            }
            borrowed = (id, engine, captureID)
        } else if config.frequencyHz == 0 {
            throw EngineError.invalidArgument("a recording needs a frequency, a preset or a channel to record", target: "")
        }
        if !config.deviceID.isEmpty, DeviceID(string: config.deviceID) == nil {
            throw EngineError.deviceNotFound(config.deviceID)
        }

        let id = JobID()
        var job = Leyline_V1_Job()
        job.jobID = id.string
        job.state = .running
        job.createdAtNs = WallClock.nowNs()
        job.createdBy = client.proto
        job.config = .record(config)
        job.statusDetail = "starting"
        // A recording is a resource from the moment it exists (invariant 8): the job's id is the
        // recording's id, so the URI is known before a sample is written.
        job.resultUris = ["ley://recordings/\(id.string)"]

        // The task goes in before the first suspension, the same actor-reentrancy care a scan
        // takes: a cancel arriving while `publishJob` runs must find something to cancel.
        let borrowedChannel = borrowed
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRecord(id, config: config, borrowed: borrowedChannel)
        }
        setRecordEntry(id, job: job, task: task, client: client)
        await store.publishJob(job)
        return job
    }

    // MARK: Running

    private func runRecord(_ id: JobID, config: Leyline_V1_RecordConfig,
                           borrowed: (id: ChannelID, engine: any ChannelEngine, captureID: CaptureID)?) async
    {
        guard jobIsLive(id) else { return }
        let iq = config.mode == .rawIq
        if iq {
            await runIQRecord(id, config: config, borrowed: borrowed)
        } else {
            await runAudioRecord(id, config: config, borrowed: borrowed)
        }
    }

    private func runAudioRecord(_ id: JobID, config: Leyline_V1_RecordConfig,
                                borrowed: (id: ChannelID, engine: any ChannelEngine, captureID: CaptureID)?) async
    {
        let lease: any ChannelLease
        let frequencyHz: UInt64
        if let borrowed {
            lease = BorrowedChannelLease(channelID: borrowed.id, captureID: borrowed.captureID, engine: borrowed.engine)
            let snapshot = await store.captureEngine(borrowed.captureID)?.snapshot
            let offset = await borrowed.engine.config.offsetHz
            frequencyHz = UInt64(Int64(snapshot?.centerHz ?? 0) + offset)
        } else {
            let mode = ProtoMapping.demodMode(config.mode == .unspecified ? .nfm : config.mode) ?? .nfm
            let deviceID = config.deviceID.isEmpty ? nil : DeviceID(string: config.deviceID)
            let allocation = await allocator.allocate(
                .channel(frequencyHz: config.frequencyHz, bandwidthHz: config.bandwidthHz, mode: mode,
                         deviceID: deviceID, takeOver: config.takeOver), for: id)
            guard case .channel(let made) = allocation else {
                await declineRecord(id, allocation)
                return
            }
            lease = made
            frequencyHz = config.frequencyHz
            // The squelch and the gain the request asked for, on the channel the allocator built.
            // A borrowed channel is left exactly as its owner set it.
            if let failure = await applyGain(config, capture: made.captureID) {
                await lease.release()
                await failRecordGain(id, failure)
                return
            }
            await applySquelch(config, to: made, gated: config.gate == .squelch, job: id)
        }
        // Allocating suspends, and a cancel that arrived in that window has already returned.
        guard jobIsLive(id) else {
            await lease.release()
            return
        }
        guard let snapshot = await store.captureEngine(lease.captureID)?.snapshot else {
            await lease.release()
            await finishRecord(id, state: .failed, detail: "the capture went away before the recording started",
                               code: EngineError.Code.captureNotFound)
            return
        }
        let channelConfig = await lease.engine.config
        let gated = config.gate == .squelch
        let manifest = RecordingManifest(
            jobID: id.string, kind: "audio", frequencyHz: frequencyHz,
            mode: modeName(channelConfig.mode), bandwidthHz: channelConfig.bandwidthHz,
            sampleRate: UInt64(lease.engine.audioRate), format: "wav-s16",
            device: await deviceInfo(lease.captureID), gains: gainInfo(snapshot),
            squelchDbfs: channelConfig.squelchDB,
            gate: gated ? RecordingGateInfo(kind: "squelch", preRollMs: preRollMs(config), hangMs: hangMs(config)) : nil,
            partMs: config.partMs, startedAtNs: WallClock.nowNs(),
            createdBy: recordingClient(id), anchors: [anchor(snapshot, capture: lease.captureID)])
        let writer: PartWriter
        do {
            writer = try await recordings.open(job: id, manifest: manifest,
                                               captureID: lease.captureID.string, centerHz: frequencyHz)
        } catch {
            await lease.release()
            await finishRecord(id, state: .failed, detail: "the recordings store would not open: \(error)",
                               code: EngineError.Code.internalError)
            return
        }
        let runner = RecordRunner(
            jobID: id, source: .audio(lease: lease, audioRate: lease.engine.audioRate), writer: writer,
            store: store, recordings: recordings, captureRateHz: snapshot.sampleRate,
            durationMs: config.durationMs, partMs: config.partMs, gated: gated,
            preRollMs: preRollMs(config), hangMs: hangMs(config), stopAfterQuietMs: config.stopAfterQuietMs,
            onStatus: { [weak self] state, detail, code in
                await self?.setRecordStatus(id, state: state, detail: detail, code: code)
            })
        setRecordRunner(id, runner)
        await runner.start()
    }

    private func runIQRecord(_ id: JobID, config: Leyline_V1_RecordConfig,
                             borrowed: (id: ChannelID, engine: any ChannelEngine, captureID: CaptureID)?) async
    {
        let lease: any CaptureIQLease
        if let borrowed {
            // The channel form with RAW_IQ records the named channel's capture, borrowed exactly
            // as its channel would be: the capture is not retuned.
            guard let capture = await store.captureEngine(borrowed.captureID) else {
                await finishRecord(id, state: .failed, detail: "that channel's capture is gone",
                                   code: EngineError.Code.captureNotFound)
                return
            }
            let rate = await capture.snapshot.sampleRate
            lease = BorrowedCaptureIQLease(captureID: borrowed.captureID, capture: capture, sampleRateHz: rate)
        } else {
            let deviceID = config.deviceID.isEmpty ? nil : DeviceID(string: config.deviceID)
            let allocation = await allocator.allocate(
                .captureIQ(frequencyHz: config.frequencyHz, sampleRateHz: 0, deviceID: deviceID,
                           takeOver: config.takeOver), for: id)
            guard case .captureIQ(let made) = allocation else {
                await declineRecord(id, allocation)
                return
            }
            lease = made
            if let failure = await applyGain(config, capture: made.captureID) {
                await lease.release()
                await failRecordGain(id, failure)
                return
            }
        }
        guard jobIsLive(id) else {
            await lease.release()
            return
        }
        guard let snapshot = await store.captureEngine(lease.captureID)?.snapshot else {
            await lease.release()
            await finishRecord(id, state: .failed, detail: "the capture went away before the recording started",
                               code: EngineError.Code.captureNotFound)
            return
        }
        // Size is why an IQ recording is cut into parts by default: 19.2 MB/s at 2.4 MSPS.
        let partMs = config.partMs > 0 ? config.partMs : Self.defaultIQPartMs
        let manifest = RecordingManifest(
            jobID: id.string, kind: "iq", frequencyHz: snapshot.centerHz, mode: "", bandwidthHz: 0,
            sampleRate: snapshot.sampleRate, format: "cf32",
            device: await deviceInfo(lease.captureID), gains: gainInfo(snapshot),
            squelchDbfs: Double.nan, gate: nil, partMs: partMs, startedAtNs: WallClock.nowNs(),
            createdBy: recordingClient(id), anchors: [anchor(snapshot, capture: lease.captureID)])
        let writer: PartWriter
        do {
            writer = try await recordings.open(job: id, manifest: manifest,
                                               captureID: lease.captureID.string, centerHz: snapshot.centerHz)
        } catch {
            await lease.release()
            await finishRecord(id, state: .failed, detail: "the recordings store would not open: \(error)",
                               code: EngineError.Code.internalError)
            return
        }
        let runner = RecordRunner(
            jobID: id, source: .iq(lease: lease), writer: writer, store: store, recordings: recordings,
            captureRateHz: snapshot.sampleRate, durationMs: config.durationMs, partMs: partMs,
            gated: false, preRollMs: 0, hangMs: 0, stopAfterQuietMs: 0,
            onStatus: { [weak self] state, detail, code in
                await self?.setRecordStatus(id, state: state, detail: detail, code: code)
            })
        setRecordRunner(id, runner)
        await runner.start()
    }

    // MARK: Details

    private func declineRecord(_ id: JobID, _ allocation: AllocationResult) async {
        if case .declined(let code, let reason) = allocation {
            await finishRecord(id, state: .failed, detail: reason, code: code)
        } else {
            await finishRecord(id, state: .failed, detail: "no radio could be allocated", code: EngineError.Code.noDevice)
        }
    }

    private func applySquelch(_ config: Leyline_V1_RecordConfig, to lease: any ChannelLease,
                              gated: Bool, job: JobID) async
    {
        // 0 dBFS is not a squelch anybody means: proto3 has no "absent" for a double, so an unset
        // field and a request to mute everything look the same, so 0 is read as unset. NaN is the
        // channel default too for a gated recording (`jobs.proto`, `squelch_dbfs`): a gate with the
        // squelch off has nothing to watch, and the app's channel page, which has no squelch of its
        // own to copy, sends NaN. `ley record --squelch off` sends NaN for a continuous recording,
        // where it means off.
        var want = config.squelchDbfs
        if want == 0 || (gated && want.isNaN) {
            // No level asked for. A continuous recording needs none; a gated one needs one or it
            // has nothing to watch, so the daemon measures the channel's own floor and sits above
            // it -- the same "auto" a person gets from `ley tune`, done where the channel is
            // (docs/design/recording.md: "NaN or unset = the channel default (auto), as ley tune").
            guard gated else { return }
            await setDetail(job, "measuring the noise floor")
            guard let measured = await autoSquelch(lease) else { return }
            want = measured
        }
        var channelConfig = await lease.engine.config
        channelConfig.squelchDB = want
        try? await lease.engine.update(channelConfig)
        await store.publishChannel(lease.channelID)
    }

    /// The noise floor at the channel's width plus 10 dB, from its own meter: the band's floor,
    /// which is the meter's power less its SNR, once the capture has measured one, else the
    /// channel's own power. The channel's power is its floor only while nothing is on it; on a
    /// broadcast carrier it is the carrier, and a squelch 10 dB above that never opens, so a gated
    /// recording of it would write nothing. `ley tune`'s auto sits over the band's floor for the
    /// same reason. Bounded: a channel whose meter never arrives leaves the squelch alone, and the
    /// gate then sees a squelch that is off -- which the runner reports rather than silently
    /// recording nothing.
    private func autoSquelch(_ lease: any ChannelLease) async -> Double? {
        let subscription = lease.engine.telemetrySubscription()
        var floors: [Double] = []
        var powers: [Double] = []
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Self.autoSquelchMs))
        for await t in subscription.stream {
            if case .meter(_, let power, let snr, _, _, _, _, _) = t, power.isFinite {
                powers.append(power)
                if snr.isFinite { floors.append(power - snr) }
            }
            if floors.count >= 5 || ContinuousClock.now >= deadline { break }
        }
        var readings = floors.isEmpty ? powers : floors
        guard !readings.isEmpty else { return nil }
        readings.sort()
        let floor = readings[readings.count / 2]
        return (floor + 10).rounded()
    }

    /// How long the auto-squelch measurement listens before giving up. Long enough for several
    /// meter intervals, short enough that the recording starts promptly.
    static let autoSquelchMs = 600

    /// Sets the gains the request asked for on the capture the allocator made, in order, and
    /// returns why one could not be set, or nil. `gains` wins over `gain` when both are sent
    /// (`jobs.proto`, `RecordConfig`). An empty element is the first the device lists and a name
    /// matches ignoring case (`resolvedGainElement`), as a gain write and a sweep read it. Passing
    /// an empty element through, or dropping the refusal, would leave `ley record --gain` never
    /// reaching a real radio: a HackRF take asked for 0 dB would run at LNA 8.
    private func applyGain(_ config: Leyline_V1_RecordConfig, capture: CaptureID) async -> EngineError? {
        let writes = config.gains.isEmpty ? (config.hasGain ? [config.gain] : []) : config.gains
        guard !writes.isEmpty else { return nil }
        guard let engine = await store.captureEngine(capture) else {
            return EngineError.captureNotFound(capture.string)
        }
        let elements = await store.deviceDescriptor(for: capture)?.gainElements ?? []
        var failure: EngineError?
        for write in writes {
            let value: GainValue
            switch write.value {
            case .db(let db): value = .db(db)
            case .auto(true): value = .auto
            default: continue
            }
            let element = resolvedGainElement(write.element, in: elements)
            guard elements.contains(where: { $0.name == element }) else {
                failure = unknownGainElement(write.element, in: elements, target: capture.string)
                break
            }
            do {
                try await engine.setGain(element: element, value: value)
            } catch {
                failure = error as? EngineError ?? EngineError.invalidArgument("\(error)", target: element)
                break
            }
        }
        // The stages set before a refusal did move, so the capture event says where they are.
        await store.publishCapture(capture)
        return failure
    }

    /// A recording at a gain other than the one asked for is not the take that was requested, so
    /// it does not start; the job fails with the radio's own reason, as a sweep's does.
    private func failRecordGain(_ id: JobID, _ failure: EngineError) async {
        await finishRecord(id, state: .failed, detail: "the gain asked for could not be set: \(failure.message)",
                           code: failure.code)
    }

    private func preRollMs(_ config: Leyline_V1_RecordConfig) -> UInt32 {
        config.preRollMs == 0 ? Self.defaultPreRollMs : config.preRollMs
    }

    private func hangMs(_ config: Leyline_V1_RecordConfig) -> UInt32 {
        config.hangMs == 0 ? Self.defaultHangMs : config.hangMs
    }

    private func deviceInfo(_ capture: CaptureID) async -> RecordingDevice? {
        guard let d = await store.deviceDescriptor(for: capture) else { return nil }
        return RecordingDevice(driver: d.driver, model: d.model, serial: d.serial)
    }

    private nonisolated func gainInfo(_ snapshot: CaptureSnapshot) -> [RecordingGain] {
        snapshot.gains.compactMap { g in
            if case .db(let db) = g.value { return RecordingGain(element: g.element, valueDb: db) }
            return nil
        }
    }

    private nonisolated func anchor(_ snapshot: CaptureSnapshot, capture: CaptureID) -> StoredAnchor {
        StoredAnchor(hostTimeNs: snapshot.anchor.hostTimeNsAtSampleZero, sampleRate: snapshot.anchor.sampleRate,
                     driftPpm: snapshot.anchor.driftPPM, fromSample: 0, captureID: capture.string)
    }

    private nonisolated func modeName(_ mode: DemodMode) -> String { mode.rawValue.uppercased() }
}

/// A record job's hold on a capture it did not make: the IQ sibling of `BorrowedChannelLease`.
/// Releasing does nothing, because the capture belongs to whoever was listening on it.
final class BorrowedCaptureIQLease: CaptureIQLease, Sendable {
    let captureID: CaptureID
    let sampleRateHz: UInt64
    let capture: any CaptureEngine

    init(captureID: CaptureID, capture: any CaptureEngine, sampleRateHz: UInt64) {
        self.captureID = captureID
        self.capture = capture
        self.sampleRateHz = sampleRateHz
    }

    var centerHz: UInt64 { get async { await capture.snapshot.centerHz } }

    func release() async {}
}
