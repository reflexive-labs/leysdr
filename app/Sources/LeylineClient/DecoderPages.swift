// SPDX-License-Identifier: Apache-2.0

// The Decoders place's rules, held here so the Linux tests reach them: which decoders the
// sidebar lists and which jobs run under each, which tabs a decoder's page shows, the record log
// the page keeps (history then live, deduplicated by `record_id`), the alerts in effect, and the
// inspector's words for a record's fields. Everything is drawn from the manifest and the records,
// never from a decoder's name (docs/plans/decoders-app.md, "Decisions": nothing is special-cased
// by decoder), so a decoder added later shows with no app change.

import Foundation
import LeylineProto

/// A tab of a decoder's page.
public enum DecoderTab: String, Sendable, CaseIterable, Identifiable, Codable {
    case log, table, map

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .log: "Log"
        case .table: "Table"
        case .map: "Map"
        }
    }

    /// The tabs a page shows: the log always, the table for a decoder that declares
    /// `SHAPE_ENTITIES`, the map once any record it holds carries a position.
    public static func available(
        _ manifest: Leyline_V1_DecoderManifest, anyPosition: Bool
    ) -> [DecoderTab] {
        var tabs: [DecoderTab] = [.log]
        if manifest.outputs.contains(.shapeEntities) { tabs.append(.table) }
        if anyPosition { tabs.append(.map) }
        return tabs
    }
}

public enum DecoderPages {
    /// How far back the page's history reaches: `QueryRecords` over the last day.
    public static let historySeconds: TimeInterval = 24 * 3600
    /// How many records the page keeps, newest first; the daemon's own query limit.
    public static let logLimit = 1000

    /// The decoders the sidebar lists: every installed one, in the order `ListDecoders` gave,
    /// except a second manifest of the same name (a scripted speech engine beside the real one).
    public static func listed(_ manifests: [Leyline_V1_DecoderManifest])
        -> [Leyline_V1_DecoderManifest]
    {
        var seen: Set<String> = []
        return manifests.filter { seen.insert($0.name).inserted }
    }

    /// The decoder's title: the display's, else its name.
    public static func title(_ m: Leyline_V1_DecoderManifest) -> String {
        m.display.title.isEmpty ? m.name : m.display.title
    }

    /// The decoder's SF Symbol: the display's, else a generic one.
    public static func symbol(_ m: Leyline_V1_DecoderManifest) -> String {
        m.display.symbol.isEmpty ? "dot.radiowaves.left.and.right" : m.display.symbol
    }

    /// The decode jobs of a decoder that read a radio, newest first: by its name or one of its
    /// aliases, and not a transcription of a recording (`source_uri` set), which the Library shows.
    public static func jobs(of m: Leyline_V1_DecoderManifest, in jobs: [Leyline_V1_Job])
        -> [Leyline_V1_Job]
    {
        jobs.filter { j in
            guard case .decode(let d)? = j.config, d.sourceUri.isEmpty else { return false }
            return d.decoder == m.name || m.aliases.contains(d.decoder)
        }
        .sorted { $0.jobID > $1.jobID }
    }

    /// The running or degraded ones of those.
    public static func running(of m: Leyline_V1_DecoderManifest, in jobs: [Leyline_V1_Job])
        -> [Leyline_V1_Job]
    {
        Self.jobs(of: m, in: jobs).filter { isLive($0) }
    }

    public static func isLive(_ j: Leyline_V1_Job) -> Bool {
        j.state == .running || j.state == .degraded
    }

    /// A job's state as one word: `Running`, `Degraded`, `Stopped`, `Failed`, `Finished`.
    public static func stateWord(_ j: Leyline_V1_Job) -> String {
        switch j.state {
        case .running: "Running"
        case .degraded: "Degraded"
        case .cancelled: "Stopped"
        case .failed: "Failed"
        case .completed: "Finished"
        default: "Starting"
        }
    }

    /// The line beside a job's state: its `status_detail` ("12 records, last 3 s ago", "the
    /// capture moved away…"), else, for a failed job, the daemon's reason.
    public static func detail(_ j: Leyline_V1_Job) -> String {
        if !j.statusDetail.isEmpty { return j.statusDetail }
        if j.state == .failed, j.hasError { return j.error.message }
        return ""
    }

    /// The frequency a decode job listens on, from its config; 0 when it names none.
    public static func frequencyHz(_ j: Leyline_V1_Job) -> UInt64 {
        if case .decode(let d)? = j.config { return d.frequencyHz }
        return 0
    }

