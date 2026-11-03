// SPDX-License-Identifier: Apache-2.0

// Decoding, seen from the radio (docs/plans/decoders-app.md, DA-9): the Radio sidebar's row per
// running decoder, and the waterfall's tags, a transmitter's name drawn at its decoder's
// frequency on the row its record arrived in. Held here, with no I/O, so the Linux tests reach
// the rules: which records make a tag, the ten seconds between two tags of one transmitter, the
// expiry once a tag's row has scrolled past what the waterfall shows, and the last minute read
// back when the tags start (DA-21), each record on the row its time fell in. Nothing is special-cased
// by decoder: the manifest's input says whether its records have a frequency of their own (an
// audio decoder's channel) or not (an IQ decoder reads the whole capture), and its display's
// `entity_name` names the transmitter.

import Foundation
import LeylineProto

/// One running decoder as the Radio sidebar lists it: its symbol, its title and the liveness
/// count from its job's `status_detail`.
public struct DecodingRow: Sendable, Equatable, Identifiable {
    /// The manifest's name, which the Decoders place selects.
    public var decoder: String
    public var title: String
    public var symbol: String
    /// The count the row shows: `12 records`, `no records yet`.
    public var count: String
    /// Every running job's whole `status_detail`, one a line: the row's tooltip.
    public var detail: String
    public var degraded: Bool

    public var id: String { decoder }

    public init(
        decoder: String, title: String, symbol: String, count: String, detail: String,
        degraded: Bool
    ) {
        self.decoder = decoder
        self.title = title
        self.symbol = symbol
        self.count = count
        self.detail = detail
        self.degraded = degraded
    }

    /// A row per listed decoder with a running or degraded job on a radio, in the list's order;
    /// none when nothing runs. The count is the newest job's: out of `held`, the newest record
    /// `seq` the window holds of each job (`WaterfallTags.lastSeq`), when it holds one, since a
    /// job's records are numbered from 1 without a hole; else out of the job's `status_detail`,
    /// which the daemon refreshes every two seconds at most.
    public static func rows(
        _ manifests: [Leyline_V1_DecoderManifest], jobs: [Leyline_V1_Job],
        held: [String: UInt64] = [:]
    ) -> [DecodingRow] {
        DecoderPages.listed(manifests).compactMap { m in
            let running = DecoderPages.running(of: m, in: jobs)
            guard let newest = running.first else { return nil }
            var count =
                held[newest.jobID].map {
                    RecordingDecodes.recordsWords(.init(records: Int($0), truncated: false))
                } ?? countWords(DecoderPages.detail(newest))
            if running.count > 1 { count += " · \(running.count) jobs" }
            return DecodingRow(
                decoder: m.name, title: DecoderPages.title(m), symbol: DecoderPages.symbol(m),
                count: count,
                detail: running.map(DecoderPages.detail).filter { !$0.isEmpty }
                    .joined(separator: "\n"),
                degraded: running.contains { $0.state == .degraded })
        }
    }

    /// The count out of a decode job's detail: `decoding with aprs: 12 records, last 3 s ago` is
    /// `12 records`, `decoding with aprs: no records yet` is `no records yet`. The age is left
    /// out because the daemon refreshes the detail every two seconds at most, so the age would be
    /// stale between events. A detail of another shape is shown whole.
    public static func countWords(_ detail: String) -> String {
        var s = Substring(detail)
        if s.hasPrefix("decoding with "), let colon = s.range(of: ": ") {
            s = s[colon.upperBound...]
        }
        if let last = s.range(of: ", last ") { s = s[..<last.lowerBound] }
        return String(s)
    }
}

