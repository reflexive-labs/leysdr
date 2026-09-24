// SPDX-License-Identifier: GPL-3.0-or-later

// The DCS decoder against synthesised bits and against the two real takes of the owner's GMRS
// handheld (docs/plans/signal-views.md, SV-7, "Recorded and read 2026-09-23"). The synthesis
// encodes a code with the generator the takes confirmed, sends it NRZ at 134.4 bit/s and
// ±550 Hz, the handheld's deviation, and filters it to the tap's 1 kHz through a 320 Hz low-pass
// as the demodulator's second decimation stage does. The takes run from their committed taps.

import Foundation
import XCTest
@testable import EngineCore

/// The sub-audible tap a DCS transmitter produces: `segments` codes in turn, each for its own
/// number of seconds, as received-polarity words (a complemented word is an inverted code), plus
/// a tuning error, Gaussian discriminator noise and, optionally, the voice `SubAudibleTests`
/// synthesises. ±1.0 is `fullScale` Hz, as on the tap.
func dcsTap(words segments: [(word: UInt32, seconds: Double)], deviationHz: Double = 550,
            tuningErrorHz: Double = 300, noiseHz: Double = 150, voice: Bool = false,
            fullScale: Double = 2500, seed: UInt64 = 7) -> [Float]
{
    let fast = 8000.0
    let decimation = 8
    var rng = SplitMix64(seed: seed)
    var x: [Float] = []
    var bitClock = 0.0
    var bitIndex = 0
    let total = segments.reduce(0) { $0 + Int($1.seconds * fast) }
    // The voice goes in ahead of the tap's low-pass, where a real one is.
    let speech = voice ? discriminatorSamples(count: total, rate: fast, fullScale: fullScale, toneHz: 0,
                                              toneDevHz: 0, voice: true, noise: 0, seed: seed) : []
    for segment in segments {
        let n = Int(segment.seconds * fast)
        for _ in 0 ..< n {
            // The first received bit is bit 22 of the word.
            let bit = (segment.word >> UInt32(22 - bitIndex % 23)) & 1
            var hz = (bit == 1 ? deviationHz : -deviationHz) + tuningErrorHz
            hz += noiseHz * rng.nextGaussian() * (fast / 1000).squareRoot()
            x.append(Float(hz / fullScale) + (voice ? speech[x.count] : 0))
            bitClock += DCS.bitRateHz / fast
            if bitClock >= 1 {
                bitClock -= 1
                bitIndex += 1
            }
        }
    }
    // The tap's own second stage: a 320 Hz low-pass and decimation to 1 kHz.
    let taps = FIRDesign.lowPass(cutoffHz: 320, rate: fast, transitionHz: 120)
    let fir = RealFIRDecimator(taps: taps, decimation: decimation, maxBlock: x.count)
    var out = [Float](repeating: 0, count: x.count / decimation + 8)
    let m = x.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { fir.process(src.baseAddress!, count: x.count, out: $0.baseAddress!) }
    }
    out.removeLast(out.count - m)
    return out
}

/// One hop of the decoder, with the second its last sample falls on.
struct DCSHop {
    let second: Double
    let result: DCSResult
}

/// Runs a tap through a fresh decoder in 128-sample hops, as the channel's task feeds it.
func dcsHops(over tap: [Float], rate: Double = 1000, fullScale: Double = 2500,
             codes: [Int] = DCS.standardCodes) -> [DCSHop]
{
    let decoder = DCSDecoder(rate: rate, codes: codes)
    var out: [DCSHop] = []
    var off = 0
    while off + 128 <= tap.count {
        let r = decoder.analyse(Array(tap[off ..< off + 128]), fullScaleDeviationHz: fullScale)
        off += 128
        out.append(DCSHop(second: Double(off) / rate, result: r))
    }
    return out
}

final class DCSTests: XCTestCase {
    // MARK: The word

