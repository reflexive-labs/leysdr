// The hot-path half of a capture: device delivery → block ring → DSP thread → channels,
// spectrum ladder and taps. Owned by `DefaultCaptureEngine`; nothing here is async.

import Foundation
import Logging
#if os(Linux)
import Glibc
#endif
import Synchronization

/// Counters exposed by a capture for diagnostics and the S2 harness.
public struct CaptureStats: Hashable, Sendable {
    /// Blocks handed to `deliver` by the device.
    public var blocksReceived: UInt64
    /// Blocks the DSP thread has processed.
    public var blocksProcessed: UInt64
    /// Samples the DSP thread has processed.
    public var samplesProcessed: UInt64
    /// Blocks dropped because the ring was full.
    public var overruns: Int
}

/// CLOCK_REALTIME in nanoseconds.
@inline(__always)
func realtimeNowNs() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
}

/// Owns the block ring, the immutable channel/tap tables and the DSP thread for one capture.
public final class CaptureDSPCore: @unchecked Sendable {
    public static let blockSize = 16384
    public static let ringSlots = 64

    public let captureID: CaptureID
    public let ring: BlockRing
    public let ladder = DefaultSpectrumLadder()
    private let sampleRateBox: Atomic<UInt64>
    private let centerHzBox: Atomic<UInt64>
    private let tableLock = NSLock()
    private var channelSlots: [ChannelSlot] = []
    private var taps: [any CaptureTap] = []
    private let blocksReceived = Atomic<UInt64>(0)
    private let blocksProcessed = Atomic<UInt64>(0)
    private let samplesProcessed = Atomic<UInt64>(0)
    private let needsAnchor = Atomic<Bool>(true)
    /// Capture-owned index base. Devices restart their own index at 0 on every `startStreaming`;
    /// the capture timeline must not. On the first block of each device epoch the base is set so
    /// that `deviceIndex &+ indexBase` continues right after the last committed sample. Device
    /// thread only (atomics because the device thread may differ between epochs).
    private let indexBase = Atomic<UInt64>(0)
    /// Capture-timeline index one past the last delivered sample (device thread only).
    private let lastDeliveredEnd = Atomic<UInt64>(0)
    private let running = Atomic<Bool>(false)
    private let threadStarts = Atomic<Int>(0)
    private let lastOverrunLogNs = Atomic<Int64>(0)
    private let lastLoggedOverruns = Atomic<Int>(0)
    private var thread: Thread?
    private let joined = DispatchSemaphore(value: 0)
    private let anchorContinuation: AsyncStream<CaptureAnchor>.Continuation
    /// Every anchor published (first block after start, sample-rate change, rebound).
    public let anchorEvents: AsyncStream<CaptureAnchor>
    private let anchorLock = NSLock()
    private var currentAnchor: CaptureAnchor
    private let log = Logger(label: "leyline.capture")

