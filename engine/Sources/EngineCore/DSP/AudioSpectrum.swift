// SPDX-License-Identifier: GPL-3.0-or-later

// The spectrum of a channel's audio output, rather than of the capture IQ: a sliding window
// over one of the channel's audio taps, Hann-windowed and transformed through the same FFT the
// ladder uses. It is attached through the sink table, so a channel with no subscriber pays
// nothing for it.

import Foundation
import Synchronization

/// One channel tap's audio spectrum, fanned to a `SpectrumSink` as rows of dBFS per bin from 0 Hz
/// to half the audio rate.
///
/// It is an `AudioSink` because it consumes the same input: the conditioned block sent to the
/// speaker (`.audio`) or the detector's own output (`.demod`), at the channel's audio rate. The
/// window is `2 × bins` samples, so `bins` rows of real spectrum come out of one complex transform,
/// and a row is emitted whenever the window has advanced by `rate / rowsPerSecond` samples --
/// windows overlap when rows come faster than the window is long, and skip samples when they come
/// slower. Each row is the newest window, not an average of the samples since the last row.
/// Unchecked Sendable: the window state and transform buffers belong to the DSP thread that calls `write`; `closed` is atomic.
package final class AudioSpectrumSink: AudioSink, @unchecked Sendable {
    /// Fastest rows served. A row is a whole transform of a window several tens of milliseconds
    /// long; a meter updating faster than 20 times a second shows nothing extra.
    package static let maxRowsPerSecond: Double = 20

    /// Rows served where the request named no rate, the same number a capture-sourced FFT answers.
    package static let defaultRowsPerSecond: Double = 10

    /// Widest row served. Every subscription on a tap runs its own transform, and at 48 kHz a
    /// 4096-bin row is already 5 Hz a bin over a 171 ms window, finer than a meter display needs.
    /// Larger transforms cost DSP-thread time for no visible gain.
    package static let maxBins = 4096

    /// Round a request to a size the ladder also serves, so every FFT reader's row layout holds;
    /// a request past the cap comes back at the cap.
    package static func roundBins(_ bins: Int) -> Int {
        Swift.min(DefaultSpectrumLadder.roundBins(bins), maxBins)
    }

    /// Clamp a requested row rate. Non-finite or non-positive means "the default".
    package static func roundRate(_ rowsPerSecond: Double) -> Double {
        guard rowsPerSecond.isFinite, rowsPerSecond > 0 else { return defaultRowsPerSecond }
        return Swift.min(Swift.max(rowsPerSecond, DefaultSpectrumLadder.minRowsPerSecond), maxRowsPerSecond)
    }

    package let id: SinkID
    package let tap: AudioTap
    /// Bins served: the row length, covering 0 Hz to half the audio rate.
    package let bins: Int
    package let rowsPerSecond: Double
    package let audioRate: UInt32
    /// What the row's frequency axis means, in the terms every FFT reader already understands.
    package let centerHz: UInt64
    package let spanHz: UInt64

    private let sink: any SpectrumSink
    private let plan: FFTPlan
    /// Window length in samples, `2 × bins`.
    private let size: Int
    /// Samples between rows.
    private let hop: Int
    private let window, samples, re, im, fRe, fIm, mag: UnsafeMutablePointer<Float>
    private let offsetDB: Float
    private let closed = Atomic<Bool>(false)
    /// Window state, owned by the DSP thread alone: where the next sample lands, how much of the
    /// window has ever been filled, and how far it has advanced since the last row.
    private var writeIndex = 0
    private var filled = 0
    private var sinceRow = 0

    /// - Parameters:
    ///   - bins: rounded to a ladder size; the window is twice this.
    ///   - rowsPerSecond: clamped to `[DefaultSpectrumLadder.minRowsPerSecond, maxRowsPerSecond]`.
    ///   - audioRate: the channel's audio rate, which is also the tapped rate, and must be
    ///     positive -- a channel whose chain is not built yet reports zero, and the subscribe path
    ///     refuses that with `INVALID_ARGUMENT` rather than building a sink with no timebase.
    package init(id: SinkID = SinkID(), tap: AudioTap, bins: Int, rowsPerSecond: Double,
                audioRate: UInt32, sink: any SpectrumSink)
    {
        self.id = id
        self.tap = tap
        self.sink = sink
        self.audioRate = audioRate
        self.bins = Self.roundBins(bins)
        self.rowsPerSecond = Self.roundRate(rowsPerSecond)
        centerHz = UInt64(audioRate / 4)
        spanHz = UInt64(audioRate / 2)
        size = self.bins * 2
        hop = Swift.max(1, Int((Double(audioRate) / self.rowsPerSecond).rounded()))
        plan = FFTPlan(size: size)
        let n = size
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        window = alloc(); samples = alloc(); re = alloc(); im = alloc()
        fRe = alloc(); fIm = alloc(); mag = alloc()
        Kernels.hannWindow(window, count: size)
        var sum: Double = 0
        for i in 0 ..< size { sum += Double(window[i]) }
        // A real full-scale sine puts half its energy in the negative frequency, so its peak bin
        // holds `sum/2` rather than `sum`: scaling by that is what makes it read about 0 dBFS.
        offsetDB = Float(-20 * log10(sum / 2))
    }

    deinit { for p in [window, samples, re, im, fRe, fIm, mag] { p.deallocate() } }

    /// Hot path (DSP thread). Copies the block into the sliding window in at most two runs and
    /// transforms whenever a row comes due; no allocation, nothing held across the sink call.
    ///
    /// A row carries the index of the sample that completed it -- the newest sample in its
    /// window -- not the start of the block it was emitted from: one block can hold several
    /// hops, and rows that all named the block's first sample would be the same moment on the
    /// wire, which is not a timebase.
    package func write(_ audio: SampleBuffer, at time: SampleTime) {
        guard !closed.load(ordering: .relaxed), audio.format == .f32, audio.count > 0 else { return }
        let sp = Signpost.begin(.audioWrite)
        defer { Signpost.end(.audioWrite, sp) }
        let src = audio.base.assumingMemoryBound(to: Float.self)
        var i = 0
        while i < audio.count {
            // Never cross a row boundary in one run: a block can span several rows, and each of
            // them must see the window as it stood when it came due.
            let take = Swift.min(hop - sinceRow, audio.count - i)
            append(src + i, take)
            sinceRow += take
            i += take
            if sinceRow >= hop {
                sinceRow = 0
                // A row built from a part-filled window would carry the zeros it was born with as
                // a wideband smear, so the first one waits for a whole window.
                if filled >= size {
                    emit(at: SampleTime(captureID: time.captureID, sampleIndex: time.sampleIndex &+ UInt64(i - 1)))
                }
            }
        }
    }

    package func flush() async {}

    /// Stops delivery; any `write` after this returns immediately.
    package func closeSink() async { closed.store(true, ordering: .relaxed) }

    private func append(_ src: UnsafePointer<Float>, _ count: Int) {
        var offset = 0
        var left = count
        while left > 0 {
            let chunk = Swift.min(left, size - writeIndex)
            Kernels.copy(src + offset, to: samples + writeIndex, count: chunk)
            writeIndex = (writeIndex + chunk) % size
            offset += chunk
            left -= chunk
        }
        filled = Swift.min(size, filled + count)
    }

    private func emit(at time: SampleTime) {
        let sp = Signpost.begin(.fft)
        defer { Signpost.end(.fft, sp) }
        // Unwrap the ring oldest-first. `im` is zero from init and the transform never writes it,
        // so a real input costs nothing to present as a complex one.
        let head = size - writeIndex
        Kernels.copy(samples + writeIndex, to: re, count: head)
        if writeIndex > 0 { Kernels.copy(samples, to: re + head, count: writeIndex) }
        Kernels.multiply(re, window, to: re, count: size)
        plan.forward(inRe: re, inIm: im, outRe: fRe, outIm: fIm)
        // Only the first half is a frequency a real signal has; the rest mirrors it.
        Kernels.magnitudeSquared(re: fRe, im: fIm, to: mag, count: bins)
        Kernels.powerToDB(mag, to: mag, count: bins)
        Kernels.scaleAdd(mag, scale: 1, offset: offsetDB, to: mag, count: bins)
        sink.write(row: UnsafeBufferPointer(start: mag, count: bins), at: time,
                   centerHz: centerHz, spanHz: spanHz, looks: 1)
    }
}