    /// The frame the takes settled: code bits low first, `001`, parity, a codeword under 0xAE3.
    func testEveryStandardCodeEncodesToACodewordAndReadsBack() {
        XCTAssertEqual(DCS.standardCodes.count, 104)
        XCTAssertEqual(Set(DCS.standardCodes).count, 104)
        for c in DCS.standardCodes {
            let w = DCS.encode(code: c)
            XCTAssertTrue(DCS.isCodeword(w), String(format: "%03o does not encode to a codeword", c))
            XCTAssertEqual(DCS.frameCode(w), c)
            // A cyclic code containing the all-ones word: every rotation and the complement divide.
            for k in 0 ..< 23 {
                XCTAssertTrue(DCS.isCodeword(DCS.rotate(w, by: k)))
                XCTAssertTrue(DCS.isCodeword(~DCS.rotate(w, by: k) & DCS.wordMask))
            }
        }
        XCTAssertEqual(DCS.octalAsDecimal(0o023), 23)
        XCTAssertEqual(DCS.octalAsDecimal(0o754), 754)
    }

    /// The aliases the SV-7 entry lists from the takes: the fixed bits alone do not frame the word,
    /// and the complement of a listed code's word carries another listed code.
    func testRotationsAndComplementsReadAsThePlanRecords() {
        func reads(_ w: UInt32) -> Set<Int> {
            Set((0 ..< 23).compactMap { DCS.frameCode(DCS.rotate(w, by: $0)) })
        }
        let w023 = DCS.encode(code: 0o023), w754 = DCS.encode(code: 0o754)
        XCTAssertEqual(reads(w023), [0o023, 0o340, 0o766])
        XCTAssertEqual(reads(~w023 & DCS.wordMask), [0o047, 0o375, 0o707])
        XCTAssertEqual(reads(w754), [0o754, 0o076, 0o203])
        XCTAssertEqual(reads(~w754 & DCS.wordMask), [0o060, 0o116, 0o737])
        // Each listed code's word reads as exactly one listed code at each polarity, so the list
        // frames the word, and it is closed under complement.
        let listed = Set(DCS.standardCodes)
        for c in DCS.standardCodes {
            let w = DCS.encode(code: c)
            XCTAssertEqual(reads(w).intersection(listed), [c], String(format: "%03o", c))
            XCTAssertEqual(reads(~w & DCS.wordMask).intersection(listed).count, 1, String(format: "%03o inverted", c))
        }
    }

    // MARK: Synthesised bits

    func testReads023And754() throws {
        for code in [0o023, 0o754] {
            let hops = dcsHops(over: dcsTap(words: [(DCS.encode(code: code), 4)]))
            let first = try XCTUnwrap(hops.first(where: \.result.detected), String(format: "%03o never locked", code))
            XCTAssertLessThanOrEqual(first.second, 1.0, String(format: "%03o locked only at %.2f s", code, first.second))
            let claims = hops.filter(\.result.detected)
            XCTAssertEqual(Set(claims.map(\.result.code)), [DCS.octalAsDecimal(code)])
            XCTAssertTrue(claims.allSatisfy { !$0.result.inverted })
            XCTAssertTrue(claims.allSatisfy { $0.result.wordsAgreeing == 3 && $0.result.bitErrors == 0 })
            // From the first lock to the end of the tap, every hop holds it.
            XCTAssertEqual(claims.count, hops.count - hops.firstIndex(where: \.result.detected)!)
            let last = hops.last!.result
            XCTAssertEqual(last.deviationHz, 550, accuracy: 60, "deviation \(last.deviationHz)")
            XCTAssertGreaterThan(last.confidence, 0.5, "confidence \(last.confidence), eye \(last.eye)")
        }
    }

    /// Voice on top of the code, at the level `SubAudibleTests` uses, does not stop the lock.
    func testReadsUnderVoice() throws {
        let hops = dcsHops(over: dcsTap(words: [(DCS.encode(code: 0o023), 4)], voice: true))
        let claims = hops.filter(\.result.detected)
        XCTAssertFalse(claims.isEmpty, "023 under voice never locked")
        XCTAssertEqual(Set(claims.map(\.result.code)), [23])
    }

