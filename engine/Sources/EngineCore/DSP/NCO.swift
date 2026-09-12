// SPDX-License-Identifier: GPL-3.0-or-later

// Numerically controlled oscillator: phase accumulator feeding a vectorised sincos.
// Phase is continuous across blocks and across `retune`. Allocation-free after init.

import Foundation

/// Complex oscillator `e^{jφ[n]}`, φ advancing by `2π·frequency/rate` per sample.
/// `fill` writes `cos` (real) and `sin` (imaginary) into caller buffers sized ≥ `maxBlock`.
public final class NCO {
    public let rate: Double
    /// Largest block `fill` accepts.
    public let maxBlock: Int
    /// Current frequency in Hz (negative allowed).
    public private(set) var frequencyHz: Double
    /// Current phase in radians, `[0, 2π)`.
    public private(set) var phase: Double = 0

    private var incrementF: Float = 0
    private var increment: Double = 0
    private let phases: UnsafeMutablePointer<Float>

    public init(rate: Double, frequencyHz: Double, maxBlock: Int) {
        precondition(rate > 0 && maxBlock >= 1)
        self.rate = rate
        self.maxBlock = maxBlock
        self.frequencyHz = frequencyHz
        phases = UnsafeMutablePointer<Float>.allocate(capacity: maxBlock)
        phases.initialize(repeating: 0, count: maxBlock)
        setFrequency(frequencyHz)
    }

    deinit { phases.deallocate() }

    /// Change frequency without a phase discontinuity.
    public func retune(frequencyHz: Double) { setFrequency(frequencyHz) }

    /// Reset phase to zero (frequency unchanged).
    public func reset() { phase = 0 }

    private func setFrequency(_ f: Double) {
        frequencyHz = f
        increment = 2 * Double.pi * f / rate
        incrementF = Float(increment)
    }

    /// Generate `count ≤ maxBlock` samples: `cosOut[n] = cos φ[n]`, `sinOut[n] = sin φ[n]`.
    /// Phase is accumulated in Double per block and rebuilt as a Float ramp per block, so error
    /// does not grow with time.
    public func fill(cosOut: UnsafeMutablePointer<Float>, sinOut: UnsafeMutablePointer<Float>, count: Int) {
        precondition(count <= maxBlock)
        guard count > 0 else { return }
        // Build the ramp in Double-accurate chunks: restart from the exact Double phase every
        // 256 samples so Float accumulation error stays ~1e-5 rad.
        var start = phase
        var i = 0
        while i < count {
            let n = min(256, count - i)
            var p = Float(start)
            for k in 0 ..< n {
                phases[i + k] = p
                p += incrementF
            }
            start = wrap(start + increment * Double(n))
            i += n
        }
        Kernels.sincos(phase: phases, sinOut: sinOut, cosOut: cosOut, count: count)
        phase = start
    }

    @inline(__always) private func wrap(_ p: Double) -> Double {
        let twoPi = 2 * Double.pi
        var r = p.truncatingRemainder(dividingBy: twoPi)
        if r < 0 { r += twoPi }
        return r
    }
}
