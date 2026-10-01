// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import LeylineProto
import XCTest

@testable import LeylineServer

/// `WatchEvents(since_seq)`: the daemon replays the retained events newer than a `GetState`
/// snapshot before going live, so "GetState then WatchEvents" cannot miss an event.
final class EventReplayTests: XCTestCase {
    func testWatchEventsReplaysSinceSnapshotSeq() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("fixture missing: \(fixture) (run leyfix generate)")
        }
        try await withDaemon { c in
            let snapshot = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)

            // Mutations after the snapshot, before any stream exists: device arrival, then a capture.
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixture
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)

            // Resume from the snapshot: the replay starts right after it, in order, and reaches the capture.
            var scope = Leyline_V1_EventScope()
            scope.daemon = true
            scope.sinceSeq = snapshot.eventSeq
            let replayed: [Leyline_V1_Event] = try await c.control.watchEvents(scope, metadata: testMetadata) { response in
                var got: [Leyline_V1_Event] = []
                for try await ev in response.messages {
                    got.append(ev)
                    if case .capture(let cap)? = ev.body, cap.captureID == capture.captureID { break }
                    if got.count >= 16 { break }
                }
                return got
            }
            XCTAssertEqual(replayed.first?.seq, snapshot.eventSeq + 1, "replay starts right after the snapshot")
            XCTAssertEqual(replayed.map(\.seq), replayed.map(\.seq).sorted(), "replay is in seq order")
            XCTAssertTrue(replayed.contains { if case .device(let d)? = $0.body { return d.deviceID == device.deviceID }; return false }, "device arrival replayed")
            XCTAssertTrue(replayed.contains { if case .capture(let cap)? = $0.body { return cap.captureID == capture.captureID }; return false }, "capture creation replayed")

            // A capture-scoped resume only replays that capture's events (and daemon-wide ones).
            var capScope = Leyline_V1_EventScope()
            capScope.captureID = capture.captureID
            capScope.sinceSeq = snapshot.eventSeq
            let scoped: [Leyline_V1_Event] = try await c.control.watchEvents(capScope, metadata: testMetadata) { response in
                var got: [Leyline_V1_Event] = []
                for try await ev in response.messages {
                    got.append(ev)
                    if case .capture? = ev.body { break }
                    if got.count >= 16 { break }
                }
                return got
            }
            XCTAssertTrue(scoped.contains { if case .capture(let cap)? = $0.body { return cap.captureID == capture.captureID }; return false }, "scoped replay carries the capture")

            var destroy = Leyline_V1_DestroyCaptureRequest()
            destroy.captureID = capture.captureID
            _ = try await c.control.destroyCapture(destroy, metadata: testMetadata)
        }
    }
}