    /// Whether a record's `validity` window holds `now`: a start of 0 is from receipt, an end of
    /// 0 has no end.
    public static func inEffect(_ r: Leyline_V1_DecodeRecord, now: Date) -> Bool {
        guard r.hasValidity else { return false }
        let ns = Int64(now.timeIntervalSince1970 * 1e9)
        let v = r.validity
        return (v.startNs == 0 || v.startNs <= ns) && (v.endNs == 0 || ns < v.endNs)
    }

    /// The alerts in effect among the page's records, newest first: one per `device_id` and
    /// kind and summary, since a station repeats an alert it is still sending.
    public static func alerts(
        _ entries: [RecordEntry], display: Leyline_V1_DecoderDisplay?, now: Date
    ) -> [RecordEntry] {
        var seen: Set<String> = []
        return entries.filter { e in
            guard inEffect(e.record, now: now) else { return false }
            let key = [
                e.record.deviceID, e.record.kind,
                DisplayTemplate.summary(display, record: e.record),
            ].joined(separator: "\u{0}")
            return seen.insert(key).inserted
        }
    }

    /// When an alert's window ends, as the page says it: `until 14:30`, or nil without an end.
    public static func untilWords(_ r: Leyline_V1_DecodeRecord, timeZone: TimeZone = .current)
        -> String?
    {
        guard r.hasValidity, r.validity.endNs > 0 else { return nil }
        let end = Date(timeIntervalSince1970: Double(r.validity.endNs) / 1e9)
        return "until " + clock(end, seconds: false, timeZone: timeZone)
    }

