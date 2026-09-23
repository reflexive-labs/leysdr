// SPDX-License-Identifier: GPL-3.0-or-later

// The sub-audible detector against recordings of real radios: the handheld with a 100 Hz PL that
// the detector must keep identifying, and NOAA weather radio, which transmits no CTCSS and whose
// synthesised announcer once read as one (docs/plans/signal-views.md, SV-13). The captures are
// large and gitignored, so these tests run only where `LEYLINE_CAPTURES` names the directory that
// holds them; the committed test input is the 1 kHz tap the same code writes beside them.

import Foundation
import XCTest
@testable import EngineCore

final class SubAudibleCaptureTests: XCTestCase {
    /// One hop of the detector, as a human-readable row.
    struct Hop {
        let second: Double
        let result: SubAudibleResult
    }

    /// Runs a capture through the channel path a tuned NFM channel takes -- channelizer at the
    /// capture's centre, 12.5 kHz NFM, the sub-audible tap -- and returns the tap at its rate.
    static func tap(of path: String) throws -> (samples: [Float], rate: Double, fullScale: Double) {
        let reader = try IQFileReader(path: path, maxBlock: 16384)
        let rate = UInt64(reader.sidecar.sampleRate)
        let ch = try Channelizer(captureRate: rate, offsetHz: 0, bandwidthHz: 12_500, mode: .nfm, maxBlock: 16384)
        let demod = NFMDemodulator()
        try demod.configure(inputRate: ch.outputRate, bandwidthHz: 12_500)
        let ring = FloatRing(capacity: 1 << 16)
        demod.subAudibleTap = ring
        let inStore = SampleStorage(capacity: 16384, format: .cf32)
        let chStore = SampleStorage(capacity: ch.maxOutput, format: .cf32)
        let outStore = SampleStorage(capacity: ch.maxOutput, format: .f32)
        var tapped: [Float] = []
        var scratch = [Float](repeating: 0, count: 1 << 16)
        while true {
            let n = try reader.read(into: inStore.view())
            if n == 0 { break }
            var chOut = chStore.view()
            let m = ch.process(input: inStore.view(count: n), output: &chOut)
            var out = outStore.view()
            _ = demod.process(iq: chStore.view(count: m), audioOut: &out)
            let got = scratch.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
            tapped.append(contentsOf: scratch[0 ..< got])
        }
        return (tapped, demod.subAudibleRate, demod.fullScaleDeviationHz)
    }

    /// Every hop of the detector over a tap.
    static func hops(over tap: [Float], rate: Double, fullScale: Double) -> [Hop] {
        let det = SubAudibleDetector(rate: rate, windowSize: 512, hop: 128)
        var out: [Hop] = []
        var off = 0
        while off + 512 <= tap.count {
            let r = det.analyse(Array(tap[off ..< off + 512]), fullScaleDeviationHz: fullScale)
            out.append(Hop(second: Double(off + 512) / rate, result: r))
            off += 128
        }
        return out
    }

    private func capturesDir() throws -> String {
        guard let dir = ProcessInfo.processInfo.environment["LEYLINE_CAPTURES"], !dir.isEmpty else {
            throw XCTSkip("set LEYLINE_CAPTURES to the directory holding the real-radio captures")
        }
        return dir
    }

    private func capture(_ name: String) throws -> String {
        let path = try capturesDir() + "/" + name
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no capture at \(path)") }
        return path
    }

    // MARK: The committed taps

    /// The taps kept under Tests/EngineCoreTests/Captures: the detector's own input, 48 KB a
    /// capture, so the test runs where the captures are not available. Each is the 1 kHz tap the
    /// code above writes, float32 little-endian, full scale 2500 Hz (12.5 kHz NFM).
    static let tapRate = 1000.0
    static let tapFullScale = 2500.0

