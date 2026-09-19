// SPDX-License-Identifier: Apache-2.0

// Parameter writes at display rate (docs/design/control-plane.md, "Parameter writes"). A drag on
// the waterfall produces a frequency per frame; the daemon coalesces last-value-per-parameter
// every 20 ms, and so does this side, so a frame's worth of writes is one message on the wire and
// the last one is the one that counts. Writes are fire-and-forget: the confirmation is the state
// event the daemon emits, folded by `DaemonMirror`, and a refusal is a `WriteRejected` event that
// names the write's tag.

import Foundation
import GRPCCore
import LeylineProto

/// Which parameter a write sets; one pending value per `(target, kind)`.
public enum ParamKind: Sendable, Hashable, CaseIterable {
    case centerHz, captureSampleRate, offsetHz, bandwidthHz, mode, squelchDb, gain, sinkVolume

    init?(_ param: Leyline_V1_ParamWrite.OneOf_Param?) {
        switch param {
        case .centerHz: self = .centerHz
        case .captureSampleRate: self = .captureSampleRate
        case .offsetHz: self = .offsetHz
        case .bandwidthHz: self = .bandwidthHz
        case .mode: self = .mode
        case .squelchDb: self = .squelchDb
        case .gain: self = .gain
        case .sinkVolume: self = .sinkVolume
        case .none: return nil
        }
    }
}

/// The pure part: last value per `(target, kind)`, tags minted in order. Unit-tested without a
/// daemon; `WriteCoalescer` wraps it in an actor and a stream.
public struct PendingWrites: Sendable {
    public struct Key: Hashable, Sendable {
        public var target: String
        public var kind: ParamKind
    }

    private var pending: [Key: Leyline_V1_ParamWrite] = [:]
    private var order: [Key] = []
    private var nextTag: UInt64 = 1

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }
    public var count: Int { pending.count }

    /// Records a write, replacing any pending write of the same parameter on the same target, and
    /// returns its tag. A write with no parameter set is dropped and tagged 0.
    @discardableResult
    public mutating func set(_ param: Leyline_V1_ParamWrite.OneOf_Param, target: String) -> UInt64 {
        guard let kind = ParamKind(param) else { return 0 }
        let key = Key(target: target, kind: kind)
        var write = Leyline_V1_ParamWrite()
        write.tag = nextTag
        write.targetID = target
        write.param = param
        nextTag += 1
        if pending[key] == nil { order.append(key) }
        pending[key] = write
        return write.tag
    }

    /// Takes everything pending, oldest key first, and leaves nothing.
    public mutating func drain() -> [Leyline_V1_ParamWrite] {
        let out = order.compactMap { pending[$0] }
        pending.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        return out
    }
}

/// One `WriteParams` stream, flushed one tick after the first write of a burst. Idle costs
/// nothing: the flush task sleeps on a kick that `set` sends, not on a timer.
public actor WriteCoalescer {
    public let connection: DaemonConnection
    public let tick: Duration
    private var pending = PendingWrites()
    private var kick: AsyncStream<Void>.Continuation?
    private var task: Task<Void, Never>?
    /// The last `WriteSummary` the daemon answered when a stream ended, for tests and logs.
    public private(set) var lastSummary: Leyline_V1_WriteSummary?
    public private(set) var lastError: LeylineError?

    /// `tick` is the coalescing window: a 60 Hz drag is one write per tick at the default.
    public init(connection: DaemonConnection, tick: Duration = .milliseconds(16)) {
        self.connection = connection
        self.tick = tick
    }

    /// Queues a write and returns its tag (echoed by a `WriteRejected` event if the daemon
    /// refuses it). The stream is opened on the first call.
    @discardableResult
    public func set(_ param: Leyline_V1_ParamWrite.OneOf_Param, target: String) -> UInt64 {
        let tag = pending.set(param, target: target)
        start()
        kick?.yield()
        return tag
    }

    // Sugar for the writes the views make.
    @discardableResult public func centerHz(_ hz: UInt64, capture: String) -> UInt64 {
        set(.centerHz(hz), target: capture)
    }
    @discardableResult public func offsetHz(_ hz: Int64, channel: String) -> UInt64 {
        set(.offsetHz(hz), target: channel)
    }
    @discardableResult public func bandwidthHz(_ hz: UInt32, channel: String) -> UInt64 {
        set(.bandwidthHz(hz), target: channel)
    }
    @discardableResult public func mode(_ mode: Leyline_V1_DemodMode, channel: String) -> UInt64 {
        set(.mode(mode), target: channel)
    }
    @discardableResult public func squelchDb(_ db: Double, channel: String) -> UInt64 {
        set(.squelchDb(db), target: channel)
    }
    @discardableResult public func volume(_ v: Double, sink: String) -> UInt64 {
        set(.sinkVolume(v), target: sink)
    }
    @discardableResult public func gain(_ write: Leyline_V1_GainWrite, capture: String) -> UInt64 {
        set(.gain(write), target: capture)
    }

    /// Ends the stream after a last flush. The daemon answers with how many writes it applied.
    public func stop() async {
        kick?.finish()
        kick = nil
        await task?.value
        task = nil
    }

    private func start() {
        guard task == nil else { return }
        let (kicks, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        kick = continuation
        let tick = tick
        task = Task { [connection] in
            do {
                let summary = try await connection.control.writeParams { writer in
                    for await _ in kicks {
                        try await Task.sleep(for: tick)
                        for write in await self.take() { try await writer.write(write) }
                    }
                    // The stream is closing: whatever arrived after the last kick goes too.
                    for write in await self.take() { try await writer.write(write) }
                }
                self.finished(summary: summary, error: nil)
            } catch {
                self.finished(summary: nil, error: LeylineError(error))
            }
        }
    }

    private func take() -> [Leyline_V1_ParamWrite] { pending.drain() }

    private func finished(summary: Leyline_V1_WriteSummary?, error: LeylineError?) {
        lastSummary = summary
        lastError = error
        kick = nil
        task = nil
    }
}
