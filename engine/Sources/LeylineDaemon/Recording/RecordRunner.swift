// SPDX-License-Identifier: GPL-3.0-or-later

// One record job's moving parts: the channel's audio (or the capture's IQ) into a part file, the
// squelch's own transitions into the gate, and a manifest that stays honest while it runs
// (docs/design/recording.md, "The daemon").
//
// Nothing here runs on the DSP thread (invariant 4). The only hot-path code is the sink the bulk
// audio path already owns and the capture tap the IQ bulk stream already owns; the drain task pops
// what they left in their rings and hands blocks to the PartWriter.

import EngineCore
import Foundation
import LeylineProto
import Logging

/// What the job table holds a record job's runner as, beside a decode job's.
protocol RecordRunning: AnyObject, Sendable {
    func start() async
    /// Ends the job and closes the files. `endedBy` is what the manifest records: "cancelled" for
    /// a client's CancelJob, "restart" for a daemon going down under it.
    func stop(endedBy: String) async
}

actor RecordRunner: RecordRunning {
    /// Slots in the IQ frame ring: the bulk `.iq` stream's depth, one capture block (cf32) each.
    static let iqSlots = 8
    /// How often the running detail is republished while the recording grows. The decode job's
    /// cadence, for the same reason: fast enough to see, slow enough not to flood.
    static let livenessInterval: Duration = .seconds(2)

    /// What the recording is reading. The channel form and the frequency form are the same case:
    /// the allocator decides who owns the channel, and the lease's own `release` is what differs.
    enum Source {
        case audio(lease: any ChannelLease, audioRate: UInt32)
        case iq(lease: any CaptureIQLease)
    }

    private let jobID: JobID
    private let source: Source
    private let writer: PartWriter
    private let store: SessionStore
    private let recordings: RecordingStore
    private let captureRateHz: UInt64
    /// 0 records until cancelled.
    private let durationSamples: UInt64
    /// 0 keeps one part for the whole recording.
    private let partSamples: UInt64
    private let gated: Bool
    private var gate: RecordGateMachine
    private let onStatus: @Sendable (Leyline_V1_JobState, String, String?) async -> Void
    private let log = Logger(label: "leyline.jobs.record")

    /// Where the recording's own timeline has reached, on the capture the samples came from.
    private var now: UInt64 = 0
    private var startSample: UInt64 = 0
    private var started = false
    private var currentPartStart: UInt64 = 0
    private var task: Task<Void, Never>?
    private var stopped = false
    private var endedBy: String?
    /// The terminal state the job is heading for, held until the files are finalised. A client
    /// that saw COMPLETED and read the manifest would otherwise race the part still being closed.
    private var pendingEnd: PendingEnd?

    /// `detail` nil means "say what the recording turned out to hold", computed once the last part
    /// is closed rather than while it is still open.
    private struct PendingEnd {
        var state: Leyline_V1_JobState
        var detail: String?
        var code: String?
    }
    /// Audio kept while no part is open, so a part can begin before the squelch did. Allocated once
    /// when the runner starts and never on a write path.
    private var preRoll: [Float] = []
    private var preRollCapacity = 0
    /// The capture sample the first element of `preRoll` sits at.
    private var preRollStart: UInt64 = 0
    /// Wakes whichever drain is parked, so a deadline or a cancel is acted on at once rather than
    /// at the next block. Set by the loop that owns the ring.
    private var wake: (@Sendable () -> Void)?
    /// The last squelch state the channel reported, for the liveness sentence.
    private var squelchOpen = false
    private var squelchChangedAt: ContinuousClock.Instant = .now
    private var degraded = false
    /// Set once the capture's real anchor has replaced the placeholder read at allocation.
    private var anchored = false

    init(jobID: JobID, source: Source, writer: PartWriter, store: SessionStore,
         recordings: RecordingStore, captureRateHz: UInt64, durationMs: Int64, partMs: Int64,
         gated: Bool, preRollMs: UInt32, hangMs: UInt32, stopAfterQuietMs: Int64,
         onStatus: @escaping @Sendable (Leyline_V1_JobState, String, String?) async -> Void)
    {
        self.jobID = jobID
        self.source = source
        self.writer = writer
        self.store = store
        self.recordings = recordings
        self.captureRateHz = captureRateHz
        self.onStatus = onStatus
        self.gated = gated
        durationSamples = durationMs > 0 ? UInt64(Double(durationMs) / 1000 * Double(captureRateHz)) : 0
        partSamples = partMs > 0 ? UInt64(Double(partMs) / 1000 * Double(captureRateHz)) : 0
        let perMs = Double(captureRateHz) / 1000
        gate = RecordGateMachine(preRollSamples: UInt64(Double(preRollMs) * perMs),
                                 hangSamples: UInt64(Double(hangMs) * perMs),
                                 quietSamples: stopAfterQuietMs > 0 ? UInt64(Double(stopAfterQuietMs) * perMs) : 0,
                                 startSample: 0)
        if case .audio(_, let audioRate) = source {
            preRollCapacity = gated ? Int(Double(preRollMs) / 1000 * Double(audioRate)) : 0
            preRoll.reserveCapacity(preRollCapacity)
        }
    }

    func start() {
        task = Task { [weak self] in await self?.loop() }
    }

    /// Ends the job: the open part is closed, the manifest says how, and the radio goes back.
    func stop(endedBy reason: String) async {
        task?.cancel()
        wake?()
        await teardown(endedBy: endedBy ?? reason)
    }

    private func teardown(endedBy reason: String) async {
        guard !stopped else { return }
        stopped = true
        for action in gate.finish(at: now) { await apply(action) }
        if await writer.isPartOpen { await writer.closePart(endSample: now) }
        await writer.finish(endedBy: reason, endSample: now)
        switch source {
        case .audio(let lease, _): await lease.release()
        case .iq(let lease): await lease.release()
        }
        // The store is brought back inside its cap once the recording has stopped growing. A
        // running one is never dropped, so this is the first moment this recording could be.
        await recordings.retain()
        // The terminal state goes out last, after the files are closed and the radio is back, the
        // same order a scan and a decode job end in: a client that sees the job finish finds the
        // recording finished too, rather than a manifest missing the part still being written.
        if let end = pendingEnd {
            pendingEnd = nil
            var detail = end.detail
            if detail == nil { detail = await completedDetail() }
            await onStatus(end.state, detail ?? "", end.code)
        }
    }

    // MARK: The loop

    private func loop() async {
        switch source {
        case .audio(let lease, let audioRate):
            await runAudio(lease: lease, audioRate: audioRate)
        case .iq(let lease):
            await runIQ(lease: lease)
        }
    }

    private func runAudio(lease: any ChannelLease, audioRate: UInt32) async {
        let engine = lease.engine
        let audio = AudioFrameSource(captureRate: captureRateHz, audioRate: audioRate, tap: .audio)
        do {
            try await engine.attach(audio.sink)
        } catch {
            finish(state: .failed, detail: "the channel would not take the recorder's sink: \(error)",
                   code: EngineError.Code.internalError, endedBy: "error")
            await teardown(endedBy: "error")
            return
        }
        wake = { audio.wake() }
        let squelch = Task { [weak self] in await self?.followSquelch(lease: lease) }
        let health = Task { [weak self] in await self?.followChannel(lease: lease) }
        let liveness = Task { [weak self] in await self?.followLiveness() }
        let deadline = startDeadline()
        // A continuous recording opens its one part at the first frame; a gated one waits for the
        // squelch. Either way the part's start is a real sample, never a guess.
        for await _ in audio.poke {
            if Task.isCancelled || stopped { break }
            while let frame = audio.next(s16: false) {
                await handle(frame: frame)
                if stopped { break }
            }
            if stopped { break }
        }
        squelch.cancel()
        health.cancel()
        liveness.cancel()
        deadline?.cancel()
        audio.wake()
        await engine.detach(audio.sink.id)
        audio.finish()
        await teardown(endedBy: endedBy ?? (Task.isCancelled ? "cancelled" : "error"))
    }

    /// `duration_ms` as a deadline on the clock as well as on the samples. The sample check inside
    /// the drain is the accurate one -- it is the recording's own timeline -- but a radio that
    /// stops delivering (a file device at the end of its file, a dongle unplugged) would leave a
    /// job that asked for five minutes running for ever. Whichever comes first ends it, and the
    /// manifest still says how much signal it actually holds.
    private func startDeadline() -> Task<Void, Never>? {
        guard durationSamples > 0, captureRateHz > 0 else { return nil }
        let seconds = Double(durationSamples) / Double(captureRateHz)
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled, let self else { return }
            await self.durationElapsed()
        }
    }

    private func durationElapsed() {
        guard !stopped, endedBy == nil else { return }
        finish(state: .completed, detail: nil, code: nil, endedBy: "duration")
    }

    private func runIQ(lease: any CaptureIQLease) async {
        let ring = FrameRing(slots: Self.iqSlots, slotBytes: CaptureDSPCore.blockSize * 8)
        let tapID = StreamID()
        let tap = IQFrameTap(id: tapID, ring: ring)
        await lease.capture.addTap(tap)
        wake = { ring.wake() }
        let liveness = Task { [weak self] in await self?.followLiveness() }
        let health = Task { [weak self] in await self?.followCapture(lease: lease) }
        let deadline = startDeadline()
        for await _ in ring.poke {
            if Task.isCancelled || stopped { break }
            while let popped = ring.pop() {
                if popped.droppedSamples > 0 {
                    await writer.noteGap(from: now, to: popped.sampleStart, reason: "samples dropped")
                }
                await handleIQ(popped)
                if stopped { break }
            }
            if stopped { break }
        }
        liveness.cancel()
        health.cancel()
        deadline?.cancel()
        await lease.capture.removeTap(id: tapID)
        ring.finish()
        await teardown(endedBy: endedBy ?? (Task.isCancelled ? "cancelled" : "error"))
    }

    // MARK: Frames

    /// One drained audio frame: the gate is advanced to the frame's end, then the samples go
    /// wherever the gate left the part. Deciding at frame granularity is the accuracy claim --
    /// a cut lands within one capture block of the transition.
    /// The capture's anchor, once it has one. A capture publishes it with its first block, so the
    /// snapshot a job reads while allocating carries a placeholder; this is where the real one
    /// lands, and every wall clock the recording derives depends on it (invariant 5).
    private func anchorOnce() async {
        guard !anchored else { return }
        guard let snapshot = await store.captureEngine(captureID)?.snapshot else { return }
        guard snapshot.anchor.hostTimeNsAtSampleZero != 0 else { return }
        anchored = true
        await writer.noteAnchor(snapshot.anchor, captureID: captureID.string, fromSample: 0)
    }

    private var captureID: CaptureID {
        switch source {
        case .audio(let lease, _): return lease.captureID
        case .iq(let lease): return lease.captureID
        }
    }

    private func handle(frame: AudioFrameSource.Frame) async {
        let floats = frame.payload.withUnsafeBytes { raw -> [Float] in
            Array(raw.bindMemory(to: Float.self))
        }
        let frameEnd = frame.sampleStart + frame.sampleCount
        await anchorOnce()
        if !started {
            started = true
            startSample = frame.sampleStart
            now = frame.sampleStart
            gate = RecordGateMachine(preRollSamples: gate.preRollSamples, hangSamples: gate.hangSamples,
                                     quietSamples: gate.quietSamples, startSample: frame.sampleStart)
            preRollStart = frame.sampleStart
            if !gated { await openPart(at: frame.sampleStart) }
        }
        if frame.droppedSamples > 0 {
            await writer.noteGap(from: now, to: frame.sampleStart, reason: "samples dropped")
        }
        now = frameEnd
        if gated {
            for action in gate.advance(to: frameEnd) { await apply(action) }
            if stopped { return }
        }
        if await writer.isPartOpen {
            await writer.append(audio: floats)
            await cutPartIfDue(at: frameEnd)
        } else if gated {
            keepPreRoll(floats, endingAt: frameEnd)
        }
        if await failIfWriteFailed() { return }
        await endIfDurationReached(at: frameEnd)
    }

    private func handleIQ(_ popped: FrameRing.Popped) async {
        await anchorOnce()
        if !started {
            started = true
            startSample = popped.sampleStart
            now = popped.sampleStart
            await openPart(at: popped.sampleStart)
        }
        now = popped.sampleStart + popped.sampleCount
        await writer.append(iq: popped.payload)
        await cutPartIfDue(at: now)
        if await failIfWriteFailed() { return }
        await endIfDurationReached(at: now)
    }

    /// The part timer. A part longer than `part_ms` is cut and the next one begins contiguously on
    /// the sample timebase: the rules compose, so a transmission longer than the part length is
    /// two parts with no gap between them.
    private func cutPartIfDue(at sample: UInt64) async {
        guard partSamples > 0, await writer.isPartOpen else { return }
        guard sample >= currentPartStart + partSamples else { return }
        await writer.closePart(endSample: sample)
        await openPart(at: sample)
    }

    /// A recording that cannot write is over: the job ends FAILED with what it managed to keep,
    /// rather than running on writing nothing. A full disk says so and names the free space and
    /// the flag, because that is what the reader does next (docs/design/recording.md, "Retention").
    /// Returns true when it ended the job.
    private func failIfWriteFailed() async -> Bool {
        guard let failure = await writer.writeFailure else { return false }
        let parts = await writer.parts
        let kept = parts == 0 ? "nothing was written" : "\(parts) part\(parts == 1 ? "" : "s") were kept"
        var detail = "\(failure); \(kept)"
        var reason = "error"
        if await writer.outOfSpace {
            reason = "store full"
            let free = writer.freeBytes().map { bytesText($0) } ?? "no"
            detail = "the disk is full (\(free) free); \(kept). leylined --recordings-cap trims the store, and --recordings moves it"
        }
        finish(state: .failed, detail: detail, code: EngineError.Code.failedPrecondition, endedBy: reason)
        return true
    }

    private func endIfDurationReached(at sample: UInt64) async {
        guard durationSamples > 0, sample >= startSample + durationSamples else { return }
        finish(state: .completed, detail: nil, code: nil, endedBy: "duration")
    }

    /// Audio the gate has not asked for yet. A ring of `pre_roll_ms` at the audio rate, so a part
    /// can begin before the squelch did.
    private func keepPreRoll(_ floats: [Float], endingAt sample: UInt64) {
        guard preRollCapacity > 0 else {
            preRollStart = sample
            return
        }
        preRoll.append(contentsOf: floats)
        if preRoll.count > preRollCapacity {
            preRoll.removeFirst(preRoll.count - preRollCapacity)
        }
        // Where the ring's first sample sits, in capture samples.
        let behind = UInt64(Double(preRoll.count) * Double(captureRateHz) / audioRateOrOne)
        preRollStart = sample > behind ? sample - behind : 0
    }

    private var audioRateOrOne: Double {
        if case .audio(_, let rate) = source { return Double(Swift.max(rate, 1)) }
        return 1
    }

    // MARK: The gate

    private func apply(_ action: RecordGateMachine.Action) async {
        switch action {
        case .openPart(let startSample):
            await openPart(at: startSample)
            await flushPreRoll(from: startSample)
        case .squelchOpened(let sample):
            await writer.noteSquelch(open: true, at: sample)
        case .squelchClosed(let sample):
            await writer.noteSquelch(open: false, at: sample)
        case .closePart(let endSample):
            // The part ends at the close transition plus the hang, which the drain may not have
            // reached yet; never past what has actually been written.
            await writer.closePart(endSample: Swift.min(endSample, now))
            // The gap between this part and the next is time nobody recorded, said out loud.
            currentPartStart = 0
        case .quiet:
            finish(state: .completed, detail: nil, code: nil, endedBy: "quiet")
        }
    }

    private func openPart(at sample: UInt64) async {
        await writer.openPart(at: sample)
        currentPartStart = sample
        // Coverage between the last part's end and this one's start is time the recording does not
        // hold. A continuous recording never lands here; a gated one does on every exchange.
        if let last = await writer.manifest.parts.last, last.endSample < sample {
            await writer.noteGap(from: last.endSample, to: sample, reason: "squelch closed")
        }
    }

    /// The pre-roll ring into the part that just opened, from its first sample.
    private func flushPreRoll(from sample: UInt64) async {
        guard !preRoll.isEmpty else { return }
        let perAudio = Double(captureRateHz) / audioRateOrOne
        let skipSamples = sample > preRollStart ? Double(sample - preRollStart) / perAudio : 0
        let skip = Swift.min(preRoll.count, Int(skipSamples.rounded()))
        let kept = Array(preRoll[skip...])
        preRoll.removeAll(keepingCapacity: true)
        if !kept.isEmpty { await writer.append(audio: kept) }
    }

    // MARK: Following the channel

    /// The squelch's own transitions, through the same in-process path TelemetryService uses. Never
    /// a second reader on the channel's DSP-side ring.
    private func followSquelch(lease: any ChannelLease) async {
        let subscription = lease.engine.telemetrySubscription()
        for await t in subscription.stream {
            if Task.isCancelled { return }
            switch t {
            case .squelch(let time, let open, _, _, _):
                await noteSquelch(open: open, at: time.sampleIndex)
            case .meter(_, _, _, let open, _, _):
                if open != squelchOpen {
                    squelchOpen = open
                    squelchChangedAt = .now
                }
            default:
                break
            }
        }
    }

    private func noteSquelch(open: Bool, at sample: UInt64) async {
        squelchOpen = open
        squelchChangedAt = .now
        guard gated, !stopped else { return }
        for action in gate.squelch(open: open, at: sample) { await apply(action) }
    }

    /// OUT_OF_CAPTURE degrades the job, closes the open part and records a coverage gap; the
    /// capture coming back opens a new part. The human is never blocked by a job
    /// (docs/design/control-plane.md): a retune over a recording degrades it, it does not refuse.
    ///
    /// The same loop notices the borrowed channel going away: its owner destroying it ends the job
    /// COMPLETED rather than orphaning a sink.
    private func followChannel(lease: any ChannelLease) async {
        var last: ChannelState?
        while !Task.isCancelled, !stopped {
            guard await store.channelEngine(lease.channelID) != nil else {
                finish(state: .completed, detail: "the channel it was recording was closed",
                       code: nil, endedBy: "channel ended")
                return
            }
            let state = await lease.engine.state
            if state != last {
                last = state
                switch state {
                case .outOfCapture:
                    await outOfCapture()
                case .active:
                    await backInCapture()
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// The IQ form has no channel: a capture that goes away stops the tap delivering, and the
    /// detach is what the job reports.
    private func followCapture(lease: any CaptureIQLease) async {
        while !Task.isCancelled, !stopped {
            let snapshot = await lease.capture.snapshot
            if snapshot.detached, !degraded {
                await outOfCapture()
            } else if !snapshot.detached, degraded {
                await backInCapture()
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func outOfCapture() async {
        guard !degraded else { return }
        degraded = true
        if await writer.isPartOpen { await writer.closePart(endSample: now) }
        outOfCaptureFrom = now
        let when = Date().formatted(date: .omitted, time: .standard)
        await onStatus(.degraded, "out of capture since \(when), will resume when \(fmtMHz(await writer.manifest.frequencyHz)) is back", nil)
    }

    private var outOfCaptureFrom: UInt64 = 0

    private func backInCapture() async {
        guard degraded else { return }
        degraded = false
        if outOfCaptureFrom > 0, now > outOfCaptureFrom {
            await writer.noteGap(from: outOfCaptureFrom, to: now, reason: "out of capture")
        }
        outOfCaptureFrom = 0
        if !gated { await openPart(at: now) }
        await onStatus(.running, await runningDetail(), nil)
    }

    // MARK: Liveness

    private func followLiveness() async {
        while !Task.isCancelled, !stopped {
            try? await Task.sleep(for: Self.livenessInterval)
            if Task.isCancelled || stopped || degraded { continue }
            await onStatus(.running, await runningDetail(), nil)
        }
    }

    /// "recording audio: 1 m 12 s, 3 parts, 6.9 MB", or for a gated recording that is waiting,
    /// "recording audio: 4 m 02 s, 3 parts, squelch closed 38 s".
    private func runningDetail() async -> String {
        let manifest = await writer.manifest
        let elapsed = captureRateHz > 0 && now > startSample
            ? Double(now - startSample) / Double(captureRateHz) : 0
        let parts = Swift.max(await writer.parts, await writer.isPartOpen ? 1 : 0)
        var line = "recording \(manifest.kind): \(elapsedText(elapsed)), \(parts) part\(parts == 1 ? "" : "s")"
        if gated, !squelchOpen {
            let closedFor = Int((ContinuousClock.now - squelchChangedAt).components.seconds)
            line += ", squelch closed \(closedFor) s"
        } else {
            line += ", \(bytesText(await writer.bytes))"
        }
        return line
    }

    private func completedDetail() async -> String {
        let parts = await writer.parts + (await writer.isPartOpen ? 1 : 0)
        let elapsed = captureRateHz > 0 && now > startSample
            ? Double(now - startSample) / Double(captureRateHz) : 0
        return "recorded \(elapsedText(elapsed)) in \(parts) part\(parts == 1 ? "" : "s"), \(bytesText(await writer.bytes))"
    }

    // MARK: Ending

    /// Ends the job from inside the runner: the loop is stopped and the terminal state is held
    /// until `teardown` has closed the files and handed the radio back, which is what publishes it.
    private func finish(state: Leyline_V1_JobState, detail: String?, code: String?, endedBy reason: String) {
        guard !stopped, endedBy == nil else { return }
        endedBy = reason
        pendingEnd = PendingEnd(state: state, detail: detail, code: code)
        task?.cancel()
        // The drain is parked on its ring; without this it would not notice until the next block,
        // which for a radio that has stopped delivering is never.
        wake?()
    }

    private nonisolated func elapsedText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        return String(format: "%d m %02d s", total / 60, total % 60)
    }

    private nonisolated func bytesText(_ bytes: UInt64) -> String {
        if bytes >= 1 << 30 { return String(format: "%.1f GB", Double(bytes) / Double(1 << 30)) }
        if bytes >= 1 << 20 { return String(format: "%.1f MB", Double(bytes) / Double(1 << 20)) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }

    private nonisolated func fmtMHz(_ hz: UInt64) -> String { String(format: "%.3f MHz", Double(hz) / 1e6) }
}

/// A record job's hold on a channel it did not make (`RecordConfig.channel_id`): the job borrows
/// what somebody is listening to and leaves it exactly as it found it. Releasing does nothing --
/// destroying the listener's channel because a recording ended would be the opposite of what
/// "record what you are hearing" means.
final class BorrowedChannelLease: ChannelLease, @unchecked Sendable {
    let channelID: ChannelID
    let captureID: CaptureID
    let engine: any ChannelEngine

    init(channelID: ChannelID, captureID: CaptureID, engine: any ChannelEngine) {
        self.channelID = channelID
        self.captureID = captureID
        self.engine = engine
    }

    func release() async {}
}
