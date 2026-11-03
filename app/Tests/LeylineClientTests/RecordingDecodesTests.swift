// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

/// Decode With (DA-11): which decoders a recording offers, the job it starts, and the
/// inspector's count per decoder.
final class RecordingDecodesTests: XCTestCase {
    func manifest(
        _ name: String, signal: Leyline_V1_DecoderSignal = .signalAudio, testOnly: Bool = false
    ) -> Leyline_V1_DecoderManifest {
        .with {
            $0.name = name
            $0.input.signal = signal
            $0.testOnly = testOnly
        }
    }

    func job(
        _ id: String, decoder: String, source: String, state: Leyline_V1_JobState = .completed
    ) -> Leyline_V1_Job {
        .with {
            $0.jobID = id
            $0.state = state
            $0.config = .decode(
                .with {
                    $0.decoder = decoder
                    $0.sourceUri = source
                })
        }
    }

    func testTheRecordingsKindPicksTheDecoders() {
        let all = [
            manifest("adsb", signal: .signalIq), manifest("ais"), manifest("aprs"),
            manifest("iqstat", signal: .signalIq), manifest("speech"),
            manifest("speech-scripted", testOnly: true), manifest("aprs"),
            manifest("old", signal: .unspecified),
        ]
        XCTAssertEqual(
            RecordingDecodes.offered(all, recordingKind: "audio", transcriber: "speech").map(
                \.name), ["ais", "aprs", "old"])
        XCTAssertEqual(
            RecordingDecodes.offered(all, recordingKind: "iq", transcriber: "speech").map(\.name),
            ["adsb", "iqstat"])
    }

    func testTheJobIsKeptOverTheRecording() {
        let c = RecordingDecodes.config(decoder: "aprs", recordingURI: "ley://recordings/job_r")
        XCTAssertEqual(c.decoder, "aprs")
        XCTAssertEqual(c.sourceUri, "ley://recordings/job_r")
        XCTAssertTrue(c.keep)
        XCTAssertFalse(c.hasPredicate)
    }

    func testTheNewestJobOfEachDecoderOverTheRecording() {
        let uri = "ley://recordings/job_r"
        let jobs = [
            job("job_1", decoder: "aprs", source: uri),
            job("job_2", decoder: "speech", source: uri),
            job("job_3", decoder: "aprs", source: uri),
            job("job_4", decoder: "ais", source: "ley://recordings/job_other"),
            job("job_5", decoder: "same", source: uri),
            job("job_6", decoder: "aprs", source: ""),
        ]
        XCTAssertEqual(
            RecordingDecodes.jobs(of: uri, in: jobs, transcriber: "speech").map(\.jobID),
            ["job_5", "job_3"])
        XCTAssertEqual(
            RecordingDecodes.all(in: jobs, transcriber: "speech").map(\.jobID),
            ["job_1", "job_3", "job_4", "job_5"])
        XCTAssertEqual(
            SpeechRecords.transcription(of: uri, in: jobs)?.jobID, "job_2",
            "another decoder's job over the recording is not a transcription")
    }

    func testTheInspectorsLine() {
        let uri = "ley://recordings/job_r"
        let three = RecordingDecodes.Count(records: 3, truncated: false)
        XCTAssertEqual(
            RecordingDecodes.line(
                title: "APRS", job: job("j", decoder: "aprs", source: uri), count: three),
            "APRS · 3 records")
        XCTAssertEqual(
            RecordingDecodes.line(
                title: "APRS", job: job("j", decoder: "aprs", source: uri),
                count: .init(records: 1, truncated: false)), "APRS · 1 record")
        XCTAssertEqual(
            RecordingDecodes.line(
                title: "APRS", job: job("j", decoder: "aprs", source: uri),
                count: .init(records: 1000, truncated: true)), "APRS · 1000+ records")
        XCTAssertEqual(
            RecordingDecodes.line(
                title: "APRS", job: job("j", decoder: "aprs", source: uri, state: .running),
                count: three), "APRS · decoding · 3 records so far")
        XCTAssertEqual(
            RecordingDecodes.line(
                title: "APRS", job: job("j", decoder: "aprs", source: uri, state: .running),
                count: nil), "APRS · decoding")
        var failed = job("j", decoder: "aprs", source: uri, state: .failed)
        failed.error.message = "the plugin exited"
        XCTAssertEqual(
            RecordingDecodes.line(title: "APRS", job: failed, count: nil),
            "APRS · could not decode: the plugin exited")
        XCTAssertEqual(
            RecordingDecodes.line(
                title: "APRS", job: job("j", decoder: "aprs", source: uri), count: nil),
            "APRS · counting the records…")
        XCTAssertEqual(
            RecordingDecodes.line(
                title: "APRS", job: job("j", decoder: "aprs", source: uri, state: .cancelled),
                count: three),
            "APRS · stopped · 3 records")
    }

    func testTheFirstDecoderRowIsLabelledDecoded() {
        XCTAssertEqual((0..<3).map(RecordingDecodes.label(at:)), ["Decoded", "", ""])
    }
}
