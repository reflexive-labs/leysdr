// SPDX-License-Identifier: GPL-3.0-or-later

// DSP primitives on preallocated buffers. This file and FFT.swift are the ONLY places that may
// import Accelerate (docs/dev/engine-internals.md, "Platform posture"). `AccelerateKernels` is the
// product; `PortableKernels` is the reference implementation used on Linux and by the macOS
// parity tests. Both expose identical static signatures; `Kernels` picks the platform default.
//
// Conventions: `count` is the number of elements the operation touches (floats for real vectors,
// complex samples for split/interleaved complex). Nothing here allocates.

import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

#if canImport(Accelerate)
package typealias Kernels = AccelerateKernels
#else
package typealias Kernels = PortableKernels
#endif

/// Plain-loop reference kernels. Correct everywhere; fast enough for tests and Linux CI.
package enum PortableKernels {
    /// cu8 → cf32: `(u - 127.5) / 127.5`. `count` is floats (2 per complex sample).
    @inline(__always)
    package static func convertCU8(_ src: UnsafePointer<UInt8>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        let k: Float = 1 / 127.5
        for i in 0 ..< count { dst[i] = (Float(src[i]) - 127.5) * k }
    }

    /// cs8 → cf32: `/128`. `count` is floats.
    @inline(__always)
    package static func convertCS8(_ src: UnsafePointer<Int8>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        let k: Float = 1 / 128
        for i in 0 ..< count { dst[i] = Float(src[i]) * k }
    }

    /// cs16 → cf32: `/32768`. `count` is floats.
    @inline(__always)
    package static func convertCS16(_ src: UnsafePointer<Int16>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        let k: Float = 1 / 32768
        for i in 0 ..< count { dst[i] = Float(src[i]) * k }
    }

    /// The rails, counted where `convertCU8` reads: complex samples with I or Q at 0 or 255, and
    /// the largest component magnitude in full-scale units (a rail is 1, by the conversion's own
    /// `(u - 127.5) / 127.5`). One pass; nothing written. `count` is floats, as for the conversion.
    @inline(__always)
    package static func countAtRailsCU8(_ src: UnsafePointer<UInt8>, count: Int) -> (clipped: Int, peak: Float) {
        var clipped = 0
        var lo: UInt8 = 255, hi: UInt8 = 0
        var i = 0
        while i + 1 < count {
            let a = src[i], b = src[i + 1]
            if a == 0 || a == 255 || b == 0 || b == 255 { clipped += 1 }
            lo = Swift.min(lo, Swift.min(a, b))
            hi = Swift.max(hi, Swift.max(a, b))
            i += 2
        }
        guard count >= 2 else { return (0, 0) }
        return (clipped, Swift.max(Float(hi) - 127.5, 127.5 - Float(lo)) / 127.5)
    }

    /// `countAtRailsCU8` for cs8: the rails are -128 and 127, full scale is 128.
    @inline(__always)
    package static func countAtRailsCS8(_ src: UnsafePointer<Int8>, count: Int) -> (clipped: Int, peak: Float) {
        var clipped = 0
        var peak = 0
        var i = 0
        while i + 1 < count {
            let a = Int(src[i]), b = Int(src[i + 1])
            if a == -128 || a == 127 || b == -128 || b == 127 { clipped += 1 }
            peak = Swift.max(peak, Swift.max(Swift.abs(a), Swift.abs(b)))
            i += 2
        }
        return (clipped, Float(peak) / 128)
    }

    /// `countAtRailsCU8` for cs16: the rails are -32768 and 32767, full scale is 32768.
    @inline(__always)
    package static func countAtRailsCS16(_ src: UnsafePointer<Int16>, count: Int) -> (clipped: Int, peak: Float) {
        var clipped = 0
        var peak = 0
        var i = 0
        while i + 1 < count {
            let a = Int(src[i]), b = Int(src[i + 1])
            if a == -32768 || a == 32767 || b == -32768 || b == 32767 { clipped += 1 }
            peak = Swift.max(peak, Swift.max(Swift.abs(a), Swift.abs(b)))
            i += 2
        }
        return (clipped, Float(peak) / 32768)
    }

    /// `countAtRailsCU8` for a block already in cf32: a component at or beyond ±1 is at a rail.
    @inline(__always)
    package static func countAtRailsCF32(_ src: UnsafePointer<Float>, count: Int) -> (clipped: Int, peak: Float) {
        var clipped = 0
        var peak: Float = 0
        var i = 0
        while i + 1 < count {
            let a = Swift.abs(src[i]), b = Swift.abs(src[i + 1])
            if a >= 1 || b >= 1 { clipped += 1 }
            peak = Swift.max(peak, Swift.max(a, b))
            i += 2
        }
        return (clipped, peak)
    }

    /// Interleaved cf32 → split re/im. `count` is complex samples.
    @inline(__always)
    package static func deinterleave(_ src: UnsafePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { re[i] = src[2 * i]; im[i] = src[2 * i + 1] }
    }

    /// Split re/im → interleaved cf32. `count` is complex samples.
    @inline(__always)
    package static func interleave(re: UnsafePointer<Float>, im: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { dst[2 * i] = re[i]; dst[2 * i + 1] = im[i] }
    }

    /// Element-wise complex multiply `out = a * b` (or `a * conj(b)`). Buffers may alias `out`.
    @inline(__always)
    package static func complexMultiply(aRe: UnsafePointer<Float>, aIm: UnsafePointer<Float>,
                                       bRe: UnsafePointer<Float>, bIm: UnsafePointer<Float>,
                                       outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>,
                                       count: Int, conjugateB: Bool = false) {
        if conjugateB {
            for i in 0 ..< count {
                let ar = aRe[i], ai = aIm[i], br = bRe[i], bi = bIm[i]
                outRe[i] = ar * br + ai * bi
                outIm[i] = ai * br - ar * bi
            }
        } else {
            for i in 0 ..< count {
                let ar = aRe[i], ai = aIm[i], br = bRe[i], bi = bIm[i]
                outRe[i] = ar * br - ai * bi
                outIm[i] = ar * bi + ai * br
            }
        }
    }

    /// Real-coefficient FIR + decimate on split complex, vDSP_zrdesamp semantics:
    /// `out[n] = Σ_{p<tapCount} in[n·decimation + p] · taps[p]` for `n < outputCount`.
    /// Caller guarantees the input holds at least `(outputCount-1)·decimation + tapCount` samples.
    @inline(__always)
    package static func firDecimate(re: UnsafePointer<Float>, im: UnsafePointer<Float>,
                                   taps: UnsafePointer<Float>, tapCount: Int, decimation: Int,
                                   outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>,
                                   outputCount: Int) {
        for n in 0 ..< outputCount {
            let base = n * decimation
            var sr: Float = 0, si: Float = 0
            for p in 0 ..< tapCount {
                let t = taps[p]
                sr += re[base + p] * t
                si += im[base + p] * t
            }
            outRe[n] = sr
            outIm[n] = si
        }
    }

    /// Real FIR + decimate, same semantics as `firDecimate` on one real vector.
    @inline(__always)
    package static func firDecimateReal(_ src: UnsafePointer<Float>, taps: UnsafePointer<Float>, tapCount: Int,
                                       decimation: Int, out: UnsafeMutablePointer<Float>, outputCount: Int) {
        for n in 0 ..< outputCount {
            let base = n * decimation
            var s: Float = 0
            for p in 0 ..< tapCount { s += src[base + p] * taps[p] }
            out[n] = s
        }
    }

    /// `dst = src · scale + offset`.
    @inline(__always)
    package static func scaleAdd(_ src: UnsafePointer<Float>, scale: Float, offset: Float, to dst: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { dst[i] = src[i] * scale + offset }
    }

    /// Element-wise real multiply `dst = a · b`.
    @inline(__always)
    package static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { dst[i] = a[i] * b[i] }
    }

    /// Element-wise real add `dst = a + b`.
    @inline(__always)
    package static func add(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { dst[i] = a[i] + b[i] }
    }

    /// `dst = min(max(src, lo), hi)` — hard limiter (audio full-scale guard).
    @inline(__always)
    package static func clip(_ src: UnsafePointer<Float>, lo: Float, hi: Float, to dst: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { dst[i] = Swift.min(Swift.max(src[i], lo), hi) }
    }

    /// `dst = 0`.
    @inline(__always)
    package static func clear(_ dst: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { dst[i] = 0 }
    }

    /// `dst = src` (memcpy semantics; no overlap).
    @inline(__always)
    package static func copy(_ src: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        dst.update(from: src, count: count)
    }

    /// `out = sqrt(re² + im²)`.
    @inline(__always)
    package static func magnitude(re: UnsafePointer<Float>, im: UnsafePointer<Float>, to out: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { out[i] = (re[i] * re[i] + im[i] * im[i]).squareRoot() }
    }

    /// `out = re² + im²`.
    @inline(__always)
    package static func magnitudeSquared(re: UnsafePointer<Float>, im: UnsafePointer<Float>, to out: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { out[i] = re[i] * re[i] + im[i] * im[i] }
    }

    /// `out = atan2(y, x)` in radians.
    @inline(__always)
    package static func atan2(y: UnsafePointer<Float>, x: UnsafePointer<Float>, to out: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { out[i] = Foundation.atan2f(y[i], x[i]) }
    }

    /// `sinOut = sin(phase)`, `cosOut = cos(phase)`.
    @inline(__always)
    package static func sincos(phase: UnsafePointer<Float>, sinOut: UnsafeMutablePointer<Float>, cosOut: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count { sinOut[i] = Foundation.sinf(phase[i]); cosOut[i] = Foundation.cosf(phase[i]) }
    }

    /// Power → dB: `out = 10·log10(src)`. Non-positive inputs clamp to `floorDB`.
    @inline(__always)
    package static func powerToDB(_ src: UnsafePointer<Float>, to out: UnsafeMutablePointer<Float>, count: Int, floorDB: Float = -200) {
        for i in 0 ..< count {
            let v = src[i]
            out[i] = v > 0 ? 10 * Foundation.log10f(v) : floorDB
        }
    }

    /// Arithmetic mean; 0 for an empty vector.
    @inline(__always)
    package static func mean(_ src: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var s: Float = 0
        for i in 0 ..< count { s += src[i] }
        return s / Float(count)
    }

    /// Mean of squares (power); 0 for an empty vector.
    @inline(__always)
    package static func meanSquare(_ src: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var s: Float = 0
        for i in 0 ..< count { s += src[i] * src[i] }
        return s / Float(count)
    }

    /// Elementwise maximum into `dst`. Used to accumulate a max-hold row.
    @inline(__always)
    package static func maxInPlace(_ dst: UnsafeMutablePointer<Float>, _ src: UnsafePointer<Float>, count: Int) {
        for i in 0 ..< count where src[i] > dst[i] { dst[i] = src[i] }
    }

    /// dB → linear power, the inverse of `powerToDB`. Averaging a spectrum has to
    /// happen in power: the mean of decibels is a different statistic and reads
    /// several dB low on a row with any structure in it.
    @inline(__always)
    package static func dbToPower(_ src: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        // powf, not pow: the Glibc overlay has Float overloads of the math functions and the
        // Darwin one does not, so a bare `pow` here compiles on Linux and fails on macOS. Every
        // other Float call in this file is f-suffixed for the same reason.
        for i in 0 ..< count { dst[i] = Foundation.powf(10, src[i] / 10) }
    }

    /// Largest absolute value; 0 for an empty vector.
    @inline(__always)
    package static func maxMagnitude(_ src: UnsafePointer<Float>, count: Int) -> Float {
        var m: Float = 0
        for i in 0 ..< count where Swift.abs(src[i]) > m { m = Swift.abs(src[i]) }
        return m
    }

    /// Maximum element; `-.infinity` for an empty vector.
    @inline(__always)
    package static func max(_ src: UnsafePointer<Float>, count: Int) -> Float {
        var m: Float = -.infinity
        for i in 0 ..< count where src[i] > m { m = src[i] }
        return m
    }

    /// Minimum element; `.infinity` for an empty vector.
    @inline(__always)
    package static func min(_ src: UnsafePointer<Float>, count: Int) -> Float {
        var m: Float = .infinity
        for i in 0 ..< count where src[i] < m { m = src[i] }
        return m
    }

    /// Periodic-style Hann window `0.5·(1 − cos(2πn/N))`, unnormalised (matches `vDSP_HANN_DENORM`).
    @inline(__always)
    package static func hannWindow(_ dst: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        for n in 0 ..< count {
            dst[n] = Float(0.5 * (1 - Foundation.cos(2 * Double.pi * Double(n) / Double(count))))
        }
    }

    /// One-pole IIR low-pass `y[n] = y[n−1] + a·(x[n] − y[n−1])`, state carried in `state`.
    /// `src` and `dst` may alias.
    @inline(__always)
    package static func onePoleLowPass(_ src: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int, coefficient a: Float, state: inout Float) {
        var y = state
        for i in 0 ..< count { y += a * (src[i] - y); dst[i] = y }
        state = y
    }

    /// One-pole coefficient for a cutoff (`fc`) at `rate`: `a = 1 − exp(−2π·fc/rate)`.
    @inline(__always)
    package static func onePoleCoefficient(cutoffHz: Double, rate: Double) -> Float {
        guard rate > 0, cutoffHz > 0 else { return 1 }
        return Float(1 - Foundation.exp(-2 * Double.pi * cutoffHz / rate))
    }
}

