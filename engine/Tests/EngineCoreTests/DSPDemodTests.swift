import XCTest
@testable import EngineCore

final class DSPDemodTests: XCTestCase {
    let fs = 2_400_000.0
    let block = 16384

    /// Channelize + demodulate `iq` (interleaved cf32 at `fs`) block by block; returns audio and rate.
    private func run(mode: DemodMode, offsetHz: Int64, bandwidthHz: UInt32, iq: [Float], agc: Bool = true) throws -> (audio: [Float], rate: Double) {
        let ch = try Channelizer(captureRate: UInt64(fs), offsetHz: offsetHz, bandwidthHz: bandwidthHz, mode: mode, maxBlock: block)
        let demod = DemodulatorFactory.make(mode: mode)
        (demod as? AMDemodulator)?.agcEnabled = agc
        (demod as? SSBDemodulator)?.agcEnabled = agc
        try demod.configure(inputRate: ch.outputRate, bandwidthHz: bandwidthHz)
        let inStore = SampleStorage(capacity: block, format: .cf32)
        let chStore = SampleStorage(capacity: ch.maxOutput, format: .cf32)
        let outStore = SampleStorage(capacity: ch.maxOutput, format: .f32)
        var audio: [Float] = []
        let total = iq.count / 2
        var i = 0
        while i < total {
            let n = min(block, total - i)
            iq.withUnsafeBufferPointer { inStore.base.copyMemory(from: $0.baseAddress! + 2 * i, byteCount: n * 8) }
            var chOut = chStore.view()
            let m = ch.process(input: inStore.view(count: n), output: &chOut)
            var out = outStore.view()
            let frames = demod.process(iq: chStore.view(count: m), audioOut: &out)
            audio.append(contentsOf: DSPTest.floats(out, count: frames))
            i += n
        }
        return (audio, Double(demod.outputRate))
    }

    private var seconds: Double { 0.25 }
    private var count: Int { Int(fs * seconds) }

    /// The advertised maximum and the bandwidth `plan` actually accepts come off one ladder, so a
    /// client is never told a channel it cannot have (or refused one it was promised).
    func testAdvertisedMaxBandwidthIsExactlyWhatPlanAccepts() throws {
        for rate: UInt64 in [250_000, 1_024_000, 1_800_000, 2_048_000, 2_400_000, 3_200_000, 20_000_000] {
            let max = ChannelPlan.maxNarrowBandwidthHz(captureRate: rate)
            let plan = try ChannelPlan.plan(captureRate: rate, mode: .nfm, bandwidthHz: UInt32(max.rounded(.down)))
            XCTAssertEqual(max, 0.9 * plan.r2, accuracy: 1e-9, "at \(rate) S/s")
            XCTAssertThrowsError(try ChannelPlan.plan(captureRate: rate, mode: .nfm,
                                                      bandwidthHz: UInt32(max.rounded(.down)) + 1),
                                 "a bandwidth over the advertised maximum must be refused at \(rate) S/s")
        }
    }

    func testChannelPlanAt2400k() throws {
        let p = try ChannelPlan.plan(captureRate: 2_400_000, mode: .nfm, bandwidthHz: 12_500)
        XCTAssertEqual(p.d1, 10); XCTAssertEqual(p.r1, 240_000)
        XCTAssertEqual(p.d2, 5); XCTAssertEqual(p.r2, 48_000)
        XCTAssertEqual(p.stage1CutoffHz, 11_250); XCTAssertEqual(p.stage2CutoffHz, 6_250)
        XCTAssertEqual(p.antiAliasCutoffHz, 21_600)
        let w = try ChannelPlan.plan(captureRate: 2_400_000, mode: .wfm, bandwidthHz: 200_000)
        XCTAssertFalse(w.usesStage2); XCTAssertEqual(w.outputRate, 240_000); XCTAssertEqual(w.stage1CutoffHz, 100_000)
        // Narrow modes are limited to 0.9·r2 (43.2 kHz here) — never silently filtered narrower than reported.
        XCTAssertEqual(ChannelPlan.maxNarrowBandwidthHz(captureRate: 2_400_000), 43_200)
        XCTAssertNoThrow(try ChannelPlan.plan(captureRate: 2_400_000, mode: .am, bandwidthHz: 43_200))
        for mode in [DemodMode.am, .nfm, .usb, .lsb, .cw, .rawIQ] {
            XCTAssertThrowsError(try ChannelPlan.plan(captureRate: 2_400_000, mode: mode, bandwidthHz: 43_201)) {
                XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
            }
        }
        // Capture rates above the documented ceiling are malformed input, not a plan.
        XCTAssertEqual(ChannelPlan.maxCaptureRate, 100_000_000)
        XCTAssertNoThrow(try ChannelPlan.plan(captureRate: ChannelPlan.maxCaptureRate, mode: .wfm, bandwidthHz: 200_000))
        XCTAssertThrowsError(try ChannelPlan.plan(captureRate: ChannelPlan.maxCaptureRate + 1, mode: .wfm, bandwidthHz: 200_000)) {
            XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
        }
        XCTAssertThrowsError(try Channelizer(captureRate: 2_400_000, offsetHz: 0, bandwidthHz: 50_000, mode: .nfm, maxBlock: 16)) {
            XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
        }
        XCTAssertThrowsError(try Channelizer(captureRate: 2_400_000, offsetHz: 1_199_000, bandwidthHz: 12_500, mode: .nfm, maxBlock: 16)) {
            XCTAssertEqual(($0 as? EngineError)?.code, "OFFSET_OUT_OF_CAPTURE")
        }
        XCTAssertThrowsError(try Channelizer(captureRate: 2_400_000, offsetHz: 0, bandwidthHz: 0, mode: .nfm, maxBlock: 16)) {
            XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
        }
    }

