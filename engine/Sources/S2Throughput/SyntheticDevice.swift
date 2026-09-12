// SPDX-License-Identifier: GPL-3.0-or-later

// A RadioDevice that plays a precomputed tone+noise cf32 loop at a fixed rate on its own thread.
// Used only by the S2 throughput spike; like FilePlaybackDevice it paces against an absolute
// start time, so sleep jitter never accumulates.

import EngineCore
import Foundation
import Synchronization

/// Sleeps for `ns`, resuming after a signal. The seconds are split out because `nanosleep` refuses
/// a `tv_nsec` of a second or more with EINVAL and sleeps not at all, which at a low `--rate` would
/// turn the pacing into a busy spin and charge the harness's own spinning to the CPU number the
/// spike exists to measure.
func sleepNanoseconds(_ ns: UInt64) {
    var request = timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))
    var remaining = timespec()
    while nanosleep(&request, &remaining) == -1, errno == EINTR {
        request = remaining
    }
}

/// Synthetic 20 MSPS-class source: a −20 dBFS NFM carrier plus white noise, cycled from a
/// pre-rendered buffer so generation cost does not pollute the measurement.
final class SyntheticDevice: RadioDevice, @unchecked Sendable {
    static let blockSize = 16384
    let rate: UInt64
    let centerHz: UInt64
    let blocks: Int
    private let storage: SampleStorage
    private let running = Atomic<Bool>(false)
    private var thread: Thread?
    private let joined = DispatchSemaphore(value: 0)
    private var nextIndex: UInt64 = 0
    let descriptor: DeviceDescriptor
    var gains: [GainState] { [] }

    /// `toneOffsetHz` is the NFM carrier offset; the pre-rendered loop holds `blocks` blocks.
    init(rate: UInt64, centerHz: UInt64, toneOffsetHz: Double, blocks: Int = 64) {
        self.rate = rate
        self.centerHz = centerHz
        self.blocks = blocks
        descriptor = DeviceDescriptor(id: DeviceID(), driver: "synthetic", model: "S2 synthetic source", serial: "s2",
                                      tuningRanges: [FrequencyRange(minHz: 0, maxHz: 6_000_000_000)], sampleRates: [rate], nativeFormat: .cf32)
        let total = blocks * Self.blockSize
        storage = SampleStorage(capacity: total, format: .cf32)
        let p = storage.base.assumingMemoryBound(to: Float.self)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var phase = 0.0
        let fs = Double(rate)
        for n in 0 ..< total {
            let m = sin(2 * Double.pi * 1000 * Double(n) / fs)
            phase += 2 * Double.pi * (toneOffsetHz + 2500 * m) / fs
            if phase > Double.pi { phase -= 2 * Double.pi }
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let n1 = Float(Int64(bitPattern: seed >> 11) % 2001) / 1000 - 1
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let n2 = Float(Int64(bitPattern: seed >> 11) % 2001) / 1000 - 1
            p[2 * n] = Float(0.1 * cos(phase)) + 0.01 * n1
            p[2 * n + 1] = Float(0.1 * sin(phase)) + 0.01 * n2
        }
    }

    func open() async throws {}
    func close() async { await stopStreaming() }
    func tune(centerHz: UInt64) async throws {}
    func setSampleRate(_ hz: UInt64) async throws {
        guard hz == rate else { throw EngineError.rateUnsupported(hz, target: descriptor.id.description) }
    }
    func setGain(element: String, value: GainValue) async throws {
        throw EngineError.gainElementUnknown(element, target: descriptor.id.description)
    }

    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { throw EngineError.deviceBusy(descriptor.id.description) }
        let t = Thread { [self] in
            let start = DispatchTime.now().uptimeNanoseconds
            var delivered: UInt64 = 0
            var block = 0
            while running.load(ordering: .relaxed) {
                let base = storage.base + block * Self.blockSize * 8
                let buffer = SampleBuffer(base: base, count: Self.blockSize, format: .cf32)
                deliver(buffer, SampleTime(captureID: captureID, sampleIndex: nextIndex))
                nextIndex &+= UInt64(Self.blockSize)
                delivered += UInt64(Self.blockSize)
                block = (block + 1) % blocks
                let due = start + delivered * 1_000_000_000 / rate
                let now = DispatchTime.now().uptimeNanoseconds
                if due > now { sleepNanoseconds(due - now) }
            }
            joined.signal()
        }
        t.name = "leyline.s2.source"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stopStreaming() async {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        joined.wait()
        thread = nil
    }
}