#if canImport(Accelerate)
/// vDSP/vForce-backed kernels. Signatures mirror `PortableKernels` exactly.
package enum AccelerateKernels {
    @inline(__always) private static func split(_ re: UnsafePointer<Float>, _ im: UnsafePointer<Float>) -> DSPSplitComplex {
        DSPSplitComplex(realp: UnsafeMutablePointer(mutating: re), imagp: UnsafeMutablePointer(mutating: im))
    }

    package static func convertCU8(_ src: UnsafePointer<UInt8>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        vDSP_vfltu8(src, 1, dst, 1, vDSP_Length(count))
        var scale: Float = 1 / 127.5, offset: Float = -1
        vDSP_vsmsa(dst, 1, &scale, &offset, dst, 1, vDSP_Length(count))
    }

    package static func convertCS8(_ src: UnsafePointer<Int8>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        vDSP_vflt8(src, 1, dst, 1, vDSP_Length(count))
        var scale: Float = 1 / 128
        vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(count))
    }

    package static func convertCS16(_ src: UnsafePointer<Int16>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        vDSP_vflt16(src, 1, dst, 1, vDSP_Length(count))
        var scale: Float = 1 / 32768
        vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(count))
    }

    // The rail counts are the portable loops on both platforms: vDSP has no compare-and-count, and
    // the peak alone (vDSP_maxmgv) would be a second pass over a block the count has to walk anyway.
    package static func countAtRailsCU8(_ src: UnsafePointer<UInt8>, count: Int) -> (clipped: Int, peak: Float) {
        PortableKernels.countAtRailsCU8(src, count: count)
    }

    package static func countAtRailsCS8(_ src: UnsafePointer<Int8>, count: Int) -> (clipped: Int, peak: Float) {
        PortableKernels.countAtRailsCS8(src, count: count)
    }

    package static func countAtRailsCS16(_ src: UnsafePointer<Int16>, count: Int) -> (clipped: Int, peak: Float) {
        PortableKernels.countAtRailsCS16(src, count: count)
    }

    package static func countAtRailsCF32(_ src: UnsafePointer<Float>, count: Int) -> (clipped: Int, peak: Float) {
        PortableKernels.countAtRailsCF32(src, count: count)
    }

    package static func deinterleave(_ src: UnsafePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>, count: Int) {
        var z = DSPSplitComplex(realp: re, imagp: im)
        src.withMemoryRebound(to: DSPComplex.self, capacity: count) { vDSP_ctoz($0, 2, &z, 1, vDSP_Length(count)) }
    }

    package static func interleave(re: UnsafePointer<Float>, im: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        var z = split(re, im)
        dst.withMemoryRebound(to: DSPComplex.self, capacity: count) { vDSP_ztoc(&z, 1, $0, 2, vDSP_Length(count)) }
    }

    package static func complexMultiply(aRe: UnsafePointer<Float>, aIm: UnsafePointer<Float>,
                                       bRe: UnsafePointer<Float>, bIm: UnsafePointer<Float>,
                                       outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>,
                                       count: Int, conjugateB: Bool = false) {
        var a = split(aRe, aIm), b = split(bRe, bIm)
        var c = DSPSplitComplex(realp: outRe, imagp: outIm)
        // vDSP_zvmul conjugates its *first* operand when the flag is -1; multiplication commutes.
        if conjugateB {
            vDSP_zvmul(&b, 1, &a, 1, &c, 1, vDSP_Length(count), -1)
        } else {
            vDSP_zvmul(&a, 1, &b, 1, &c, 1, vDSP_Length(count), 1)
        }
    }

    package static func firDecimate(re: UnsafePointer<Float>, im: UnsafePointer<Float>,
                                   taps: UnsafePointer<Float>, tapCount: Int, decimation: Int,
                                   outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>,
                                   outputCount: Int) {
        guard outputCount > 0 else { return }
        var a = split(re, im)
        var c = DSPSplitComplex(realp: outRe, imagp: outIm)
        vDSP_zrdesamp(&a, vDSP_Stride(decimation), taps, &c, vDSP_Length(outputCount), vDSP_Length(tapCount))
    }

    package static func firDecimateReal(_ src: UnsafePointer<Float>, taps: UnsafePointer<Float>, tapCount: Int,
                                       decimation: Int, out: UnsafeMutablePointer<Float>, outputCount: Int) {
        guard outputCount > 0 else { return }
        vDSP_desamp(src, vDSP_Stride(decimation), taps, out, vDSP_Length(outputCount), vDSP_Length(tapCount))
    }

    package static func scaleAdd(_ src: UnsafePointer<Float>, scale: Float, offset: Float, to dst: UnsafeMutablePointer<Float>, count: Int) {
        var s = scale, o = offset
        vDSP_vsmsa(src, 1, &s, &o, dst, 1, vDSP_Length(count))
    }

    package static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        vDSP_vmul(a, 1, b, 1, dst, 1, vDSP_Length(count))
    }

    package static func add(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        vDSP_vadd(a, 1, b, 1, dst, 1, vDSP_Length(count))
    }

    package static func clip(_ src: UnsafePointer<Float>, lo: Float, hi: Float, to dst: UnsafeMutablePointer<Float>, count: Int) {
        var l = lo, h = hi
        vDSP_vclip(src, 1, &l, &h, dst, 1, vDSP_Length(count))
    }

    package static func clear(_ dst: UnsafeMutablePointer<Float>, count: Int) {
        vDSP_vclr(dst, 1, vDSP_Length(count))
    }

    package static func copy(_ src: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        dst.update(from: src, count: count)
    }

    package static func magnitude(re: UnsafePointer<Float>, im: UnsafePointer<Float>, to out: UnsafeMutablePointer<Float>, count: Int) {
        var a = split(re, im)
        vDSP_zvabs(&a, 1, out, 1, vDSP_Length(count))
    }

    package static func magnitudeSquared(re: UnsafePointer<Float>, im: UnsafePointer<Float>, to out: UnsafeMutablePointer<Float>, count: Int) {
        var a = split(re, im)
        vDSP_zvmags(&a, 1, out, 1, vDSP_Length(count))
    }

    package static func atan2(y: UnsafePointer<Float>, x: UnsafePointer<Float>, to out: UnsafeMutablePointer<Float>, count: Int) {
        var n = Int32(count)
        vvatan2f(out, y, x, &n)
    }

    package static func sincos(phase: UnsafePointer<Float>, sinOut: UnsafeMutablePointer<Float>, cosOut: UnsafeMutablePointer<Float>, count: Int) {
        var n = Int32(count)
        vvsincosf(sinOut, cosOut, phase, &n)
    }

    package static func powerToDB(_ src: UnsafePointer<Float>, to out: UnsafeMutablePointer<Float>, count: Int, floorDB: Float = -200) {
        // Clamp to the power that maps to `floorDB` so log10 never sees ≤ 0, then 10·log10(x / 1).
        var floorPower = Float(pow(10.0, Double(floorDB) / 10.0))
        vDSP_vthr(src, 1, &floorPower, out, 1, vDSP_Length(count))
        var reference: Float = 1
        vDSP_vdbcon(out, 1, &reference, out, 1, vDSP_Length(count), 0)
    }

    package static func mean(_ src: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var m: Float = 0
        vDSP_meanv(src, 1, &m, vDSP_Length(count))
        return m
    }

    /// Mean of squares (power); 0 for an empty vector.
    @inline(__always)
    package static func meanSquare(_ src: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var m: Float = 0
        vDSP_measqv(src, 1, &m, vDSP_Length(count))
        return m
    }

    /// Elementwise maximum into `dst`. Used to accumulate a max-hold row.
    @inline(__always)
    package static func maxInPlace(_ dst: UnsafeMutablePointer<Float>, _ src: UnsafePointer<Float>, count: Int) {
        vDSP_vmax(dst, 1, src, 1, dst, 1, vDSP_Length(count))
    }

    /// dB → linear power, the inverse of `powerToDB`. Averaging a spectrum has to
    /// happen in power: the mean of decibels is a different statistic and reads
    /// several dB low on a row with any structure in it.
    @inline(__always)
    package static func dbToPower(_ src: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
        // The scalar loop, not vForce. There is no vDSP inverse of vDSP_vdbcon, and
        // this is the only caller of any exp/pow in the file, so vectorising it would mean adding
        // the first unproven Accelerate symbol here to save work on a path nothing takes by
        // default: dbToPower runs for ROW_MEAN alone, at most 64 looks a row, and ROW_MEAN is not
        // the default for any command. A 1024-bin row is ~65k powf a second at the worst rate.
        PortableKernels.dbToPower(src, to: dst, count: count)
    }

    /// Largest absolute value; 0 for an empty vector.
    @inline(__always)
    package static func maxMagnitude(_ src: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var m: Float = 0
        vDSP_maxmgv(src, 1, &m, vDSP_Length(count))
        return m
    }

    package static func max(_ src: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return -.infinity }
        var m: Float = 0
        vDSP_maxv(src, 1, &m, vDSP_Length(count))
        return m
    }

    package static func min(_ src: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return .infinity }
        var m: Float = 0
        vDSP_minv(src, 1, &m, vDSP_Length(count))
        return m
    }

    package static func hannWindow(_ dst: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        vDSP_hann_window(dst, vDSP_Length(count), Int32(vDSP_HANN_DENORM))
    }

    /// Recursive filter; vDSP has no 1-pole primitive, so this is the same loop as the portable kernel.
    package static func onePoleLowPass(_ src: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int, coefficient a: Float, state: inout Float) {
        PortableKernels.onePoleLowPass(src, to: dst, count: count, coefficient: a, state: &state)
    }

    package static func onePoleCoefficient(cutoffHz: Double, rate: Double) -> Float {
        PortableKernels.onePoleCoefficient(cutoffHz: cutoffHz, rate: rate)
    }
}
#endif
