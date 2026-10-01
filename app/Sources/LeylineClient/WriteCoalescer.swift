// SPDX-License-Identifier: Apache-2.0

// Parameter writes at display rate (docs/design/control-plane.md, "Parameter writes"). A drag on
// the waterfall produces a frequency per frame; the daemon coalesces last-value-per-parameter
// every 20 ms, and so does this side, so a frame's worth of writes is one message on the wire and
// the last one is the one that counts. Writes are fire-and-forget: the confirmation is the state
// event the daemon emits, folded by `DaemonMirror`, and a refusal is a `WriteRejected` event that
// carries the write's tag.

import Foundation
import GRPCCore
import LeylineProto
import Synchronization

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
/// daemon; `WriteCoalescer` wraps it in a lock and a stream.
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

/// How the coalescer reaches the daemon: one `WriteParams` stream, opened for the call, whose
/// `body` is handed a function that sends one write. It returns the daemon's summary once `body`
/// returns and the stream is closed. Tests pass their own to see what would be sent.
public typealias WriteStream =
    @Sendable (
        _ body:
            @escaping @Sendable (
                _ send: @escaping @Sendable (Leyline_V1_ParamWrite) async throws -> Void
            ) async throws -> Void
    ) async throws -> Leyline_V1_WriteSummary

/// One `WriteParams` stream, flushed one tick after the first write of a burst. Idle costs
/// nothing: the flush task sleeps on a kick that `set` sends, not on a timer.
///
/// The setters are synchronous and callable from any context, and record the write before they
/// return, under a lock. A caller's writes are therefore recorded in the order it made them, so
/// the last value per parameter is the last one asked for. Writes made from separate unstructured
/// tasks would not be: two `Task { await ... }` blocks are not guaranteed to run in the order they
/// were created, which could leave an older offset as the last value.
public final class WriteCoalescer: Sendable {
    public let tick: Duration
    private let stream: WriteStream
    private let state = Mutex(State())

    private struct State {
        var pending = PendingWrites()
        var kick: AsyncStream<Void>.Continuation?
        var task: Task<Void, Never>?
        var lastSummary: Leyline_V1_WriteSummary?
        var lastError: LeylineError?
    }

    /// The last `WriteSummary` the daemon answered when a stream ended, for tests and logs.
    public var lastSummary: Leyline_V1_WriteSummary? { state.withLock { $0.lastSummary } }
    public var lastError: LeylineError? { state.withLock { $0.lastError } }

    /// `tick` is the coalescing window: a 60 Hz drag is one write per tick at the default.
    public convenience init(connection: DaemonConnection, tick: Duration = .milliseconds(16)) {
        self.init(tick: tick) { body in
            try await connection.control.writeParams { writer in
                try await body { try await writer.write($0) }
            }
        }
    }

    init(tick: Duration, stream: @escaping WriteStream) {
        self.tick = tick
        self.stream = stream
    }

    /// Queues a write and returns its tag (echoed by a `WriteRejected` event if the daemon
    /// refuses it). The stream is opened on the first call.
    @discardableResult
    public func set(_ param: Leyline_V1_ParamWrite.OneOf_Param, target: String) -> UInt64 {
        let (tag, kick) = state.withLock { s -> (UInt64, AsyncStream<Void>.Continuation?) in
            let tag = s.pending.set(param, target: target)
            if s.task == nil { start(&s) }
            return (tag, s.kick)
        }
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
        let (kick, task) = state.withLock { s in
            defer { s.kick = nil }
            return (s.kick, s.task)
        }
        kick?.finish()
        await task?.value
        state.withLock { s in
            if s.task == task { s.task = nil }
        }
    }

    /// Opens the stream and its flush task. Called under the lock, so one write opens one stream.
    private func start(_ s: inout State) {
        let (kicks, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        s.kick = continuation
        let tick = tick
        let stream = stream
        s.task = Task {
            do {
                let summary = try await stream { send in
                    for await _ in kicks {
                        try await Task.sleep(for: tick)
                        for write in self.take() { try await send(write) }
                    }
                    // The stream is closing: whatever arrived after the last kick goes too.
                    for write in self.take() { try await send(write) }
                }
                self.finished(summary: summary, error: nil)
            } catch {
                self.finished(summary: nil, error: LeylineError(error))
            }
        }
    }

    private func take() -> [Leyline_V1_ParamWrite] { state.withLock { $0.pending.drain() } }

    private func finished(summary: Leyline_V1_WriteSummary?, error: LeylineError?) {
        state.withLock { s in
            s.lastSummary = summary
            s.lastError = error
            s.kick = nil
            s.task = nil
        }
    }
}
