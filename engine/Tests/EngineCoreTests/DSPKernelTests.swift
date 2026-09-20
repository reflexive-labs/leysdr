// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import EngineCore

final class DSPKernelTests: XCTestCase {
    func testConversionsAndComplexOps() {
        let u8: [UInt8] = [0, 127, 128, 255]
        var f = [Float](repeating: 0, count: 4)
        PortableKernels.convertCU8(u8, to: &f, count: 4)
        XCTAssertEqual(f[0], -1, accuracy: 1e-6); XCTAssertEqual(f[3], 1, accuracy: 1e-6)
        XCTAssertEqual(f[1], -0.5 / 127.5, accuracy: 1e-6)
        let s16: [Int16] = [-32768, 0, 16384, 32767]
        PortableKernels.convertCS16(s16, to: &f, count: 4)
        XCTAssertEqual(f[0], -1); XCTAssertEqual(f[2], 0.5)
        var re: [Float] = [1, 0], im: [Float] = [0, 1]
        var oRe = [Float](repeating: 0, count: 2), oIm = oRe
        PortableKernels.complexMultiply(aRe: re, aIm: im, bRe: re, bIm: im, outRe: &oRe, outIm: &oIm, count: 2, conjugateB: true)
        XCTAssertEqual(oRe, [1, 1]); XCTAssertEqual(oIm, [0, 0])
        PortableKernels.complexMultiply(aRe: re, aIm: im, bRe: re, bIm: im, outRe: &oRe, outIm: &oIm, count: 2)
        XCTAssertEqual(oRe, [1, -1]); XCTAssertEqual(oIm, [0, 0])
        var inter = [Float](repeating: 0, count: 4)
        PortableKernels.interleave(re: re, im: im, to: &inter, count: 2)
        XCTAssertEqual(inter, [1, 0, 0, 1])
        re = [9, 9]; im = [9, 9]
        PortableKernels.deinterleave(inter, re: &re, im: &im, count: 2)
        XCTAssertEqual(re, [1, 0]); XCTAssertEqual(im, [0, 1])
        var db = [Float](repeating: 0, count: 3)
        PortableKernels.powerToDB([1, 0.001, 0], to: &db, count: 3)
        XCTAssertEqual(db[0], 0); XCTAssertEqual(db[1], -30, accuracy: 1e-3); XCTAssertEqual(db[2], -200)
        var w = [Float](repeating: 0, count: 8)
        PortableKernels.hannWindow(&w, count: 8)
        XCTAssertEqual(w[0], 0); XCTAssertEqual(w[4], 1, accuracy: 1e-6)
    }

    /// Documents invariant 4 for Instruments: run the whole per-block hot path many times. On macOS
    /// wrap this in the Allocations instrument; here it asserts the path runs and stays bounded.
    func testAllocationAuditHotPath() async throws {
        let block = 16384
        let ch = try Channelizer(captureRate: 2_400_000, offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm, maxBlock: block)
        let demod = DemodulatorFactory.make(mode: .nfm)
        try demod.configure(inputRate: ch.outputRate, bandwidthHz: 12_500)
        let ladder = DefaultSpectrumLadder()
        let sink = CollectingSpectrumSink()
        _ = await ladder.subscribe(bins: 1024, rowsPerSecond: 30, accumulation: .snapshot, policy: .latestWins, sink: sink)
        let iq = DSPTest.storage(DSPTest.fmTone(carrierHz: 100_000, audioHz: 1_000, deviationHz: 3_000, rate: 2_400_000, count: block))
        let chStore = SampleStorage(capacity: ch.maxOutput, format: .cf32)
        let outStore = SampleStorage(capacity: ch.maxOutput, format: .f32)
        var meter = PowerMeter()
        var squelch = Squelch(thresholdDB: -40)
        let cap = CaptureID()
        var frames = 0
        for i in 0 ..< 1000 {
            let t = SampleTime(captureID: cap, sampleIndex: UInt64(i * block))
            var chOut = chStore.view()
            let m = ch.process(input: iq.view(), output: &chOut)
            let power = meter.measure(chStore.view(count: m))
            squelch.update(powerDB: power)
            var out = outStore.view()
            frames += demod.process(iq: chStore.view(count: m), audioOut: &out)
            ladder.process(block: iq.view(), at: t, centerHz: 0, spanHz: 2_400_000)
        }
        XCTAssertEqual(frames, 1000 * block / 50) // decimation 50 overall, phase carried across blocks
        XCTAssertTrue(squelch.isOpen)
        XCTAssertGreaterThan(sink.rows.count, 100)
    }
}

#if canImport(Accelerate)
/// vDSP vs portable reference, tolerance 1e-4 (macOS only).
final class KernelParityTests: XCTestCase {
    let n = 1000

    private func vec(_ seed: Int) -> [Float] { (0 ..< n).map { Float(sin(Double($0 * seed) * 0.013 + Double(seed))) } }

