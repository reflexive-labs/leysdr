// SPDX-License-Identifier: GPL-3.0-or-later

// Lock-free single-producer / single-consumer rings used on the sample path.
// - `FloatRing`: audio floats between a sink's `write` and a render callback.
// - `BlockRing`: N slots of cf32 blocks between the device deliver callback and the DSP thread.
// Both are allocation-free after init. Neither is safe for more than one producer or consumer.

import Foundation
import Synchronization

/// SPSC ring of `Float`. Producer calls `push`, consumer calls `pop`. When the ring is full,
/// `push` drops the excess (LATEST is *not* preserved — the writer's tail is dropped, keeping the
/// stream continuous from the consumer's point of view) and counts it in `dropped`.
/// Unchecked Sendable: one producer and one consumer, ordered by the head and tail atomics; each side touches only its own end of the storage.
package final class FloatRing: @unchecked Sendable {
    /// Number of floats the ring can hold.
    package let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0) // consumer position (monotonic)
    private let tail = Atomic<Int>(0) // producer position (monotonic)
    private let droppedCount = Atomic<Int>(0)
    private let flushRequested = Atomic<Bool>(false)

    package init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// Floats currently readable.
    package var available: Int {
        tail.load(ordering: .acquiring) - head.load(ordering: .acquiring)
    }

    /// Floats currently writable.
    package var free: Int { capacity - available }

    /// Total floats dropped because the ring was full.
    package var dropped: Int { droppedCount.load(ordering: .relaxed) }

    /// Append as many of `samples` as fit. Returns the count written; the remainder is dropped.
    @discardableResult
    package func push(_ samples: UnsafeBufferPointer<Float>) -> Int {
        guard let src = samples.baseAddress, samples.count > 0 else { return 0 }
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let space = capacity - (t - h)
        let n = min(space, samples.count)
        if n > 0 {
            let start = t % capacity
            let first = min(n, capacity - start)
            (storage + start).update(from: src, count: first)
            if n > first {
                storage.update(from: src + first, count: n - first)
            }
            tail.store(t + n, ordering: .releasing)
        }
        if n < samples.count {
            droppedCount.wrappingAdd(samples.count - n, ordering: .relaxed)
            Signpost.event(.ringOverrun)
        }
        return n
    }

    /// Fill `out` with up to `out.count` floats. Returns the count read (may be 0).
    @discardableResult
    package func pop(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let dst = out.baseAddress, out.count > 0 else { return 0 }
        if flushRequested.exchange(false, ordering: .acquiringAndReleasing) {
            // Honour a control-plane flush here, on the consumer thread, so `head` has one writer.
            clear()
            return 0
        }
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let n = min(t - h, out.count)
        if n > 0 {
            let start = h % capacity
            let first = min(n, capacity - start)
            dst.update(from: storage + start, count: first)
            if n > first {
                (dst + first).update(from: storage, count: n - first)
            }
            head.store(h + n, ordering: .releasing)
        }
        return n
    }

    /// Discard everything buffered. **Consumer-thread only**: it stores `head`, which `pop` also
    /// writes, so calling it from any other thread races the consumer. Other threads use
    /// `requestFlush()`.
    package func clear() {
        head.store(tail.load(ordering: .acquiring), ordering: .releasing)
    }

    /// Ask the consumer to discard everything buffered at its next `pop`. Safe from any thread;
    /// the flush takes effect on the consumer side so `head` keeps a single writer.
    package func requestFlush() {
        flushRequested.store(true, ordering: .releasing)
    }
}

