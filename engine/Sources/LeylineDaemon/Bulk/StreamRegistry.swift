// SPDX-License-Identifier: GPL-3.0-or-later

// Bulk plane (docs/dev/engine-internals.md "Bulk service"): Subscribe negotiates an authoritative
// StreamDescriptor, Stream drains frames until the client cancels, Unsubscribe tears down.

import EngineCore
import Foundation
import LeylineProto
import Logging
import Synchronization

/// One negotiated bulk subscription and the engine hook feeding it.
final class BulkSubscription: @unchecked Sendable {
    enum Source {
        case fft(FrameRing, SpectrumSubscription, any SpectrumLadder, FFTFrameSink)
        case audio(AudioFrameSource, any ChannelEngine)
        case iq(FrameRing, IQFrameTap, any CaptureEngine)
        case persistence(FrameRing, SpectrumSubscription, any SpectrumLadder, PersistenceFrameSink)
        /// An FFT of a channel's audio: the rows come off the channel's own sink table rather than
        /// the capture's ladder, so it is torn down like the audio tap it reads.
        case audioSpectrum(FrameRing, AudioSpectrumSink, any ChannelEngine)
    }

    let id: StreamID
    let descriptor: Leyline_V1_StreamDescriptor
    let captureID: CaptureID
    let channelID: ChannelID?
    let source: Source
    /// Set while exactly one Stream reader is attached (reaper checks this after 10 s). Atomic:
    /// written on the registry actor, read from the nonisolated reader loop.
    private let reading = Atomic<Bool>(false)
    private let closed = Atomic<Bool>(false)
    /// Set by `cancelReader` when the attached Stream RPC is cancelled; cleared by the next claim.
    private let readerCancelled = Atomic<Bool>(false)

    var isReading: Bool { reading.load(ordering: .acquiring) }
    var isClosed: Bool { closed.load(ordering: .acquiring) }
    var isReaderCancelled: Bool { readerCancelled.load(ordering: .acquiring) }
    /// Claims the single reader slot; false when another Stream RPC already holds it.
    func claimReader() -> Bool {
        guard reading.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return false }
        readerCancelled.store(false, ordering: .releasing)
        return true
    }
    func releaseReader() { reading.store(false, ordering: .releasing) }
    /// The reader's RPC was cancelled: flag it and wake the drain loop so it returns without waiting
    /// for the next frame. The poke stream itself stays open for a reader that reconnects in grace.
    func cancelReader() {
        readerCancelled.store(true, ordering: .releasing)
        switch source {
        case .fft(let ring, _, _, _), .iq(let ring, _, _), .persistence(let ring, _, _, _),
             .audioSpectrum(let ring, _, _): ring.wake()
        case .audio(let audio, _): audio.wake()
        }
    }
    func markClosed() { closed.store(true, ordering: .releasing) }
    /// Whether this stream is fed by a channel tap, and so stops being true the moment the audio
    /// rate under it can move: both the audio stream and the spectrum taken off it describe a rate
    /// their descriptor named, and a client re-subscribes for a fresh one.
    var readsChannelAudio: Bool {
        switch source {
        case .audio, .audioSpectrum: true
        default: false
        }
    }

    init(id: StreamID, descriptor: Leyline_V1_StreamDescriptor, captureID: CaptureID, channelID: ChannelID?, source: Source) {
        self.id = id
        self.descriptor = descriptor
        self.captureID = captureID
        self.channelID = channelID
        self.source = source
    }
}

