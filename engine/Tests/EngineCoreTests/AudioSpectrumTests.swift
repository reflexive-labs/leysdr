import Foundation
import XCTest
@testable import EngineCore

/// Collects the rows an `AudioSpectrumSink` produces.
final class SpectrumCollector: SpectrumSink, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[Float]] = []

    func write(row: UnsafeBufferPointer<Float>, at _: SampleTime, centerHz _: UInt64, spanHz _: UInt64, looks _: Int) {
        let copy = Array(row)
        lock.lock(); rows.append(copy); lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return rows.count }
    var all: [[Float]] { lock.lock(); defer { lock.unlock() }; return rows }

    /// Power mean of every row collected, back in dB: the rows are independent looks at the same
    /// tones, and averaging them puts the noise between the peaks where it belongs.
    var meanDB: [Double] {
        let rows = all
        guard let bins = rows.first?.count else { return [] }
        var acc = [Double](repeating: 0, count: bins)
        for row in rows {
            for i in 0 ..< bins { acc[i] += pow(10, Double(row[i]) / 10) }
        }
        return acc.map { 10 * log10(Swift.max($0 / Double(rows.count), 1e-30)) }
    }
}

/// The two largest local maxima of a row above `minHz`, loudest first, as (frequency, dB).
private func peaks(_ row: [Double], rate: Double, minHz: Double = 50) -> [(hz: Double, db: Double)] {
    let binHz = rate / 2 / Double(row.count)
    var found: [(hz: Double, db: Double)] = []
    for i in 1 ..< row.count - 1 where Double(i) * binHz >= minHz {
        if row[i] >= row[i - 1], row[i] > row[i + 1] { found.append((Double(i) * binHz, row[i])) }
    }
    return Array(found.sorted { $0.db > $1.db }.prefix(2))
}

final class AudioSpectrumTests: XCTestCase {
    /// The scale the design rests on: a full-scale sine reads about 0 dBFS at its own bin, so a
    /// level meter built on these rows can print dBFS without a calibration of its own.
    func testFullScaleSineReadsZeroDBFS() throws {
        let rate: UInt32 = 48000
        let bins = 1024
        let collector = SpectrumCollector()
        let spectrum = AudioSpectrumSink(tap: .audio, bins: bins, rowsPerSecond: 20,
                                         audioRate: rate, sink: collector)
        // On a bin centre, where the window's scalloping loss is zero: half a bin off it costs
        // 1.4 dB, and this asserts the scale rather than the shape of the window.
        let binHz = Double(rate) / Double(2 * bins)
        let toneHz = 43 * binHz
        var block = [Float](repeating: 0, count: 9600)
        for i in 0 ..< block.count { block[i] = Float(sin(2 * Double.pi * toneHz * Double(i) / Double(rate))) }
        block.withUnsafeMutableBufferPointer { buf in
            let time = SampleTime(captureID: CaptureID(), sampleIndex: 0)
            spectrum.write(SampleBuffer(base: UnsafeMutableRawPointer(buf.baseAddress!), count: buf.count, format: .f32), at: time)
        }
        XCTAssertGreaterThan(collector.count, 0, "9600 samples at 20 rows a second is four rows")
        let row = collector.meanDB
        XCTAssertEqual(row.count, bins)
        let top = try XCTUnwrap(peaks(row, rate: Double(rate)).first)
        XCTAssertEqual(top.hz, toneHz, accuracy: binHz, "peak at \(top.hz) Hz, tone at \(toneHz) Hz")
        XCTAssertEqual(top.db, 0, accuracy: 0.5, "full scale reads \(top.db) dBFS")
    }

    /// Both taps of one fixture channel, as spectra: the same air through the same window, so the
    /// only difference between the two is the conditioning between them.
    private func run(fixture name: String, bins: Int = 1024, rows: Int = 8)
        async throws -> (audio: [Double], demod: [Double], rate: Double)
    {
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
        let listener = SpectrumCollector()
        let scope = SpectrumCollector()
        let rate = channel.audioRate
        try await channel.attach(AudioSpectrumSink(tap: .audio, bins: bins, rowsPerSecond: 20, audioRate: rate, sink: listener))
        try await channel.attach(AudioSpectrumSink(tap: .demod, bins: bins, rowsPerSecond: 20, audioRate: rate, sink: scope))
        try await capture.start()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, listener.count < rows || scope.count < rows {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await capture.stop()
        guard listener.count >= rows, scope.count >= rows else {
            XCTFail("both taps must produce rows: \(scope.count) demod and \(listener.count) audio of \(rows)")
            throw XCTSkip("no rows")
        }
        return (listener.meanDB, scope.meanDB, Double(rate))
    }

    /// The CTCSS tone is a peak on the discriminator beside the voice tone, and the audio tap's
    /// 300 Hz high-pass has taken it away: the pair of spectra says which tap a meter is reading.
    func testNFMTapsDifferBelowTheHighPass() async throws {
        let (audio, demod, rate) = try await run(fixture: "nfm_pl.cf32")
        let binHz = rate / 2 / Double(demod.count)
        let two = peaks(demod, rate: rate).map(\.hz).sorted()
        XCTAssertEqual(two.count, 2, "the demod tap carries the PL and the voice tone")
        XCTAssertEqual(two.first ?? 0, 100, accuracy: binHz, "PL at \(two.first ?? 0) Hz")
        XCTAssertEqual(two.last ?? 0, 1000, accuracy: binHz, "voice tone at \(two.last ?? 0) Hz")
        let heard = try XCTUnwrap(peaks(audio, rate: rate).first)
        XCTAssertEqual(heard.hz, 1000, accuracy: binHz, "the listener's loudest is \(heard.hz) Hz")
        let pl = Int((100 / binHz).rounded())
        XCTAssertLessThan(audio[pl], demod[pl] - 12,
                          "100 Hz reads \(audio[pl]) dB on the audio tap against \(demod[pl]) dB on the demod tap")
    }

    /// The AM fixture's tone lands on its own bin, which is the whole claim a level meter makes.
    func testAMToneLandsOnItsBin() async throws {
        let (audio, _, rate) = try await run(fixture: "am_tone.cf32")
        let binHz = rate / 2 / Double(audio.count)
        let top = try XCTUnwrap(peaks(audio, rate: rate).first)
        XCTAssertEqual(top.hz, 1000, accuracy: binHz, "AM tone at \(top.hz) Hz")
    }
}
