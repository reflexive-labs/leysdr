import Foundation
import XCTest
@testable import EngineCore

/// Power of one tone in a block, in dB relative to full scale, by Goertzel over a Hann window.
/// The window is what keeps a 1 kHz voice tone out of the 80 and 120 Hz answers: at a 20-bin
/// distance its leakage is far below anything being compared here.
private func tonePowerDB(_ x: [Float], rate: Double, frequency: Double, size: Int) -> Double {
    precondition(x.count >= size)
    let k = 2 * Double.pi * frequency / rate
    let coefficient = 2 * Foundation.cos(k)
    var s1 = 0.0, s2 = 0.0, window = 0.0
    for i in 0 ..< size {
        let w = 0.5 - 0.5 * Foundation.cos(2 * Double.pi * Double(i) / Double(size))
        window += w
        let s0 = w * Double(x[i]) + coefficient * s1 - s2
        s2 = s1
        s1 = s0
    }
    let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
    // Normalised by the window's coherent gain so a full-scale tone reads 0 dB.
    let amplitude = 2 * power.squareRoot() / window
    return 20 * Foundation.log10(Swift.max(amplitude, 1e-12))
}

/// The demod tap: what the detector produced, before the conditioning that makes it listenable.
/// Every assertion here is a thing the audio tap cannot show, which is the reason the tap exists.
final class DemodTapTests: XCTestCase {
    /// Collect both taps of one fixture channel at once, so the two are the same air.
    private func run(fixture name: String, seconds: Double = 0.7) async throws -> (audio: [Float], demod: [Float], rate: Double) {
        let path = Fixtures.dir + "/" + name
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no \(name) in \(Fixtures.dir); run `make fixtures`")
        }
        let device = try FilePlaybackDevice(path: path, loop: true, realtime: true)
        let sidecar = device.sidecar
        let e = try XCTUnwrap(sidecar.expect?.first, "\(name) has no expectation to run")
        let mode = try XCTUnwrap(DemodMode(rawValue: e.mode.lowercased()))
        let capture = DefaultCaptureEngine(device: device, centerHz: UInt64(sidecar.centerHz), sampleRate: UInt64(sidecar.sampleRate))
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: e.offsetHz,
                                                                 bandwidthHz: e.bandwidthHz ?? mode.defaultBandwidthHz,
                                                                 mode: mode))
        let listener = AudioCollector()
        let scope = AudioCollector(tap: .demod)
        try await channel.attach(listener.sink)
        try await channel.attach(scope.sink)
        try await capture.start()
        let want = Int(seconds * Double(channel.audioRate))
        let deadline = Date().addingTimeInterval(seconds + 10)
        while Date() < deadline, listener.count < want || scope.count < want {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await capture.stop()
        XCTAssertGreaterThanOrEqual(scope.count, want, "the demod tap must flow like the audio one")
        return (listener.all, scope.all, Double(channel.audioRate))
    }

    /// The CTCSS tone the sidecar names is on the discriminator and inaudible in the audio: the
    /// 300 Hz high-pass that makes it inaudible is exactly what the demod tap is taken before.
    func testNFMDemodTapCarriesThePLTone() async throws {
        let (audio, demod, rate) = try await run(fixture: "nfm_pl.cf32")
        // 0.5 s at 48 kHz: 100, 80 and 120 Hz all land on bin centres.
        let size = Int(rate / 2)
        let tone = tonePowerDB(demod, rate: rate, frequency: 100, size: size)
        let below = tonePowerDB(demod, rate: rate, frequency: 80, size: size)
        let above = tonePowerDB(demod, rate: rate, frequency: 120, size: size)
        XCTAssertGreaterThan(tone, below + 20, "100 Hz \(tone) dB against 80 Hz \(below) dB")
        XCTAssertGreaterThan(tone, above + 20, "100 Hz \(tone) dB against 120 Hz \(above) dB")
        let heard = tonePowerDB(audio, rate: rate, frequency: 100, size: size)
        // The high-pass is two poles at 300 Hz and the de-emphasis behind it hands about 5 dB of
        // that back at 100 Hz, so what reaches the listener is some 14 dB under the tap. The tap is
        // where the tone is a signal; in the audio it is a residue.
        XCTAssertLessThan(heard, tone - 12, "the listener hears \(heard) dB where the tap has \(tone) dB")
    }

    /// AM: the envelope includes the carrier as DC, which is the level a tuning eye wants; the audio
    /// has it blocked, so its mean is nothing.
    func testAMDemodTapKeepsTheCarrierAsDC() async throws {
        let (audio, demod, _) = try await run(fixture: "am_tone.cf32")
        // The second half only: the DC block and the AGC both start from nothing, and their settling
        // is a transient of the first block, not a property of either tap.
        func mean(_ x: [Float]) -> Double {
            let tail = x.suffix(x.count / 2)
            return tail.reduce(0.0) { $0 + Double($1) } / Double(tail.count)
        }
        let carrier = mean(demod)
        // The fixture's carrier sits at -20 dBFS, so the envelope averages about 0.1.
        XCTAssertEqual(carrier, 0.1, accuracy: 0.05, "envelope mean \(carrier)")
        XCTAssertLessThan(abs(mean(audio)), carrier / 20, "audio mean \(mean(audio)) against carrier \(carrier)")
    }

    /// A closed squelch silences the listener and nobody else: between words is when the demod tap
    /// earns its keep.
    func testClosedSquelchZeroesAudioAndNotTheDemodTap() throws {
        let rate: UInt64 = 240_000
        let core = try ChannelDSPCore(captureRate: rate,
                                      config: ChannelConfig(offsetHz: 0, bandwidthHz: 12_500, mode: .nfm, squelchDB: 10),
                                      telemetry: ChannelTelemetryQueue())
        let listener = AudioCollector()
        let scope = AudioCollector(tap: .demod)
        core.setSinks([listener.sink, scope.sink])
        let block = 4096
        let signal = DSPTest.storage(DSPTest.fmTone(carrierHz: 0, audioHz: 1000, deviationHz: 2500, rate: Double(rate), count: block))
        let cap = CaptureID()
        for i in 0 ..< 8 {
            core.process(block: signal.view(count: block), at: SampleTime(captureID: cap, sampleIndex: UInt64(i * block)))
        }
        XCTAssertGreaterThan(listener.count, 0)
        XCTAssertEqual(listener.count, scope.count, "both taps run at the audio rate")
        XCTAssertTrue(listener.all.allSatisfy { $0 == 0 }, "a closed squelch is silence to the listener")
        XCTAssertTrue(scope.all.contains { abs($0) > 0.1 }, "the detector's output keeps flowing while the squelch is shut")
    }

    /// Nobody watching costs the demodulator nothing: with no demod sink attached the audio is the
    /// same block it always was.
    func testAudioIsUnchangedByTheTapBeingAvailable() throws {
        let rate: UInt64 = 240_000
        let block = 4096
        let signal = DSPTest.storage(DSPTest.fmTone(carrierHz: 0, audioHz: 1000, deviationHz: 2500, rate: Double(rate), count: block))
        let cap = CaptureID()
        func audio(withScope: Bool) throws -> [Float] {
            let core = try ChannelDSPCore(captureRate: rate,
                                          config: ChannelConfig(offsetHz: 0, bandwidthHz: 12_500, mode: .nfm, squelchDB: -40),
                                          telemetry: ChannelTelemetryQueue())
            let listener = AudioCollector()
            let scope = AudioCollector(tap: .demod)
            core.setSinks(withScope ? [listener.sink, scope.sink] : [listener.sink])
            for i in 0 ..< 4 {
                core.process(block: signal.view(count: block), at: SampleTime(captureID: cap, sampleIndex: UInt64(i * block)))
            }
            return listener.all
        }
        XCTAssertEqual(try audio(withScope: true), try audio(withScope: false))
    }

    /// WFM: the tap is taken before the 15 kHz audio filter, which is the only reason a 19 kHz
    /// stereo pilot is visible at all. Its own decimator stays block-aligned with the audio one.
    func testWFMDemodTapKeepsWhatTheAudioFilterCuts() throws {
        let rate: UInt32 = 240_000
        let demod = WFMDemodulator()
        try demod.configure(inputRate: rate, bandwidthHz: 200_000)
        let block = 4096
        let blocks = 12
        // One continuous tone across every block: a per-block restart would put a step at each join.
        let signal = DSPTest.fmTone(carrierHz: 0, audioHz: 19_000, deviationHz: 37_500, rate: Double(rate), count: block * blocks)
        let audioStore = SampleStorage(capacity: block, format: .f32)
        let rawStore = SampleStorage(capacity: block, format: .f32)
        var heard: [Float] = []
        var tapped: [Float] = []
        for b in 0 ..< blocks {
            let iq = DSPTest.storage(Array(signal[(b * block * 2) ..< ((b + 1) * block * 2)]))
            var audio = audioStore.view()
            var raw: SampleBuffer? = rawStore.view()
            let frames = demod.process(iq: iq.view(count: block), audioOut: &audio, rawOut: &raw)
            XCTAssertEqual(raw?.count, frames, "the tap decimates in step with the audio")
            heard += Array(UnsafeBufferPointer(start: audioStore.base.assumingMemoryBound(to: Float.self), count: frames))
            tapped += Array(UnsafeBufferPointer(start: rawStore.base.assumingMemoryBound(to: Float.self), count: frames))
        }
        let audioRate = Double(demod.outputRate)
        let onTap = tonePowerDB(tapped, rate: audioRate, frequency: 19_000, size: 8192)
        let onAudio = tonePowerDB(heard, rate: audioRate, frequency: 19_000, size: 8192)
        XCTAssertGreaterThan(onTap, onAudio + 20, "tap \(onTap) dB against audio \(onAudio) dB")
        // ±75 kHz reads ±1.0, so half that deviation is half scale.
        XCTAssertEqual(tapped.map { abs($0) }.max() ?? 0, 0.5, accuracy: 0.1)
    }

    /// A raw-IQ channel has no detector, so there is nothing to tap and the attach says so rather
    /// than serving silence.
    func testRawIQChannelRefusesTheDemodTap() async throws {
        let capture = DefaultCaptureEngine(device: try FilePlaybackDevice(path: Fixtures.dir + "/nfm_pl.cf32", loop: true, realtime: false),
                                           centerHz: 146_520_000, sampleRate: 2_400_000)
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 0, bandwidthHz: 12_500, mode: .rawIQ))
        let scope = AudioCollector(tap: .demod)
        do {
            try await channel.attach(scope.sink)
            XCTFail("a raw-IQ channel has no demod tap to attach to")
        } catch let error as EngineError {
            XCTAssertEqual(error.code, "INVALID_ARGUMENT")
        }
        await capture.stop()
    }
}
