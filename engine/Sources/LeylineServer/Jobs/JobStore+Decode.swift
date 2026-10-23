// SPDX-License-Identifier: GPL-3.0-or-later

// Decode jobs: a decoder plugin on a channel or a capture (docs/dev/engine-internals.md, "Decoders").

import EngineCore
import Foundation
import LeylineProto
import Logging
import Synchronization

extension JobStore {
    // MARK: Starting a decode

    /// Runs a decoder on its recipe (docs/design/decoders.md, "Decisions": "A decode job is a
    /// job"). The lookup and the refusals happen here, where the caller can be told; everything
    /// that can take a radio's time happens in the task. `resuming` starts a kept job again as the
    /// job it was: the same id, so its records and its resource URI carry on, and the time it was
    /// first started.
    func startDecode(config: Leyline_V1_DecodeConfig, by client: ClientContext,
                     resuming: (id: JobID, createdAtNs: Int64)? = nil) async throws -> Leyline_V1_Job
    {
        guard let installed = decoders.find(config.decoder) else {
            throw EngineError.decoderNotFound(config.decoder)
        }
        if installed.manifest.input.mode == .slotAligned {
            throw EngineError.unimplemented("slot-aligned decoder input")
        }
        // Overs are cut at a channel's squelch, and raw IQ has no channel.
        if installed.manifest.input.mode == .segmented, installed.manifest.input.signal == .signalIq {
            throw EngineError.unimplemented("segmented IQ decoder input")
        }
        // A key the provider has already refused would fail the decoder's first call, so the
        // caller is told now, in the provider's words, rather than by a job that dies later.
        // A decoder that calls a provider cannot start without the key, and the caller is told
        // the command that adds one rather than meeting a job that fails at its first call.
        let provider = installed.manifest.credentialProvider
        if !provider.isEmpty {
            guard let key = await credentials?.credential(provider) else {
                throw EngineError.credentialMissing(provider)
            }
            if key.lastCheck.outcome == .rejected {
                throw EngineError.credentialRejected(provider, providerMessage: key.lastCheck.message)
            }
        }
        if !config.sourceUri.isEmpty {
            return try await startSourceDecode(config: config, installed: installed, by: client, resuming: resuming)
        }
        let frequencyHz = config.frequencyHz != 0 ? config.frequencyHz : (installed.manifest.recipe.frequenciesHz.first ?? 0)
        guard frequencyHz > 0 else {
            throw EngineError.invalidArgument("\(config.decoder) names no frequency of its own; say which with --freq", target: config.decoder)
        }
        let deviceID = config.deviceID.isEmpty ? nil : DeviceID(string: config.deviceID)
        if !config.deviceID.isEmpty, deviceID == nil {
            throw EngineError.deviceNotFound(config.deviceID)
        }

        return await addDecodeJob(config: config, installed: installed, by: client, resuming: resuming) { [weak self] id in
            await self?.runDecode(id, config: config, installed: installed, frequencyHz: frequencyHz, deviceID: deviceID)
        }
    }

    /// Enters a decode job in the table and starts `run` for it. The task goes in before the first
    /// suspension, for the same reason a scan's does: a cancel arriving while `publishJob` runs
    /// must find something to cancel.
    private func addDecodeJob(config: Leyline_V1_DecodeConfig, installed: DecoderRegistry.Installed,
                              by client: ClientContext, resuming: (id: JobID, createdAtNs: Int64)?,
                              run: @escaping @Sendable (JobID) async -> Void) async -> Leyline_V1_Job
    {
        let id = resuming?.id ?? JobID()
        var job = Leyline_V1_Job()
        job.jobID = id.string
        job.state = .running
        job.createdAtNs = resuming?.createdAtNs ?? WallClock.nowNs()
        job.createdBy = client.proto
        job.config = .decode(config)
        job.statusDetail = resuming == nil ? "starting" : "resuming after a daemon restart"
        // Persistence follows intent (invariant 8): only a kept job's records are a resource. A
        // live segmented job's clips are one while it runs, and stay one only when it is kept.
        if config.keep { job.resultUris = ["ley://records/\(id.string)"] }
        if Self.writesClips(config, installed.manifest) { job.resultUris.append("ley://recordings/\(id.string)") }
        let task = Task { await run(id) }
        entries[id] = Entry(proto: job, scan: nil, task: task, ownerClientID: client.id, decode: nil, keep: config.keep,
                            credentialProvider: installed.manifest.credentialProvider)
        order.append(id)
        trim()
        if config.keep { persistKept() }
        await store.publishJob(job)
        return job
    }

