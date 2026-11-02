// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

/// Decoding seen from the radio (DA-9): the sidebar's rows, which records tag the waterfall,
/// the ten seconds between two tags of one transmitter, and the expiry with the rows.
final class WaterfallTagsTests: XCTestCase {
    func manifest(_ name: String, iq: Bool = false, entityName: String = "")
        -> Leyline_V1_DecoderManifest
    {
        var m = Leyline_V1_DecoderManifest()
        m.name = name
        m.input.signal = iq ? .signalIq : .signalAudio
        if !entityName.isEmpty { m.display.entityName = entityName }
        m.display.title = name.uppercased()
        m.display.symbol = "antenna.radiowaves.left.and.right"
        return m
    }

    func job(
        _ id: String, decoder: String, hz: UInt64 = 144_390_000,
        state: Leyline_V1_JobState = .running, detail: String = "", source: String = ""
    ) -> Leyline_V1_Job {
        var j = Leyline_V1_Job()
        j.jobID = id
        j.state = state
        j.statusDetail = detail
        var d = Leyline_V1_DecodeConfig()
        d.decoder = decoder
        d.frequencyHz = hz
        d.sourceUri = source
        j.config = .decode(d)
        return j
    }

    func record(
        _ id: String, job: String = "job_1", device: String = "N0CALL-3", proto: String = "aprs",
        channel: String = "chan_1", fields: [String: String] = [:]
    ) -> Leyline_V1_DecodeRecord {
        var r = Leyline_V1_DecodeRecord()
        r.recordID = id
        r.jobID = job
        r.deviceID = device
        r.protocol = proto
        r.channelID = channel
        for (k, v) in fields {
            var f = Leyline_V1_FieldValue()
            f.text = v
            r.fields[k] = f
        }
        return r
    }

    func capture(_ id: String = "cap_1", centre: UInt64 = 144_390_000, rate: UInt64 = 960_000)
        -> Leyline_V1_Capture
    {
        var c = Leyline_V1_Capture()
        c.captureID = id
        c.centerHz = centre
        c.sampleRate = rate
        return c
    }

    func channel(_ id: String = "chan_1", capture: String = "cap_1", offset: Int64 = 0)
        -> Leyline_V1_Channel
    {
        var c = Leyline_V1_Channel()
        c.channelID = id
        c.captureID = capture
        c.offsetHz = offset
        return c
    }

    // MARK: The sidebar's rows

    func testOnlyRunningDecodersGetARow() {
        let ms = [manifest("aprs"), manifest("ais"), manifest("adsb", iq: true)]
        XCTAssertEqual(DecodingRow.rows(ms, jobs: []), [])
        let jobs = [
            job("job_2", decoder: "aprs", detail: "decoding with aprs: 12 records, last 3 s ago"),
            job("job_1", decoder: "ais", state: .cancelled),
            job(
                "job_3", decoder: "adsb", state: .degraded,
                detail: "decoding with adsb: no records yet"),
            job("job_4", decoder: "ais", source: "ley://recordings/r1"),
        ]
        let rows = DecodingRow.rows(ms, jobs: jobs)
        XCTAssertEqual(rows.map(\.decoder), ["aprs", "adsb"])
        XCTAssertEqual(rows[0].title, "APRS")
        XCTAssertEqual(rows[0].count, "12 records")
        XCTAssertEqual(rows[0].detail, "decoding with aprs: 12 records, last 3 s ago")
        XCTAssertFalse(rows[0].degraded)
        XCTAssertEqual(rows[1].count, "no records yet")
        XCTAssertTrue(rows[1].degraded)
    }

    func testTwoJobsOfOneDecoderAreOneRow() {
        let rows = DecodingRow.rows(
            [manifest("aprs")],
            jobs: [
                job(
                    "job_1", decoder: "aprs", detail: "decoding with aprs: 1 record, last just now"),
                job(
                    "job_2", decoder: "aprs", detail: "decoding with aprs: 4 records, last 2 s ago"),
            ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].count, "4 records · 2 jobs")
    }