/// Owns bulk subscriptions. Frames are produced on engine threads into per-subscription rings and
/// drained by `Stream` RPC tasks.
actor StreamRegistry {
    static let fftSlots = 8
    static let iqSlots = 8
    static let readerGraceNs: UInt64 = 10_000_000_000
    static let defaultFFTRows: Double = 10
    /// Range a persistence half-life is clamped to. The floor keeps the decay visible over at least
    /// a few ladder rows; the ceiling (an hour) keeps `halfLife * rows` inside `Int` for any value
    /// that arrives on the wire, including infinity.
    static let minHalfLifeSeconds: Double = 0.1
    static let maxHalfLifeSeconds: Double = 3600

    private let store: SessionStore
    private let log = Logger(label: "leyline.bulk")
    private var subs: [StreamID: BulkSubscription] = [:]
    /// Subscribes still negotiating: the object they name is known, the engine hookups are not built
    /// yet, so there is nothing for `teardown` to close. It marks them in `abandoned` instead.
    private var pending: [StreamID: (captureID: CaptureID?, channelID: ChannelID?)] = [:]
    /// Pending subscribes whose capture or channel was destroyed under them.
    private var abandoned: Set<StreamID> = []

    init(store: SessionStore) { self.store = store }

    /// Installs the store teardown hook so streams on destroyed objects end.
    func install() async {
        await store.setTeardownHook { [weak self] scope in
            await self?.teardown(scope)
        }
    }

    func subscription(_ id: StreamID) -> BulkSubscription? { subs[id] }

    /// v0 rules: transport always gRPC, start LIVE only, policy default LATEST_WINS.
    func subscribe(_ req: Leyline_V1_SubscribeRequest) async throws -> Leyline_V1_StreamDescriptor {
        if req.hasStart, let pos = req.start.position {
            guard case .live = pos else { throw EngineError.unimplemented("non-live stream start") }
        }
        let policy: Leyline_V1_DeliveryPolicy = req.policy == .unspecified ? .latestWins : req.policy
        let enginePolicy: DeliveryPolicy = policy == .gapMarked ? .gapMarked : .latestWins
        var desc = Leyline_V1_StreamDescriptor()
        let id = StreamID()
        desc.streamID = id.string
        desc.kind = req.kind
        desc.policy = policy
        desc.transport = .grpc(true)

        let captureID: CaptureID
        var channelID: ChannelID?
        var channel: (any ChannelEngine)?
        // Claim the id before the first await. Negotiation is full of suspension points, and a
        // capture destroyed inside one runs its teardown over a table this subscription is not in
        // yet; the claim is what teardown marks so the half-built stream is closed rather than left
        // holding a ladder subscription or an IQ tap on a stopped engine.
        switch req.source {
        case .captureID(let s)?: pending[id] = (CaptureID(string: s), nil)
        case .channelID(let s)?: pending[id] = (nil, ChannelID(string: s))
        case nil: break
        }
        defer { pending[id] = nil; abandoned.remove(id) }
        switch req.source {
        case .captureID(let s)?:
            guard let c = CaptureID(string: s), await store.captureEngine(c) != nil else { throw EngineError.captureNotFound(s) }
            captureID = c
        case .channelID(let s)?:
            guard let ch = ChannelID(string: s), let engine = await store.channelEngine(ch) else { throw EngineError.channelNotFound(s) }
            channelID = ch
            channel = engine
            captureID = engine.captureID
        case nil:
            throw EngineError.invalidArgument("source is required")
        }
        pending[id] = (captureID, channelID)
        guard let capture = await store.captureEngine(captureID) else { throw EngineError.captureNotFound(captureID.string) }
        let snap = await capture.snapshot
        desc.centerHz = snap.centerHz
        desc.spanHz = snap.sampleRate

        let source: BulkSubscription.Source
        switch req.kind {
        case .fft:
            let want = req.fft
            // looks_per_row is an answer, never a request: a client asking for a look count would
            // be asking the daemon to spend CPU it does not own.
            if want.looksPerRow != 0 {
                throw EngineError.invalidArgument("looks_per_row is answered by the daemon; leave it 0")
            }
            let format: Leyline_V1_FftBinFormat = want.binFormat == .unspecified ? .dbF32 : want.binFormat
            if let ch = channel, let chID = channelID {
                source = try await subscribeAudioSpectrum(channel: ch, id: chID, want: want,
                                                          format: format, into: &desc)
                break
            }
            var rows = want.rowsPerSecond > 0 ? want.rowsPerSecond : Self.defaultFFTRows
            rows = min(rows, DefaultSpectrumLadder.maxRowsPerSecond)
            let bins = DefaultSpectrumLadder.roundBins(want.bins == 0 ? 1024 : Int(want.bins))
            let ring = FrameRing(slots: Self.fftSlots, slotBytes: bins * 4)
            let sink = FFTFrameSink(ring: ring, bins: bins, u8: format == .dbU8)
            let accumulation: SpectrumAccumulation
            switch want.accumulation {
            case .unspecified, .rowSnapshot: accumulation = .snapshot
            case .rowMean: accumulation = .mean
            case .rowMax: accumulation = .max
            case .UNRECOGNIZED(let v):
                throw EngineError.invalidArgument("unknown FftAccumulation \(v)")
            }
            let sub = await capture.spectrum.subscribe(bins: bins, rowsPerSecond: rows,
                                                       accumulation: accumulation, policy: enginePolicy, sink: sink)
            var p = Leyline_V1_FftParams()
            p.bins = UInt32(sub.actualBins)
            p.binFormat = format
            p.rowsPerSecond = sub.actualRate
            p.accumulation = want.accumulation == .unspecified ? .rowSnapshot : want.accumulation
            p.looksPerRow = UInt32(sub.looksPerRow)
            desc.fft = p
            source = .fft(ring, sub, capture.spectrum, sink)
        case .persistence:
            guard channelID == nil else { throw EngineError.invalidArgument("persistence streams are capture-scoped", target: channelID!.string) }
            let want = req.persistence
            // The scale is the client's to state. A daemon-chosen one would have to appear in the
            // descriptor before any row had arrived, and a persistence frame on the wrong scale is
            // not obviously wrong to look at -- so this is refused rather than defaulted.
            guard want.rangeDb > 0 else {
                throw EngineError.invalidArgument("persistence needs range_db > 0 and a floor_db; take an FFT row first to find the floor")
            }
            let levels = want.levels == 0 ? 32 : Int(want.levels)
            guard levels > 1, levels <= 256 else {
                throw EngineError.invalidArgument("persistence levels must be 2...256, got \(levels)")
            }
            let pbins = DefaultSpectrumLadder.roundBins(want.bins == 0 ? 256 : Int(want.bins))
            // Both rates arrive as proto3 doubles, so they are clamped to ranges the arithmetic
            // below can represent -- a denormal rate or an infinite half-life would otherwise
            // overflow the integer conversions. The descriptor answers with what was used.
            let emitRows = DefaultSpectrumLadder.roundRate(want.rowsPerSecond > 0 ? want.rowsPerSecond : 2)
            // Accumulate as fast as the ladder will go and display slowly: the histogram wants
            // every row it can get, and a person reads a couple of frames a second.
            let ladderRows = DefaultSpectrumLadder.maxRowsPerSecond
            let halfLife = want.halfLifeSeconds > 0
                ? Swift.min(Swift.max(want.halfLifeSeconds, Self.minHalfLifeSeconds), Self.maxHalfLifeSeconds)
                : 20
            let acc = PersistenceAccumulator(bins: pbins, levels: levels,
                                             floorDB: want.floorDb, rangeDB: want.rangeDb,
                                             halfLifeRows: Swift.max(1, Int(halfLife * ladderRows)))
            let ring = FrameRing(slots: Self.fftSlots, slotBytes: pbins * levels * 2)
            let rowSamples = Swift.max(1.0, Double(snap.sampleRate) / emitRows)
            let emitInterval = UInt64(Swift.min(rowSamples, Double(UInt64.max / 2)))
            let sink = PersistenceFrameSink(ring: ring, accumulator: acc, emitInterval: emitInterval)
            let sub = await capture.spectrum.subscribe(bins: pbins, rowsPerSecond: ladderRows,
                                                       accumulation: .snapshot, policy: enginePolicy, sink: sink)
            var p = Leyline_V1_PersistenceParams()
            p.bins = UInt32(sub.actualBins)
            p.levels = UInt32(levels)
            p.floorDb = want.floorDb
            p.rangeDb = want.rangeDb
            p.halfLifeSeconds = halfLife
            p.rowsPerSecond = emitRows
            desc.persistence = p
            source = .persistence(ring, sub, capture.spectrum, sink)
        case .audio:
            guard let ch = channel, let chID = channelID else { throw EngineError.invalidArgument("audio streams are channel-scoped", target: captureID.string) }
            let format: Leyline_V1_AudioSampleFormat = req.audio.format == .unspecified ? .s16 : req.audio.format
            // No resampling in v0: the channel's audio rate is the only one served. A request for
            // another rate is refused rather than silently upgraded (bulk.proto: never upgrade).
            if req.audio.sampleRate != 0, req.audio.sampleRate != ch.audioRate {
                throw EngineError.invalidArgument(
                    "audio sample_rate \(req.audio.sampleRate) unavailable; channel produces \(ch.audioRate) Hz (request 0 to accept it)",
                    target: chID.string)
            }
            let tap: AudioTap
            switch req.audio.tap {
            case .tapAudio: tap = .audio
            case .tapDemod:
                // No detector on a raw-IQ channel, so there is no stage before the audio to serve;
                // silence would look like a quiet band rather than the mistake it is.
                guard await ch.config.mode != .rawIQ else {
                    throw EngineError.invalidArgument(
                        "TAP_DEMOD needs a demodulated channel; this one is raw IQ", target: chID.string)
                }
                tap = .demod
            case .UNRECOGNIZED(let v):
                throw EngineError.invalidArgument("unknown AudioTap \(v)", target: chID.string)
            }
            let audio = AudioFrameSource(captureRate: snap.sampleRate, audioRate: ch.audioRate, tap: tap)
            try await ch.attach(audio.sink)
            var p = Leyline_V1_AudioParams()
            p.sampleRate = ch.audioRate
            p.format = format
            p.tap = req.audio.tap
            // Both taps carry the same units, so the descriptor answers the channel's full-scale
            // deviation whichever one was asked for.
            let chConfig = await ch.config
            p.fullScaleDeviationHz = UInt32(DemodulatorFactory.fullScaleDeviationHz(
                mode: chConfig.mode, bandwidthHz: chConfig.bandwidthHz).rounded())
            desc.audio = p
            source = .audio(audio, ch)
        case .iq:
            // v0 IQ contract: raw CF32 at the capture's native rate only. The request is validated
            // rather than silently overridden (bulk.proto: downgrade, never upgrade -- so refuse).
            // Integer formats and decimated IQ are a documented v1 addition.
            if req.iq.format != .unspecified, req.iq.format != .cf32 {
                throw EngineError.invalidArgument(
                    "iq format \(req.iq.format) unavailable; v0 serves CF32 only (request UNSPECIFIED or CF32)",
                    target: captureID.string)
            }
            if req.iq.sampleRate != 0, req.iq.sampleRate != snap.sampleRate {
                throw EngineError.invalidArgument(
                    "iq sample_rate \(req.iq.sampleRate) unavailable; capture runs at \(snap.sampleRate) Hz (request 0 to accept it)",
                    target: captureID.string)
            }
            let ring = FrameRing(slots: Self.iqSlots, slotBytes: CaptureDSPCore.blockSize * 8)
            let tap = IQFrameTap(id: id, ring: ring)
            await capture.addTap(tap)
            var p = Leyline_V1_IqParams()
            p.sampleRate = snap.sampleRate
            p.format = .cf32
            desc.iq = p
            source = .iq(ring, tap, capture)
        case .decoded:
            throw EngineError.unimplemented("decoded streams")
        case .unspecified, .UNRECOGNIZED:
            throw EngineError.invalidArgument("stream kind is required")
        }
        let sub = BulkSubscription(id: id, descriptor: desc, captureID: captureID, channelID: channelID, source: source)
        subs[id] = sub
        if abandoned.contains(id) {
            // The object went away while this was being built: close what was built and answer as
            // if the lookup had failed, rather than hand back a stream that can never produce a
            // frame and can never be reaped once a reader attaches.
            await close(sub, detach: false)
            if let ch = channelID { throw EngineError.channelNotFound(ch.string) }
            throw EngineError.captureNotFound(captureID.string)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.readerGraceNs)
            await self?.reapIfUnread(id)
        }
        return desc
    }

    /// The channel-scoped half of `FFT`: the spectrum of what the channel produces rather than of
    /// the radio it came from. Rows come off the channel's sink table, so the tap rules and the
    /// teardown are the audio stream's; only the row layout is the ladder's.
    private func subscribeAudioSpectrum(channel ch: any ChannelEngine, id chID: ChannelID,
                                        want: Leyline_V1_FftParams, format: Leyline_V1_FftBinFormat,
                                        into desc: inout Leyline_V1_StreamDescriptor) async throws -> BulkSubscription.Source
    {
        // No detector and no audio on a raw-IQ channel, so there is no stage to take a spectrum of;
        // the band is what `capture_id` already answers.
        guard await ch.config.mode != .rawIQ else {
            throw EngineError.invalidArgument(
                "a channel FFT is the spectrum of the channel's audio; this one is raw IQ", target: chID.string)
        }
        let tap: AudioTap
        switch want.tap {
        case .tapAudio: tap = .audio
        case .tapDemod: tap = .demod
        case .UNRECOGNIZED(let v):
            throw EngineError.invalidArgument("unknown AudioTap \(v)", target: chID.string)
        }
        // A row is one transform of one window, so there is nothing to accumulate over -- but an
        // enum value the daemon does not know is still a request it cannot answer.
        if case .UNRECOGNIZED(let v) = want.accumulation {
            throw EngineError.invalidArgument("unknown FftAccumulation \(v)", target: chID.string)
        }
        // The rate is the audio timebase the window advances on; a channel whose chain is not
        // running yet has none to offer.
        let audioRate = ch.audioRate
        guard audioRate > 0 else {
            throw EngineError.invalidArgument(
                "the channel has no audio rate yet; retry once it is running", target: chID.string)
        }
        let bins = AudioSpectrumSink.roundBins(want.bins == 0 ? 1024 : Int(want.bins))
        let rows = AudioSpectrumSink.roundRate(want.rowsPerSecond)
        let ring = FrameRing(slots: Self.fftSlots, slotBytes: bins * 4)
        let frames = FFTFrameSink(ring: ring, bins: bins, u8: format == .dbU8)
        let spectrum = AudioSpectrumSink(tap: tap, bins: bins, rowsPerSecond: rows,
                                         audioRate: audioRate, sink: frames)
        try await ch.attach(spectrum)
        var p = Leyline_V1_FftParams()
        p.bins = UInt32(bins)
        p.binFormat = format
        p.rowsPerSecond = rows
        // A row is one transform of one window, so there is nothing to accumulate over: the
        // accumulation a client asked for is answered with the snapshot it actually gets.
        p.accumulation = .rowSnapshot
        p.looksPerRow = 1
        p.tap = want.tap
        desc.fft = p
        // The frequency axis in the terms every FFT reader already understands: the row runs from
        // 0 Hz to half the audio rate.
        desc.centerHz = spectrum.centerHz
        desc.spanHz = spectrum.spanHz
        return .audioSpectrum(ring, spectrum, ch)
    }

    /// Marks a Stream reader attached; `STREAM_NOT_FOUND` when the stream does not exist,
    /// `FAILED_PRECONDITION` when another Stream RPC is already draining it (one ring, one reader).
    func beginReading(_ id: StreamID) throws -> BulkSubscription {
        guard let sub = subs[id], !sub.isClosed else {
            throw EngineError.streamNotFound(id.string)
        }
        guard sub.claimReader() else {
            throw EngineError.failedPrecondition("stream already has a reader", target: id.string)
        }
        return sub
    }

    /// The Stream reader went away: the subscription lives on for another reader grace period.
    func endReading(_ id: StreamID) {
        guard let sub = subs[id] else { return }
        sub.releaseReader()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.readerGraceNs)
            await self?.reapIfUnread(id)
        }
    }

    private func reapIfUnread(_ id: StreamID) async {
        guard let sub = subs[id], !sub.isReading else { return }
        log.info("reaping unread bulk stream \(id)")
        await close(sub)
    }

    func unsubscribe(_ id: StreamID) async throws {
        guard let sub = subs[id] else { throw EngineError.streamNotFound(id.string) }
        await close(sub)
    }

    /// Ends every stream on a destroyed capture or channel.
    func teardown(_ scope: TeardownScope) async {
        for (id, p) in pending {
            switch scope {
            case .capture(let c) where p.captureID == c: abandoned.insert(id)
            case .channel(let ch) where p.channelID == ch: abandoned.insert(id)
            default: break
            }
        }
        for sub in subs.values {
            switch scope {
            case .capture(let c) where sub.captureID == c: await close(sub, detach: false)
            case .channel(let ch) where sub.channelID == ch: await close(sub, detach: false)
            case .channelAudioRate(let ch) where sub.channelID == ch:
                if sub.readsChannelAudio { await close(sub) }
            case .captureRate(let c) where sub.captureID == c:
                if sub.readsChannelAudio { await close(sub) }
            default: break
            }
        }
    }

    /// Detaches the engine hook and finishes the ring so the reader loop exits.
    private func close(_ sub: BulkSubscription, detach: Bool = true) async {
        guard subs.removeValue(forKey: sub.id) != nil else { return }
        sub.markClosed()
        switch sub.source {
        case .fft(let ring, let spectrumSub, let ladder, _),
             .persistence(let ring, let spectrumSub, let ladder, _):
            if detach { await ladder.cancel(spectrumSub) }
            ring.finish()
        case .audio(let audio, let channel):
            if detach { await channel.detach(audio.sink.id) }
            await audio.sink.closeSink()
            audio.finish()
        case .iq(let ring, let tap, let capture):
            if detach { await capture.removeTap(id: tap.id) }
            ring.finish()
        case .audioSpectrum(let ring, let spectrum, let channel):
            if detach { await channel.detach(spectrum.id) }
            await spectrum.closeSink()
            ring.finish()
        }
    }

    /// Drains one subscription into `write` until the ring finishes, the subscription closes, or
    /// `cancelReader` fires. Runs outside the actor so a slow client never blocks negotiation.
    nonisolated static func run(_ sub: BulkSubscription, write: (Leyline_V1_Frame) async throws -> Void) async throws {
        var seq: UInt64 = 0
        var lastEnd: UInt64 = 0
        let gapMarked = sub.descriptor.policy == .gapMarked
        /// `seq` nil: reader-counted (audio); otherwise the ring's writer-side sequence, so evicted
        /// frames leave a visible gap.
        func frame(payload: Data, start: UInt64, count: UInt64, dropped: UInt64, seq ringSeq: UInt64? = nil) -> Leyline_V1_Frame {
            seq = ringSeq ?? (seq + 1)
            var f = Leyline_V1_Frame()
            f.streamID = sub.id.string
            f.seq = seq
            f.time.captureID = sub.captureID.string
            f.time.sampleIndex = start
            f.payload = payload
            if gapMarked, dropped > 0 {
                f.gap.fromSample = lastEnd
                f.gap.toSample = start
            }
            lastEnd = start + count
            return f
        }
        switch sub.source {
        case .fft(let ring, _, _, _), .iq(let ring, _, _), .persistence(let ring, _, _, _),
             .audioSpectrum(let ring, _, _):
            for await _ in ring.poke {
                while let p = ring.pop() {
                    try await write(frame(payload: p.payload, start: p.sampleStart, count: p.sampleCount, dropped: p.droppedSamples, seq: p.seq))
                }
                if sub.isClosed || sub.isReaderCancelled { return }
            }
            while let p = ring.pop() {
                try await write(frame(payload: p.payload, start: p.sampleStart, count: p.sampleCount, dropped: p.droppedSamples, seq: p.seq))
            }
        case .audio(let audio, _):
            let s16 = sub.descriptor.audio.format != .f32
            for await _ in audio.poke {
                while let p = audio.next(s16: s16) {
                    try await write(frame(payload: p.payload, start: p.sampleStart, count: p.sampleCount, dropped: p.droppedSamples))
                }
                if sub.isClosed || sub.isReaderCancelled { return }
            }
            // The audio callback runs on another thread: a push that lands as `finish()` is called
            // has its wakeup dropped, so drain once more for the last samples it left behind.
            while let p = audio.next(s16: s16) {
                try await write(frame(payload: p.payload, start: p.sampleStart, count: p.sampleCount, dropped: p.droppedSamples))
            }
        }
    }

    /// Shutdown: close everything.
    func closeAll() async {
        for sub in subs.values { await close(sub) }
    }
}