    public init(captureID: CaptureID, sampleRate: UInt64, centerHz: UInt64) {
        self.captureID = captureID
        sampleRateBox = Atomic(sampleRate)
        centerHzBox = Atomic(centerHz)
        ring = BlockRing(slots: Self.ringSlots, blockCapacity: Self.blockSize)
        currentAnchor = CaptureAnchor(hostTimeNsAtSampleZero: 0, sampleRate: sampleRate)
        (anchorEvents, anchorContinuation) = AsyncStream<CaptureAnchor>.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    public var sampleRate: UInt64 {
        get { sampleRateBox.load(ordering: .relaxed) }
        set { sampleRateBox.store(newValue, ordering: .relaxed) }
    }

    public var centerHz: UInt64 {
        get { centerHzBox.load(ordering: .relaxed) }
        set { centerHzBox.store(newValue, ordering: .relaxed) }
    }

    /// Latest published anchor (zero host time until the first block).
    public var anchor: CaptureAnchor {
        anchorLock.lock(); defer { anchorLock.unlock() }
        return currentAnchor
    }

    public var stats: CaptureStats {
        CaptureStats(blocksReceived: blocksReceived.load(ordering: .relaxed),
                     blocksProcessed: blocksProcessed.load(ordering: .relaxed),
                     samplesProcessed: samplesProcessed.load(ordering: .relaxed),
                     overruns: ring.overruns)
    }

    /// Ask for a fresh anchor on the next delivered block (stream restart, rebound). That block
    /// also starts a new device epoch: its device index is rebased onto the capture timeline so
    /// committed `SampleTime`s keep increasing across the restart.
    public func expectNewAnchor() { needsAnchor.store(true, ordering: .relaxed) }

    /// Capture-timeline index one past the last delivered sample. Diagnostics/tests.
    public var deliveredEnd: UInt64 { lastDeliveredEnd.load(ordering: .relaxed) }

    /// Waits until the DSP thread has released every block committed before the call. Control
    /// plane only: used between `stopStreaming` and a new plan (sample-rate change) so blocks
    /// captured under the old rate are never processed under the new one. Returns `false` if the
    /// backlog did not clear within `timeoutMs` (or no DSP thread is running to clear it).
    @discardableResult
    public func drainPending(timeoutMs: Int = 500) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMs)) * 1_000_000
        while ring.available > 0 {
            guard isRunning, DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }

    /// Replace the channel table (control plane).
    public func setChannels(_ slots: [ChannelSlot]) {
        tableLock.lock(); channelSlots = slots; tableLock.unlock()
    }

    /// Replace the tap table (control plane).
    public func setTaps(_ newTaps: [any CaptureTap]) {
        tableLock.lock(); taps = newTaps; tableLock.unlock()
    }

    public var currentTaps: [any CaptureTap] {
        tableLock.lock(); defer { tableLock.unlock() }
        return taps
    }

    // MARK: Device thread

    /// Device-thread entry: convert the native block to cf32 into the next ring slot and commit.
    /// Oversized blocks are split across slots; a full ring drops and counts. Never blocks.
    public func deliver(_ buffer: SampleBuffer, at time: SampleTime) {
        let sp = Signpost.begin(.blockIngest)
        defer { Signpost.end(.blockIngest, sp) }
        blocksReceived.wrappingAdd(1, ordering: .relaxed)
        let total = buffer.count
        let newEpoch = needsAnchor.exchange(false, ordering: .relaxed)
        if newEpoch {
            // New device epoch: continue the capture timeline from where the last one ended.
            indexBase.store(lastDeliveredEnd.load(ordering: .relaxed) &- time.sampleIndex, ordering: .relaxed)
        }
        let first = time.sampleIndex &+ indexBase.load(ordering: .relaxed)
        lastDeliveredEnd.store(first &+ UInt64(total), ordering: .relaxed)
        if newEpoch { publishAnchor(firstIndex: first, count: total) }
        var offset = 0
        while offset < total {
            let n = min(Self.blockSize, total - offset)
            // Full ring: the block is dropped and counted by the ring (signpost included). No
            // logging here — this is the USB callback thread and stderr I/O could stall it.
            guard let (slot, index) = ring.acquire() else { return }
            let dst = slot.base.assumingMemoryBound(to: Float.self)
            let floats = n * 2
            switch buffer.format {
            case .cf32:
                Kernels.copy(buffer.base.assumingMemoryBound(to: Float.self) + offset * 2, to: dst, count: floats)
            case .cu8:
                Kernels.convertCU8(buffer.base.assumingMemoryBound(to: UInt8.self) + offset * 2, to: dst, count: floats)
            case .cs8:
                Kernels.convertCS8(buffer.base.assumingMemoryBound(to: Int8.self) + offset * 2, to: dst, count: floats)
            case .cs16:
                Kernels.convertCS16(buffer.base.assumingMemoryBound(to: Int16.self) + offset * 2, to: dst, count: floats)
            case .f32:
                ring.commit(index: index, count: 0, time: time)
                ring.noteOverrun()
                return
            }
            ring.commit(index: index, count: n, time: SampleTime(captureID: time.captureID, sampleIndex: first &+ UInt64(offset)))
            offset += n
        }
    }

    private func publishAnchor(firstIndex: UInt64, count: Int) {
        let rate = sampleRate
        let now = realtimeNowNs()
        let elapsed = rate > 0 ? Int64(Double(firstIndex &+ UInt64(count)) / Double(rate) * 1e9) : 0
        let anchor = CaptureAnchor(hostTimeNsAtSampleZero: now - elapsed, sampleRate: rate)
        anchorLock.lock(); currentAnchor = anchor; anchorLock.unlock()
        anchorContinuation.yield(anchor)
    }

    /// DSP-thread overrun reporting: at most once per second, compares the ring's overrun counter
    /// against the last reported value and logs the difference. Kept off the device thread so the
    /// USB callback never allocates or blocks on stderr while the ring is already overrunning.
    private func reportOverrunsIfDue() {
        let total = ring.overruns
        guard total != lastLoggedOverruns.load(ordering: .relaxed) else { return }
        let now = realtimeNowNs()
        let last = lastOverrunLogNs.load(ordering: .relaxed)
        guard now - last >= 1_000_000_000 else { return }
        lastOverrunLogNs.store(now, ordering: .relaxed)
        let since = total - lastLoggedOverruns.exchange(total, ordering: .relaxed)
        log.warning("capture \(captureID) ring overrun: \(since) blocks dropped since last report (\(total) total)")
    }

    // MARK: DSP thread

    /// Starts the DSP thread (`leyline.dsp.<id>`, user-interactive QoS). Idempotent.
    public func startThread() {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        threadStarts.wrappingAdd(1, ordering: .relaxed)
        let t = Thread { [self] in
            self.loop()
            self.joined.signal()
        }
        t.name = "leyline.dsp.\(captureID)"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops and joins the DSP thread. Blocks the caller briefly (≤ one wait timeout).
    public func stopThread() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        joined.wait()
        thread = nil
    }

    public var isRunning: Bool { running.load(ordering: .relaxed) }

    /// Number of times a DSP thread has been spawned for this core. Lets tests assert that a device
    /// rebind reuses the running thread instead of respawning it.
    public var threadStartCount: Int { threadStarts.load(ordering: .relaxed) }

    /// Finishes the anchor stream. Call once at teardown.
    public func finish() {
        anchorContinuation.finish()
    }

    private func loop() {
        // Foundation's Thread.name is not visible to the kernel on Linux; name the pthread as well
        // (Linux caps names at 15 bytes) so `ps -T` / Instruments show it.
        #if os(Linux)
        if let f = fopen("/proc/thread-self/comm", "w") {
            fputs("leyline.dsp", f)
            fclose(f)
        }
        #elseif canImport(Darwin)
        pthread_setname_np("leyline.dsp.\(captureID)")
        #endif
        while running.load(ordering: .relaxed) {
            reportOverrunsIfDue()
            guard ring.wait(timeoutMs: 50) else { continue }
            while let (block, time) = ring.peek() {
                processBlock(block, at: time)
                ring.release()
            }
        }
        // Drain whatever was committed before the stop so tests see every delivered block.
        while let (block, time) = ring.peek() {
            processBlock(block, at: time)
            ring.release()
        }
    }

    /// One block through every channel, the ladder and every tap. Table snapshot: lock, copy, release.
    @inline(__always)
    private func processBlock(_ block: SampleBuffer, at time: SampleTime) {
        tableLock.lock()
        let slots = channelSlots
        let tapTable = taps
        tableLock.unlock()
        for slot in slots {
            if let core = slot.load() { core.process(block: block, at: time) }
        }
        ladder.process(block: block, at: time, centerHz: centerHz, spanHz: sampleRate)
        for tap in tapTable { tap.write(iq: block, at: time) }
        blocksProcessed.wrappingAdd(1, ordering: .relaxed)
        samplesProcessed.wrappingAdd(UInt64(block.count), ordering: .relaxed)
    }
}
