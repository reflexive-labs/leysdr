// Preallocated SPSC slot ring carrying encoded bulk frames from the DSP/device thread to the
// Stream RPC reader. Hot path on the writer side: no allocation, no locks (CLAUDE.md invariant 4).

import Synchronization
import EngineCore
import Foundation

/// Fixed number of fixed-size payload slots plus per-slot sample bookkeeping. When the ring is full
/// the writer evicts the *oldest* frame (latest-wins: a slow reader resyncs to live rather than
/// replaying a backlog) and counts the dropped samples so GAP_MARKED streams can report them.
/// Every frame carries a writer-side sequence number, so evicted frames leave a visible `seq` gap.
///
/// Concurrency: the writer owns `tail`; both sides move `head` with compare-exchange. The reader
/// copies a slot out and then claims it (`head: h -> h+1`); if the writer evicted that slot in the
/// meantime the claim fails and the (possibly torn) copy is discarded and retried.
final class FrameRing: @unchecked Sendable {
    let slots: Int
    let slotBytes: Int
    private let storage: UnsafeMutableRawPointer
    private let lengths: UnsafeMutablePointer<Int>
    private let starts: UnsafeMutablePointer<UInt64>
    private let counts: UnsafeMutablePointer<UInt64>
    private let seqs: UnsafeMutablePointer<UInt64>
    private var writeSeq: UInt64 = 0
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let droppedSamples = Atomic<UInt64>(0)
    private let droppedFrames = Atomic<Int>(0)
    private let pokeContinuation: AsyncStream<Void>.Continuation
    /// Fires (coalesced) whenever a frame is committed or the ring is finished.
    let poke: AsyncStream<Void>

    init(slots: Int, slotBytes: Int) {
        self.slots = slots
        self.slotBytes = slotBytes
        storage = UnsafeMutableRawPointer.allocate(byteCount: slots * slotBytes, alignment: 16)
        lengths = .allocate(capacity: slots)
        lengths.initialize(repeating: 0, count: slots)
        starts = .allocate(capacity: slots)
        starts.initialize(repeating: 0, count: slots)
        counts = .allocate(capacity: slots)
        counts.initialize(repeating: 0, count: slots)
        seqs = .allocate(capacity: slots)
        seqs.initialize(repeating: 0, count: slots)
        var cont: AsyncStream<Void>.Continuation!
        poke = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        pokeContinuation = cont
    }

    deinit {
        storage.deallocate()
        lengths.deallocate()
        starts.deallocate()
        counts.deallocate()
        seqs.deallocate()
    }

    var available: Int { tail.load(ordering: .acquiring) - head.load(ordering: .acquiring) }
    var dropped: Int { droppedFrames.load(ordering: .relaxed) }

    /// Writer side. `fill` receives the slot memory and returns the bytes it wrote (≤ slotBytes).
    /// `sampleStart`/`sampleCount` are in capture samples for gap accounting.
    func write(sampleStart: UInt64, sampleCount: UInt64, _ fill: (UnsafeMutableRawPointer) -> Int) {
        let t = tail.load(ordering: .relaxed)
        var h = head.load(ordering: .acquiring)
        while t - h >= slots {
            // Full: evict the oldest slot. A failed exchange means the reader just popped it.
            let (won, current) = head.compareExchange(expected: h, desired: h + 1, ordering: .acquiringAndReleasing)
            if won {
                droppedSamples.wrappingAdd(counts[h % slots], ordering: .relaxed)
                droppedFrames.wrappingAdd(1, ordering: .relaxed)
                h += 1
            } else {
                h = current
            }
        }
        let slot = t % slots
        let n = fill(storage + slot * slotBytes)
        lengths[slot] = min(n, slotBytes)
        starts[slot] = sampleStart
        counts[slot] = sampleCount
        writeSeq += 1
        seqs[slot] = writeSeq
        tail.store(t + 1, ordering: .releasing)
        pokeContinuation.yield(())
    }

    /// One popped frame: payload bytes copied out of the slot, its sample span, and the samples
    /// dropped since the previous pop (0 when none).
    struct Popped {
        var payload: Data
        var sampleStart: UInt64
        var sampleCount: UInt64
        var droppedSamples: UInt64
        /// Writer-side sequence (1-based, monotonic); gaps mean evicted frames.
        var seq: UInt64
    }

    /// Reader side (not hot): copies the oldest frame out.
    func pop() -> Popped? {
        var h = head.load(ordering: .acquiring)
        while true {
            let t = tail.load(ordering: .acquiring)
            guard t > h else { return nil }
            let slot = h % slots
            let payload = Data(bytes: storage + slot * slotBytes, count: min(lengths[slot], slotBytes))
            let out = Popped(payload: payload, sampleStart: starts[slot], sampleCount: counts[slot],
                             droppedSamples: 0, seq: seqs[slot])
            let (won, current) = head.compareExchange(expected: h, desired: h + 1, ordering: .acquiringAndReleasing)
            if won {
                var claimed = out
                claimed.droppedSamples = droppedSamples.exchange(0, ordering: .relaxed)
                return claimed
            }
            h = current  // the writer evicted this slot while we copied it: resync to the new oldest
        }
    }

    /// Wakes a reader parked on `poke` without committing a frame (used to end a cancelled reader).
    func wake() { pokeContinuation.yield(()) }

    /// Ends the poke stream; the reader loop exits after draining.
    func finish() { pokeContinuation.finish() }
}
