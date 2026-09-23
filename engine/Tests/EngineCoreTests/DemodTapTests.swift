// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import EngineCore

/// Power of one tone in a block, in dB relative to full scale, by Goertzel over a Hann window.
/// The window keeps a 1 kHz voice tone out of the 80 and 120 Hz measurements: at a 20-bin
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

/// Thrown when a tap produced less than a test asked for: the assertions below size their windows
/// from `want`, and `tonePowerDB` preconditions on that length rather than failing.
private struct TapUnderrun: Error {}

/// The demod tap: what the detector produced, before the conditioning that makes it listenable.
/// Every assertion here checks something the audio tap cannot show.
final class DemodTapTests: XCTestCase {
    /// Collect both taps of one fixture channel at once, so both see the same signal.
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
        guard scope.count >= want, listener.count >= want else {
            XCTFail("the demod tap must flow like the audio one: \(scope.count) demod and \(listener.count) audio of \(want)")
            throw TapUnderrun()
        }
        return (listener.all, scope.all, Double(channel.audioRate))
    }

    /// The CTCSS tone the sidecar specifies is on the discriminator and inaudible in the audio: the
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
        // Full scale is the ±2.5 kHz a 12.5 kHz channel carries, so the fixture's ±2.5 kHz voice
        // tone reads full scale and its ±700 Hz PL sits 20·log10(700/2500) under it. These are the
        // numbers a client turns back into hertz with the descriptor's full-scale deviation.
        let voice = tonePowerDB(demod, rate: rate, frequency: 1_000, size: size)
        XCTAssertEqual(voice, 0, accuracy: 1, "1 kHz reads \(voice) dBFS on the demod tap")
        XCTAssertEqual(tone, -11, accuracy: 1, "100 Hz reads \(tone) dBFS on the demod tap")
        let heard = tonePowerDB(audio, rate: rate, frequency: 100, size: size)
        // Two cascaded 300 Hz poles put 100 Hz about 20 dB down and the de-emphasis make-up gain
        // hands some 6 dB of that back, so the listener gets the tone about 14 dB under the tap:
        // it is clearly present on the discriminator and mostly removed from the audio.
        XCTAssertLessThan(heard, tone - 12, "the listener hears \(heard) dB where the tap has \(tone) dB")
    }

    /// AM: the envelope includes the carrier as DC, which is the level a tuning indicator needs;
    /// the audio has it blocked, so its mean is near zero.
    func testAMDemodTapKeepsTheCarrierAsDC() async throws {
        let (audio, demod, _) = try await run(fixture: "am_tone.cf32")
        // The second half only: the DC block and the AGC both start from zero, and their settling
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

    /// A closed squelch mutes the audio tap only: the demod tap keeps producing between
    /// transmissions, which is where it is most useful.
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

    /// An attached demod sink does not change the demodulator's output: the conditioned block a
    /// listener gets is the same whether or not a demod sink is attached beside it.
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
    /// stereo pilot is visible at all. Both decimators start from a reset here, the case where the
    /// tap and the audio produce the same count block for block; a tap that attaches mid-stream
    /// resets its own decimator alone and the two counts can then differ by one on some blocks.
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
            XCTAssertEqual(raw?.count, frames, "from a shared reset the tap decimates in step with the audio")
            heard += Array(UnsafeBufferPointer(start: audioStore.base.assumingMemoryBound(to: Float.self), count: frames))
            tapped += Array(UnsafeBufferPointer(start: rawStore.base.assumingMemoryBound(to: Float.self), count: frames))
        }
        let audioRate = Double(demod.outputRate)
        guard tapped.count >= 8192, heard.count >= 8192 else {
            XCTFail("need 8192 samples per tap for the tone measurement: \(tapped.count) tapped, \(heard.count) heard")
            return
        }
        let onTap = tonePowerDB(tapped, rate: audioRate, frequency: 19_000, size: 8192)
        let onAudio = tonePowerDB(heard, rate: audioRate, frequency: 19_000, size: 8192)
        XCTAssertGreaterThan(onTap, onAudio + 20, "tap \(onTap) dB against audio \(onAudio) dB")
        // ±75 kHz reads ±1.0, so half that deviation is half scale.
        XCTAssertEqual(tapped.map { abs($0) }.max() ?? 0, 0.5, accuracy: 0.1)
    }

    /// A raw-IQ channel has no detector, so there is nothing to tap and the attach fails rather
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

    /// Switching a tapped channel to raw IQ would leave the scope subscribed to a stage that no
    /// longer runs, so the reconfigure is refused while the tap is attached.
    func testSwitchToRawIQRefusedWhileDemodTapAttached() async throws {
        let capture = DefaultCaptureEngine(device: try FilePlaybackDevice(path: Fixtures.dir + "/nfm_pl.cf32", loop: true, realtime: false),
                                           centerHz: 146_520_000, sampleRate: 2_400_000)
        var config = ChannelConfig(offsetHz: 0, bandwidthHz: 12_500, mode: .nfm)
        let channel = try await capture.addChannel(config)
        let scope = AudioCollector(tap: .demod)
        try await channel.attach(scope.sink)
        config.mode = .rawIQ
        do {
            try await channel.update(config)
            XCTFail("a demod tap cannot survive the switch to raw IQ")
        } catch let error as EngineError {
            XCTAssertEqual(error.code, "INVALID_ARGUMENT")
        }
        let mode = await channel.config.mode
        XCTAssertEqual(mode, .nfm, "the rejected update leaves the channel alone")
        await capture.stop()
    }
}