    func testTheCountComesOutOfTheDetail() {
        XCTAssertEqual(
            DecodingRow.countWords("decoding with aprs: 12 records, last 3 s ago"), "12 records")
        XCTAssertEqual(
            DecodingRow.countWords("decoding with aprs: 1 record, last just now"), "1 record")
        XCTAssertEqual(
            DecodingRow.countWords("decoding with aprs: no records yet"), "no records yet")
        XCTAssertEqual(DecodingRow.countWords("starting"), "starting")
        XCTAssertEqual(DecodingRow.countWords(""), "")
    }

    // MARK: Which records tag

    func testAnAudioDecodersRecordInsideTheCaptureTags() {
        let hz = WaterfallTags.frequency(
            of: record("rec_1"), jobs: [job("job_1", decoder: "aprs")],
            manifests: [manifest("aprs")], channels: [channel()], capture: capture())
        XCTAssertEqual(hz, 144_390_000)
    }

    func testAnIQDecoderDrawsNone() {
        let hz = WaterfallTags.frequency(
            of: record("rec_1", proto: "adsb"),
            jobs: [job("job_1", decoder: "adsb", hz: 144_390_000)],
            manifests: [manifest("adsb", iq: true)], channels: [], capture: capture())
        XCTAssertNil(hz)
    }

    func testARecordOutsideTheCaptureOrOnAnotherDrawsNone() {
        let jobs = [job("job_1", decoder: "aprs", hz: 162_400_000)]
        XCTAssertNil(
            WaterfallTags.frequency(
                of: record("rec_1"), jobs: jobs, manifests: [manifest("aprs")], channels: [],
                capture: capture()))
        // The same frequency, heard by another radio's capture.
        XCTAssertNil(
            WaterfallTags.frequency(
                of: record("rec_1"), jobs: [job("job_1", decoder: "aprs")],
                manifests: [manifest("aprs")], channels: [channel(capture: "cap_2")],
                capture: capture()))
        XCTAssertNil(
            WaterfallTags.frequency(
                of: record("rec_1"), jobs: [job("job_1", decoder: "aprs")],
                manifests: [manifest("aprs")], channels: [], capture: nil))
    }

    func testAJobWithNoFrequencyTagsAtItsChannel() {
        let hz = WaterfallTags.frequency(
            of: record("rec_1"), jobs: [job("job_1", decoder: "aprs", hz: 0)],
            manifests: [manifest("aprs")], channels: [channel(offset: -20_000)],
            capture: capture())
        XCTAssertEqual(hz, 144_370_000)
    }

    func testAnUnknownJobADecodedRecordingOrAnUnknownDecoderDrawsNone() {
        let m = [manifest("aprs")]
        XCTAssertNil(
            WaterfallTags.frequency(
                of: record("rec_1", job: "job_9"), jobs: [job("job_1", decoder: "aprs")],
                manifests: m, channels: [], capture: capture()))
        XCTAssertNil(
            WaterfallTags.frequency(
                of: record("rec_1"),
                jobs: [job("job_1", decoder: "aprs", source: "ley://recordings/r1")],
                manifests: m, channels: [], capture: capture()))
        XCTAssertNil(
            WaterfallTags.frequency(
                of: record("rec_1"), jobs: [job("job_1", decoder: "ais")], manifests: m,
                channels: [], capture: capture()))
    }

    // MARK: Names and the rate limit

    func testTheNameIsTheEntityNameElseTheDeviceID() {
        var tags = WaterfallTags()
        let t0 = Date(timeIntervalSince1970: 1000)
        let display = manifest("ais", entityName: "{name}").display
        tags.add(
            record("rec_1", device: "366000001", proto: "ais", fields: ["name": "EVER GIVEN"]),
            display: display, frequencyHz: 1, captureID: "cap_1", rows: 10, at: t0)
        XCTAssertEqual(tags.tags.map(\.name), ["EVER GIVEN"])
        // A position report lacks the name; the one the vessel last sent stands.
        tags.add(
            record("rec_2", device: "366000001", proto: "ais"), display: display, frequencyHz: 1,
            captureID: "cap_1", rows: 400, at: t0 + 11)
        XCTAssertEqual(tags.tags.map(\.name), ["EVER GIVEN", "EVER GIVEN"])
        // A vessel never named is its MMSI.
        tags.add(
            record("rec_3", device: "366000002", proto: "ais"), display: display, frequencyHz: 1,
            captureID: "cap_1", rows: 401, at: t0 + 11)
        XCTAssertEqual(tags.tags.first?.name, "366000002")
        // No name and no id: no tag.
        XCTAssertFalse(
            tags.add(
                record("rec_4", device: ""), display: nil, frequencyHz: 1, captureID: "cap_1",
                rows: 402, at: t0 + 30))
    }