    /// Whether the job records its audio as clips: a SEGMENTED decoder on a live channel. A job
    /// that reads a stored recording already has its audio.
    static func writesClips(_ config: Leyline_V1_DecodeConfig, _ manifest: Leyline_V1_DecoderManifest) -> Bool {
        config.sourceUri.isEmpty && manifest.input.mode == .segmented && manifest.input.signal != .signalIq
    }

    // MARK: A stored recording

    /// A decode job over a stored recording (`DecodeConfig.source_uri`). The recording is read and
    /// cut here, so a missing one, a part URI or an IQ recording is refused to the caller. No
    /// allocation, channel or lease: the job needs no radio, so a daemon without hardware runs it.
    private func startSourceDecode(config: Leyline_V1_DecodeConfig, installed: DecoderRegistry.Installed,
                                   by client: ClientContext,
                                   resuming: (id: JobID, createdAtNs: Int64)?) async throws -> Leyline_V1_Job
    {
        if installed.manifest.input.signal == .signalIq {
            throw EngineError.unimplemented("an IQ decoder on a stored recording")
        }
        let source = try await RecordingSource.open(uri: config.sourceUri, store: recordings,
                                                    input: installed.manifest.input)
        return await addDecodeJob(config: config, installed: installed, by: client, resuming: resuming) { [weak self] id in
            await self?.runSourceDecode(id, config: config, installed: installed, source: source)
        }
    }

    private func runSourceDecode(_ id: JobID, config: Leyline_V1_DecodeConfig, installed: DecoderRegistry.Installed,
                                 source: RecordingSource) async
    {
        guard entries[id]?.proto.state == .running else { return }
        let writer: RecordWriter?
        do {
            writer = try await openSourceWriterIfKept(id, config: config, installed: installed, source: source)
        } catch {
            await finish(id, state: .failed, detail: "the record store would not open: \(error)",
                         code: EngineError.Code.internalError)
            return
        }
        let runner = DecodeRunner(
            jobID: id, installed: installed, lease: nil, source: source, hub: hub, writer: writer, store: store,
            frequencyHz: source.manifest.frequencyHz, captureRateHz: source.captureRate, tap: .audio,
            predicate: config.predicate, notify: config.hasNotify ? config.notify : nil,
            usage: usage, credentials: credentials, keep: config.keep,
            onStatus: { [weak self] state, detail in
                await self?.setDecodeStatus(id, state: state, detail: detail)
            },
            onFailure: { [weak self] error in
                await self?.finish(id, state: .failed, detail: error.message, code: error.code)
            },
            seqStart: await writer?.recordCount ?? 0)
        entries[id]?.decode = runner
        await runner.start()
    }

    /// The kept job's store, dated by the recording's own anchors, so a record from a stored
    /// recording has the wall clock the audio was heard at.
    private func openSourceWriterIfKept(_ id: JobID, config: Leyline_V1_DecodeConfig,
                                        installed: DecoderRegistry.Installed,
                                        source: RecordingSource) async throws -> RecordWriter?
    {
        guard config.keep else { return nil }
        let anchors = source.manifest.anchors
        let first = anchors.first
        let capture = first.flatMap { CaptureID(string: $0.captureID ?? "") }
            ?? CaptureID(string: source.parts.first?.captureID ?? "") ?? CaptureID()
        await records.retain()
        let writer = try await records.open(
            job: id, config: config, manifest: installed.manifest, capture: capture,
            anchor: first.map { CaptureAnchor(hostTimeNsAtSampleZero: $0.hostTimeNs, sampleRate: $0.sampleRate, driftPPM: $0.driftPpm) })
        for a in anchors.dropFirst() {
            await writer.noteAnchor(CaptureAnchor(hostTimeNsAtSampleZero: a.hostTimeNs, sampleRate: a.sampleRate, driftPPM: a.driftPpm),
                                    fromSample: a.fromSample, captureID: a.captureID)
        }
        return writer
    }

