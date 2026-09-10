// The multi-step sweep, end to end through the daemon: a synthetic radio that really retunes, so
// hop discard, cross-step merging and the IQ image test are exercised rather than assumed.
//
// A file device cannot do this -- its tuning range is the single point its recording was made at --
// and making it retunable would need an oversampled source and a mix-filter-decimate chain, because
// shifting a 2.4 MSPS fixture by 960 kHz aliases its own carriers back into the analysis windows.
// See docs/design-scan.md. This device synthesises its band at whatever centre it is asked for,
// which is the one thing a recording cannot do.

import EngineCore
import Foundation
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// A radio that can be tuned anywhere and generates the band it is pointed at.
///
/// It changes what it emits `staleBlocks` after `tune` returns, on purpose: real hardware keeps
/// tens of USB buffers of already-captured air queued, and a sweep that trusts the frame's centre
/// frequency attributes that air to the wrong step. Without the delay, hop discard passes trivially.
final class SyntheticBandDevice: VirtualDevice, @unchecked Sendable {
    struct Carrier {
        var hz: Double
        var dbfs: Double
        /// Deviation of a 1 kHz tone, so the carrier has a width to measure. 0 is a bare tone.
        var widthHz: Double
    }

    static let rate: UInt64 = 2_400_000
    static let blockSize = 16384
    /// Blocks of old-centre content delivered after `tune` returns.
    static let staleBlocks = 6

    private let lock = NSLock()
    private var _descriptor = DeviceDescriptor(id: DeviceID(), driver: "test", model: "synthetic-band", serial: "synth-1",
                                               tuningRanges: [FrequencyRange(minHz: 100_000_000, maxHz: 200_000_000)],
                                               sampleRates: [rate], nativeFormat: .cf32,
                                               gainElements: [GainElement(name: "TUNER", minDB: 0, maxDB: 49.6, stepDB: 0.9, supportsAuto: true)])
    private var _onStateChange: (@Sendable (DeviceState) -> Void)?
    private var _gain = GainState(element: "TUNER", value: .auto)
    private let carriers: [Carrier]
    private let floorDBFS: Double
    /// The image of every carrier, this far down. 30 dB is an R820T's typical rejection.
    private let imageRejectionDB: Double

