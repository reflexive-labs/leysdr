// SPDX-License-Identifier: GPL-3.0-or-later

// Record jobs: playing a recording back through the daemon.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

extension RecordingJobTests {
    // MARK: Playing a recording back

    /// The daemon owns the speakers, so a recording plays where the radio is. This container has
    /// no CoreAudio, so what is asserted here is the contract either way: an IQ recording is
    /// refused because those are tuned, a nonexistent recording is not found, and a host with no
    /// audio returns PLATFORM_UNSUPPORTED rather than failing some other way.
    func testPlaybackRefusesWhatItCannotPlay() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 146_520_000
            config.mode = .rawIq
            config.durationMs = 500
            let iq = try await self.start(c, config)
            _ = try await self.waitForEnd(c, iq.jobID)

            func play(_ uri: String) async -> RPCError? {
                var request = Leyline_V1_StartPlaybackRequest()
                request.resourceUri = uri
                do {
                    _ = try await c.control.startPlayback(request, metadata: testMetadata)
                    return nil
                } catch let e as RPCError {
                    return e
                } catch {
                    return nil
                }
            }
            // Raw samples are tuned, not played.
            var got = await play("ley://recordings/\(iq.jobID)")
            var e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .invalidArgument)
            XCTAssertTrue(e.message.contains("tuned rather than played"), e.message)

            got = await play("ley://recordings/job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB")
            e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .notFound)

            got = await play("file:///etc/passwd")
            e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .invalidArgument)

            // An audio recording is playable; on a host with no audio device the daemon returns an
            // error rather than faking playback, and `ley` falls back on that error.
            var audio = Leyline_V1_RecordConfig()
            audio.frequencyHz = recordFrequencyHz
            audio.mode = .nfm
            audio.durationMs = 500
            audio.squelchDbfs = -80
            let made = try await self.start(c, audio)
            _ = try await self.waitForEnd(c, made.jobID)
            got = await play("ley://recordings/\(made.jobID)")
            #if canImport(AVFoundation)
            XCTAssertNil(got, "a macOS daemon plays it")
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.playbacks.count, 1, "and a second client can see it")
            XCTAssertEqual(state.playbacks.first?.state, .playbackPlaying)
            var stop = Leyline_V1_StopPlaybackRequest()
            stop.playbackID = state.playbacks[0].playbackID
            _ = try await c.control.stopPlayback(stop, metadata: testMetadata)
            let after = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(after.playbacks.isEmpty, "stopping takes it out of the daemon's state")
            #else
            e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .unimplemented, "a host with no audio device says so")
            #endif
        }
    }

    /// Makes a finished one-second audio recording and swaps the daemon's audio device for a sink
    /// that discards the audio, so a host with no audio device plays it too.
    func playableRecording(_ c: DaemonClients) async throws -> Leyline_V1_Job {
        await c.daemon.store.setPlaybackSinkFactory { id, _, _, _ in NullSink(id: id) }
        try await attach(c, fixture: "nfm_tone.cf32", loop: true)
        var config = Leyline_V1_RecordConfig()
        config.frequencyHz = recordFrequencyHz
        config.mode = .nfm
        config.durationMs = 1000
        config.squelchDbfs = -80
        let done = try await waitForEnd(c, try await start(c, config).jobID)
        XCTAssertEqual(done.state, .completed, done.statusDetail)
        return done
    }

    func play(_ c: DaemonClients, _ uri: String) async throws -> Leyline_V1_Playback {
        var request = Leyline_V1_StartPlaybackRequest()
        request.resourceUri = uri
        return try await c.control.startPlayback(request, metadata: testMetadata)
    }

    /// A playing playback is published four times a second with its position, full state each
    /// time, so a client renders elapsed time from the event plane; the tombstone still ends it,
    /// and nothing playing follows the tombstone.
    func testAPlayingPartIsPublishedWithItsPosition() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            let done = try await self.playableRecording(c)
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            defer { Task { await events.stop() } }
            let pb = try await self.play(c, "ley://recordings/\(done.jobID)/1")
            let id = pb.playbackID
            let tomb = await events.waitFor(timeoutMs: 5000) {
                $0.playback.playbackID == id && $0.playback.state == .unspecified
            }
            XCTAssertNotNil(tomb, "the playback ends at the end of the file")
            let mine = await events.events.filter {
                if case .playback(let p)? = $0.body { return p.playbackID == id }
                return false
            }
            let playing = mine.prefix { $0.playback.state == .playbackPlaying }.map(\.playback)
            XCTAssertEqual(mine.count, playing.count + 1, "one tombstone, last, and nothing playing after it")
            // The start and at least two on the cadence: a second of audio is four ticks.
            XCTAssertGreaterThanOrEqual(playing.count, 3, "\(playing.map(\.position))")
            let positions = playing.map(\.position)
            XCTAssertEqual(positions, positions.sorted(), "the position only moves forward")
            XCTAssertGreaterThan(Set(positions.dropFirst()).count, 1, "and it moves between events: \(positions)")
            for p in playing {
                XCTAssertEqual(p.samples, pb.samples, "every event is the whole object")
                XCTAssertEqual(p.resourceUri, pb.resourceUri)
                XCTAssertLessThanOrEqual(p.position, p.samples)
            }
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.playbacks.isEmpty, "the finished playback is out of the daemon's state")
        }
    }

    /// Pausing holds the position across half a second, resuming moves it on, and the paused
    /// state is on the event and in `GetState`. Any client may pause, as any client may stop a
    /// playback; the event names who did.
    func testPausingAPlaybackHoldsItsPosition() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            let done = try await self.playableRecording(c)
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            defer { Task { await events.stop() } }
            let pb = try await self.play(c, "ley://recordings/\(done.jobID)/1")
            XCTAssertFalse(pb.paused)
            try await Task.sleep(nanoseconds: 200_000_000)

            var pause = Leyline_V1_SetPlaybackPausedRequest()
            pause.playbackID = pb.playbackID
            pause.paused = true
            let paused = try await c.control.setPlaybackPaused(pause, metadata: testMetadata)
            XCTAssertTrue(paused.paused)
            XCTAssertEqual(paused.state, .playbackPlaying, "a paused playback is still a playback")
            XCTAssertGreaterThan(paused.position, 0)
            let event = await events.waitFor { $0.playback.playbackID == pb.playbackID && $0.playback.paused }
            XCTAssertEqual(event?.causedBy.clientID, testClientID, "the pause is the pausing client's event")

            try await Task.sleep(nanoseconds: 500_000_000)
            let held = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let still = try XCTUnwrap(held.playbacks.first { $0.playbackID == pb.playbackID })
            XCTAssertTrue(still.paused)
            XCTAssertEqual(still.position, paused.position, "half a second paused and the position has not moved")

            pause.paused = false
            let resumed = try await c.control.setPlaybackPaused(pause, metadata: testMetadata)
            XCTAssertFalse(resumed.paused)
            try await Task.sleep(nanoseconds: 300_000_000)
            let moving = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let later = try XCTUnwrap(moving.playbacks.first { $0.playbackID == pb.playbackID })
            XCTAssertGreaterThan(later.position, paused.position, "resuming continues from where it was")
            // From where it was, not from where the clock says: 0.3 s of a 48 kHz file is 14,400
            // frames, and the pause is not owed as a burst.
            XCTAssertLessThan(later.position - paused.position, 48000 * 6 / 10)

            // Another client pauses it too, and the event is theirs.
            let other: Metadata = ["leyline-client-id": .string("cli_OTHER"), "leyline-client-kind": .string("app")]
            pause.paused = true
            let theirs = try await c.control.setPlaybackPaused(pause, metadata: other)
            XCTAssertTrue(theirs.paused)
            let otherEvent = await events.waitFor {
                $0.playback.playbackID == pb.playbackID && $0.playback.paused && $0.causedBy.clientID == "cli_OTHER"
            }
            XCTAssertNotNil(otherEvent)

            pause.playbackID = "pb_01J8XQ2M7V3N9K5R4T6W8Y0ZAB"
            do {
                _ = try await c.control.setPlaybackPaused(pause, metadata: testMetadata)
                XCTFail("paused a playback that does not exist")
            } catch {
                XCTAssertEqual(errorCode(error).code, EngineError.Code.sinkNotFound)
            }

            var stop = Leyline_V1_StopPlaybackRequest()
            stop.playbackID = pb.playbackID
            _ = try await c.control.stopPlayback(stop, metadata: testMetadata)
            let tomb = await events.waitFor { $0.playback.playbackID == pb.playbackID && $0.playback.state == .unspecified }
            XCTAssertNotNil(tomb, "a paused playback stops like any other")
        }
    }

    /// A sample range plays only that stretch of the part: the playback counts the range's frames,
    /// carries the range it was given, starts from frame 0 of it and ends on its own once the range
    /// has played. A range outside the part is refused before anything plays.
    func testPlaybackOfARangePlaysOnlyThatStretch() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            let done = try await self.playableRecording(c)
            let data = try XCTUnwrap(FileManager.default.contents(atPath: dir + "/" + done.jobID + "/recording.json"))
            let manifest = try JSONDecoder().decode(RecordingManifest.self, from: data)
            let part = try XCTUnwrap(manifest.parts.first)
            let span = part.endSample - part.startSample
            let from = part.startSample + span / 4
            let to = part.startSample + span / 2

            let events = await EventCollector.start(c.control, daemon: c.daemon)
            defer { Task { await events.stop() } }
            var request = Leyline_V1_StartPlaybackRequest()
            request.resourceUri = "ley://recordings/\(done.jobID)/\(part.part)"
            request.startSample = from
            request.endSample = to
            let pb = try await c.control.startPlayback(request, metadata: testMetadata)
            XCTAssertEqual(pb.startSample, from, "the playback carries the range it plays")
            XCTAssertEqual(pb.endSample, to)
            // A quarter of the part's frames, to the frame either way for the rounding of each end.
            let quarter = Double(part.samples) / 4
            XCTAssertEqual(Double(pb.samples), quarter, accuracy: 2, "samples counts the range, not the file")
            XCTAssertLessThan(pb.position, pb.samples)

            let tomb = await events.waitFor(timeoutMs: 5000) {
                $0.playback.playbackID == pb.playbackID && $0.playback.state == .unspecified
            }
            XCTAssertNotNil(tomb, "the playback ends at the end of the range")
            XCTAssertEqual(tomb?.playback.position, pb.samples, "and it played every frame of the range")
            XCTAssertEqual(tomb?.playback.startSample, from)

            // Outside the part, empty, and backwards: each refused with what the part holds.
            for (start, end) in [(part.startSample &- 1, to), (from, part.endSample + 1), (to, from)] {
                request.startSample = start
                request.endSample = end
                do {
                    _ = try await c.control.startPlayback(request, metadata: testMetadata)
                    XCTFail("played \(start)..<\(end) of a part that holds \(part.startSample)..<\(part.endSample)")
                } catch let e as RPCError {
                    XCTAssertEqual(e.code, .invalidArgument)
                    XCTAssertTrue(e.message.contains("not a range inside part \(part.part)"), e.message)
                }
            }
        }
    }

    /// The range is placed in the file by the two rates: capture samples at the anchor's rate,
    /// frames at the audio rate. A 0 start is the part's start and a 0 end its end; 0 and 0 is
    /// the whole part. With no capture rate, the part's own span over its frames stands in.
    func testAPlaybackRangeIsPlacedByTheTwoRates() throws {
        // One second of capture at 2.4 MSPS from sample 2,400,000, as 48,000 frames at 48 kHz.
        let part = RecordingPart(part: 2, file: "x.wav", startSample: 2_400_000, endSample: 4_800_000,
                                 samples: 48000, bytes: 96044, peakDbfs: nil, meanDbfs: nil, squelchOpens: 1)
        XCTAssertNil(try PlaybackRange.resolve(start: 0, end: 0, part: part, audioRate: 48000,
                                               captureRate: 2_400_000, target: "t"))
        let r = try XCTUnwrap(PlaybackRange.resolve(start: 3_000_000, end: 3_600_000, part: part, audioRate: 48000,
                                                    captureRate: 2_400_000, target: "t"))
        XCTAssertEqual(r.frames, 12000..<24000)
        let open = try XCTUnwrap(PlaybackRange.resolve(start: 3_600_000, end: 0, part: part, audioRate: 48000,
                                                       captureRate: 0, target: "t"))
        XCTAssertEqual(open.frames, 24000..<48000, "to the part's end, by the part's own span")
        XCTAssertEqual(open.endSample, 4_800_000)
        let head = try XCTUnwrap(PlaybackRange.resolve(start: 0, end: 2_400_050, part: part, audioRate: 48000,
                                                       captureRate: 2_400_000, target: "t"))
        XCTAssertEqual(head.frames, 0..<1, "from the part's start; fifty samples is one frame")
        XCTAssertThrowsError(try PlaybackRange.resolve(start: 2_400_000, end: 2_400_010, part: part, audioRate: 48000,
                                                       captureRate: 2_400_000, target: "t"),
                             "ten capture samples are less than one frame of audio")
    }
}