    private func runDecode(_ id: JobID, config: Leyline_V1_DecodeConfig, installed: DecoderRegistry.Installed,
                           frequencyHz: UInt64, deviceID: DeviceID?) async
    {
        guard entries[id]?.proto.state == .running else { return }
        // The signal the manifest declares picks the input the daemon streams (docs/design/
        // decoders.md, "Multiplexing"; DecoderSignal): SIGNAL_IQ taps the whole capture band as
        // cf32, everything else is a channel's demodulated audio.
        if installed.manifest.input.signal == .signalIq {
            await runIQDecode(id, config: config, installed: installed, frequencyHz: frequencyHz, deviceID: deviceID)
        } else {
            await runAudioDecode(id, config: config, installed: installed, frequencyHz: frequencyHz, deviceID: deviceID)
        }
    }

    private func runAudioDecode(_ id: JobID, config: Leyline_V1_DecodeConfig, installed: DecoderRegistry.Installed,
                                frequencyHz: UInt64, deviceID: DeviceID?) async
    {
        let mode = ProtoMapping.demodMode(installed.manifest.recipe.mode == .unspecified ? .nfm : installed.manifest.recipe.mode) ?? .nfm
        let allocation = await allocator.allocate(
            .channel(frequencyHz: frequencyHz, bandwidthHz: installed.manifest.recipe.bandwidthHz,
                     mode: mode, deviceID: deviceID, takeOver: config.takeOver), for: id)
        guard case .channel(let lease) = allocation else {
            await declineDecode(id, allocation)
            return
        }
        // Allocating suspends, and a cancel in that window has already returned. Hand the radio
        // back rather than decoding for a job nobody is waiting on.
        guard entries[id]?.proto.state == .running else {
            await lease.release()
            return
        }
        // A squelch that could not be measured or set leaves a segmented job with no edges to cut
        // at; it runs, DEGRADED with the reason, rather than looking healthy.
        var squelchProblem: String?
        if installed.manifest.input.mode == .segmented {
            squelchProblem = await squelchForSegments(id, lease: lease)
        }
        let snapshot = await store.captureEngine(lease.captureID)?.snapshot
        let writer: RecordWriter?
        do {
            writer = try await openWriterIfKept(id, config: config, installed: installed,
                                                capture: lease.captureID, anchor: snapshot?.anchor)
        } catch {
            await lease.release()
            await finish(id, state: .failed, detail: "the record store would not open: \(error)",
                         code: EngineError.Code.internalError)
            return
        }
        var clips: LiveClips?
        if Self.writesClips(config, installed.manifest) {
            do {
                clips = try await openClips(id, lease: lease, frequencyHz: frequencyHz, keep: config.keep)
            } catch {
                await writer?.close()
                await lease.release()
                await finish(id, state: .failed, detail: "the recordings store would not open: \(error)",
                             code: EngineError.Code.internalError)
                return
            }
        }
        let runner = DecodeRunner(
            jobID: id, installed: installed, lease: lease, hub: hub, writer: writer, store: store,
            frequencyHz: frequencyHz, captureRateHz: snapshot?.sampleRate ?? 0,
            tap: installed.manifest.input.tap == .tapDemod ? .demod : .audio,
            predicate: config.predicate, notify: config.hasNotify ? config.notify : nil,
            usage: usage, credentials: credentials, keep: config.keep, standingDegradation: squelchProblem,
            clips: clips,
            onStatus: { [weak self] state, detail in
                await self?.setDecodeStatus(id, state: state, detail: detail)
            },
            onFailure: { [weak self] error in
                await self?.finish(id, state: .failed, detail: error.message, code: error.code)
            },
            seqStart: await writer?.recordCount ?? 0)
        entries[id]?.decode = runner
        await runner.start()
    }

    private func runIQDecode(_ id: JobID, config: Leyline_V1_DecodeConfig, installed: DecoderRegistry.Installed,
                             frequencyHz: UInt64, deviceID: DeviceID?) async
    {
        // The recipe's sample rate when it names one, else the device's default (allocator's choice).
        let allocation = await allocator.allocate(
            .captureIQ(frequencyHz: frequencyHz, sampleRateHz: installed.manifest.recipe.sampleRate,
                       deviceID: deviceID, takeOver: config.takeOver), for: id)
        guard case .captureIQ(let lease) = allocation else {
            await declineDecode(id, allocation)
            return
        }
        guard entries[id]?.proto.state == .running else {
            await lease.release()
            return
        }
        let snapshot = await store.captureEngine(lease.captureID)?.snapshot
        let writer: RecordWriter?
        do {
            writer = try await openWriterIfKept(id, config: config, installed: installed,
                                                capture: lease.captureID, anchor: snapshot?.anchor)
        } catch {
            await lease.release()
            await finish(id, state: .failed, detail: "the record store would not open: \(error)",
                         code: EngineError.Code.internalError)
            return
        }
        let runner = IQDecodeRunner(
            jobID: id, installed: installed, lease: lease, hub: hub, writer: writer, store: store,
            predicate: config.predicate, notify: config.hasNotify ? config.notify : nil,
            credentials: credentials,
            onStatus: { [weak self] state, detail in
                await self?.setDecodeStatus(id, state: state, detail: detail)
            },
            seqStart: await writer?.recordCount ?? 0)
        entries[id]?.decode = runner
        await runner.start()
    }