    func testNFMRecoversTone() throws {
        let iq = DSPTest.fmTone(carrierHz: 100_000, audioHz: 1_000, deviationHz: 3_000, rate: fs, count: count)
        let (audio, rate) = try run(mode: .nfm, offsetHz: 100_000, bandwidthHz: 12_500, iq: iq)
        XCTAssertEqual(rate, 48_000)
        let (snr, amp) = DSPTest.toneSNR(audio, toneHz: 1_000, rate: rate, skip: Int(rate * 0.05))
        XCTAssertGreaterThan(snr, 30)
        // ±3 kHz of the ±2.5 kHz a 12.5 kHz channel carries → 1.2 full-scale, times 1-pole LPF
        // droop (0.97), the 300 Hz two-pole high-pass at 1 kHz (0.917), 300 Hz de-emphasis at
        // 1 kHz (0.287) and ×2 make-up gain.
        XCTAssertEqual(amp, 1.2 * 0.97 * 0.917 * 0.287 * 2, accuracy: 0.06)
    }

    /// Full scale follows the channel, so the same transmission is 6 dB quieter on a 25 kHz channel
    /// than on a 12.5 kHz one: ±5 kHz is what a wide NFM radio sends and what ±1.0 stands for there.
    func testNFMFullScaleFollowsChannelBandwidth() throws {
        let iq = DSPTest.fmTone(carrierHz: 100_000, audioHz: 1_000, deviationHz: 3_000, rate: fs, count: count)
        let (audio, rate) = try run(mode: .nfm, offsetHz: 100_000, bandwidthHz: 25_000, iq: iq)
        let (_, amp) = DSPTest.toneSNR(audio, toneHz: 1_000, rate: rate, skip: Int(rate * 0.05))
        XCTAssertEqual(amp, 0.6 * 0.97 * 0.917 * 0.287 * 2, accuracy: 0.03)
        XCTAssertEqual(NFMDemodulator.fullScaleDeviation(bandwidthHz: 12_500), 2_500)
        XCTAssertEqual(NFMDemodulator.fullScaleDeviation(bandwidthHz: 25_000), 5_000)
        // Either side of the two standard spacings the rule clamps rather than extrapolates.
        XCTAssertEqual(NFMDemodulator.fullScaleDeviation(bandwidthHz: 6_250), 2_500)
        XCTAssertEqual(NFMDemodulator.fullScaleDeviation(bandwidthHz: 50_000), 5_000)
        XCTAssertEqual(DemodulatorFactory.fullScaleDeviationHz(mode: .wfm, bandwidthHz: 200_000), 75_000)
        XCTAssertEqual(DemodulatorFactory.fullScaleDeviationHz(mode: .am, bandwidthHz: 12_500), 0)
    }