    /// An inverted code is the complemented stream, which is bit for bit another listed code's
    /// normal stream: 023 inverted is on the air as 047 normal. The decoder prefers the received
    /// polarity, so it reports 047 normal, and never a code the stream does not carry.
    func testComplementedStreamReadsAsItsNormalAlias() {
        let hops = dcsHops(over: dcsTap(words: [(~DCS.encode(code: 0o023) & DCS.wordMask, 4)]))
        let claims = hops.filter(\.result.detected)
        XCTAssertFalse(claims.isEmpty)
        XCTAssertEqual(Set(claims.map(\.result.code)), [47])
        XCTAssertTrue(claims.allSatisfy { !$0.result.inverted })
    }

    /// The complemented-polarity branch, reached with a list that holds 023 and not its alias: the
    /// same stream then reads as 023 inverted.
    func testComplementBranchReportsInverted() {
        let hops = dcsHops(over: dcsTap(words: [(~DCS.encode(code: 0o023) & DCS.wordMask, 4)]), codes: [0o023])
        let claims = hops.filter(\.result.detected)
        XCTAssertFalse(claims.isEmpty)
        XCTAssertEqual(Set(claims.map(\.result.code)), [23])
        XCTAssertTrue(claims.allSatisfy(\.result.inverted))
    }

    /// A valid codeword whose rotations and complement carry no listed code is never claimed, and
    /// in particular not as the listed code nearest it (024 is one from 023; invariant 12).
    func testNonStandardWordIsNeverClaimed() {
        let listed = Set(DCS.standardCodes)
        let w = DCS.encode(code: 0o024)
        XCTAssertTrue(DCS.isCodeword(w))
        for k in 0 ..< 23 {
            for r in [DCS.rotate(w, by: k), ~DCS.rotate(w, by: k) & DCS.wordMask] {
                if let c = DCS.frameCode(r) { XCTAssertFalse(listed.contains(c), String(format: "024 reads as %03o", c)) }
            }
        }
        let hops = dcsHops(over: dcsTap(words: [(w, 4)]))
        XCTAssertTrue(hops.allSatisfy { !$0.result.detected && $0.result.code == 0 })
        // It still reports the word it saw, for the log.
        XCTAssertTrue(hops.last.map { DCS.isCodeword($0.result.rawWord) } ?? false)
    }

    /// Voice, noise, and every standard CTCSS tone under voice: no code, on any hop.
    func testVoiceNoiseAndTonesAreNeverClaimed() {
        for seed in UInt64(1) ... 6 {
            let voice = discriminatorSamples(count: 10_000, rate: 1000, fullScale: 2500, toneHz: 0, toneDevHz: 0,
                                             voice: true, noise: 0.05, seed: seed)
            XCTAssertFalse(dcsHops(over: voice).contains(where: \.result.detected), "voice claimed (seed \(seed))")
            var rng = SplitMix64(seed: seed)
            let noise = (0 ..< 10_000).map { _ in Float(0.3 * rng.nextGaussian()) }
            XCTAssertFalse(dcsHops(over: noise).contains(where: \.result.detected), "noise claimed (seed \(seed))")
        }
        for tone in CTCSS.tones {
            let t = discriminatorSamples(count: 6000, rate: 1000, fullScale: 2500, toneHz: tone, toneDevHz: 700,
                                         voice: true, noise: 0.02, seed: 11)
            let claims = dcsHops(over: t).filter(\.result.detected)
            XCTAssertTrue(claims.isEmpty, "a \(tone) Hz tone was read as DCS \(claims.first?.result.code ?? 0)")
        }
    }

    /// A different code on the same carrier with no squelch close between them: the new code
    /// locks within a second of the change, and no third code is ever named.
    func testCodeChangeRelocks() throws {
        let hops = dcsHops(over: dcsTap(words: [(DCS.encode(code: 0o023), 3), (DCS.encode(code: 0o754), 3)]))
        let claims = hops.filter(\.result.detected)
        XCTAssertEqual(Set(claims.map(\.result.code)), [23, 754])
        let relock = try XCTUnwrap(claims.first(where: { $0.result.code == 754 }))
        XCTAssertLessThanOrEqual(relock.second - 3, 1.0, String(format: "754 locked %.2f s after the change", relock.second - 3))
        XCTAssertFalse(claims.contains { $0.result.code == 23 && $0.second > 3.4 },
                       "023 still claimed after its words left the history")
    }

