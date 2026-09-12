// SPDX-License-Identifier: GPL-3.0-or-later

// FFT plan and spectrum analyzer. With Kernels.swift, the only file allowed to import Accelerate.
// Plans allocate at init; `forward`/`analyze` are allocation-free.

import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Forward complex DFT of a fixed power-of-two size on split-complex data (unnormalised).
public final class FFTPlan {
    public let size: Int
    public let log2Size: Int

    #if canImport(Accelerate)
    private let setup: vDSP_DFT_Setup
    #else
    private let twiddleRe: UnsafeMutablePointer<Float>
    private let twiddleIm: UnsafeMutablePointer<Float>
    private let bitReverse: UnsafeMutablePointer<Int>
    #endif

    /// - Precondition: `size` is a power of two ≥ 8.
    public init(size: Int) {
        precondition(size >= 8 && size & (size - 1) == 0, "FFT size must be a power of two ≥ 8")
        self.size = size
        log2Size = size.trailingZeroBitCount
        #if canImport(Accelerate)
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        #else
        twiddleRe = UnsafeMutablePointer<Float>.allocate(capacity: size / 2)
        twiddleIm = UnsafeMutablePointer<Float>.allocate(capacity: size / 2)
        for k in 0 ..< size / 2 {
            let a = -2 * Double.pi * Double(k) / Double(size)
            twiddleRe[k] = Float(cos(a))
            twiddleIm[k] = Float(sin(a))
        }
        bitReverse = UnsafeMutablePointer<Int>.allocate(capacity: size)
        for i in 0 ..< size {
            var r = 0, v = i
            for _ in 0 ..< log2Size { r = (r << 1) | (v & 1); v >>= 1 }
            bitReverse[i] = r
        }
        #endif
    }

    deinit {
        #if canImport(Accelerate)
        vDSP_DFT_DestroySetup(setup)
        #else
        twiddleRe.deallocate(); twiddleIm.deallocate(); bitReverse.deallocate()
        #endif
    }

    /// `out = DFT(in)`; input and output must not alias. All buffers hold `size` floats.
    public func forward(inRe: UnsafePointer<Float>, inIm: UnsafePointer<Float>,
                        outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>) {
        #if canImport(Accelerate)
        vDSP_DFT_Execute(setup, inRe, inIm, outRe, outIm)
        #else
        let n = size
        for i in 0 ..< n {
            let r = bitReverse[i]
            outRe[r] = inRe[i]
            outIm[r] = inIm[i]
        }
        var len = 2
        while len <= n {
            let half = len / 2
            let step = n / len
            var start = 0
            while start < n {
                var k = 0
                for j in 0 ..< half {
                    let wr = twiddleRe[k], wi = twiddleIm[k]
                    let a = start + j, b = a + half
                    let br = outRe[b], bi = outIm[b]
                    let tr = br * wr - bi * wi
                    let ti = br * wi + bi * wr
                    let ar = outRe[a], ai = outIm[a]
                    outRe[b] = ar - tr; outIm[b] = ai - ti
                    outRe[a] = ar + tr; outIm[a] = ai + ti
                    k += step
                }
                start += len
            }
            len <<= 1
        }
        #endif
    }
}

/// Windowed power spectrum in dBFS from an interleaved cf32 block (docs: "Spectrum ladder").
/// Scaling: `10·log10(|X|² / (Σw)²)` so a full-scale complex tone reads ≈ 0 dBFS at its bin.
/// Rows are fft-shifted: index 0 is `−Fs/2`, index `size/2` is DC.
public final class SpectrumAnalyzer {
    public let size: Int
    private let plan: FFTPlan
    private let window, re, im, fRe, fIm, mag: UnsafeMutablePointer<Float>
    private let offsetDB: Float

    public init(size: Int) {
        self.size = size
        plan = FFTPlan(size: size)
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: size)
            p.initialize(repeating: 0, count: size)
            return p
        }
        window = alloc(); re = alloc(); im = alloc(); fRe = alloc(); fIm = alloc(); mag = alloc()
        Kernels.hannWindow(window, count: size)
        var sum: Double = 0
        for i in 0 ..< size { sum += Double(window[i]) }
        offsetDB = Float(-20 * log10(sum))
    }

    deinit { for p in [window, re, im, fRe, fIm, mag] { p.deallocate() } }

    /// Compute one row from the first `size` samples of `block` (`block.count ≥ size`, cf32) into
    /// `row` (`row.count ≥ size`). Hot path: no allocation.
    public func analyze(_ block: SampleBuffer, into row: UnsafeMutableBufferPointer<Float>) {
        precondition(block.format == .cf32 && block.count >= size && row.count >= size)
        let sp = Signpost.begin(.fft)
        defer { Signpost.end(.fft, sp) }
        Kernels.deinterleave(block.base.assumingMemoryBound(to: Float.self), re: re, im: im, count: size)
        Kernels.multiply(re, window, to: re, count: size)
        Kernels.multiply(im, window, to: im, count: size)
        plan.forward(inRe: re, inIm: im, outRe: fRe, outIm: fIm)
        Kernels.magnitudeSquared(re: fRe, im: fIm, to: mag, count: size)
        Kernels.powerToDB(mag, to: mag, count: size)
        Kernels.scaleAdd(mag, scale: 1, offset: offsetDB, to: mag, count: size)
        let half = size / 2
        let out = row.baseAddress!
        Kernels.copy(mag + half, to: out, count: half)
        Kernels.copy(mag, to: out + half, count: half)
    }
}