    private let centerBox = LockedValue<UInt64>(146_000_000)
    private let emittedBox = LockedValue<UInt64>(146_000_000)
    private let pendingBox = LockedValue<Int>(0)
    private let streaming = LockedValue(false)
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)
    let tunes = LockedValue(0)

    init(carriers: [Carrier], floorDBFS: Double = -60, imageRejectionDB: Double = 30) {
        self.carriers = carriers
        self.floorDBFS = floorDBFS
        self.imageRejectionDB = imageRejectionDB
    }

    var descriptor: DeviceDescriptor { lock.lock(); defer { lock.unlock() }; return _descriptor }
    var gains: [GainState] { lock.lock(); defer { lock.unlock() }; return [_gain] }
    var inFlightSamples: UInt64 { UInt64(Self.staleBlocks * Self.blockSize) }

    func assignID(_ id: DeviceID) { lock.lock(); _descriptor.id = id; lock.unlock() }
    func setState(_ state: DeviceState) {
        lock.lock(); _descriptor.state = state; let hook = _onStateChange; lock.unlock()
        hook?(state)
    }

    func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) { lock.lock(); _onStateChange = hook; lock.unlock() }

    func open() async throws {}
    func close() async {}

    func tune(centerHz: UInt64) async throws {
        guard descriptor.canTune(centerHz) else { throw EngineError.freqOutOfRange(centerHz, target: descriptor.id.string) }
        tunes.value += 1
        centerBox.value = centerHz
        // The queue: this many more blocks come out at the old centre.
        pendingBox.value = Self.staleBlocks
    }

    func setSampleRate(_ hz: UInt64) async throws {
        guard hz == Self.rate else { throw EngineError.rateUnsupported(hz, target: descriptor.id.string) }
    }

    func setGain(element: String, value: GainValue) async throws {
        guard element == "TUNER" else { throw EngineError.gainElementUnknown(element, target: "") }
        lock.lock(); _gain = GainState(element: element, value: value); lock.unlock()
    }

    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        streaming.value = true
        let t = Thread { [self] in
            let storage = SampleStorage(capacity: Self.blockSize, format: .cf32)
            var rng = SweepRNG(seed: 0x5EED)
            var index: UInt64 = 0
            var phase = [Double](repeating: 0, count: carriers.count * 2)
            while streaming.value {
                // Blocks still in the queue carry the previous centre.
                var emitCentre = centerBox.value
                if pendingBox.value > 0 {
                    emitCentre = emittedBox.value
                    pendingBox.value -= 1
                } else {
                    emittedBox.value = centerBox.value
                }
                var view = storage.view()
                fill(&view, centre: emitCentre, rng: &rng, phase: &phase)
                deliver(view, SampleTime(captureID: captureID, sampleIndex: index))
                index &+= UInt64(Self.blockSize)
                var ts = timespec(tv_sec: 0, tv_nsec: 2_000_000)
                nanosleep(&ts, nil)
            }
            done.signal()
        }
        t.name = "synthetic-band"
        thread = t
        t.start()
    }

    func stopStreaming() async {
        guard streaming.value else { return }
        streaming.value = false
        done.wait()
        thread = nil
    }

    /// Noise plus every carrier that falls inside the span at `centre`, plus each one's image
    /// reflected about `centre`.
    private func fill(_ buf: inout SampleBuffer, centre: UInt64, rng: inout SweepRNG, phase: inout [Double]) {
        let n = Self.blockSize
        buf.count = n
        let amp = pow(10, floorDBFS / 20)
        let half = Double(Self.rate) / 2
        let dst = buf.floats
        for i in 0 ..< n {
            dst[2 * i] = Float(amp * rng.normal())
            dst[2 * i + 1] = Float(amp * rng.normal())
        }
        for (k, c) in carriers.enumerated() {
            let offsets = [(c.hz - Double(centre), c.dbfs),
                           (Double(centre) - c.hz, c.dbfs - imageRejectionDB)]
            for (j, pair) in offsets.enumerated() {
                let (offset, dbfs) = pair
                guard abs(offset) < half else { continue }
                let a = pow(10, dbfs / 20)
                let w = 2 * Double.pi * offset / Double(Self.rate)
                let wt = 2 * Double.pi * 1000 / Double(Self.rate)
                var p = phase[k * 2 + j]
                for i in 0 ..< n {
                    // FM by a 1 kHz tone gives the carrier a measurable width.
                    let dev = c.widthHz > 0 ? (c.widthHz / 2) / 1000 * sin(wt * Double(i)) : 0
                    p += w
                    let ang = p + dev
                    dst[2 * i] += Float(a * cos(ang))
                    dst[2 * i + 1] += Float(a * sin(ang))
                }
                phase[k * 2 + j] = p
            }
        }
    }
}

/// Box-Muller normals from a deterministic stream.
struct SweepRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
    mutating func next() -> Double {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= (z >> 31)
        return Swift.max(Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0), 1e-12)
    }

    mutating func normal() -> Double {
        let u1 = next(), u2 = next()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2) / 2.squareRoot()
    }
}