/// One tag on the waterfall: a transmitter's name at its decoder's frequency, on the row its
/// record arrived in.
public struct WaterfallTag: Sendable, Equatable, Identifiable {
    /// The record's `record_id`.
    public var id: String
    /// The transmitter, the rate limit's key: the protocol and the `device_id`, else the name.
    public var transmitter: String
    public var name: String
    public var frequencyHz: UInt64
    /// The capture whose rows the tag sits on.
    public var captureID: String
    /// How many rows the waterfall had written when the record arrived: the tag sits on the
    /// newest of them, so its age is `rows - row`, 0 while that row is the newest.
    public var row: Int
    public var at: Date

    public init(
        id: String, transmitter: String, name: String, frequencyHz: UInt64, captureID: String,
        row: Int, at: Date
    ) {
        self.id = id
        self.transmitter = transmitter
        self.name = name
        self.frequencyHz = frequencyHz
        self.captureID = captureID
        self.row = row
        self.at = at
    }

    /// The tag's age in rows once the waterfall has written `rows`: 0 on the newest row.
    public func age(rows: Int) -> Int { rows - row }
}

/// The waterfall's tags, newest first, bounded at `limit`, with at most one per transmitter in
/// any `repeatSeconds`.
public struct WaterfallTags: Sendable, Equatable {
    /// The least time between two tags of one transmitter.
    public static let repeatSeconds: TimeInterval = 10
    /// The most tags held. The waterfall shows about a minute of rows, so this is far more than
    /// ever fit, and it bounds the overlay's work whatever the decoders send.
    public static let limit = 32
    /// The most transmitters whose last name is remembered (`names`) before the memory is
    /// cleared.
    public static let namesLimit = 512

    /// How far back the tags are read when they start (`backfill`): about what the waterfall
    /// shows.
    public static let backfillSeconds: TimeInterval = 60

    public private(set) var tags: [WaterfallTag] = []
    /// The newest `seq` of each job's records the window holds, live or read back: how many
    /// records the job has, for the sidebar's count (`DecodingRow.rows`).
    public private(set) var lastSeq: [String: UInt64] = [:]

    /// No tag and no count held.
    public var isEmpty: Bool { tags.isEmpty && lastSeq.isEmpty }
    /// When each transmitter was last tagged, for the rate limit; entries older than
    /// `repeatSeconds` are dropped as tags are added.
    private var lastTagged: [String: Date] = [:]
    /// The name each transmitter's display template last rendered, so a record that lacks the
    /// fields the template reads (an AIS position report, without the vessel's name) keeps the
    /// name an earlier one gave rather than falling back to the id.
    private var names: [String: String] = [:]

    public init() {}

    /// The frequency a record's tag sits at, or nil when it makes none: the record's job must be
    /// a decode job on a radio (no `source_uri`) whose decoder reads AUDIO, because an IQ
    /// decoder's records have no frequency of their own inside the capture; the record's channel,
    /// when the mirror has it, must ride `capture`; and the frequency (the job's, else its
    /// channel's) must lie inside `capture`'s span.
    public static func frequency(
        of record: Leyline_V1_DecodeRecord, jobs: [Leyline_V1_Job],
        manifests: [Leyline_V1_DecoderManifest], channels: [Leyline_V1_Channel],
        capture: Leyline_V1_Capture?
    ) -> UInt64? {
        guard let capture, capture.sampleRate > 0,
            let job = jobs.first(where: { $0.jobID == record.jobID }),
            case .decode(let d)? = job.config, d.sourceUri.isEmpty,
            let m = manifests.first(where: {
                $0.name == d.decoder || $0.aliases.contains(d.decoder)
            }),
            m.input.signal != .signalIq
        else { return nil }
        let channel = channels.first { $0.channelID == record.channelID }
        if let channel, channel.captureID != capture.captureID { return nil }
        var hz = d.frequencyHz
        if hz == 0, let channel {
            hz = UInt64(max(0, Int64(capture.centerHz) + channel.offsetHz))
        }
        guard hz > 0,
            ViewWindow.span(centerHz: capture.centerHz, sampleRate: capture.sampleRate)
                .contains(hz)
        else { return nil }
        return hz
    }

