// Shared synthesis helpers for the DSP tests.
import Foundation
@testable import EngineCore

enum DSPTest {
    /// Interleaved cf32 complex tone `A·e^{j(2πft/rate + φ)}`.
    static func complexTone(frequencyHz: Double, rate: Double, count: Int, amplitude: Double = 1, phase: Double = 0, startIndex: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        for n in 0 ..< count {
            let a = 2 * Double.pi * frequencyHz * Double(n + startIndex) / rate + phase
            out[2 * n] = Float(amplitude * cos(a))
            out[2 * n + 1] = Float(amplitude * sin(a))
        }
        return out
    }

    /// FM: carrier at `carrierHz` modulated by a tone at `audioHz` with `deviationHz`.
    static func fmTone(carrierHz: Double, audioHz: Double, deviationHz: Double, rate: Double, count: Int, amplitude: Double = 1) -> [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        var phase = 0.0
        for n in 0 ..< count {
            let m = sin(2 * Double.pi * audioHz * Double(n) / rate)
            phase += 2 * Double.pi * (carrierHz + deviationHz * m) / rate
            out[2 * n] = Float(amplitude * cos(phase))
            out[2 * n + 1] = Float(amplitude * sin(phase))
        }
        return out
    }

    /// AM: carrier at `carrierHz`, modulation index `depth`, audio tone at `audioHz`.
    static func amTone(carrierHz: Double, audioHz: Double, depth: Double, rate: Double, count: Int, amplitude: Double = 0.5) -> [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        for n in 0 ..< count {
            let t = Double(n) / rate
            let env = amplitude * (1 + depth * sin(2 * Double.pi * audioHz * t))
            let a = 2 * Double.pi * carrierHz * t
            out[2 * n] = Float(env * cos(a))
            out[2 * n + 1] = Float(env * sin(a))
        }
        return out
    }

    static func storage(_ samples: [Float], format: SampleFormat = .cf32) -> SampleStorage {
        let n = format == .cf32 ? samples.count / 2 : samples.count
        let s = SampleStorage(capacity: max(n, 1), format: format)
        samples.withUnsafeBufferPointer { s.base.copyMemory(from: $0.baseAddress!, byteCount: samples.count * 4) }
        return s
    }

    static func floats(_ buf: SampleBuffer, count: Int) -> [Float] {
        let n = buf.format == .cf32 ? count * 2 : count
        return Array(UnsafeBufferPointer(start: buf.base.assumingMemoryBound(to: Float.self), count: n))
    }

    /// SNR (dB) of `signal` against a least-squares fit of a sinusoid at `toneHz` over `[start, end)`.
    /// Residual after removing the fitted tone (and DC) is treated as noise+distortion.
    static func toneSNR(_ signal: [Float], toneHz: Double, rate: Double, skip: Int = 0) -> (snrDB: Double, amplitude: Double) {
        let x = signal[skip...].map(Double.init)
        let n = x.count
        var sc = 0.0, ss = 0.0, sum = 0.0
        for i in 0 ..< n {
            let a = 2 * Double.pi * toneHz * Double(i) / rate
            sc += x[i] * cos(a); ss += x[i] * sin(a); sum += x[i]
        }
        let c = 2 * sc / Double(n), s = 2 * ss / Double(n), dc = sum / Double(n)
        var sig = 0.0, noise = 0.0
        for i in 0 ..< n {
            let a = 2 * Double.pi * toneHz * Double(i) / rate
            let fit = c * cos(a) + s * sin(a)
            sig += fit * fit
            let r = x[i] - fit - dc
            noise += r * r
        }
        let amp = (c * c + s * s).squareRoot()
        return (10 * log10(sig / max(noise, 1e-30)), amp)
    }

    /// Run a demodulator over `iq` in blocks of `blockSize`; returns concatenated audio.
    static func demodulate(_ demod: any Demodulator, iq: [Float], blockSize: Int) -> [Float] {
        let total = iq.count / 2
        let inStore = SampleStorage(capacity: blockSize, format: .cf32)
        let outStore = SampleStorage(capacity: blockSize, format: .f32)
        var audio: [Float] = []
        var i = 0
        while i < total {
            let n = min(blockSize, total - i)
            iq.withUnsafeBufferPointer { inStore.base.copyMemory(from: $0.baseAddress! + 2 * i, byteCount: n * 8) }
            var out = outStore.view()
            let frames = demod.process(iq: inStore.view(count: n), audioOut: &out)
            audio.append(contentsOf: floats(out, count: frames))
            i += n
        }
        return audio
    }
}
