// SPDX-License-Identifier: GPL-3.0-or-later

// The plugin wire, against the fake decoder: a descriptor, then a record per frame, then an exit
// the daemon can see (docs/design/decoders.md, "Decisions": "Transport: stdio").

import EngineCore
import Foundation
@testable import LeylineDaemon
import LeylineProto
import XCTest

final class PluginProcessTests: XCTestCase {
    private func descriptor() -> Leyline_V1_StreamDescriptor {
        var d = Leyline_V1_StreamDescriptor()
        d.streamID = "plug_test"
        d.kind = .audio
        d.policy = .gapMarked
        var audio = Leyline_V1_AudioParams()
        audio.sampleRate = 48000
        audio.format = .f32
        audio.tap = .tapAudio
        d.audio = audio
        d.centerHz = 146_000_000
        d.spanHz = 2_400_000
        d.grpc = true
        return d
    }

    private func frame(_ seq: UInt64, payload: Data) -> Leyline_V1_Frame {
        var f = Leyline_V1_Frame()
        f.streamID = "plug_test"
        f.seq = seq
        f.time.captureID = "cap_test"
        f.time.sampleIndex = seq * 1000
        f.payload = payload
        return f
    }

    func testOneRecordPerFrame() async throws {
        let plugin = PluginProcess(name: "fake", executable: fakeDecoderPath(), args: [],
                                   directory: NSTemporaryDirectory())
        try plugin.start(descriptor: descriptor())
        for i in 1...3 {
            try plugin.write(frame(UInt64(i), payload: Data([UInt8(i), 9, 9, 9, 9, 9])))
        }
        var seen: [Leyline_V1_DecodeRecord] = []
        for await rec in plugin.records {
            seen.append(rec)
            if seen.count == 3 { break }
        }
        XCTAssertEqual(seen.map(\.deviceID), ["FAKE-1", "FAKE-2", "FAKE-3"])
        XCTAssertEqual(seen.map(\.protocol), ["fake", "fake", "fake"])
        XCTAssertEqual(seen[1].time.sampleIndex, 2000)
        XCTAssertEqual(seen[2].position.latitude, 1.0)
        XCTAssertEqual(Array(seen[0].raw), [1, 9, 9, 9])
        await plugin.stop()
    }

    func testAnEmptyPayloadEndsThePlugin() async throws {
        let plugin = PluginProcess(name: "fake", executable: fakeDecoderPath(), args: [],
                                   directory: NSTemporaryDirectory())
        try plugin.start(descriptor: descriptor())
        try plugin.write(frame(1, payload: Data([1, 2, 3, 4])))
        try plugin.write(frame(2, payload: Data()))
        var status: Int32?
        for await code in plugin.exits { status = code }
        XCTAssertEqual(status, 3)
        await plugin.stop()
    }

    func testAnExecutableThatIsNotThereFails() async throws {
        let plugin = PluginProcess(name: "ghost", executable: "/nowhere/leydec-ghost", args: [],
                                   directory: NSTemporaryDirectory())
        XCTAssertThrowsError(try plugin.start(descriptor: descriptor())) { error in
            XCTAssertEqual((error as? EngineError)?.code, EngineError.Code.decoderFailed)
        }
    }

    func testAFrameAfterStopIsDroppedNotACrash() async throws {
        // Cancelling a decode job closes the plugin's stdin while the drain may still be handing
        // it a frame. The write used to ask the closed NSFileHandle for its descriptor, which
        // raises an Objective-C exception Swift cannot catch and took the daemon down (DEC-22).
        // Now a frame after stop is a drop, the same result as a plugin that stopped reading,
        // and a second stop is a no-op rather than a second close.
        let plugin = PluginProcess(name: "fake", executable: fakeDecoderPath(), args: [],
                                   directory: NSTemporaryDirectory())
        try plugin.start(descriptor: descriptor())
        try plugin.write(frame(1, payload: Data([1, 2, 3, 4])))
        await plugin.stop()
        guard case .droppedFull = try plugin.write(frame(2, payload: Data([1, 2, 3, 4]))) else {
            return XCTFail("a frame written after stop must be dropped, not written to a closed pipe")
        }
        await plugin.stop()
    }

    func testWritesRacingStopNeverTouchTheClosedHandle() async throws {
        // The race itself: frames written from one task while stop runs on another. Every write
        // must come back as a PluginWrite or a thrown error; the process must still be here. On
        // Darwin the old code raised out of the closed NSFileHandle and this test process died with
        // it; swift-corelibs-foundation returns -1 instead, so on Linux the first test is the one
        // that tells the old code from the new.
        let plugin = PluginProcess(name: "fake", executable: fakeDecoderPath(), args: [],
                                   directory: NSTemporaryDirectory())
        try plugin.start(descriptor: descriptor())
        let writer = Task.detached {
            var dropped = 0
            for i in 1...2000 {
                if case .droppedFull? = try? plugin.write(self.frame(UInt64(i), payload: Data([1, 2, 3, 4]))) {
                    dropped += 1
                }
            }
            return dropped
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        await plugin.stop()
        let dropped = await writer.value
        XCTAssertGreaterThan(dropped, 0, "the writes after stop were dropped, not written to a closed pipe")
    }

    func testStopClosesStdinAndWaits() async throws {
        let plugin = PluginProcess(name: "fake", executable: fakeDecoderPath(), args: [],
                                   directory: NSTemporaryDirectory())
        try plugin.start(descriptor: descriptor())
        try plugin.write(frame(1, payload: Data([1, 2, 3, 4])))
        var seen = 0
        for await _ in plugin.records {
            seen += 1
            break
        }
        XCTAssertEqual(seen, 1)
        let start = ContinuousClock.now
        await plugin.stop()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "a plugin that reads EOF should exit at once")
    }
}