    /// Adds the tag for `record` at `frequencyHz`, on the newest of `rows` rows of `captureID`,
    /// and says whether it was added. A record makes none when it names no transmitter (no
    /// `entity_name` renders and it has no `device_id`), or when its transmitter was tagged less
    /// than `repeatSeconds` before `at`. The name is the display's `entity_name` over the record,
    /// else the name it last rendered for the transmitter, else the `device_id`.
    @discardableResult
    public mutating func add(
        _ record: Leyline_V1_DecodeRecord, display: Leyline_V1_DecoderDisplay?,
        frequencyHz: UInt64, captureID: String, rows: Int, at: Date
    ) -> Bool {
        hold(record)
        guard !tags.contains(where: { $0.id == record.recordID }),
            let named = naming(record, display: display)
        else { return false }
        let transmitter = named.transmitter
        lastTagged = lastTagged.filter { at.timeIntervalSince($0.value) < Self.repeatSeconds }
        if lastTagged[transmitter] != nil { return false }
        lastTagged[transmitter] = at
        tags.insert(
            WaterfallTag(
                id: record.recordID, transmitter: transmitter, name: named.name,
                frequencyHz: frequencyHz, captureID: captureID, row: rows, at: at),
            at: 0)
        if tags.count > Self.limit { tags.removeLast(tags.count - Self.limit) }
        return true
    }

    /// Notes `record` for its job's count (`lastSeq`), whether or not it tags.
    public mutating func hold(_ record: Leyline_V1_DecodeRecord) {
        guard !record.jobID.isEmpty, record.seq > 0 else { return }
        if record.seq > lastSeq[record.jobID] ?? 0 { lastSeq[record.jobID] = record.seq }
    }

    /// The protocols read back when the tags start: every decoder with a running or degraded
    /// job on a radio, as the sidebar lists them. An IQ decoder's records tag nothing, and are
    /// read for its row's count.
    public static func backfillProtocols(
        _ manifests: [Leyline_V1_DecoderManifest], jobs: [Leyline_V1_Job]
    ) -> [String] {
        DecodingRow.rows(manifests, jobs: jobs).map(\.decoder)
    }

    /// Where the read-back starts, in nanoseconds since 1970 on the daemon's clock: a minute
    /// before the newest waterfall row of `capture`, dated through its anchor, so a daemon whose
    /// clock is not the Mac's (`leylined --wall-clock`) still answers the last minute; `now` less
    /// a minute when the capture has no anchor or no row yet.
    public static func backfillSinceNs(
        capture: Leyline_V1_Capture?, rows: ClippedRows, now: Date
    ) -> Int64 {
        var end = now
        if let cap = capture, cap.hasAnchor,
            let sample = rows.newestSample(captureID: cap.captureID),
            let d = SampleClock.wallTime(
                of: .with {
                    $0.captureID = cap.captureID
                    $0.sampleIndex = sample
                }, anchor: cap.anchor)
        {
            end = d
        }
        return Int64((end.timeIntervalSince1970 - backfillSeconds) * 1e9)
    }

    /// A record read back with `QueryRecords` when the tags start, with where it goes: its
    /// frequency (`frequency(of:)`), the row its time fell in (`ClippedRows.row(atSample:)`, as
    /// `rows` counts them: the row's index plus one) and its wall time.
    public struct Backfill: Sendable, Equatable {
        public var record: Leyline_V1_DecodeRecord
        public var display: Leyline_V1_DecoderDisplay?
        public var frequencyHz: UInt64
        public var row: Int
        public var at: Date

        public init(
            record: Leyline_V1_DecodeRecord, display: Leyline_V1_DecoderDisplay?,
            frequencyHz: UInt64, row: Int, at: Date
        ) {
            self.record = record
            self.display = display
            self.frequencyHz = frequencyHz
            self.row = row
            self.at = at
        }
    }

