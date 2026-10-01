// SPDX-License-Identifier: GPL-3.0-or-later

// Coalesced parameter writes (docs/dev/engine-internals.md "Control service", WriteParams).

import EngineCore
import Foundation
import GRPCCore
import LeylineProto
import Synchronization

/// Runs one `WriteParams` stream: keeps the last value per `(target_id, param case[, gain element])`,
/// applies the pending set every `tickNs` and once more when the stream ends. Rejections become
/// `WriteRejected` events; the summary counts received vs. applied writes.
/// Unchecked Sendable: the pending writes and counters are read and written only under `lock`.
final class WriteCoalescer: @unchecked Sendable {
    struct Key: Hashable {
        var target: String
        var param: Int
        var element: String
    }

    static let tickNs: UInt64 = 20_000_000

    private let store: SessionStore
    private let client: ClientContext
    private let lock = NSLock()
    private var pending: [Key: Leyline_V1_ParamWrite] = [:]
    private var order: [Key] = []
    private var received: UInt64 = 0
    private var applied: UInt64 = 0

    init(store: SessionStore, client: ClientContext) {
        self.store = store
        self.client = client
    }

    static func key(_ w: Leyline_V1_ParamWrite) -> Key {
        let param: Int
        var element = ""
        switch w.param {
        case .centerHz?: param = 3
        case .captureSampleRate?: param = 4
        case .offsetHz?: param = 5
        case .bandwidthHz?: param = 6
        case .mode?: param = 7
        case .squelchDb?: param = 8
        case .gain(let g)?: param = 9; element = g.element
        case .sinkVolume?: param = 10
        case nil: param = 0
        }
        return Key(target: w.targetID, param: param, element: element)
    }

    /// Records one write (last value wins within a tick).
    func enqueue(_ w: Leyline_V1_ParamWrite) {
        let k = Self.key(w)
        lock.lock()
        received += 1
        if pending[k] == nil { order.append(k) }
        pending[k] = w
        lock.unlock()
    }

    /// Applies everything pending, in first-seen order.
    func flush() async {
        for w in takeBatch() {
            if let err = await store.applyWrite(w, by: client) {
                await store.emitWriteRejected(tag: w.tag, error: err, by: client)
            } else {
                noteApplied()
            }
        }
    }

    private func takeBatch() -> [Leyline_V1_ParamWrite] {
        lock.lock(); defer { lock.unlock() }
        let batch = order.compactMap { pending[$0] }
        pending.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        return batch
    }

    private func noteApplied() {
        lock.lock(); applied += 1; lock.unlock()
    }

    var summary: Leyline_V1_WriteSummary {
        lock.lock(); defer { lock.unlock() }
        var s = Leyline_V1_WriteSummary()
        s.writesReceived = received
        s.writesApplied = applied
        return s
    }

    /// Drives the stream to completion: a reader task feeds `enqueue`, the tick loop flushes
    /// every `tickNs` while the stream is open and once more after it ends. The reader is
    /// never awaited from inside the tick loop (awaiting a `Task.value` is not cancellable),
    /// so a long-lived stream still gets its writes applied every tick.
    func run<S: AsyncSequence & Sendable>(_ writes: S) async -> Leyline_V1_WriteSummary
    where S.Element == Leyline_V1_ParamWrite {
        let finished = LockedFlag()
        let reader = Task { [self] in
            defer { finished.set() }
            do {
                for try await w in writes { self.enqueue(w) }
            } catch {
                // Client cancelled or transport failed: apply what we have and finish.
            }
        }
        while !finished.value {
            // A thrown sleep means this task was cancelled. Leaving the loop is the only thing that
            // paces it: the condition tracks the reader, so a cancelled sleep that is merely
            // swallowed turns the tick into a busy loop hammering the store actor.
            guard (try? await Task.sleep(nanoseconds: Self.tickNs)) != nil else {
                reader.cancel()
                break
            }
            await flush()
        }
        _ = await reader.value
        await flush()
        return summary
    }
}

/// A boolean shared between the reader task and the tick loop; set once, read every tick.
final class LockedFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var value: Bool { flag.load(ordering: .acquiring) }
    func set() { flag.store(true, ordering: .releasing) }
}
