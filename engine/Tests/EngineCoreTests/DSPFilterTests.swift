// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import EngineCore

final class DSPFilterTests: XCTestCase {
    /// Frequency response of taps at `hz` (magnitude).
    private func response(_ taps: [Float], hz: Double, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (n, t) in taps.enumerated() {
            let a = -2 * Double.pi * hz * Double(n) / rate
            re += Double(t) * cos(a); im += Double(t) * sin(a)
        }
        return (re * re + im * im).squareRoot()
    }

    func testLowPassDesignResponse() {
        let rate = 240_000.0
        let taps = FIRDesign.lowPass(cutoffHz: 6_000, rate: rate, transitionHz: 3_000)
        XCTAssertEqual(taps.count % 2, 1)
        XCTAssertLessThanOrEqual(taps.count, FIRDesign.maxTaps)
        XCTAssertEqual(response(taps, hz: 0, rate: rate), 1, accuracy: 1e-4)
        XCTAssertEqual(response(taps, hz: 2_000, rate: rate), 1, accuracy: 0.01)
        XCTAssertEqual(response(taps, hz: 6_000, rate: rate), 0.5, accuracy: 0.05)
        XCTAssertLessThan(20 * log10(response(taps, hz: 12_000, rate: rate)), -60)
        XCTAssertLessThan(20 * log10(response(taps, hz: 60_000, rate: rate)), -70)
    }

    func testTapCountRules() {
        XCTAssertEqual(FIRDesign.tapCount(rate: 2_400_000, transitionHz: 200_000) % 2, 1)
        XCTAssertEqual(FIRDesign.tapCount(rate: 240_000, transitionHz: 10), FIRDesign.maxTaps)
        XCTAssertEqual(FIRDesign.tapCount(rate: 1000, transitionHz: 1000), 5)
    }

    func testDecimatorBlockwiseMatchesOneShot() {
        let rate = 48_000.0, d = 5
        let taps = FIRDesign.lowPass(cutoffHz: 3_000, rate: rate, transitionHz: 1_000)
        let total = 10_000
        let iq = DSPTest.complexTone(frequencyHz: 1_000, rate: rate, count: total)
        var re = [Float](repeating: 0, count: total), im = re
        for i in 0 ..< total { re[i] = iq[2 * i]; im[i] = iq[2 * i + 1] }

        let oneShot = FIRDecimator(taps: taps, decimation: d, maxBlock: total)
        var oRe = [Float](repeating: 0, count: total), oIm = oRe
        let nOne = oneShot.process(re: re, im: im, count: total, outRe: &oRe, outIm: &oIm)

        let blockwise = FIRDecimator(taps: taps, decimation: d, maxBlock: 1000)
        var bRe: [Float] = [], bIm: [Float] = []
        var tmpRe = [Float](repeating: 0, count: blockwise.maxOutput), tmpIm = tmpRe
        var i = 0
        let sizes = [7, 333, 1000, 1, 512, 999, 64] // odd sizes exercise the phase carry
        var k = 0
        while i < total {
            let n = min(sizes[k % sizes.count], total - i)
            let m = re.withUnsafeBufferPointer { rp in im.withUnsafeBufferPointer { ip in
                blockwise.process(re: rp.baseAddress! + i, im: ip.baseAddress! + i, count: n, outRe: &tmpRe, outIm: &tmpIm)
            } }
            bRe.append(contentsOf: tmpRe[0 ..< m]); bIm.append(contentsOf: tmpIm[0 ..< m])
            i += n; k += 1
        }
        XCTAssertEqual(bRe.count, nOne)
        XCTAssertEqual(nOne, (total - 1) / d + 1) // history is primed with taps−1 zeros
        for j in 0 ..< nOne {
            XCTAssertEqual(bRe[j], oRe[j], accuracy: 1e-4)
            XCTAssertEqual(bIm[j], oIm[j], accuracy: 1e-4)
        }
        // Passband tone survives with unity-ish gain at the decimated rate.
        var out = [Float](repeating: 0, count: nOne * 2)
        for j in 0 ..< nOne { out[2 * j] = oRe[j]; out[2 * j + 1] = oIm[j] }
        let real = (0 ..< nOne).map { oRe[$0] }
        let (snr, amp) = DSPTest.toneSNR(real, toneHz: 1_000, rate: rate / Double(d), skip: 100)
        XCTAssertGreaterThan(snr, 40)
        XCTAssertEqual(amp, 1, accuracy: 0.02)
    }

    func testRealDecimatorMatchesComplex() {
        let taps = FIRDesign.lowPass(cutoffHz: 100, rate: 1000, taps: 11)
        let x = (0 ..< 500).map { Float(sin(Double($0) * 0.05)) }
        let zeros = [Float](repeating: 0, count: 500)
        let c = FIRDecimator(taps: taps, decimation: 3, maxBlock: 500)
        let r = RealFIRDecimator(taps: taps, decimation: 3, maxBlock: 500)
        var cRe = [Float](repeating: 0, count: 200), cIm = cRe, rOut = cRe
        let n1 = c.process(re: x, im: zeros, count: 500, outRe: &cRe, outIm: &cIm)
        let n2 = r.process(x, count: 500, out: &rOut)
        XCTAssertEqual(n1, n2)
        for i in 0 ..< n1 { XCTAssertEqual(cRe[i], rOut[i], accuracy: 1e-6) }
    }

    func testNCOAccuracyAndContinuity() {
        let rate = 48_000.0
        let nco = NCO(rate: rate, frequencyHz: 1234.5, maxBlock: 1000)
        var cosOut = [Float](repeating: 0, count: 1000), sinOut = cosOut
        var idx = 0
        var maxErr: Float = 0
        for block in [1000, 3, 777, 1000, 250] {
            nco.fill(cosOut: &cosOut, sinOut: &sinOut, count: block)
            for k in 0 ..< block {
                let a = 2 * Double.pi * 1234.5 * Double(idx + k) / rate
                maxErr = max(maxErr, abs(cosOut[k] - Float(cos(a))), abs(sinOut[k] - Float(sin(a))))
            }
            idx += block
        }
        XCTAssertLessThan(maxErr, 1e-4)
        // Retune keeps phase continuous: the first sample after retune is exactly one *old* step past
        // the last emitted sample (the accumulator already advanced), and the new step applies after.
        nco.fill(cosOut: &cosOut, sinOut: &sinOut, count: 1)
        let last = (cosOut[0], sinOut[0])
        nco.retune(frequencyHz: -5000)
        nco.fill(cosOut: &cosOut, sinOut: &sinOut, count: 2)
        let oldStep = 2 * Double.pi * 1234.5 / rate, newStep = 2 * Double.pi * -5000 / rate
        let expectedPhase = atan2(Double(last.1), Double(last.0)) + oldStep
        XCTAssertEqual(Double(cosOut[1]), cos(expectedPhase + newStep), accuracy: 1e-4)
        XCTAssertEqual(Double(cosOut[0]), cos(expectedPhase), accuracy: 1e-4)
        XCTAssertEqual(Double(sinOut[0]), sin(expectedPhase), accuracy: 1e-4)
    }
}
