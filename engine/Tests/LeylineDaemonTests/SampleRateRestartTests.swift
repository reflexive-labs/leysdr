// SPDX-License-Identifier: GPL-3.0-or-later

// A capture_sample_rate write restarts the device stream (device index back to 0). The FFT bulk
// stream opened before the write must keep delivering rows with a monotonic SampleTime after it.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineServer
import LeylineProto
import XCTest

final class SampleRateRestartDaemonTests: XCTestCase {
    /// Polls `cond` every 20 ms until it holds or `timeoutMs` elapses.
    private func eventually(timeoutMs: Int = 3000, _ cond: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0 ..< (timeoutMs / 20) {
            if try await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return try await cond()
    }

    func testFFTRowsContinueAcrossSampleRateWrite() async throws {
        try await withDaemon { c in
            let device = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            let mirrored = try await self.eventually {
                let s = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                return s.devices.contains(where: { $0.deviceID == d.id.string })
            }
            XCTAssertTrue(mirrored, "session store mirrors the attached device")
            let events = await EventCollector.start(c.control, daemon: c.daemon)

            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            XCTAssertEqual(capture.sampleRate, 2_400_000)

            var req = Leyline_V1_SubscribeRequest()
            req.captureID = capture.captureID
            req.kind = .fft
            req.policy = .gapMarked
            req.transport = .grpc
            req.fft.bins = 256
            req.fft.rowsPerSecond = 30
            req.fft.binFormat = .dbF32
            let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTAssertEqual(desc.spanHz, 2_400_000)
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID

            // Collect rows; after the third one, change the rate from inside the open stream and
            // keep reading until five more rows have arrived under the new rate.
            let rateWritten = LockedValue(false)
            let frames: [Leyline_V1_Frame] = try await c.bulk.stream(ref, metadata: testMetadata) { response in
                var out: [Leyline_V1_Frame] = []
                for try await f in response.messages {
                    out.append(f)
                    if out.count == 3 {
                        let summary = try await c.control.writeParams(metadata: testMetadata) { writer in
                            var w = Leyline_V1_ParamWrite()
                            w.tag = 1
                            w.targetID = capture.captureID
                            w.captureSampleRate = 1_024_000
                            try await writer.write(w)
                        }
                        XCTAssertEqual(summary.writesApplied, 1, "rate write applied")
                        rateWritten.value = true
                    }
                    if out.count >= 8 { break }
                }
                return out
            }
            XCTAssertTrue(rateWritten.value)
            XCTAssertEqual(frames.count, 8, "rows keep arriving after the rate change")
            XCTAssertEqual(frames.map(\.seq), Array(1 ... 8), "no gap: the ladder never stalls across the restart")
            XCTAssertEqual(device.streamStarts.value, 2, "the rate change restarted the device stream")
            let indexes = frames.map(\.time.sampleIndex)
            for i in 1 ..< indexes.count {
                XCTAssertGreaterThan(indexes[i], indexes[i - 1], "SampleTime must not rewind at row \(i): \(indexes)")
            }
            for f in frames {
                XCTAssertEqual(f.time.captureID, capture.captureID)
                XCTAssertEqual(f.payload.count, 256 * 4)
                XCTAssertFalse(f.hasGap, "no drop should be marked on a clean restart")
            }

            let applied = await events.waitFor { ev in
                if case .capture(let cap)? = ev.body { return cap.captureID == capture.captureID && cap.sampleRate == 1_024_000 }
                return false
            }
            XCTAssertNotNil(applied, "capture event carries the new rate")
            // The new anchor is published from the first block of the restarted stream.
            let anchored = await events.waitFor { ev in
                if case .anchor(let a)? = ev.body { return a.captureID == capture.captureID && a.sampleRate == 1_024_000 }
                return false
            }
            XCTAssertNotNil(anchored, "anchor event at the new rate")
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.first?.sampleRate, 1_024_000)
            _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
            await events.stop()
        }
    }
}