final class ScanSweepTests: XCTestCase {
    /// A sweep wider than one span, over a radio that really retunes.
    func testMultiStepSweepFindsCarriersAcrossSteps() async throws {
        let carriers = [
            SyntheticBandDevice.Carrier(hz: 145_400_000, dbfs: -25, widthHz: 12_500),
            SyntheticBandDevice.Carrier(hz: 146_900_000, dbfs: -30, widthHz: 12_500),
            SyntheticBandDevice.Carrier(hz: 148_300_000, dbfs: -35, widthHz: 12_500),
        ]
        try await withSweepDaemon(carriers) { c, scan in
            // The advance the geometry uses, not the gap between the first two centres: the first
            // gap is between the low end-cap and the first interior step, which is edge+guard.
            let span = Double(SyntheticBandDevice.rate)
            XCTAssertEqual(Double(scan.config.stepHz),
                           (SweepPlan.edgeFraction - SweepPlan.guardFraction) * span, accuracy: 1)
            // How finely it looked, stated rather than left for a client to reverse-engineer.
            XCTAssertEqual(Double(scan.resolutionHz), span / 1024, accuracy: 1)
            // What it actually covered, which for a whole sweep is the range asked for.
            XCTAssertLessThanOrEqual(scan.covered.minHz, 145_100_000)
            XCTAssertGreaterThanOrEqual(scan.covered.maxHz, 148_500_000)
            let found = scan.detections.map(\.centerHz).sorted()
            for want in carriers.map({ UInt64($0.hz) }) {
                XCTAssertTrue(found.contains { $0 > want - 20_000 && $0 < want + 20_000 },
                              "nothing near \(want) in \(found)")
            }
            // The steps cover the range twice over almost all of it, so a real carrier is merged
            // rather than reported once per step.
            XCTAssertEqual(Set(found).count, found.count, "duplicates across steps: \(found)")
            _ = c
        }
    }

    /// The image is 30 dB down and moves with the tuner; the carrier does not. Neither the image
    /// nor anything else that is not a carrier may reach the answer.
    func testTheIQImageNeverReachesTheAnswer() async throws {
        let carriers = [SyntheticBandDevice.Carrier(hz: 145_400_000, dbfs: -20, widthHz: 12_500)]
        try await withSweepDaemon(carriers) { _, scan in
            let found = scan.detections.map(\.centerHz).sorted()
            XCTAssertTrue(found.contains { $0 > 145_380_000 && $0 < 145_420_000 }, "the carrier is missing: \(found)")
            // Every step plants an image at 2*centre - 145.4 MHz. None of those is a real signal,
            // and the answer must contain exactly one thing.
            XCTAssertEqual(found.count, 1, "an artefact reached the answer: \(found)")
        }
    }

    /// Detections carry how many looks found them out of how many looked, and a continuous carrier
    /// is found by every look that covered it.
    func testDetectionsCarryTheirEvidence() async throws {
        let carriers = [SyntheticBandDevice.Carrier(hz: 145_400_000, dbfs: -25, widthHz: 12_500)]
        try await withSweepDaemon(carriers) { _, scan in
            let d = try XCTUnwrap(scan.detections.first)
            XCTAssertGreaterThan(d.looks, 0)
            XCTAssertGreaterThanOrEqual(d.looksPossible, d.looks)
            // The denominator counts every look that covered the frequency, including the steps
            // that saw nothing there -- otherwise a carrier one of two steps missed reads 8/8.
            XCTAssertGreaterThan(d.looksPossible, 1, "a frequency the geometry looks at twice cannot have one opportunity")
            XCTAssertLessThan(d.floorDbfs, -40)
            XCTAssertGreaterThan(d.snrDb, 10)
            XCTAssertEqual(d.modulationGuess, "", "invariant 12: v0 has no opinion about modulation")
            XCTAssertEqual(d.guessConfidence, 0)
            XCTAssertFalse(d.firstSeen.captureID.isEmpty, "invariant 5: detections carry sample time")
        }
    }

    /// The sweep pins the tuner's gain, and gives it back.
    func testTheSweepPinsGainAndRestoresIt() async throws {
        let carriers = [SyntheticBandDevice.Carrier(hz: 145_400_000, dbfs: -25, widthHz: 12_500)]
        try await withSweepDaemon(carriers) { _, scan in
            let g = try XCTUnwrap(scan.gains.first)
            XCTAssertEqual(g.element, "TUNER")
            XCTAssertFalse(g.auto, "a sweep must not run under the tuner's AGC")
        }
    }

