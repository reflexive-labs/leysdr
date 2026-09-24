// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import EngineCore

/// Synthesise decimated discriminator output: a sub-audible tone, optional voice, and noise, in the
/// units the detector takes (±1.0 is full-scale deviation).
/// Internal rather than private so the DCS tests can put the same voice under a code.
func discriminatorSamples(count: Int, rate: Double, fullScale: Double,
                          toneHz: Double, toneDevHz: Double,
                          voice: Bool, noise: Double, seed: UInt64) -> [Float]
{
    var rng = SplitMix64(seed: seed)
    var out = [Float](repeating: 0, count: count)
    for i in 0 ..< count {
        let t = Double(i) / rate
        var v = 0.0
        if toneHz > 0 { v += (toneDevHz / fullScale) * Foundation.sin(2 * Double.pi * toneHz * t) }
        if voice {
            // Speech-ish: a couple of tones well above the sub-audible band, syllabically shaped.
            let env = 0.5 + 0.5 * Foundation.sin(2 * Double.pi * 3 * t)
            v += 0.5 * env * (Foundation.sin(2 * Double.pi * 340 * t) + 0.6 * Foundation.sin(2 * Double.pi * 780 * t))
        }
        v += noise * rng.nextGaussian()
        out[i] = Float(v)
    }
    return out
}

/// Deterministic RNG: the fixtures must not move between runs.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUniform() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func nextGaussian() -> Double {
        let u1 = Swift.max(1e-12, nextUniform()), u2 = nextUniform()
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2)
    }
}

final class SubAudibleTests: XCTestCase {
    private let rate = 1000.0
    private let fullScale = 5000.0

    /// Run enough hops for the stability tests to have a whole horizon to work with.
    private func run(toneHz: Double, devHz: Double, voice: Bool = true, noise: Double = 0.01,
                     seed: UInt64 = 3, hops: Int = SubAudibleDetector.stabilityHops + 2) -> SubAudibleResult
    {
        let d = SubAudibleDetector(rate: rate, windowSize: 512, hop: 128)
        let total = 512 + hops * 128
        let all = discriminatorSamples(count: total, rate: rate, fullScale: fullScale,
                                       toneHz: toneHz, toneDevHz: devHz, voice: voice, noise: noise, seed: seed)
        var last = SubAudibleResult()
        for h in 0 ... hops {
            last = d.analyse(Array(all[(h * 128) ..< (h * 128 + 512)]), fullScaleDeviationHz: fullScale)
        }
        return last
    }

    /// The everyday case, at the deviation a transmitter actually uses.
    func testDetectsATone() {
        for tone in [67.0, 100.0, 123.0, 241.8] {
            let r = run(toneHz: tone, devHz: 700)
            XCTAssertTrue(r.detected, "\(tone) Hz not detected: \(r.reason)")
            XCTAssertEqual(r.standardToneHz, tone, "classified \(r.standardToneHz), want \(tone)")
            XCTAssertEqual(r.toneHz, tone, accuracy: 0.4, "measured \(r.toneHz)")
            XCTAssertEqual(r.deviationHz, 700, accuracy: 200, "deviation \(r.deviationHz)")
            XCTAssertGreaterThan(r.confidence, 0.3, "confidence \(r.confidence)")
        }
    }

    /// The hard pair: 67.0 and 69.3 are 2.3 Hz apart, and reporting the wrong one is worse than
    /// reporting none. The detector's design is driven by this case.
    func testDiscriminatesTheClosestPair() {
        let low = run(toneHz: 67.0, devHz: 700)
        let high = run(toneHz: 69.3, devHz: 700)
        XCTAssertTrue(low.detected && high.detected, "both must be detected: \(low.reason) / \(high.reason)")
        XCTAssertEqual(low.standardToneHz, 67.0, "67.0 was classified as \(low.standardToneHz)")
        XCTAssertEqual(high.standardToneHz, 69.3, "69.3 was classified as \(high.standardToneHz)")
    }