    /// An HT-style signal: voice at ±3 kHz plus a 100 Hz CTCSS tone at ±0.7 kHz. The high-pass must
    /// leave the voice alone and knock the sub-audible tone down by ≥ 20 dB relative to its raw level.
    func testNFMHighPassRemovesCTCSS() throws {
        let voice = DSPTest.fmTone(carrierHz: 100_000, audioHz: 1_000, deviationHz: 3_000, rate: fs, count: count)
        let ctcss = DSPTest.fmTone(carrierHz: 0, audioHz: 100, deviationHz: 700, rate: fs, count: count)
        var iq = [Float](repeating: 0, count: count * 2)
        for n in 0 ..< count { // complex product: FM with both modulating tones on one carrier
            let (a, b, c, d) = (voice[2 * n], voice[2 * n + 1], ctcss[2 * n], ctcss[2 * n + 1])
            iq[2 * n] = a * c - b * d
            iq[2 * n + 1] = a * d + b * c
        }
        let (audio, rate) = try run(mode: .nfm, offsetHz: 100_000, bandwidthHz: 12_500, iq: iq)
        let skip = Int(rate * 0.2)
        let (_, voiceAmp) = DSPTest.toneSNR(audio, toneHz: 1_000, rate: rate, skip: skip)
        let (_, toneAmp) = DSPTest.toneSNR(audio, toneHz: 100, rate: rate, skip: skip)
        XCTAssertEqual(voiceAmp, 1.2 * 0.97 * 0.917 * 0.287 * 2, accuracy: 0.08)
        // Raw CTCSS would be 0.7/2.5 = 0.28; two one-pole high-pass stages at f/fc = 1/3 leave
        // ≈ 0.1 of it, de-emphasis passes 0.95 at 100 Hz, make-up gain doubles: ≈ 0.053.
        XCTAssertLessThan(toneAmp, 0.08, "CTCSS at 100 Hz should be ≈ 20 dB down (got \(toneAmp))")
        XCTAssertGreaterThan(20 * log10(voiceAmp / max(toneAmp, 1e-9)), 18, "voice must dominate the PL tone")
    }

    func testWFMRecoversTone() throws {
        let iq = DSPTest.fmTone(carrierHz: -300_000, audioHz: 1_000, deviationHz: 50_000, rate: fs, count: count)
        let (audio, rate) = try run(mode: .wfm, offsetHz: -300_000, bandwidthHz: 200_000, iq: iq)
        XCTAssertEqual(rate, 48_000)
        let (snr, amp) = DSPTest.toneSNR(audio, toneHz: 1_000, rate: rate, skip: Int(rate * 0.05))
        XCTAssertGreaterThan(snr, 30)
        XCTAssertEqual(amp, 0.5 * 50 / 75 * 0.905, accuracy: 0.03) // de-emphasis droop at 1 kHz
    }

    func testAMRecoversTone() throws {
        let iq = DSPTest.amTone(carrierHz: 50_000, audioHz: 1_000, depth: 0.5, rate: fs, count: count)
        let (audio, rate) = try run(mode: .am, offsetHz: 50_000, bandwidthHz: 10_000, iq: iq)
        let (snr, amp) = DSPTest.toneSNR(audio, toneHz: 1_000, rate: rate, skip: Int(rate * 0.1))
        XCTAssertGreaterThan(snr, 30)
        XCTAssertEqual(amp, 0.25, accuracy: 0.05) // carrier 0.5 → AGC target 0.5, depth 0.5
    }

    func testUSBRecoversTone() throws {
        let iq = DSPTest.complexTone(frequencyHz: 20_000 + 1_000, rate: fs, count: count)
        let (audio, rate) = try run(mode: .usb, offsetHz: 20_000, bandwidthHz: 2_800, iq: iq, agc: false)
        let (snr, amp) = DSPTest.toneSNR(audio, toneHz: 1_000, rate: rate, skip: Int(rate * 0.05))
        XCTAssertGreaterThan(snr, 30)
        XCTAssertEqual(amp, 1, accuracy: 0.05)
    }

    /// `agc == .auto` brings a −30 dBFS SSB signal to the 0.5 target; manual gain leaves it at RF level.
    func testUSBAGCNormalisesLevel() throws {
        let iq = DSPTest.complexTone(frequencyHz: 20_000 + 1_000, rate: fs, count: count, amplitude: 0.0316) // −30 dBFS
        let auto = try run(mode: .usb, offsetHz: 20_000, bandwidthHz: 2_800, iq: iq, agc: true)
        let (snrAuto, ampAuto) = DSPTest.toneSNR(auto.audio, toneHz: 1_000, rate: auto.rate, skip: Int(auto.rate * 0.1))
        XCTAssertGreaterThan(snrAuto, 30)
        XCTAssertEqual(ampAuto, 0.5, accuracy: 0.05)
        let manual = try run(mode: .usb, offsetHz: 20_000, bandwidthHz: 2_800, iq: iq, agc: false)
        let (_, ampManual) = DSPTest.toneSNR(manual.audio, toneHz: 1_000, rate: manual.rate, skip: Int(manual.rate * 0.1))
        XCTAssertEqual(ampManual, 0.0316, accuracy: 0.005)
        XCTAssertLessThanOrEqual(auto.audio.map(abs).max() ?? 0, 1)
    }