    /// Tags the records of the last minute on `captureID`'s rows, oldest first, and says how many
    /// it tagged: each on the row its time fell in, under the same rules as a live record (no
    /// two tags of one transmitter within `repeatSeconds`, by the records' times, whichever came
    /// first; `limit` at most, the oldest dropped). A record already tagged, live or by an
    /// earlier read, is not tagged twice. The tags stay newest row first.
    @discardableResult
    public mutating func backfill(_ items: [Backfill], captureID: String) -> Int {
        var added = 0
        for item in items.sorted(by: { ($0.at, $0.row) < ($1.at, $1.row) }) {
            let r = item.record
            hold(r)
            guard !tags.contains(where: { $0.id == r.recordID }),
                let named = naming(r, display: item.display, onlyIfUnnamed: true)
            else { continue }
            let transmitter = named.transmitter
            let near = { (d: Date) in abs(d.timeIntervalSince(item.at)) < Self.repeatSeconds }
            if tags.contains(where: { $0.transmitter == transmitter && near($0.at) })
                || lastTagged[transmitter].map(near) == true
            {
                continue
            }
            lastTagged[transmitter] = max(lastTagged[transmitter] ?? item.at, item.at)
            tags.append(
                WaterfallTag(
                    id: r.recordID, transmitter: transmitter, name: named.name,
                    frequencyHz: item.frequencyHz, captureID: captureID, row: item.row,
                    at: item.at))
            added += 1
        }
        guard added > 0 else { return 0 }
        // Newest row first, as live tags are inserted; of one row, the later record first.
        tags.sort { ($0.row, $0.at) > ($1.row, $1.at) }
        if tags.count > Self.limit { tags.removeLast(tags.count - Self.limit) }
        return added
    }

    /// A record's transmitter, the rate limit's key, and the name its tag shows: the display's
    /// `entity_name` over the record, else the name it last rendered for the transmitter, else
    /// the `device_id`; nil when there is none. A fresh rendering is remembered, except a record
    /// read back (`onlyIfUnnamed`) does not replace a name a newer one gave.
    private mutating func naming(
        _ record: Leyline_V1_DecodeRecord, display: Leyline_V1_DecoderDisplay?,
        onlyIfUnnamed: Bool = false
    ) -> (transmitter: String, name: String)? {
        let key = record.protocol + "\u{0}" + record.deviceID
        let rendered = DisplayTemplate.entityName(display, record: record)
        let fresh = !rendered.isEmpty && rendered != record.deviceID
        if fresh, !onlyIfUnnamed || names[key] == nil {
            if names.count >= Self.namesLimit, names[key] == nil { names.removeAll() }
            names[key] = rendered
        }
        let name = fresh ? rendered : names[key] ?? record.deviceID
        guard !name.isEmpty else { return nil }
        let transmitter = record.deviceID.isEmpty ? record.protocol + "\u{0}" + name : key
        return (transmitter, name)
    }

    /// The tags still on the waterfall once it has written `rows` rows of `captureID` and shows
    /// `horizon` of them, newest first: a tag goes with its row, once its age reaches the
    /// horizon, and with its capture, whose rows the waterfall no longer holds. A tag whose row
    /// is newer than the rows written belongs to rows that were started over.
    public func shown(rows: Int, horizon: Int, captureID: String?) -> [WaterfallTag] {
        tags.filter { t in
            let age = t.age(rows: rows)
            return t.captureID == captureID && age >= 0 && age < horizon
        }
    }

    /// Drops every tag `shown` would leave out.
    public mutating func expire(rows: Int, horizon: Int, captureID: String?) {
        let kept = shown(rows: rows, horizon: horizon, captureID: captureID)
        if kept.count != tags.count { tags = kept }
    }

    /// Forgets every tag, when each transmitter was last tagged and the jobs' counts: the names
    /// are switched off, or the waterfall's rows started over.
    public mutating func removeAll() {
        tags = []
        lastTagged = [:]
        lastSeq = [:]
    }
}