    /// Voice alone is not a tone. This is the false-positive that would make the feature useless.
    func testVoiceAloneIsNotATone() {
        for seed in UInt64(1) ... 6 {
            let r = run(toneHz: 0, devHz: 0, seed: seed)
            XCTAssertFalse(r.detected, "voice alone reported \(r.standardToneHz) Hz (seed \(seed))")
        }
    }

    /// 50 Hz mains hum lands on exactly 100.0 Hz, is perfectly stable, and passes every frequency
    /// test there is. 100.0 is also one of the commonest real PL tones. Only its deviation tells
    /// them apart, and this fixture tests the deviation gate.
    func testMainsHumIsNotReportedAsATone() {
        // Hum with no voice, the design's fixture: with voice on top, which hop's winning bin is
        // the hum and which is voice leakage decides whether the deviation gate or the stability
        // test rejects it first, and this test is about the deviation gate.
        let r = run(toneHz: 100.0, devHz: 40, voice: false)
        XCTAssertFalse(r.detected, "40 Hz of deviation at 100 Hz is hum, not PL; got \(r.standardToneHz)")
        XCTAssertTrue(r.reason.contains("deviation"), "the reason should name the deviation: \(r.reason)")
    }

    /// A measurement two standard tones could both explain is reported as a measurement and nothing
    /// more. Snapping to the nearer one on a 2.3 Hz ladder would present a guess as a reading.
    func testAmbiguousMeasurementIsNotClassified() {
        // Halfway between 67.0 and 69.3.
        XCTAssertEqual(SubAudibleDetector.classify(68.15), 0)
        XCTAssertEqual(SubAudibleDetector.classify(67.0), 67.0)
        XCTAssertEqual(SubAudibleDetector.classify(69.3), 69.3)
        // Nowhere near anything.
        XCTAssertEqual(SubAudibleDetector.classify(300), 0)
    }

    /// Confidence is a stated score, and it is zero whenever there is no classification to be
    /// confident about.
    func testConfidenceIsZeroWithoutAClassification() {
        XCTAssertEqual(SubAudibleDetector.confidence(snrDB: 40, measured: 68.15, standard: 0, hops: 5), 0)
        let strong = SubAudibleDetector.confidence(snrDB: 30, measured: 100.0, standard: 100.0, hops: 5)
        let weak = SubAudibleDetector.confidence(snrDB: 7, measured: 100.0, standard: 100.0, hops: 5)
        XCTAssertGreaterThan(strong, weak, "a cleaner tone must score higher")
        XCTAssertLessThanOrEqual(strong, 1)
    }

    /// A carrier with a tone and no speech is the start of every transmission.
    func testToneWithoutVoice() {
        let r = run(toneHz: 123.0, devHz: 700, voice: false)
        XCTAssertTrue(r.detected, "tone-only not detected: \(r.reason)")
        XCTAssertEqual(r.standardToneHz, 123.0)
    }

    /// The first window of a run has nothing to measure phase advance against, and the winning
    /// bin's nominal ladder value is a label rather than a reading. Reporting it would classify a
    /// tone on less evidence than the detector requires.
    func testFirstWindowHasNothingToMeasure() {
        let d = SubAudibleDetector(rate: rate, windowSize: 512, hop: 128)
        let s = discriminatorSamples(count: 512, rate: rate, fullScale: fullScale,
                                     toneHz: 100, toneDevHz: 700, voice: true, noise: 0.01, seed: 5)
        let first = d.analyse(s, fullScaleDeviationHz: fullScale)
        XCTAssertFalse(first.detected, "the first window reported \(first.standardToneHz) Hz")
        XCTAssertTrue(first.toneHz.isNaN, "nothing was measured, so toneHz must say so: \(first.toneHz)")
        XCTAssertEqual(first.standardToneHz, 0)
        XCTAssertEqual(first.confidence, 0)
        XCTAssertTrue(first.reason.contains("phase"), "the reason should name the missing phase reference: \(first.reason)")
        // The measurements the bank did make are still reported.
        XCTAssertFalse(first.deviationHz.isNaN)
        XCTAssertFalse(first.toneSNRDB.isNaN)
    }

