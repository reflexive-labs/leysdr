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