    private func assertClose(_ a: [Float], _ b: [Float], _ tol: Float = 1e-4, _ label: String) {
        XCTAssertEqual(a.count, b.count, label)
        for i in a.indices where abs(a[i] - b[i]) > tol {
            XCTFail("\(label)[\(i)]: \(a[i]) vs \(b[i])"); return
        }
    }

    func testParity() {
        let re = vec(1), im = vec(2), b1 = vec(3), b2 = vec(4)
        var pRe = [Float](repeating: 0, count: n), pIm = pRe, aRe = pRe, aIm = pRe
        PortableKernels.complexMultiply(aRe: re, aIm: im, bRe: b1, bIm: b2, outRe: &pRe, outIm: &pIm, count: n, conjugateB: true)
        AccelerateKernels.complexMultiply(aRe: re, aIm: im, bRe: b1, bIm: b2, outRe: &aRe, outIm: &aIm, count: n, conjugateB: true)
        assertClose(pRe, aRe, 1e-4, "cmul conj re"); assertClose(pIm, aIm, 1e-4, "cmul conj im")
        PortableKernels.complexMultiply(aRe: re, aIm: im, bRe: b1, bIm: b2, outRe: &pRe, outIm: &pIm, count: n)
        AccelerateKernels.complexMultiply(aRe: re, aIm: im, bRe: b1, bIm: b2, outRe: &aRe, outIm: &aIm, count: n)
        assertClose(pRe, aRe, 1e-4, "cmul re"); assertClose(pIm, aIm, 1e-4, "cmul im")

        let taps = FIRDesign.lowPass(cutoffHz: 0.1, rate: 1, taps: 31)
        let outs = (n - 31) / 4 + 1
        PortableKernels.firDecimate(re: re, im: im, taps: taps, tapCount: 31, decimation: 4, outRe: &pRe, outIm: &pIm, outputCount: outs)
        AccelerateKernels.firDecimate(re: re, im: im, taps: taps, tapCount: 31, decimation: 4, outRe: &aRe, outIm: &aIm, outputCount: outs)
        assertClose(Array(pRe[0 ..< outs]), Array(aRe[0 ..< outs]), 1e-4, "firDecimate re")
        PortableKernels.firDecimateReal(re, taps: taps, tapCount: 31, decimation: 4, out: &pRe, outputCount: outs)
        AccelerateKernels.firDecimateReal(re, taps: taps, tapCount: 31, decimation: 4, out: &aRe, outputCount: outs)
        assertClose(Array(pRe[0 ..< outs]), Array(aRe[0 ..< outs]), 1e-4, "firDecimateReal")

        PortableKernels.magnitude(re: re, im: im, to: &pRe, count: n); AccelerateKernels.magnitude(re: re, im: im, to: &aRe, count: n)
        assertClose(pRe, aRe, 1e-4, "magnitude")
        PortableKernels.magnitudeSquared(re: re, im: im, to: &pRe, count: n); AccelerateKernels.magnitudeSquared(re: re, im: im, to: &aRe, count: n)
        assertClose(pRe, aRe, 1e-4, "magnitudeSquared")
        PortableKernels.atan2(y: im, x: re, to: &pRe, count: n); AccelerateKernels.atan2(y: im, x: re, to: &aRe, count: n)
        assertClose(pRe, aRe, 1e-4, "atan2")
        let phase = (0 ..< n).map { Float($0) * 0.01 }
        PortableKernels.sincos(phase: phase, sinOut: &pRe, cosOut: &pIm, count: n); AccelerateKernels.sincos(phase: phase, sinOut: &aRe, cosOut: &aIm, count: n)
        assertClose(pRe, aRe, 1e-4, "sin"); assertClose(pIm, aIm, 1e-4, "cos")
        let power = re.map { $0 * $0 + 1e-3 }
        PortableKernels.powerToDB(power, to: &pRe, count: n); AccelerateKernels.powerToDB(power, to: &aRe, count: n)
        assertClose(pRe, aRe, 1e-3, "powerToDB")
        PortableKernels.hannWindow(&pRe, count: n); AccelerateKernels.hannWindow(&aRe, count: n)
        assertClose(pRe, aRe, 1e-4, "hann")
        XCTAssertEqual(PortableKernels.mean(re, count: n), AccelerateKernels.mean(re, count: n), accuracy: 1e-4)
        XCTAssertEqual(PortableKernels.meanSquare(re, count: n), AccelerateKernels.meanSquare(re, count: n), accuracy: 1e-4)
        XCTAssertEqual(PortableKernels.maxMagnitude(re, count: n), AccelerateKernels.maxMagnitude(re, count: n), accuracy: 1e-4)
        // A new kernel added here but not exercised above can reference a symbol that doesn't
        // exist on Darwin without anyone noticing, since this container never compiles Accelerate;
        // parity coverage is the only check for that.
        let db = re.map { $0 * 10 - 40 }
        PortableKernels.dbToPower(db, to: &pRe, count: n)
        AccelerateKernels.dbToPower(db, to: &aRe, count: n)
        assertClose(pRe, aRe, 1e-3, "dbToPower")
        // powerToDB is its inverse; the round trip pins the scaling rather than just the agreement.
        PortableKernels.powerToDB(pRe, to: &pIm, count: n)
        assertClose(Array(pIm[0 ..< n]), Array(db[0 ..< n]), 1e-2, "dbToPower round trip")
        var pMax = re, aMax = re
        let other = re.map { -$0 }
        PortableKernels.maxInPlace(&pMax, other, count: n)
        AccelerateKernels.maxInPlace(&aMax, other, count: n)
        assertClose(pMax, aMax, 1e-4, "maxInPlace")
        XCTAssertEqual(PortableKernels.max(re, count: n), AccelerateKernels.max(re, count: n), accuracy: 1e-6)
        XCTAssertEqual(PortableKernels.min(re, count: n), AccelerateKernels.min(re, count: n), accuracy: 1e-6)
        PortableKernels.scaleAdd(re, scale: 2.5, offset: -0.25, to: &pRe, count: n); AccelerateKernels.scaleAdd(re, scale: 2.5, offset: -0.25, to: &aRe, count: n)
        assertClose(pRe, aRe, 1e-4, "scaleAdd")
        PortableKernels.multiply(re, im, to: &pRe, count: n); AccelerateKernels.multiply(re, im, to: &aRe, count: n)
        assertClose(pRe, aRe, 1e-5, "multiply")
        PortableKernels.add(re, im, to: &pRe, count: n); AccelerateKernels.add(re, im, to: &aRe, count: n)
        assertClose(pRe, aRe, 1e-5, "add")
        PortableKernels.clip(re, lo: -0.3, hi: 0.4, to: &pRe, count: n); AccelerateKernels.clip(re, lo: -0.3, hi: 0.4, to: &aRe, count: n)
        assertClose(pRe, aRe, 0, "clip")
        let u8 = (0 ..< n).map { UInt8($0 % 256) }, s16 = (0 ..< n).map { Int16(truncatingIfNeeded: $0 * 37) }, s8 = (0 ..< n).map { Int8(truncatingIfNeeded: $0) }
        PortableKernels.convertCU8(u8, to: &pRe, count: n); AccelerateKernels.convertCU8(u8, to: &aRe, count: n); assertClose(pRe, aRe, 1e-5, "cu8")
        PortableKernels.convertCS16(s16, to: &pRe, count: n); AccelerateKernels.convertCS16(s16, to: &aRe, count: n); assertClose(pRe, aRe, 1e-5, "cs16")
        PortableKernels.convertCS8(s8, to: &pRe, count: n); AccelerateKernels.convertCS8(s8, to: &aRe, count: n); assertClose(pRe, aRe, 1e-5, "cs8")
        // The rail counts are the portable loop on both platforms; the lines exist so a forwarder
        // that names a symbol wrongly fails here rather than on the Mac's first build.
        let railsU8 = (PortableKernels.countAtRailsCU8(u8, count: n), AccelerateKernels.countAtRailsCU8(u8, count: n))
        XCTAssertEqual(railsU8.0.clipped, railsU8.1.clipped, "countAtRailsCU8"); XCTAssertEqual(railsU8.0.peak, railsU8.1.peak, "countAtRailsCU8 peak")
        let railsS16 = (PortableKernels.countAtRailsCS16(s16, count: n), AccelerateKernels.countAtRailsCS16(s16, count: n))
        XCTAssertEqual(railsS16.0.clipped, railsS16.1.clipped, "countAtRailsCS16"); XCTAssertEqual(railsS16.0.peak, railsS16.1.peak, "countAtRailsCS16 peak")
        let railsS8 = (PortableKernels.countAtRailsCS8(s8, count: n), AccelerateKernels.countAtRailsCS8(s8, count: n))
        XCTAssertEqual(railsS8.0.clipped, railsS8.1.clipped, "countAtRailsCS8"); XCTAssertEqual(railsS8.0.peak, railsS8.1.peak, "countAtRailsCS8 peak")
        let railsF32 = (PortableKernels.countAtRailsCF32(re, count: n), AccelerateKernels.countAtRailsCF32(re, count: n))
        XCTAssertEqual(railsF32.0.clipped, railsF32.1.clipped, "countAtRailsCF32"); XCTAssertEqual(railsF32.0.peak, railsF32.1.peak, "countAtRailsCF32 peak")
        let inter = (0 ..< 2 * n).map { Float($0) }
        PortableKernels.deinterleave(inter, re: &pRe, im: &pIm, count: n); AccelerateKernels.deinterleave(inter, re: &aRe, im: &aIm, count: n)
        assertClose(pRe, aRe, 0, "deinterleave re"); assertClose(pIm, aIm, 0, "deinterleave im")
        var pInter = [Float](repeating: 0, count: 2 * n), aInter = pInter
        PortableKernels.interleave(re: re, im: im, to: &pInter, count: n); AccelerateKernels.interleave(re: re, im: im, to: &aInter, count: n)
        assertClose(pInter, aInter, 0, "interleave")
    }
}
#endif
