// Bulk plane (docs/engine-internals.md "Bulk service"): Subscribe negotiates an authoritative
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
        case .fft(let ring, _, _, _), .iq(let ring, _, _): ring.wake()
        case .audio(let audio, _): audio.wake()
        }
    }
    func markClosed() { closed.store(true, ordering: .releasing) }

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

    private let store: SessionStore
    private let log = Logger(label: "leyline.bulk")
    private var subs: [StreamID: BulkSubscription] = [:]

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
        guard let capture = await store.captureEngine(captureID) else { throw EngineError.captureNotFound(captureID.string) }
        let snap = await capture.snapshot
        desc.centerHz = snap.centerHz
        desc.spanHz = snap.sampleRate

        let source: BulkSubscription.Source
        switch req.kind {
        case .fft:
            guard channelID == nil else { throw EngineError.invalidArgument("FFT streams are capture-scoped", target: channelID!.string) }
            let want = req.fft
            var rows = want.rowsPerSecond > 0 ? want.rowsPerSecond : Self.defaultFFTRows
            rows = min(rows, DefaultSpectrumLadder.maxRowsPerSecond)
            let format: Leyline_V1_FftBinFormat = want.binFormat == .unspecified ? .dbF32 : want.binFormat
            let bins = DefaultSpectrumLadder.roundBins(want.bins == 0 ? 1024 : Int(want.bins))
            let ring = FrameRing(slots: Self.fftSlots, slotBytes: bins * 4)
            let sink = FFTFrameSink(ring: ring, bins: bins, u8: format == .dbU8)
            let sub = await capture.spectrum.subscribe(bins: bins, rowsPerSecond: rows, policy: enginePolicy, sink: sink)
            var p = Leyline_V1_FftParams()
            p.bins = UInt32(sub.actualBins)
            p.binFormat = format
            p.rowsPerSecond = sub.actualRate
            desc.fft = p
            source = .fft(ring, sub, capture.spectrum, sink)
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
            let audio = AudioFrameSource(captureRate: snap.sampleRate, audioRate: ch.audioRate)
            try await ch.attach(audio.sink)
            var p = Leyline_V1_AudioParams()
            p.sampleRate = ch.audioRate
            p.format = format
            desc.audio = p
            _ = chID
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
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.readerGraceNs)
            await self?.reapIfUnread(id)
        }
        return desc
    }

    /// Marks a Stream reader attached; `STREAM_NOT_FOUND` when the stream does not exist,
    /// `FAILED_PRECONDITION` when another Stream RPC is already draining it (one ring, one reader).
    func beginReading(_ id: StreamID) throws -> BulkSubscription {
        guard let sub = subs[id], !sub.isClosed else {
            throw EngineError(code: "STREAM_NOT_FOUND", message: "no such stream", target: id.string)
        }
        guard sub.claimReader() else {
            throw EngineError(code: "FAILED_PRECONDITION", message: "stream already has a reader", target: id.string)
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
        guard let sub = subs[id] else { throw EngineError(code: "STREAM_NOT_FOUND", message: "no such stream", target: id.string) }
        await close(sub)
    }

    /// Ends every stream on a destroyed capture or channel.
    func teardown(_ scope: TeardownScope) async {
        for sub in subs.values {
            switch scope {
            case .capture(let c) where sub.captureID == c: await close(sub, detach: false)
            case .channel(let ch) where sub.channelID == ch: await close(sub, detach: false)
            case .channelAudioRate(let ch) where sub.channelID == ch:
                if case .audio = sub.source { await close(sub) }
            default: break
            }
        }
    }

    /// Detaches the engine hook and finishes the ring so the reader loop exits.
    private func close(_ sub: BulkSubscription, detach: Bool = true) async {
        guard subs.removeValue(forKey: sub.id) != nil else { return }
        sub.markClosed()
        switch sub.source {
        case .fft(let ring, let spectrumSub, let ladder, _):
            if detach { await ladder.cancel(spectrumSub) }
            ring.finish()
        case .audio(let audio, let channel):
            if detach { await channel.detach(audio.sink.id) }
            await audio.sink.closeSink()
            audio.finish()
        case .iq(let ring, let tap, let capture):
            if detach { await capture.removeTap(id: tap.id) }
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
        case .fft(let ring, _, _, _), .iq(let ring, _, _):
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
        }
    }

    /// Shutdown: close everything.
    func closeAll() async {
        for sub in subs.values { await close(sub) }
    }
}