    static func committedTap(_ name: String) throws -> [Float] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "f32", subdirectory: "Captures") else {
            throw XCTSkip("no committed tap \(name).f32")
        }
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(start: raw.baseAddress!.assumingMemoryBound(to: Float.self), count: data.count / 4))
        }
    }

    /// NOAA weather radio transmits no CTCSS. Its synthesised announcer's pitch fundamental sits
    /// in the 60-260 Hz band and, over three hops, held steady enough to be classified as a tone
    /// (233.6 Hz, then 241.8) on the owner's radio on 2026-09-14; the capture is that broadcast at
    /// gain auto. The detector must report no tone on it, on any hop.
    func testNOAAAnnouncerIsNotATone() throws {
        let tap = try Self.committedTap("noaa-wx2-auto")
        let claimed = Self.hops(over: tap, rate: Self.tapRate, fullScale: Self.tapFullScale).filter(\.result.detected)
        XCTAssertTrue(claimed.isEmpty, "the announcer was named a tone on \(claimed.count) hops: "
            + claimed.prefix(5).map { String(format: "%.1fs %.1f Hz", $0.second, $0.result.standardToneHz) }.joined(separator: ", "))
    }

    /// The counterpart: the handheld's real 100 Hz PL, with speech on top, is still classified,
    /// and only as 100.0. Over three hops it was classified on 48 of 75 hops and once as 110.9;
    /// the one-second horizon loses the first hops of each key-up and nothing else.
    func testHandheldPLIsStillNamed() throws {
        let tap = try Self.committedTap("ht-narrow")
        let hops = Self.hops(over: tap, rate: Self.tapRate, fullScale: Self.tapFullScale)
        let claimed = hops.filter(\.result.detected)
        XCTAssertGreaterThanOrEqual(claimed.count, 35, "the PL was named on only \(claimed.count) of \(hops.count) hops")
        let tones = Set(claimed.map(\.result.standardToneHz))
        XCTAssertEqual(tones, [100.0], "the handheld's PL was classified as \(tones.sorted())")
    }

    /// Writes the committed taps from the captures: LEYLINE_CAPTURE_WRITE_TAPS names the output
    /// directory. Run it when a capture is added or the channel path changes what the tap sees.
    func testWriteTaps() throws {
        guard let outDir = ProcessInfo.processInfo.environment["LEYLINE_CAPTURE_WRITE_TAPS"], !outDir.isEmpty else {
            throw XCTSkip("set LEYLINE_CAPTURE_WRITE_TAPS to a directory to write the taps")
        }
        for name in ["noaa-wx2-auto.cu8", "ht-narrow.cu8"] {
            let t = try Self.tap(of: try capture(name))
            XCTAssertEqual(t.rate, Self.tapRate, "\(name): the tap rate moved; the committed taps assume \(Self.tapRate)")
            XCTAssertEqual(t.fullScale, Self.tapFullScale)
            let data = t.samples.withUnsafeBufferPointer { Data(buffer: $0) }
            let stem = String(name.split(separator: ".")[0])
            try data.write(to: URL(fileURLWithPath: outDir + "/" + stem + ".f32"))
        }
    }

    /// Prints the per-hop numbers for every capture named in LEYLINE_CAPTURE_DUMP (comma
    /// separated), so a threshold is chosen from a measurement rather than a guess.
    func testDumpHops() throws {
        guard let names = ProcessInfo.processInfo.environment["LEYLINE_CAPTURE_DUMP"], !names.isEmpty else {
            throw XCTSkip("set LEYLINE_CAPTURE_DUMP=a.cu8,b.cf32 to print the detector's hops")
        }
        for name in names.split(separator: ",") {
            let path = try capture(String(name))
            let t = try Self.tap(of: path)
            var lines = ["# \(name): tap \(t.rate) Hz, full scale \(t.fullScale) Hz, \(t.samples.count) samples"]
            lines.append("sec,measuredHz,standardHz,deviationHz,snrDB,detected,reason")
            for h in Self.hops(over: t.samples, rate: t.rate, fullScale: t.fullScale) {
                let r = h.result
                lines.append(String(format: "%.2f,%.2f,%.1f,%.0f,%.1f,%d,%@", h.second, r.toneHz, r.standardToneHz,
                                    r.deviationHz, r.toneSNRDB, r.detected ? 1 : 0, r.reason))
            }
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }
}