/// SPSC ring of fixed-size cf32 block slots (docs: 64 slots × 16384 samples per capture).
///
/// Producer (device thread): `acquire()` borrows the next free slot, fills it, then
/// `commit(index:count:time:)`. If no slot is free the producer gets `nil`, the block is dropped and
/// `overruns` increments — the device callback never blocks.
///
/// Consumer (DSP thread): `wait(timeoutMs:)` blocks on a semaphore until a block is committed,
/// `peek()` borrows the oldest committed block, `release()` frees it. Exactly one of each side.
/// Unchecked Sendable: one producer and one consumer, ordered by the head and tail atomics; `acquired` and the slot being filled are the producer's alone.
package final class BlockRing: @unchecked Sendable {
    /// Slots in the ring.
    package let slots: Int
    /// Complex samples per slot.
    package let blockCapacity: Int

    private let storage: [SampleStorage]
    private let counts: UnsafeMutablePointer<Int>
    private let times: UnsafeMutablePointer<SampleTime>
    private let head = Atomic<Int>(0)    // consumer: next slot to read (monotonic)
    private let tail = Atomic<Int>(0)    // producer: next slot to commit (monotonic)
    private let overrunCount = Atomic<Int>(0)
    private let semaphore = DispatchSemaphore(value: 0)
    private var acquired = false

    package init(slots: Int, blockCapacity: Int) {
        precondition(slots > 0 && blockCapacity > 0)
        self.slots = slots
        self.blockCapacity = blockCapacity
        storage = (0 ..< slots).map { _ in SampleStorage(capacity: blockCapacity, format: .cf32) }
        counts = UnsafeMutablePointer<Int>.allocate(capacity: slots)
        counts.initialize(repeating: 0, count: slots)
        times = UnsafeMutablePointer<SampleTime>.allocate(capacity: slots)
        times.initialize(repeating: SampleTime(captureID: CaptureID(), sampleIndex: 0), count: slots)
    }

    deinit {
        counts.deallocate()
        times.deinitialize(count: slots)
        times.deallocate()
    }

    /// Committed blocks not yet released.
    package var available: Int {
        tail.load(ordering: .acquiring) - head.load(ordering: .acquiring)
    }

    /// Blocks dropped by the producer because the ring was full.
    package var overruns: Int { overrunCount.load(ordering: .relaxed) }

    // MARK: Producer

    /// Borrow the next free slot. Returns `nil` (and counts an overrun) when the ring is full.
    /// The returned buffer has `count == blockCapacity`; fill up to that and `commit` the real count.
    package func acquire() -> (buffer: SampleBuffer, index: Int)? {
        precondition(!acquired, "BlockRing.acquire called twice without commit")
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        if t - h >= slots {
            overrunCount.wrappingAdd(1, ordering: .relaxed)
            Signpost.event(.ringOverrun)
            return nil
        }
        acquired = true
        let i = t % slots
        return (storage[i].view(), i)
    }

    /// Publish the slot borrowed by `acquire`. `count` is the number of complex samples written.
    package func commit(index: Int, count: Int, time: SampleTime) {
        precondition(acquired && index == tail.load(ordering: .relaxed) % slots, "commit without matching acquire")
        precondition(count >= 0 && count <= blockCapacity)
        counts[index] = count
        times[index] = time
        acquired = false
        tail.wrappingAdd(1, ordering: .releasing)
        semaphore.signal()
    }

    /// Record a producer-side drop that happened before `acquire` (e.g. conversion failure).
    package func noteOverrun() {
        overrunCount.wrappingAdd(1, ordering: .relaxed)
        Signpost.event(.ringOverrun)
    }

    // MARK: Consumer

    /// Block until a block is committed or `timeoutMs` elapses. Returns true if a block is available.
    /// Consumer-only; the DSP thread is allowed to block here (it has nothing else to do).
    package func wait(timeoutMs: Int) -> Bool {
        // One signal per commit; a spurious extra wake-up only yields a `nil` peek, which is harmless.
        if semaphore.wait(timeout: .now() + .milliseconds(max(0, timeoutMs))) == .success { return true }
        return available > 0
    }

    /// Borrow the oldest committed block, or `nil` if none. Valid until `release()`.
    package func peek() -> (buffer: SampleBuffer, time: SampleTime)? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard t > h else { return nil }
        let i = h % slots
        return (storage[i].view(count: counts[i]), times[i])
    }

    /// Free the block returned by the last `peek`. No-op if nothing is pending.
    package func release() {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard t > h else { return }
        head.store(h + 1, ordering: .releasing)
    }
}