    /// `14:03:20`, or `14:03` without seconds, in the given time zone.
    public static func clock(_ d: Date, seconds: Bool = true, timeZone: TimeZone = .current)
        -> String
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .second], from: d)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return seconds ? hm + String(format: ":%02d", c.second ?? 0) : hm
    }

    /// How long ago, coarsened the way a person says it: `now`, `12 s`, `4 min`, `3 h`, `2 d`.
    public static func ageWords(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 2 { return "now" }
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3600) h" }
        return "\(s / 86_400) d"
    }

    /// A raw payload as hex, sixteen bytes a line in pairs: `8d 48 40 d6 20 2c …`.
    public static func hexLines(_ d: Data) -> [String] {
        let bytes = Array(d)
        return stride(from: 0, to: bytes.count, by: 16).map { start in
            bytes[start..<min(start + 16, bytes.count)]
                .map { DisplayTemplate.hex(Data([$0])) }.joined(separator: " ")
        }
    }

    /// A display column's header as `ley track` writes it: a field with a unit is named with the
    /// unit in brackets and the unit suffix its name carries dropped (`sog_kn` in kn is `SOG
    /// (kn)`); otherwise the name, upper case, words split at underscores.
    public static func columnHead(_ name: String, manifest: Leyline_V1_DecoderManifest) -> String {
        let word = { (s: String) in s.replacingOccurrences(of: "_", with: " ").uppercased() }
        guard let hint = manifest.fields.first(where: { $0.name == name }), !hint.unit.isEmpty
        else { return word(name) }
        var base = name
        if let i = name.lastIndex(of: "_"), i > name.startIndex { base = String(name[..<i]) }
        return word(base) + " (" + unitWords(hint.unit) + ")"
    }

    /// Whether a column holds numbers, so it is set flush right.
    public static func columnIsNumeric(_ name: String, manifest: Leyline_V1_DecoderManifest)
        -> Bool
    {
        guard let hint = manifest.fields.first(where: { $0.name == name }) else { return false }
        return hint.type == .number || hint.type == .integer
    }

    /// A hint's unit as a person writes it: `deg` is `°` and `degC` is `°C`; the rest as given.
    public static func unitWords(_ unit: String) -> String {
        switch unit {
        case "deg": "°"
        case "degC": "°C"
        default: unit
        }
    }

    /// One field of the inspector: the field's name, its value with the hint's unit, and the
    /// hint's description.
    public struct FieldRow: Sendable, Equatable, Identifiable {
        public var name: String
        public var value: String
        public var description: String
        public var id: String { name }
    }

    /// A record's fields for the inspector: those the manifest hints in its order first, then the
    /// rest by name; a field that does not print (an empty text, a false flag) is left out. A
    /// number keeps up to `DisplayTemplate.maxDecimals` decimals, because the inspector is where
    /// the whole value is read.
    public static func fieldRows(
        _ fields: [String: Leyline_V1_FieldValue], manifest: Leyline_V1_DecoderManifest
    ) -> [FieldRow] {
        let hinted = manifest.fields.map(\.name)
        let rest = fields.keys.filter { !hinted.contains($0) }.sorted()
        return (hinted.filter { fields[$0] != nil } + rest).compactMap { name in
            guard
                let v = DisplayTemplate.formatField(
                    name, fields[name], decimals: DisplayTemplate.maxDecimals)
            else { return nil }
            let hint = manifest.fields.first { $0.name == name }
            let unit = hint.map { unitWords($0.unit) } ?? ""
            let value: String
            if unit.isEmpty {
                value = v
            } else if unit.hasPrefix("°") || unit == "%" {
                value = v + unit
            } else {
                value = v + " " + unit
            }
            return FieldRow(name: name, value: value, description: hint?.description_p ?? "")
        }
    }

    /// The signal line under a record: `-42.1 dBFS · 18.0 dB SNR`, the parts the daemon
    /// measured; nil when it measured neither.
    public static func signalWords(_ r: Leyline_V1_DecodeRecord) -> String? {
        var parts: [String] = []
        if r.rssiDbfs.isFinite { parts.append(String(format: "%.1f dBFS", r.rssiDbfs)) }
        if r.snrDb.isFinite { parts.append(String(format: "%.1f dB SNR", r.snrDb)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One record on a decoder's page, with the wall time it is shown at: its own, through the
/// anchor of the capture it was decoded on, else when it reached the window.
public struct RecordEntry: Sendable, Equatable, Identifiable {
    public var record: Leyline_V1_DecodeRecord
    public var at: Date
    /// Whether `at` came from an anchor rather than the window's own clock.
    public var dated: Bool

    public var id: String { record.recordID }

    public init(record: Leyline_V1_DecodeRecord, at: Date, dated: Bool) {
        self.record = record
        self.at = at
        self.dated = dated
    }
}

/// A decoder page's records, newest first, each once by `record_id`: the history read with
/// `QueryRecords` and the records `SubscribeRecords` delivers after it, in whichever order the
/// two arrive, because the subscription opens before the history lands so nothing falls between.
public struct RecordLog: Sendable, Equatable {
    public private(set) var entries: [RecordEntry] = []
    private var ids: Set<String> = []
    public let limit: Int

    public init(limit: Int = DecoderPages.logLimit) { self.limit = limit }

    /// Adds records not already held, keeps the newest first (ties by `seq`, newest first), and
    /// drops the oldest past `limit`. Returns the entries that were new, in the order given.
    @discardableResult
    public mutating func insert(_ new: [RecordEntry]) -> [RecordEntry] {
        let fresh = new.filter { !$0.record.recordID.isEmpty && !ids.contains($0.record.recordID) }
        guard !fresh.isEmpty else { return [] }
        var added: [RecordEntry] = []
        for e in fresh where ids.insert(e.record.recordID).inserted { added.append(e) }
        entries.append(contentsOf: added)
        entries.sort {
            $0.at != $1.at ? $0.at > $1.at : $0.record.seq > $1.record.seq
        }
        if entries.count > limit {
            for gone in entries[limit...] { ids.remove(gone.record.recordID) }
            entries.removeLast(entries.count - limit)
        }
        return added
    }

    public var anyPosition: Bool { entries.contains { $0.record.hasPosition } }
}

extension RecordEntry {
    /// A record dated through the page's anchors (`RecordPage.anchors`): the newest anchor on its
    /// capture whose `from_sample` is not past it, else `fallback` and undated.
    public static func dated(
        _ r: Leyline_V1_DecodeRecord, anchors: [Leyline_V1_RecordAnchor], fallback: Date
    ) -> RecordEntry {
        let t = r.time
        // The newest that applies; of two from the same sample, the later listed, as Go's
        // `RecordWallTime` takes it.
        let best = anchors.reduce(nil as Leyline_V1_RecordAnchor?) { best, a in
            guard a.anchor.captureID == t.captureID, a.fromSample <= t.sampleIndex else {
                return best
            }
            return best.map { a.fromSample >= $0.fromSample ? a : $0 } ?? a
        }
        if r.hasTime, let a = best,
            let d = SampleClock.wallTime(of: t, anchor: a.anchor, fromSample: a.fromSample)
        {
            return RecordEntry(record: r, at: d, dated: true)
        }
        return RecordEntry(record: r, at: fallback, dated: false)
    }

    /// A live record dated through its capture's newest anchor, as the mirror holds it.
    public static func live(
        _ r: Leyline_V1_DecodeRecord, capture: Leyline_V1_Capture?, arrived: Date
    ) -> RecordEntry {
        if r.hasTime, let cap = capture, cap.hasAnchor,
            let d = SampleClock.wallTime(of: r.time, anchor: cap.anchor)
        {
            return RecordEntry(record: r, at: d, dated: true)
        }
        return RecordEntry(record: r, at: arrived, dated: false)
    }
}
