// SPDX-License-Identifier: GPL-3.0-or-later

// One decode job's moving parts: the channel's audio into the plugin, the plugin's records out
// (docs/design/decoders.md, "Decisions": "A decode job is a job").
//
// Nothing here runs on the DSP thread (invariant 4). The only hot-path code is the AudioFrameSource
// callback the channel already owns; the drain task pops what it left in the ring and writes it to
// the plugin, and the reader task stamps what comes back.

import EngineCore
import Foundation
import LeylineProto
import Logging
import Synchronization

actor DecodeRunner {
    /// How long after a plugin exits before it is spawned again, and the ceiling the wait doubles
    /// to. A decoder that crashes on every frame should not spin the CPU.
    static let firstRestartSeconds: Double = 1
    static let maxRestartSeconds: Double = 30
    /// The exit status a plugin uses to say its provider refused a request for a reason of its own
    /// (a rate or spend limit), with the provider's words as its last line on stderr: `EX_TEMPFAIL`
    /// from `sysexits.h`, "try again later". A kept job waits and retries on the restart backoff;
    /// any other job ends with `PROVIDER_REFUSED`, since nobody asked it to outlast the refusal.
    static let refusedExitStatus: Int32 = 75

    private let jobID: JobID
    private let installed: DecoderRegistry.Installed
    /// The channel the job decodes, or nil when it reads a stored recording instead.
    private let lease: (any ChannelLease)?
    /// The stored recording the job reads (`DecodeConfig.source_uri`), or nil on a channel.
    private let source: RecordingSource?
    /// The next of the source's items the plugin has not had whole, so a restarted plugin starts
    /// where its predecessor was cut off rather than at the beginning.
    private let sourceCursor = Mutex(0)
    private let hub: RecordHub
    private let writer: RecordWriter?
    private let store: SessionStore
    private let frequencyHz: UInt64
    private let captureRateHz: UInt64
    private let tap: AudioTap
    /// The daemon-side record filter and where a passing record fires (docs/design/decoders.md,
    /// "Predicates and delivery"). An empty predicate matches everything; notify nil is delivery
    /// with no side channel. Both are read off the DecodeConfig in JobStore.startDecode.
    private let predicate: Leyline_V1_Predicate
    private let notify: Leyline_V1_NotifyTarget?
    private let notifier = Notifier()
    /// Where the usage a record carries goes, before the record is published.
    private let usage: UsageRecorder?
    /// The user's keys, so a refusal's words are cleared of the decoder's key before they reach
    /// `status_detail` or an error (`WorkerProcess.redacting(_:in:)`).
    private let credentials: CredentialStore?
    private let onStatus: @Sendable (Leyline_V1_JobState, String) async -> Void
    /// Ends the job with a code of its own, where `onStatus(.failed, …)` would say the decoder
    /// failed. Nil falls back to that.
    private let onFailure: (@Sendable (EngineError) async -> Void)?
    /// `keep`: whether a refusal is waited out (`refusedExitStatus`).
    private let keep: Bool
    private let log: Logger

    /// The record sequence: 1-based and contiguous per job, so it continues from what a kept job's
    /// store already holds when the job is resumed after a restart.
    private var seq: UInt64
    /// Record count and last-record time, for the detail it publishes while RUNNING.
    private var liveness = DecodeLiveness()
    /// The DEGRADED detail while the channel is out of its capture, nil while it is in. Every
    /// RUNNING the runner would publish goes through `publishRunning`, which reads this, because
    /// the record count moving is not the channel coming back: records still arrive after the
    /// move, and the count's two-second republish would otherwise put a degraded job back to
    /// RUNNING while the capture is still away.
    private var awayDetail: String?
    /// A fault the job lives with for its whole run, published as DEGRADED wherever RUNNING would
    /// be: a segmented job whose squelch could not be measured or set has no edges to cut at.
    private let standingDegradation: String?
    private var rssiDBFS = Double.nan
    private var snrDB = Double.nan
    private var task: Task<Void, Never>?
    /// The plugin the drain is feeding. Held outside the actor because the drain runs as its own
    /// task: a pipe write must never park the actor that is also stamping records.
    private let currentPlugin = Mutex<PluginProcess?>(nil)
    /// SEGMENTED input's cutter, nil for every other mode. Set once by `loop` before the drain and
    /// the squelch follower start, and shared by the two: the follower hands it records, the drain
    /// hands it audio and writes what it releases.
    private let segmenter = Mutex<Segmenter?>(nil)
    private var stopped = false

    /// Exactly one of `lease` and `source` is set: a channel to decode or a recording to read.
    init(jobID: JobID, installed: DecoderRegistry.Installed, lease: (any ChannelLease)?,
         source: RecordingSource? = nil, hub: RecordHub,
         writer: RecordWriter?, store: SessionStore, frequencyHz: UInt64, captureRateHz: UInt64,
         tap: AudioTap, predicate: Leyline_V1_Predicate, notify: Leyline_V1_NotifyTarget?,
         usage: UsageRecorder? = nil, credentials: CredentialStore? = nil, keep: Bool = false,
         standingDegradation: String? = nil,
         onStatus: @escaping @Sendable (Leyline_V1_JobState, String) async -> Void,
         onFailure: (@Sendable (EngineError) async -> Void)? = nil,
         seqStart: UInt64 = 0)
    {
        self.jobID = jobID
        self.installed = installed
        self.lease = lease
        self.source = source
        self.hub = hub
        self.writer = writer
        self.store = store
        self.frequencyHz = frequencyHz
        self.captureRateHz = captureRateHz
        self.tap = tap
        self.predicate = predicate
        self.notify = notify
        self.usage = usage
        self.credentials = credentials
        self.keep = keep
        self.standingDegradation = standingDegradation
        self.onStatus = onStatus
        self.onFailure = onFailure
        seq = seqStart
        log = Logger(label: "leyline.jobs.decode")
    }

    func start() {
        task = Task { [weak self] in await self?.loop() }
    }

    /// Ends the job: the plugin goes, the store writer is closed and the radio goes back.
    func stop() async {
        task?.cancel()
        await teardown()
    }

    /// The same hand-back without cancelling the loop, for the paths that are already inside it.
    /// Idempotent: cancel, a failure and shutdown can all arrive.
    private func teardown() async {
        guard !stopped else { return }
        stopped = true
        if let plugin = currentPlugin.withLock({ $0 }) { await plugin.stop() }
        currentPlugin.withLock { $0 = nil }
        await writer?.close()
        await lease?.release()
    }

    // MARK: The loop

    private func loop() async {
        if let source {
            await loopSource(source)
            return
        }
        guard let lease else { return }
        let engine = lease.engine
        let audio = AudioFrameSource(captureRate: captureRateHz, audioRate: engine.audioRate, tap: tap)
        do {
            try await engine.attach(audio.sink)
        } catch {
            await onStatus(.failed, "the channel would not take the decoder's sink: \(error)")
            await teardown()
            return
        }
        let meter = Task { [weak self] in await self?.followMeter(lease) }
        let health = Task { [weak self] in await self?.followChannel(lease) }
        var squelch: Task<Void, Never>?
        if installed.manifest.input.mode == .segmented {
            let (preRollMs, hangMs) = Segmenter.timings(installed.manifest.input)
            segmenter.withLock {
                $0 = Segmenter(preRollMs: preRollMs, hangMs: hangMs, captureRateHz: captureRateHz,
                               audioRateHz: engine.audioRate)
            }
            squelch = Task { [weak self] in await self?.followSquelch(audio: audio, lease: lease) }
        }
        // One drain for the life of the job, not one per plugin: `AudioFrameSource.poke` has a
        // single iterator, and a second `for await` on it would see a finished stream and feed a
        // restarted plugin nothing. Frames written while no plugin is up are dropped, and the ring
        // reports what was lost as a Gap on the next frame that lands.
        let drain = Task { [weak self] in await self?.drain(audio: audio, lease: lease) }
        let counting = Task { [weak self] in await self?.followRecords() }
        var wait = Self.firstRestartSeconds
        var restarts = 0
        while !Task.isCancelled {
            let exit = await runPlugin()
            if Task.isCancelled || stopped { break }
            restarts += 1
            guard await recover(from: exit, restarts: restarts, wait: wait) else { break }
            wait = Swift.min(wait * 2, Self.maxRestartSeconds)
        }
        meter.cancel()
        health.cancel()
        squelch?.cancel()
        drain.cancel()
        counting.cancel()
        audio.wake()
        await engine.detach(audio.sink.id)
        audio.finish()
    }

    /// After a plugin exit nobody asked for: a refusal ends a job that is not kept, and otherwise
    /// the job says what happened, waits `wait` seconds and goes back to RUNNING for the restart.
    /// False when the job is over.
    private func recover(from exit: (status: Int32, lastErrorLine: String?), restarts: Int, wait: Double) async -> Bool {
        if exit.status == Self.refusedExitStatus {
            let said = await redacted(exit.lastErrorLine ?? "no reason given")
            guard keep else {
                await fail(EngineError.providerRefused(providerName, providerMessage: said))
                await teardown()
                return false
            }
            await onStatus(.degraded, "the provider refused: \(said); retrying in \(Int(wait)) s (retry \(restarts))")
        } else {
            // A coverage gap the job reports. A transcript's own Gap list arrives with the
            // watch job, which is not built yet (docs/plans/build-order.md).
            await onStatus(.degraded, "the decoder exited (status \(exit.status)); restarting in \(Int(wait)) s (restart \(restarts))")
        }
        try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        if Task.isCancelled || stopped { return false }
        await publishRunning(liveness.detail(decoder: installed.manifest.name))
        return true
    }

    // MARK: A stored recording

    /// How long a plugin may take to exit once a recording has all gone: a base, plus a share for
    /// each segment it has not yet answered, since a speech plugin may still be transcribing them.
    /// Settable so a test need not wait half a minute.
    static let sourceExitAllowance = Mutex<(baseSeconds: Double, perItemSeconds: Double)>((30, 2))

    /// The restart loop for a job that reads a recording. It ends on its own: once every item has
    /// reached the plugin and the plugin has exited cleanly with its last records written, the job
    /// is COMPLETED.
    private func loopSource(_ source: RecordingSource) async {
        let counting = Task { [weak self] in await self?.followRecords() }
        defer { counting.cancel() }
        var wait = Self.firstRestartSeconds
        var restarts = 0
        while !Task.isCancelled {
            let exit = await runSourcePlugin(source)
            if Task.isCancelled || stopped { return }
            switch exit.fed {
            case .unreadable(let why):
                await teardown()
                await fail(EngineError.failedPrecondition("\(source.uri) could not be read: \(why)", target: source.uri))
                return
            case .noExit(let seconds):
                await teardown()
                await fail(EngineError.decoderFailed(
                    "\(installed.manifest.name) did not exit within \(Int(seconds)) s of the end of \(source.uri)",
                    target: installed.manifest.name))
                return
            case .all where exit.status == 0:
                let records = liveness.records
                await teardown()
                await onStatus(.completed, "read \(source.uri): \(records) record\(records == 1 ? "" : "s")")
                return
            default:
                break
            }
            restarts += 1
            guard await recover(from: (exit.status, exit.lastErrorLine), restarts: restarts, wait: wait) else { return }
            wait = Swift.min(wait * 2, Self.maxRestartSeconds)
        }
    }

    /// One plugin over the recording: fed from the cursor on, its input closed when everything has
    /// gone, and read until it exits. A clean run ends with the plugin's stdout closed, so every
    /// record it wrote has been emitted before this returns. A plugin that does not exit within
    /// `sourceExitAllowance` of its input closing is stopped, and the feed says so.
    private func runSourcePlugin(_ source: RecordingSource) async -> (status: Int32, lastErrorLine: String?, fed: FeedOutcome) {
        guard let process = await spawnPlugin() else { return (-1, nil, .stopped) }
        let recordsDone = DoneFlag()
        let fed = await withTaskGroup(of: FeedOutcome?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return .stopped }
                let outcome = await self.feed(source, to: process)
                guard case .all = outcome else {
                    // The plugin's input will not finish, so it is stopped rather than left
                    // waiting for more; its stdout then closes and the reader below ends.
                    await process.stop()
                    return outcome
                }
                process.closeInput()
                let allowance = self.exitAllowance(source)
                let deadline = ContinuousClock.now.advanced(by: .seconds(allowance))
                while !recordsDone.isSet, ContinuousClock.now < deadline {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return .stopped }
                }
                guard recordsDone.isSet else {
                    await process.stop()
                    return .noExit(seconds: allowance)
                }
                return .all
            }
            group.addTask { [weak self] in
                for await record in process.records {
                    await self?.emit(record)
                }
                recordsDone.set()
                return nil
            }
            var fed = FeedOutcome.stopped
            for await result in group {
                if let result { fed = result }
            }
            return fed
        }
        var status: Int32 = 0
        for await code in process.exits {
            status = code
            break
        }
        let said = status == Self.refusedExitStatus ? await process.lastErrorLine() : nil
        await process.stop()
        currentPlugin.withLock { $0 = nil }
        return (status, said, fed)
    }

    /// `sourceExitAllowance` for the items from the cursor on, which have no record yet.
    private nonisolated func exitAllowance(_ source: RecordingSource) -> Double {
        let outstanding = source.items.count - sourceCursor.withLock { $0 }
        let a = Self.sourceExitAllowance.withLock { $0 }
        return a.baseSeconds + a.perItemSeconds * Double(Swift.max(0, outstanding))
    }

    /// Set once, read from another task.
    private final class DoneFlag: Sendable {
        private let value = Atomic<Bool>(false)
        var isSet: Bool { value.load(ordering: .acquiring) }
        func set() { value.store(true, ordering: .releasing) }
    }

    /// How feeding a plugin from a recording ended.
    private enum FeedOutcome: Sendable {
        /// Every item reached the plugin, and it exited.
        case all
        /// The plugin stopped taking input, or the job was cancelled.
        case stopped
        /// A part could not be read; restarting the plugin would not change that.
        case unreadable(String)
        /// Every item reached the plugin, and it had not exited this many seconds later.
        case noExit(seconds: Double)
    }

    /// The source's items from the cursor on, each written whole: a full pipe is waited out rather
    /// than dropped, because nothing here is live and the plugin sets the pace. The cursor is not
    /// moved here: an item counts as done when a record for it comes back (`emit`), so a plugin
    /// that dies after an item's END but before its record gets that item again.
    private nonisolated func feed(_ source: RecordingSource, to process: PluginProcess) async -> FeedOutcome {
        var seq: UInt64 = 0
        var index = sourceCursor.withLock { $0 }
        while !Task.isCancelled {
            guard index < source.items.count else { return .all }
            let item = source.items[index]
            // Under continuous input the time between two parts is not in the recording: a gap.
            var gapFrom: UInt64?
            if !source.segmented, index > 0, source.items[index - 1].part != item.part {
                let before = source.parts[source.items[index - 1].part]
                if before.captureID == source.parts[item.part].captureID { gapFrom = before.endSample }
            }
            var frames: RecordingSource.FrameReader
            do {
                frames = try source.frames(of: item, gapFrom: gapFrom)
            } catch {
                return .unreadable((error as? EngineError)?.message ?? "\(error)")
            }
            while var frame = frames.next() {
                seq += 1
                frame.streamID = streamID
                frame.seq = seq
                do {
                    try process.writeWaiting(frame)
                } catch {
                    return .stopped
                }
            }
            index += 1
        }
        return .stopped
    }

    /// The provider a refusal is reported against: the one whose key the decoder uses, else the
    /// decoder itself.
    private var providerName: String {
        installed.manifest.credentialProvider.isEmpty ? installed.manifest.name : installed.manifest.credentialProvider
    }

    /// What a plugin wrote, with the key of the provider its manifest names replaced: a plugin that
    /// echoes its request into a refusal must not put the key on the event plane.
    private func redacted(_ text: String) async -> String {
        let provider = installed.manifest.credentialProvider
        guard !provider.isEmpty, let secret = try? await credentials?.secret(provider: provider) else { return text }
        return WorkerProcess.redacting(secret, in: text)
    }

    private func fail(_ error: EngineError) async {
        if let onFailure { await onFailure(error) } else { await onStatus(.failed, error.message) }
    }

    /// Spawns the plugin with its descriptor and makes it the one the drain feeds. Nil, with the
    /// job failed and torn down, when it would not start.
    private func spawnPlugin() async -> PluginProcess? {
        let credential: Leyline_V1_SetCredentialRequest?
        do {
            credential = try await pluginCredential(for: installed.manifest, from: credentials)
        } catch {
            await fail(error as? EngineError ?? EngineError.credentialMissing(installed.manifest.credentialProvider))
            await teardown()
            return nil
        }
        let process = PluginProcess(name: installed.manifest.name, executable: installed.executablePath,
                                    args: await pluginArguments(for: installed.manifest, from: credentials),
                                    directory: installed.directory)
        do {
            try await process.start(descriptor: descriptor(), credential: credential)
        } catch {
            await onStatus(.failed, (error as? EngineError)?.message ?? "\(error)")
            await teardown()
            return nil
        }
        currentPlugin.withLock { $0 = process }
        await publishRunning(liveness.detail(decoder: installed.manifest.name))
        return process
    }

    /// Spawns the plugin and pumps it until it exits or the job is cancelled. Returns its status,
    /// and for a refusal the last line it wrote on stderr, which is the provider's reason.
    private func runPlugin() async -> (status: Int32, lastErrorLine: String?) {
        guard let process = await spawnPlugin() else { return (-1, nil) }
        let status = await withTaskGroup(of: Int32?.self) { group in
            group.addTask { [weak self] in
                for await record in process.records {
                    await self?.emit(record)
                }
                return nil
            }
            group.addTask {
                for await code in process.exits { return code }
                return 0
            }
            var out: Int32 = 0
            while let next = await group.next() {
                if let code = next {
                    out = code
                    break
                }
            }
            group.cancelAll()
            return out
        }
        let said = status == Self.refusedExitStatus ? await process.lastErrorLine() : nil
        await process.stop()
        currentPlugin.withLock { $0 = nil }
        return (status, said)
    }

    /// Audio out of the ring and into whichever plugin is up, one frame at a time. Nonisolated: it
    /// is the one part of the job that should never wait on the actor.
    private nonisolated func drain(audio: AudioFrameSource, lease: any ChannelLease) async {
        if segmenter.withLock({ $0 != nil }) {
            await drainSegmented(audio: audio, lease: lease)
            return
        }
        var seq: UInt64 = 0
        var lastEnd: UInt64 = 0
        // The earliest sample the plugin has not seen, held open across dropped frames so the next
        // frame that lands reports the whole gap at once (invariant 3). nil when nothing is owed.
        var lostFrom: UInt64?
        for await _ in audio.poke {
            if Task.isCancelled { return }
            while let f = audio.next(s16: false) {
                // The ring dropped samples ahead of this frame: a hole from the last frame's end.
                if f.droppedSamples > 0, lostFrom == nil { lostFrom = lastEnd }
                let end = f.sampleStart + f.sampleCount
                defer { lastEnd = end }
                guard let process = currentPlugin.withLock({ $0 }) else {
                    // No plugin up (a restart is in flight): the frame is lost and the gap stays open.
                    if lostFrom == nil { lostFrom = f.sampleStart }
                    continue
                }
                seq += 1
                var frame = Leyline_V1_Frame()
                frame.streamID = streamID
                frame.seq = seq
                frame.time.captureID = lease.captureID.string
                frame.time.sampleIndex = f.sampleStart
                frame.payload = f.payload
                if let from = lostFrom {
                    frame.gap.fromSample = from
                    frame.gap.toSample = f.sampleStart
                }
                do {
                    switch try process.write(frame) {
                    case .written:
                        lostFrom = nil
                    case .droppedFull:
                        // The plugin has stopped reading. Drop the frame and keep the gap open. Not
                        // reading is not a failure: a decoder may legitimately ignore this audio.
                        if lostFrom == nil { lostFrom = f.sampleStart }
                    }
                } catch is PluginStalled {
                    // A frame stalled half-written: the stream is unsalvageable, so replace the
                    // plugin. The restart loop is what respawns; stopping it makes runPlugin return.
                    if lostFrom == nil { lostFrom = f.sampleStart }
                    await process.stop()
                    continue
                } catch {
                    // The plugin died between the check and the write; the restart loop handles it.
                    if lostFrom == nil { lostFrom = f.sampleStart }
                    continue
                }
            }
        }
    }

    // MARK: Segmented input

    /// What the segmented drain knows about the plugin's side of the stream. A segment exists on
    /// the wire only between a START the plugin was given and its END, so a START that cannot be
    /// written skips the whole segment, an END that cannot be written is owed before anything else,
    /// and a plugin that replaced the one a segment was open on sees nothing more of it.
    private struct SegmentedWire {
        var seq: UInt64 = 0
        /// The plugin that has the open segment's START.
        var openOn: ObjectIdentifier?
        var skipping = false
        var owedEnd: Segmenter.Piece?
        /// Audio of a segment the plugin did not get, reported on the next frame that reaches it.
        var lost: Range<UInt64>?

        mutating func lose(_ piece: Segmenter.Piece) {
            if piece.mark == .segmentStart { skipping = true }
            guard !piece.floats.isEmpty else { return }
            let end = piece.time + UInt64(Double(piece.floats.count) * perAudioHint)
            lost = (lost?.lowerBound ?? piece.time)..<Swift.max(lost?.upperBound ?? end, end)
        }

        /// Capture samples per audio sample, for the end of a lost piece.
        var perAudioHint: Double = 1
    }

    /// The drain under SEGMENTED input: audio into the segmenter, and what it releases into the
    /// plugin. The squelch follower wakes it when a record lets waiting frames go.
    private nonisolated func drainSegmented(audio: AudioFrameSource, lease: any ChannelLease) async {
        var wire = SegmentedWire()
        wire.perAudioHint = audio.captureRate / audio.audioRate
        for await _ in audio.poke {
            if Task.isCancelled { return }
            while let f = audio.next(s16: false) {
                let floats = f.payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let frame = Segmenter.Frame(start: f.sampleStart, count: f.sampleCount, floats: floats,
                                            dropped: f.droppedSamples)
                segmenter.withLock { $0?.push(frame) }
            }
            let pieces = segmenter.withLock { $0?.release() } ?? []
            for piece in pieces {
                await deliver(piece, on: lease.captureID, wire: &wire)
            }
        }
    }

    private nonisolated func deliver(_ piece: Segmenter.Piece, on capture: CaptureID, wire: inout SegmentedWire) async {
        guard let process = currentPlugin.withLock({ $0 }) else {
            wire.lose(piece)
            return
        }
        let plugin = ObjectIdentifier(process)
        if let open = wire.openOn, open != plugin {
            // The plugin was replaced inside a segment: the new one never saw its START.
            wire.openOn = nil
            wire.owedEnd = nil
            wire.skipping = true
        }
        if let owed = wire.owedEnd {
            guard await send(owed, on: capture, to: process, wire: &wire) == .written else {
                wire.lose(piece)
                return
            }
            wire.owedEnd = nil
            wire.openOn = nil
        }
        switch piece.mark {
        case .segmentStart:
            wire.skipping = false
        case .segmentEnd:
            // Nothing of this segment is open on the wire, so there is nothing to end.
            guard !wire.skipping, wire.openOn != nil else {
                wire.skipping = false
                return
            }
        default:
            guard !wire.skipping, wire.openOn != nil else {
                wire.lose(piece)
                return
            }
        }
        switch await send(piece, on: capture, to: process, wire: &wire) {
        case .written:
            if piece.mark == .segmentStart { wire.openOn = plugin }
            if piece.mark == .segmentEnd { wire.openOn = nil }
        case .droppedFull:
            if piece.mark == .segmentEnd {
                wire.owedEnd = piece
            } else {
                wire.lose(piece)
            }
        }
    }

    /// One piece as a frame. A failure or a stall counts as a drop: the restart loop replaces the
    /// plugin, and `deliver` sees the new one.
    private nonisolated func send(_ piece: Segmenter.Piece, on capture: CaptureID, to process: PluginProcess,
                                  wire: inout SegmentedWire) async -> PluginWrite
    {
        var frame = Leyline_V1_Frame()
        frame.streamID = streamID
        frame.seq = wire.seq + 1
        frame.time.captureID = capture.string
        frame.time.sampleIndex = piece.time
        frame.segment = piece.mark
        frame.payload = piece.floats.withUnsafeBytes { Data($0) }
        let gap = [wire.lost, piece.gap].compactMap { $0 }
        if piece.mark != .segmentEnd, let from = gap.map(\.lowerBound).min(), let to = gap.map(\.upperBound).max() {
            frame.gap.fromSample = from
            frame.gap.toSample = to
        }
        do {
            let result = try process.write(frame)
            if result == .written {
                wire.seq += 1
                if piece.mark != .segmentEnd { wire.lost = nil }
            }
            return result
        } catch is PluginStalled {
            await process.stop()
            return .droppedFull
        } catch {
            return .droppedFull
        }
    }

    /// The channel's squelch records and meters into the segmenter, in the channel's order, through
    /// the same in-process path `RecordRunner.followSquelch` uses. Each one may let frames the
    /// drain is holding go, so it wakes the drain.
    private nonisolated func followSquelch(audio: AudioFrameSource, lease: any ChannelLease) async {
        let subscription = lease.engine.telemetrySubscription()
        for await t in subscription.stream {
            if Task.isCancelled { return }
            switch t {
            case .squelch(let time, let open, _, _, _):
                segmenter.withLock { $0?.hear(.squelch(open: open, at: time.sampleIndex)) }
            case .meter(let time, _, _, let open, _, _, _, _):
                segmenter.withLock { $0?.hear(.meter(open: open, at: time.sampleIndex)) }
            default:
                continue
            }
            audio.wake()
        }
    }

    // MARK: Stamping

    /// The daemon's own fields: a record id, the job, the channel, the sequence and the levels the
    /// engine measured. A plugin's values for these are overwritten.
    private func emit(_ incoming: Leyline_V1_DecodeRecord) async {
        var rec = incoming
        if rec.protocol.isEmpty { rec.protocol = installed.manifest.name }
        // Where the record came from in a stored recording, found before the time is filled in so
        // an unstamped capture matches any part.
        let located = source?.locate(rec.time)
        if let located, let source {
            // The plugin has answered this item, and so every one before it, which it was given
            // first. A segment's record comes at its END, so the segment is done; a continuous
            // part may have more to come, so a restart gives it again. Before any filter: the
            // plugin answered whether or not the record is delivered.
            let done = source.segmented ? located.item + 1 : located.item
            sourceCursor.withLock { $0 = Swift.max($0, done) }
        }
        if rec.time.captureID.isEmpty {
            rec.time.captureID = lease?.captureID.string ?? located?.captureID ?? ""
        }
        // A plugin has no socket, so the usage of the call behind a record travels on the record.
        // It is counted before the predicate: a call the filter discards was still paid for. A
        // decoder's calls are speech, scoped to this job, whatever the plugin wrote there.
        if rec.hasUsage {
            rec.usage.feature = "speech"
            rec.usage.jobID = jobID.string
            rec.usage.conversationID = ""
            if rec.usage.provider.isEmpty { rec.usage.provider = installed.manifest.credentialProvider }
            if rec.usage.atNs == 0 { rec.usage.atNs = WallClock.nowNs() }
            await usage?.record(rec.usage, by: .daemon)
        }
        // The predicate filters delivery (docs/design/decoders.md, "Predicates and delivery"): a
        // record that does not match reaches neither the hub nor the store nor the notifier. An
        // empty predicate matches everything, so `ley decode` delivers all. Judged before the seq
        // is spent, so a delivered record's seq stays contiguous -- a hole is a lost record, never
        // a filtered one -- and the promoted fields it tests are the plugin's, set already.
        guard matches(rec, predicate) else { return }
        seq += 1
        rec.recordID = "rec_" + ULID().string
        rec.jobID = jobID.string
        rec.seq = seq
        if let source {
            // A stored recording has no channel and no meter: the part that holds the record's
            // audio, and under SEGMENTED input the over's index in that part's squelch_opens.
            rec.channelID = ""
            rec.clipUri = located.map { "\(source.uri)/\($0.part)" } ?? ""
            rec.over = located?.over ?? 0
            rec.rssiDbfs = .nan
            rec.snrDb = .nan
        } else {
            rec.channelID = lease?.channelID.string ?? ""
            // Under SEGMENTED input the over is the segment the plugin stamped the record inside,
            // counted from 1 since the job began. No recording holds a live job's audio yet, so
            // there is no clip to name.
            rec.over = segmenter.withLock { $0?.over(at: rec.time.sampleIndex) } ?? 0
            rec.clipUri = ""
            rec.rssiDbfs = rssiDBFS
            rec.snrDb = snrDB
        }
        await hub.publish(rec)
        if let lease { await writer?.settleAnchor(of: lease.captureID, in: store) }
        await writer?.append(rec)
        if liveness.noteRecord(), awayDetail == nil {
            await publishRunning(liveness.publish(decoder: installed.manifest.name))
        }
        // Off the hot path and fire-and-forget: a slow webhook or shell hook must never stall the
        // reader, so the notifier runs in its own task with the record it saw (invariant 4 is about
        // the DSP thread; this is well clear of it, but a stall here would still back the reader up).
        if let notify {
            let record = rec
            Task { [notifier] in await notifier.fire(record, notify) }
        }
    }

    private func noteMeter(power: Double, snr: Double) {
        rssiDBFS = power
        snrDB = snr
    }

    /// The channel's own telemetry, for the levels every record is stamped with. A meter reading is
    /// 100 ms old at worst and a packet is longer than that.
    private func followMeter(_ lease: any ChannelLease) async {
        let subscription = lease.engine.telemetrySubscription()
        for await t in subscription.stream {
            if Task.isCancelled { return }
            if case .meter(_, let power, let snr, _, _, _, _, _) = t {
                noteMeter(power: power, snr: snr)
            }
        }
    }

    /// OUT_OF_CAPTURE degrades the job and the channel coming back restores it. The state is read
    /// from the channel engine rather than from the event stream: the engine holds the state, and
    /// the event only reports it.
    private func followChannel(_ lease: any ChannelLease) async {
        var last: ChannelState?
        while !Task.isCancelled {
            let state = await lease.engine.state
            if state != last {
                last = state
                switch state {
                case .outOfCapture:
                    let detail = "the capture moved away from \(fmtMHz(frequencyHz)); waiting for it to come back"
                    awayDetail = detail
                    await onStatus(.degraded, detail)
                case .active:
                    awayDetail = nil
                    await publishRunning(liveness.detail(decoder: installed.manifest.name))
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// RUNNING with `detail`, or DEGRADED with the away detail while the channel is out of its
    /// capture. A plugin restart replaced the away detail with its own, so the restart's RUNNING
    /// puts the away detail back rather than claiming the job is decoding.
    private func publishRunning(_ detail: String) async {
        if let awayDetail {
            await onStatus(.degraded, awayDetail)
        } else if let standingDegradation {
            await onStatus(.degraded, standingDegradation)
        } else {
            await onStatus(.running, detail)
        }
    }

    /// Republishes the running detail while the count moves, every DecodeLiveness.interval, so a
    /// busy decoder's count is current without a Job event per record.
    private func followRecords() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: DecodeLiveness.interval)
            if Task.isCancelled || stopped { return }
            if liveness.moved, awayDetail == nil {
                await publishRunning(liveness.publish(decoder: installed.manifest.name))
            }
        }
    }

    // MARK: The descriptor

    /// Named once, for the life of the runner: the plugin sees one stream, restarts included.
    private nonisolated let streamID = "plug_" + ULID().string

    private func descriptor() async -> Leyline_V1_StreamDescriptor {
        var d = Leyline_V1_StreamDescriptor()
        d.streamID = streamID
        d.kind = .audio
        // GAP_MARKED, so the decoder is told what was lost (invariant 3).
        d.policy = .gapMarked
        var audio = Leyline_V1_AudioParams()
        audio.format = .f32
        if let source {
            // What the recording holds: the audio a listener heard, at the recording's rate, from
            // the channel at the recording's frequency.
            audio.sampleRate = source.audioRate
            audio.tap = .tapAudio
            if let mode = DemodMode(rawValue: source.manifest.mode.lowercased()) {
                audio.fullScaleDeviationHz = UInt32(DemodulatorFactory.fullScaleDeviationHz(
                    mode: mode, bandwidthHz: source.manifest.bandwidthHz).rounded())
            }
            d.audio = audio
            d.centerHz = source.manifest.frequencyHz
            d.spanHz = source.captureRate
            d.grpc = true
            return d
        }
        guard let lease else { return d }
        audio.sampleRate = lease.engine.audioRate
        audio.tap = tap == .demod ? .tapDemod : .tapAudio
        // Both taps carry the same units, so the descriptor answers the channel's full-scale
        // deviation whichever one the manifest asked for.
        let config = await lease.engine.config
        audio.fullScaleDeviationHz = UInt32(DemodulatorFactory.fullScaleDeviationHz(
            mode: config.mode, bandwidthHz: config.bandwidthHz).rounded())
        d.audio = audio
        // Where the channel is and how wide the radio around it is, so a plugin can report the
        // frequency a packet was on.
        d.centerHz = frequencyHz
        d.spanHz = captureRateHz
        d.grpc = true
        return d
    }

    private nonisolated func fmtMHz(_ hz: UInt64) -> String { String(format: "%.3f MHz", Double(hz) / 1e6) }
}
