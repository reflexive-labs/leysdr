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
        let frequencyHz = config.frequencyHz != 0 ? config.frequencyHz : (installed.manifest.recipe.frequenciesHz.first ?? 0)
        guard frequencyHz > 0 else {
            throw EngineError.invalidArgument("\(config.decoder) names no frequency of its own; say which with --freq", target: config.decoder)
        }
        let deviceID = config.deviceID.isEmpty ? nil : DeviceID(string: config.deviceID)
        if !config.deviceID.isEmpty, deviceID == nil {
            throw EngineError.deviceNotFound(config.deviceID)
        }

        let id = resuming?.id ?? JobID()
        var job = Leyline_V1_Job()
        job.jobID = id.string
        job.state = .running
        job.createdAtNs = resuming?.createdAtNs ?? realtimeNs()
        job.createdBy = client.proto
        job.config = .decode(config)
        job.statusDetail = resuming == nil ? "starting" : "resuming after a daemon restart"
        // Persistence follows intent (invariant 8): only a kept job has a resource.
        if config.keep { job.resultUris = ["ley://records/\(id.string)"] }

        // The task goes in before the first suspension, for the same reason a scan's does: a cancel
        // arriving while `publishJob` runs must find something to cancel.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDecode(id, config: config, installed: installed, frequencyHz: frequencyHz, deviceID: deviceID)
        }
        entries[id] = Entry(proto: job, scan: nil, task: task, ownerClientID: client.id, decode: nil, keep: config.keep)
        order.append(id)
        trim()
        if config.keep { persistKept() }
        await store.publishJob(job)
        return job
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
        let runner = DecodeRunner(
            jobID: id, installed: installed, lease: lease, hub: hub, writer: writer, store: store,
            frequencyHz: frequencyHz, captureRateHz: snapshot?.sampleRate ?? 0,
            tap: installed.manifest.input.tap == .tapDemod ? .demod : .audio,
            predicate: config.predicate, notify: config.hasNotify ? config.notify : nil,
            onStatus: { [weak self] state, detail in
                await self?.setDecodeStatus(id, state: state, detail: detail)
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
            onStatus: { [weak self] state, detail in
                await self?.setDecodeStatus(id, state: state, detail: detail)
            },
            seqStart: await writer?.recordCount ?? 0)
        entries[id]?.decode = runner
        await runner.start()
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

    /// What the runner reports. FAILED is terminal and carries the decoder's code; RUNNING and
    /// DEGRADED are the job moving between having its capture and waiting for it back.
    private func setDecodeStatus(_ id: JobID, state: Leyline_V1_JobState, detail: String) async {
        guard var e = entries[id], Self.isLive(e.proto.state) else { return }
        if state == .failed {
            await finish(id, state: .failed, detail: detail, code: EngineError.Code.decoderFailed)
            return
        }
        e.proto.state = state
        e.proto.statusDetail = detail
        entries[id] = e
        await store.publishJob(e.proto)
    }
}