    /// `reset` forgets the history: straight after it, the decoder claims nothing until it has
    /// three words of the new transmission.
    func testResetForgetsHistory() {
        let tap = dcsTap(words: [(DCS.encode(code: 0o023), 3)])
        let d = DCSDecoder(rate: 1000)
        var off = 0
        var last = DCSResult()
        while off + 128 <= tap.count {
            last = d.analyse(Array(tap[off ..< off + 128]), fullScaleDeviationHz: 2500)
            off += 128
        }
        XCTAssertTrue(last.detected)
        d.reset()
        let after = d.analyse(Array(tap[0 ..< 128]), fullScaleDeviationHz: 2500)
        XCTAssertFalse(after.detected)
        XCTAssertTrue(after.deviationHz.isNaN, "nothing was sliced yet")
    }

    /// The stated score: zero without agreeing words, rising with the eye, never above 1.
    func testConfidenceFormula() {
        XCTAssertEqual(DCSDecoder.confidence(wordsAgreeing: 0, eye: 50), 0)
        XCTAssertEqual(DCSDecoder.confidence(wordsAgreeing: 3, eye: 2), 0)
        XCTAssertEqual(DCSDecoder.confidence(wordsAgreeing: 3, eye: 5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(DCSDecoder.confidence(wordsAgreeing: 3, eye: 80), 1)
        XCTAssertEqual(DCSDecoder.confidence(wordsAgreeing: 1, eye: 80), 1.0 / 3, accuracy: 1e-12)
    }

    /// The merged result: a lock claims DCS and suppresses the CTCSS claim; no lock leaves the
    /// CTCSS result as it was.
    func testLockSuppressesTheCTCSSClaim() {
        var tone = SubAudibleResult()
        tone.detected = true
        tone.toneHz = 100.02
        tone.standardToneHz = 100
        var lock = DCSResult()
        lock.detected = true
        lock.code = 23
        lock.deviationHz = 560
        lock.confidence = 0.9
        let merged = SubAudibleResult.merged(ctcss: tone, dcs: lock)
        XCTAssertEqual(merged.kind, .dcs)
        XCTAssertFalse(merged.detected)
        XCTAssertTrue(merged.toneHz.isNaN)
        XCTAssertEqual(merged.standardToneHz, 0)
        XCTAssertEqual(merged.deviationHz, 560)
        let unlocked = SubAudibleResult.merged(ctcss: tone, dcs: DCSResult())
        XCTAssertEqual(unlocked.kind, .ctcss)
        XCTAssertEqual(unlocked.standardToneHz, 100)
        XCTAssertEqual(unlocked.toneHz, 100.02)
        var other = merged
        other.dcs?.inverted = true
        XCTAssertFalse(merged.sameClaim(as: other), "a change of polarity is an edge")
        other = merged
        other.dcs?.confidence = 0.1
        XCTAssertTrue(merged.sameClaim(as: other), "a change of confidence is not")
    }

    // MARK: The two takes

    /// Where the carrier comes up on a committed tap: the first 100 ms whose sample-to-sample
    /// scatter drops under 300 Hz. The discriminator on noise scatters by about 1 kHz there and
    /// on the handheld's carrier by about 100 Hz.
    private func keyedSpan(_ tap: [Float]) -> (start: Double, end: Double) {
        var quiet: [Bool] = []
        var i = 0
        while i + 101 <= tap.count {
            var s = 0.0, s2 = 0.0
            for j in i ..< i + 100 {
                let d = Double(tap[j + 1] - tap[j]) * SubAudibleCaptureTests.tapFullScale
                s += d
                s2 += d * d
            }
            let sd = (s2 / 100 - (s / 100) * (s / 100)).squareRoot()
            quiet.append(sd < 300)
            i += 100
        }
        let first = quiet.firstIndex(of: true) ?? 0
        let last = quiet.lastIndex(of: true) ?? 0
        return (Double(first) / 10, Double(last + 1) / 10)
    }

    private func checkTake(_ name: String, code: Int) throws {
        let tap = try SubAudibleCaptureTests.committedTap(name)
        let span = keyedSpan(tap)
        let hops = dcsHops(over: tap, rate: SubAudibleCaptureTests.tapRate, fullScale: SubAudibleCaptureTests.tapFullScale)
        let claims = hops.filter(\.result.detected)
        let first = try XCTUnwrap(claims.first, "\(name): never locked")
        let latency = first.second - span.start
        // The lock must hold on every hop after it until the carrier goes. The last 100 ms are
        // left out: the 754 take's carrier fades over its last half second (the scatter doubles
        // from 10.3 s) and the hop ending at 10.75 s reads a word that runs into the fade.
        let inSpan = hops.filter { $0.second > first.second && $0.second < span.end - 0.1 }
        let held = inSpan.filter(\.result.detected).count
        let meanConfidence = claims.map(\.result.confidence).reduce(0, +) / Double(claims.count)
        print(String(format: "%@: keyed %.1f-%.1f s, locked at %.3f s (%.3f s after key-up) as %03d inverted=%d, "
                + "held %d of %d hops after, confidence %.2f at lock and %.2f mean, deviation %.0f Hz",
            name, span.start, span.end, first.second, latency, first.result.code, first.result.inverted ? 1 : 0,
            held, inSpan.count, first.result.confidence, meanConfidence, first.result.deviationHz))
        XCTAssertLessThanOrEqual(latency, 1.0, "\(name): locked \(latency) s after the key-up")
        XCTAssertEqual(Set(claims.map(\.result.code)), [code], "\(name) read as \(Set(claims.map(\.result.code)))")
        XCTAssertTrue(claims.allSatisfy { !$0.result.inverted }, "\(name) is a normal code")
        XCTAssertEqual(held, inSpan.count, "\(name): the lock dropped inside the keyed span at "
            + inSpan.filter { !$0.result.detected }.map { String(format: "%.3f s (agree %d, eye %.1f)", $0.second, $0.result.wordsAgreeing, $0.result.eye) }.joined(separator: ", "))
        // Every published word is a rotation of the word the generator encodes for the code: the
        // takes and the encoder agree on the polynomial and the frame.
        let expected = DCS.encode(code: Int(String(code), radix: 8)!)
        let rotations = Set((0 ..< 23).map { DCS.rotate(expected, by: $0) })
        XCTAssertTrue(claims.allSatisfy { rotations.contains($0.result.rawWord) }, "\(name): a locked word is not the code's")

        // The CTCSS detector claims no tone anywhere in the keyed span, so nothing is left for
        // the lock to suppress before it forms or after it goes.
        let tones = SubAudibleCaptureTests.hops(over: tap, rate: SubAudibleCaptureTests.tapRate,
                                                fullScale: SubAudibleCaptureTests.tapFullScale)
            .filter { $0.result.detected && $0.second >= span.start && $0.second <= span.end + 0.6 }
        XCTAssertTrue(tones.isEmpty, "\(name): CTCSS claimed "
            + tones.prefix(3).map { String(format: "%.1f Hz at %.1f s", $0.result.standardToneHz, $0.second) }.joined(separator: ", "))
    }

    func testHandheldDCS023IsRead() throws {
        try checkTake("ht-dcs-023", code: 23)
    }

    func testHandheldDCS754IsRead() throws {
        try checkTake("ht-dcs-754", code: 754)
    }

    /// The CTCSS takes: the handheld's 100 Hz PL under speech and NOAA's announcer carry no DCS,
    /// and the decoder claims none on any hop.
    func testCTCSSTakesMakeNoDCSClaim() throws {
        for name in ["ht-narrow", "noaa-wx2-auto"] {
            let tap = try SubAudibleCaptureTests.committedTap(name)
            let claims = dcsHops(over: tap, rate: SubAudibleCaptureTests.tapRate,
                                 fullScale: SubAudibleCaptureTests.tapFullScale).filter(\.result.detected)
            XCTAssertTrue(claims.isEmpty, "\(name) read as DCS \(claims.first?.result.code ?? 0) on \(claims.count) hops")
        }
    }
}