    /// Closing the squelch forgets the phase history: the next transmission is a different one, and
    /// carrying phase across the gap would fabricate a stable estimate out of two unrelated ones.
    func testResetForgetsHistory() {
        let d = SubAudibleDetector(rate: rate, windowSize: 512, hop: 128)
        let s = discriminatorSamples(count: 512, rate: rate, fullScale: fullScale,
                                     toneHz: 100, toneDevHz: 700, voice: true, noise: 0.01, seed: 5)
        _ = d.analyse(s, fullScaleDeviationHz: fullScale)
        // Without the reset the second window measures against the first: a frequency, and the
        // start of a horizon that will classify the tone once it has held for a second.
        let carried = d.analyse(s, fullScaleDeviationHz: fullScale)
        XCTAssertFalse(carried.toneHz.isNaN, "a phase reference should produce a measurement: \(carried.reason)")
        XCTAssertTrue(carried.reason.contains("settling"), "one hop is not a tone yet: \(carried.reason)")

        let d2 = SubAudibleDetector(rate: rate, windowSize: 512, hop: 128)
        _ = d2.analyse(s, fullScaleDeviationHz: fullScale)
        d2.reset()
        let after = d2.analyse(s, fullScaleDeviationHz: fullScale)
        XCTAssertFalse(after.detected, "a forgotten phase reference still produced \(after.standardToneHz) Hz")
        XCTAssertTrue(after.toneHz.isNaN, "measured \(after.toneHz) with no phase reference")
    }

    /// The tolerance a classification is granted is the one confidence scores against. When they
    /// disagree, a measurement `classify` accepts can still score near zero for being far from the
    /// tone -- which understates the detector's actual confidence.
    func testConfidenceUsesTheTonesOwnTolerance() {
        // 203.5's nearest neighbour is 210.7, 7.2 Hz away, so 40% of that gap is 2.88 Hz and the
        // tighter 1% term wins: the tolerance here is 2.035 Hz.
        let standard = 203.5
        let measured = standard + 1.0
        XCTAssertEqual(SubAudibleDetector.classify(measured), standard, "the measurement must be classifiable")
        let c = SubAudibleDetector.confidence(snrDB: 30, measured: measured, standard: standard, hops: 5)
        // A fixed tolerance taken from the tightest gap in the ladder (0.4 * 2.3 Hz = 0.92 Hz)
        // would put this measurement outside tolerance and score it 0, understating the
        // detector's confidence.
        XCTAssertGreaterThan(c, 0.4, "confidence \(c) understates a cleanly resolved tone")
        XCTAssertLessThan(c, SubAudibleDetector.confidence(snrDB: 30, measured: standard, standard: standard, hops: 5))
    }
}

/// The tap is taken from the discriminator, before the 300 Hz high-pass that makes CTCSS
/// inaudible. These tests run a real NFM signal through the real demodulator and check the tone
/// survives the tap and does not survive the audio -- which is why the tap exists.
final class SubAudibleTapTests: XCTestCase {
    /// Build a channel-rate NFM signal carrying voice and a sub-audible tone.
    private func nfmIQ(rate: Double, count: Int, toneHz: Double, subHz: Double, subDevHz: Double) -> SampleStorage {
        var phase = 0.0
        var out = [Float](repeating: 0, count: count * 2)
        for i in 0 ..< count {
            let t = Double(i) / rate
            let dev = 2500 * Foundation.sin(2 * Double.pi * toneHz * t)
                + subDevHz * Foundation.sin(2 * Double.pi * subHz * t)
            phase += 2 * Double.pi * dev / rate
            out[2 * i] = Float(0.5 * Foundation.cos(phase))
            out[2 * i + 1] = Float(0.5 * Foundation.sin(phase))
        }
        return DSPTest.storage(out)
    }