    /// SEGMENTED input cuts at the squelch's edges, and a channel with the squelch off has none:
    /// every meter says open, and the plugin would get one segment that never ends. The job's own
    /// channel gets the gated recorder's auto squelch, the band's floor plus 10 dB, measured where
    /// the channel is (`autoSquelch`). A channel whose meter never arrives keeps its squelch off.
    /// Returns what went wrong, for the job to stay DEGRADED with, or nil.
    private func squelchForSegments(_ id: JobID, lease: any ChannelLease) async -> String? {
        var channelConfig = await lease.engine.config
        guard channelConfig.squelchDB.isNaN else { return nil }
        await setDetail(id, "measuring the noise floor")
        guard let measured = await autoSquelch(lease) else {
            return "no level measured; squelch left as it was"
        }
        channelConfig.squelchDB = measured
        do {
            try await lease.engine.update(channelConfig)
        } catch {
            return "the squelch could not be set (\((error as? EngineError)?.message ?? "\(error)")); squelch left as it was"
        }
        await store.publishChannel(lease.channelID, squelchAuto: true)
        return nil
    }

    /// Fails the job with the allocator's decline reason and code (or a fallback when it declined
    /// without one).
    private func declineDecode(_ id: JobID, _ allocation: AllocationResult) async {
        if case .declined(let code, let reason) = allocation {
            await finish(id, state: .failed, detail: reason, code: code)
        } else {
            await finish(id, state: .failed, detail: "no radio could be allocated", code: EngineError.Code.noDevice)
        }
    }

    /// Opens the record store writer when the job is kept, else nil. Retention runs when a kept job
    /// starts, as the design doc says, so the store is inside its cap before it is written to.
    private func openWriterIfKept(_ id: JobID, config: Leyline_V1_DecodeConfig,
                                  installed: DecoderRegistry.Installed, capture: CaptureID,
                                  anchor: CaptureAnchor?) async throws -> RecordWriter?
    {
        guard config.keep else { return nil }
        await records.retain()
        return try await records.open(job: id, config: config, manifest: installed.manifest,
                                      capture: capture, anchor: anchor)
    }

    /// Ends every live decode job whose decoder uses `provider`'s key, FAILED with
    /// `CREDENTIAL_MISSING` and the command that adds one: the key has been deleted, and a job
    /// left running would fail on its next call anyway, or worse, keep a key the user meant to
    /// revoke in use. A kept job ends too and is not resumed at the next start.
    func endJobs(usingCredential provider: String) async {
        guard !provider.isEmpty else { return }
        let error = EngineError.credentialMissing(provider)
        for id in order {
            guard let e = entries[id], Self.isLive(e.proto.state), e.credentialProvider == provider else { continue }
            log.info("ending \(id.string): the \(provider) key it uses was deleted")
            e.task?.cancel()
            if let runner = e.decode { await runner.stop() }
            await finish(id, state: .failed, detail: error.message, code: error.code)
        }
    }

    /// What the runner reports. FAILED is terminal and carries the decoder's code; RUNNING and
    /// DEGRADED are the job moving between having its capture and waiting for it back.
    private func setDecodeStatus(_ id: JobID, state: Leyline_V1_JobState, detail: String) async {
        guard var e = entries[id], Self.isLive(e.proto.state) else { return }
        if state == .failed {
            await finish(id, state: .failed, detail: detail, code: EngineError.Code.decoderFailed)
            return
        }
        // A job that reads a stored recording ends on its own once the plugin has had all of it.
        if state == .completed {
            await finish(id, state: .completed, detail: detail)
            return
        }
        e.proto.state = state
        e.proto.statusDetail = detail
        entries[id] = e
        await store.publishJob(e.proto)
    }
}