    func testLSBRecoversTone() throws {
        let iq = DSPTest.complexTone(frequencyHz: 20_000 - 1_000, rate: fs, count: count)
        let (audio, rate) = try run(mode: .lsb, offsetHz: 20_000, bandwidthHz: 2_800, iq: iq)
        let (snr, amp) = DSPTest.toneSNR(audio, toneHz: 1_000, rate: rate, skip: Int(rate * 0.1))
        XCTAssertGreaterThan(snr, 30)
        XCTAssertEqual(amp, 0.5, accuracy: 0.05) // AGC target
    }

    func testUSBRejectsOppositeSideband() throws {
        let iq = DSPTest.complexTone(frequencyHz: 20_000 - 1_000, rate: fs, count: count)
        // Manual gain: this measures filter selectivity, not the AGC (which would amplify the residual).
        let (audio, rate) = try run(mode: .usb, offsetHz: 20_000, bandwidthHz: 2_800, iq: iq, agc: false)
        let (_, amp) = DSPTest.toneSNR(audio, toneHz: 1_000, rate: rate, skip: Int(rate * 0.05))
        XCTAssertLessThan(amp, 0.01)
    }

    func testCWBeatsAt700Hz() throws {
        let iq = DSPTest.complexTone(frequencyHz: -7_000, rate: fs, count: count, amplitude: 0.5)
        let (audio, rate) = try run(mode: .cw, offsetHz: -7_000, bandwidthHz: 500, iq: iq, agc: false)
        let (snr, amp) = DSPTest.toneSNR(audio, toneHz: 700, rate: rate, skip: Int(rate * 0.1))
        XCTAssertGreaterThan(snr, 30)
        XCTAssertEqual(amp, 0.5, accuracy: 0.05)
    }

    /// 500 Hz CW selectivity: an equal-power interferer 1 kHz off-channel must be ≥ 40 dB down
    /// (the selectivity FIR is designed at r2, so the 1023-tap cap at r1 no longer widens the skirt).
    func testCWRejectsInterfererAt1kHz() throws {
        let wanted = DSPTest.complexTone(frequencyHz: -7_000, rate: fs, count: count, amplitude: 0.5)
        let interferer = DSPTest.complexTone(frequencyHz: -7_000 + 1_000, rate: fs, count: count, amplitude: 0.5)
        let iq = zip(wanted, interferer).map(+)
        let (audio, rate) = try run(mode: .cw, offsetHz: -7_000, bandwidthHz: 500, iq: iq, agc: false)
        let skip = Int(rate * 0.1)
        let (_, ampWanted) = DSPTest.toneSNR(audio, toneHz: 700, rate: rate, skip: skip)
        let (_, ampInterferer) = DSPTest.toneSNR(audio, toneHz: 1_700, rate: rate, skip: skip)
        XCTAssertEqual(ampWanted, 0.5, accuracy: 0.05)
        XCTAssertLessThan(20 * log10(ampInterferer / ampWanted), -40)
    }

    /// Unsquelched noise through the NFM discriminator reaches ±2.4 before the limiter; audio must stay within ±1.
    func testNFMNoiseIsClippedToFullScale() throws {
        var g = SystemRandomNumberGenerator()
        let iq = (0 ..< 2 * count).map { _ in Float.random(in: -0.5 ... 0.5, using: &g) }
        let (audio, _) = try run(mode: .nfm, offsetHz: 100_000, bandwidthHz: 12_500, iq: iq)
        let peak = audio.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(peak, 1)
        // Noise still reaches most of full scale after de-emphasis (peaks ≈ 0.85; the clamp is the point).
        XCTAssertGreaterThan(peak, 0.5) // the clamp is actually engaging
    }

    func testRawIQProducesNoAudio() throws {
        let iq = DSPTest.complexTone(frequencyHz: 1_000, rate: fs, count: block)
        let (audio, _) = try run(mode: .rawIQ, offsetHz: 0, bandwidthHz: 12_500, iq: iq)
        XCTAssertEqual(audio.count, 0)
    }
}