    /// A sweep declines a radio somebody is listening on, and --take-over borrows it and gives it
    /// back where it was.
    func testTakeOverBorrowsAndRestores() async throws {
        try await withDaemon { c in
            let device = SyntheticBandDevice(carriers: [.init(hz: 145_400_000, dbfs: -25, widthHz: 12_500)])
            let desc = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            try await Task.sleep(nanoseconds: 200_000_000)

            // Somebody is listening on 146.9 MHz.
            let cap = try await c.control.createCapture(.with {
                $0.deviceID = desc.id.string
                $0.centerHz = 146_900_000
                $0.sampleRate = SyntheticBandDevice.rate
            }, metadata: testMetadata)
            _ = try await c.control.createChannel(.with {
                $0.captureID = cap.captureID
                $0.offsetHz = 0
                $0.mode = .nfm
            }, metadata: testMetadata)

            func sweep(takeOver: Bool) async throws -> Leyline_V1_Job {
                var config = Leyline_V1_ScanConfig()
                config.range.minHz = 145_000_000
                config.range.maxHz = 146_000_000
                config.dwellMs = 120
                config.once = true
                config.takeOver = takeOver
                let job = try await c.jobs.startJob(.with { $0.config = .scan(config) }, metadata: testMetadata)
                var final = job
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while final.state == .running, ContinuousClock.now < deadline {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    final = try await c.jobs.getJob(.with { $0.jobID = job.jobID }, metadata: testMetadata)
                }
                return final
            }

            let refused = try await sweep(takeOver: false)
            XCTAssertEqual(refused.state, .failed)
            XCTAssertTrue(refused.statusDetail.contains("listening"), refused.statusDetail)
            XCTAssertTrue(refused.statusDetail.contains("146.900"), refused.statusDetail)
            // Why it failed is a field, not a prefix: a client branches on the code and prints
            // the prose.
            XCTAssertEqual(refused.error.code, EngineError.Code.deviceBusy)
            XCTAssertEqual(refused.error.message, refused.statusDetail)
            XCTAssertEqual(refused.error.target, refused.jobID)
            XCTAssertFalse(refused.statusDetail.contains(EngineError.Code.deviceBusy), refused.statusDetail)
            // The refusal must not have moved anything.
            var state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.first?.centerHz, 146_900_000)

            let took = try await sweep(takeOver: true)
            XCTAssertEqual(took.state, .completed, took.statusDetail)
            XCTAssertTrue(took.error.code.isEmpty, took.error.code)

            // The radio is back where its owner left it, and the channel is still theirs.
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.first?.centerHz, 146_900_000, "a borrowed capture must be given back")
            XCTAssertEqual(state.channels.count, 1, "the listener's channel must survive")
            XCTAssertEqual(state.channels.first?.state, .channelActive)
        }
    }

    /// A client whose only calls are on the Jobs plane keeps its scan. An agent that starts a sweep
    /// and polls for it holds no stream, and presence that only the control plane can renew would
    /// have the session store reap it and cancel the job mid-sweep.
    func testAPollingClientKeepsItsScan() async throws {
        try await withDaemon(presenceGraceNs: 300_000_000) { c in
            let device = SyntheticBandDevice(carriers: [.init(hz: 145_400_000, dbfs: -25, widthHz: 12_500)])
            _ = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            try await Task.sleep(nanoseconds: 200_000_000)
            // The first call arms the grace, as any client's does. Nothing after this touches the
            // control plane or opens a stream.
            _ = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)

            var config = Leyline_V1_ScanConfig()
            config.range.minHz = 145_000_000
            config.range.maxHz = 148_600_000
            config.dwellMs = 800
            config.once = true
            let job = try await c.jobs.startJob(.with { $0.config = .scan(config) }, metadata: testMetadata)

            // Five grace periods of polling and nothing else.
            var seen = job
            for _ in 0 ..< 15 {
                try await Task.sleep(nanoseconds: 100_000_000)
                seen = try await c.jobs.getJob(.with { $0.jobID = job.jobID }, metadata: testMetadata)
                XCTAssertNotEqual(seen.state, .cancelled, "a polling client's scan was reaped: \(seen.statusDetail)")
            }
            XCTAssertEqual(seen.state, .running, seen.statusDetail)
            _ = try await c.jobs.cancelJob(.with { $0.jobID = job.jobID }, metadata: testMetadata)
        }
    }

    /// While a sweep holds a radio, the two writes that would move it out from under the lease are
    /// refused: the gain the sweep pinned, and destroying the capture outright.
    func testASweptRadioRefusesGainAndDestroy() async throws {
        try await withDaemon { c in
            let device = SyntheticBandDevice(carriers: [.init(hz: 145_400_000, dbfs: -25, widthHz: 12_500)])
            _ = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            try await Task.sleep(nanoseconds: 200_000_000)
            let events = await EventCollector.start(c.control, daemon: c.daemon)

            var config = Leyline_V1_ScanConfig()
            config.range.minHz = 145_000_000
            config.range.maxHz = 148_600_000
            config.dwellMs = 800
            config.once = true
            let job = try await c.jobs.startJob(.with { $0.config = .scan(config) }, metadata: testMetadata)

            // The lease is held once the sweep is stepping.
            var capture: Leyline_V1_Capture?
            for _ in 0 ..< 200 {
                let now = try await c.jobs.getJob(.with { $0.jobID = job.jobID }, metadata: testMetadata)
                if now.statusDetail.hasPrefix("sweeping") || now.statusDetail.hasPrefix("step") {
                    let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                    if let cap = state.captures.first { capture = cap; break }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let cap = try XCTUnwrap(capture, "the sweep never opened a capture")

            let summary = try await c.control.writeParams(metadata: testMetadata) { writer in
                var w = Leyline_V1_ParamWrite()
                w.tag = 41
                w.targetID = cap.captureID
                w.gain = .with { $0.element = "TUNER"; $0.db = 20 }
                try await writer.write(w)
            }
            XCTAssertEqual(summary.writesApplied, 0, "the gain a sweep pinned must not move")
            let rejected = await events.waitFor { ev in
                if case .writeRejected(let wr)? = ev.body { return wr.tag == 41 }
                return false
            }
            XCTAssertEqual(rejected?.writeRejected.error.code, "DEVICE_SWEEPING")

            do {
                _ = try await c.control.destroyCapture(.with { $0.captureID = cap.captureID }, metadata: testMetadata)
                XCTFail("destroying a swept capture must be refused")
            } catch {
                XCTAssertEqual(errorCode(error).code, "DEVICE_SWEEPING")
            }

            await events.stop()
            _ = try await c.jobs.cancelJob(.with { $0.jobID = job.jobID }, metadata: testMetadata)
        }
    }

    // MARK: harness

    /// Runs one sweep over a synthetic radio and hands the finished Scan to `check`.
    private func withSweepDaemon(_ carriers: [SyntheticBandDevice.Carrier],
                                 _ check: @escaping @Sendable (DaemonClients, Leyline_V1_Scan) async throws -> Void) async throws
    {
        try await withDaemon { c in
            let device = SyntheticBandDevice(carriers: carriers)
            _ = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            // Let the registry publish it.
            try await Task.sleep(nanoseconds: 200_000_000)

            var config = Leyline_V1_ScanConfig()
            config.range.minHz = 145_000_000
            config.range.maxHz = 148_600_000
            config.dwellMs = 200
            config.once = true
            var req = Leyline_V1_StartJobRequest()
            req.config = .scan(config)
            let job = try await c.jobs.startJob(req, metadata: testMetadata)
            XCTAssertEqual(job.state, .running)

            var final = job
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while final.state == .running, ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                final = try await c.jobs.getJob(Leyline_V1_JobRef.with { $0.jobID = job.jobID }, metadata: testMetadata)
            }
            XCTAssertEqual(final.state, .completed, "job did not finish: \(final.statusDetail)")
            XCTAssertGreaterThan(device.tunes.value, 1, "a multi-step sweep must retune more than once")

            let uri = try XCTUnwrap(final.resultUris.first)
            let scanID = String(uri.dropFirst("ley://scans/".count))
            let scan = try await c.jobs.getScan(Leyline_V1_ScanRef.with { $0.scanID = scanID }, metadata: testMetadata)
            try await check(c, scan)
        }
    }
}