    func testTapCarriesTheToneTheAudioHasLost() throws {
        let rate: UInt32 = 48_000
        let demod = NFMDemodulator()
        try demod.configure(inputRate: rate, bandwidthHz: 12_500)
        XCTAssertGreaterThan(demod.subAudibleRate, 900, "the tap should land near 1 kHz")
        XCTAssertLessThan(demod.subAudibleRate, 1_400)

        let ring = FloatRing(capacity: 8192)
        demod.subAudibleTap = ring
        // One continuous signal, fed in blocks. Regenerating it per block would restart the phase
        // every time and put a discontinuity into the discriminator that is not in any real signal.
        let per = 4096
        let blocks = 40
        let whole = nfmIQ(rate: Double(rate), count: per * blocks, toneHz: 1000, subHz: 100, subDevHz: 700)
        let src = whole.view().base.assumingMemoryBound(to: Float.self)
        var audio = SampleStorage(capacity: per, format: .f32)
        var audioAll: [Float] = []
        var chunk = SampleStorage(capacity: per, format: .cf32)
        for b in 0 ..< blocks {
            var cv = chunk.view()
            cv.base.assumingMemoryBound(to: Float.self).update(from: src + b * per * 2, count: per * 2)
            cv.count = per
            var view = audio.view()
            let n = demod.process(iq: cv, audioOut: &view)
            audioAll.append(contentsOf: UnsafeBufferPointer(start: view.base.assumingMemoryBound(to: Float.self), count: n))
        }
        XCTAssertGreaterThan(ring.available, 512, "the tap produced \(ring.available) samples")

        // Drain the tap and detect. The tone must be there.
        var tapped = [Float](repeating: 0, count: ring.available)
        let got = tapped.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
        tapped = Array(tapped[0 ..< got])
        let det = SubAudibleDetector(rate: demod.subAudibleRate, windowSize: 512, hop: 128)
        var result = SubAudibleResult()
        var off = 0
        while off + 512 <= tapped.count {
            result = det.analyse(Array(tapped[off ..< off + 512]), fullScaleDeviationHz: demod.fullScaleDeviationHz)
            off += 128
        }
        XCTAssertTrue(result.detected, "the tap should carry the tone: \(result.reason)")
        XCTAssertEqual(result.standardToneHz, 100.0, "classified \(result.standardToneHz)")

        // And the audio must not: the 300 Hz high-pass is what makes CTCSS sub-audible, and this
        // measurement shows the tap is necessary.
        let toneEnergy = energyAt(audioAll, rate: Double(rate), hz: 100)
        let voiceEnergy = energyAt(audioAll, rate: Double(rate), hz: 1000)
        XCTAssertLessThan(toneEnergy, voiceEnergy * 0.05,
                          "the audio still carries the sub-audible tone (\(toneEnergy) vs \(voiceEnergy))")
    }

    /// With no tap set, the demodulator does no sub-audible work at all.
    func testNoTapNoWork() throws {
        let demod = NFMDemodulator()
        try demod.configure(inputRate: 48_000, bandwidthHz: 12_500)
        XCTAssertNil(demod.subAudibleTap)
        let iq = nfmIQ(rate: 48_000, count: 4096, toneHz: 1000, subHz: 100, subDevHz: 700)
        var audio = SampleStorage(capacity: 4096, format: .f32)
        var view = audio.view()
        XCTAssertGreaterThan(demod.process(iq: iq.view(), audioOut: &view), 0)
    }

    private func energyAt(_ x: [Float], rate: Double, hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() {
            let a = 2 * Double.pi * hz * Double(i) / rate
            re += Double(v) * Foundation.cos(a)
            im += Double(v) * Foundation.sin(a)
        }
        return (re * re + im * im) / Double(Swift.max(1, x.count))
    }
}