    func testOneTagPerTransmitterPerTenSeconds() {
        var tags = WaterfallTags()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(
            tags.add(
                record("rec_1"), display: nil, frequencyHz: 1, captureID: "cap_1", rows: 1,
                at: t0))
        XCTAssertFalse(
            tags.add(
                record("rec_2"), display: nil, frequencyHz: 1, captureID: "cap_1", rows: 60,
                at: t0 + 2))
        // Another transmitter is not held back.
        XCTAssertTrue(
            tags.add(
                record("rec_3", device: "N0CALL-5"), display: nil, frequencyHz: 1,
                captureID: "cap_1", rows: 61, at: t0 + 2))
        XCTAssertFalse(
            tags.add(
                record("rec_4"), display: nil, frequencyHz: 1, captureID: "cap_1", rows: 290,
                at: t0 + 9.9))
        // Ten seconds after the last tag shown, not after the last record held back.
        XCTAssertTrue(
            tags.add(
                record("rec_5"), display: nil, frequencyHz: 1, captureID: "cap_1", rows: 300,
                at: t0 + 10))
        XCTAssertEqual(tags.tags.map(\.id), ["rec_5", "rec_3", "rec_1"])
    }

    func testTheListIsBounded() {
        var tags = WaterfallTags()
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0..<(WaterfallTags.limit + 10) {
            tags.add(
                record("rec_\(i)", device: "N0CALL-\(i)"), display: nil, frequencyHz: 1,
                captureID: "cap_1", rows: i, at: t0)
        }
        XCTAssertEqual(tags.tags.count, WaterfallTags.limit)
        XCTAssertEqual(tags.tags.first?.id, "rec_\(WaterfallTags.limit + 9)")
    }

    // MARK: Expiry

    func testATagGoesWithItsRow() {
        var tags = WaterfallTags()
        let t0 = Date(timeIntervalSince1970: 1000)
        tags.add(
            record("rec_1"), display: nil, frequencyHz: 1, captureID: "cap_1", rows: 100, at: t0)
        tags.add(
            record("rec_2", device: "N0CALL-5"), display: nil, frequencyHz: 1,
            captureID: "cap_1", rows: 500, at: t0)
        XCTAssertEqual(tags.tags.first?.age(rows: 500), 0)
        XCTAssertEqual(
            tags.shown(rows: 500, horizon: 800, captureID: "cap_1").map(\.id),
            ["rec_2", "rec_1"])
        // rec_1's row is 800 rows down, past the bottom.
        XCTAssertEqual(tags.shown(rows: 900, horizon: 800, captureID: "cap_1").map(\.id), ["rec_2"])
        // Another capture's rows, or rows started over.
        XCTAssertEqual(tags.shown(rows: 500, horizon: 800, captureID: "cap_2"), [])
        XCTAssertEqual(tags.shown(rows: 50, horizon: 800, captureID: "cap_1"), [])
        tags.expire(rows: 900, horizon: 800, captureID: "cap_1")
        XCTAssertEqual(tags.tags.map(\.id), ["rec_2"])
        tags.removeAll()
        XCTAssertEqual(tags.tags, [])
        // The rate limit was forgotten with them.
        XCTAssertTrue(
            tags.add(
                record("rec_3", device: "N0CALL-5"), display: nil, frequencyHz: 1,
                captureID: "cap_1", rows: 901, at: t0 + 1))
    }
}
