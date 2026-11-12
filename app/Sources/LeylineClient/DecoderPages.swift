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
    /// `SHAPE_ENTITIES`, and the map for a decoder whose display says it reports positions, or
    /// else once any record it holds carries one.
    public static func available(
        _ manifest: Leyline_V1_DecoderManifest, anyPosition: Bool
    ) -> [DecoderTab] {
        var tabs: [DecoderTab] = [.log]
        if manifest.outputs.contains(.shapeEntities) { tabs.append(.table) }
        if manifest.display.positions || anyPosition { tabs.append(.map) }
        return tabs
    }

    /// Whether a tab the page shows can be chosen: the map only once a record carries a position,
    /// so a decoder that reports positions shows it disabled until then
    /// (docs/plans/decoders-app.md, DA-25).
    public func enabled(anyPosition: Bool) -> Bool {
        self != .map || anyPosition
    }

    /// The tooltip of a disabled tab.
    public static let noPositions = "No positions yet"
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

    /// The plain runs of a decoder, newest first: its decode jobs that read a radio, by its name
    /// or one of its aliases, not a decode of a recording (`source_uri` set), which the Library
    /// shows, and not a watch (a predicate set, `Watches.watches`), which the sidebar lists on its
    /// own. Start and Stop concern these.
    public static func jobs(of m: Leyline_V1_DecoderManifest, in jobs: [Leyline_V1_Job])
        -> [Leyline_V1_Job]
    {
        jobs.filter { j in
            guard case .decode(let d)? = j.config, d.sourceUri.isEmpty, !d.hasPredicate else {
                return false
            }
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

    /// The header's red line under the placement sentence while no job runs: `Failed: <reason>`
    /// for the newest job when it failed, or nil when there is none or its reason is the
    /// placement sentence again, as when the daemon declined a job for the reason the page
    /// already gives. The two compare without a trailing full stop, which the sentence has.
    public static func failedLine(newest: Leyline_V1_Job?, placement: String) -> String? {
        guard let j = newest, j.state == .failed else { return nil }
        let reason = detail(j)
        func bare(_ s: String) -> Substring {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.hasSuffix(".") ? t.dropLast() : Substring(t)
        }
        if reason.isEmpty || bare(reason) == bare(placement) { return nil }
        return "Failed: \(reason)"
    }

    /// The log's words with no record in it: reading the history, listening while a job runs,
    /// else nothing heard, with the prompt to start only when Start can be pressed.
    public static func emptyLogWords(historyLoaded: Bool, listening: Bool, canStart: Bool)
        -> String
    {
        if !historyLoaded { return "Reading the last day's records…" }
        if listening { return "Listening. Nothing decoded yet." }
        return canStart
            ? "Nothing heard in the last day. Start the decoder to listen."
            : "Nothing heard in the last day."
    }

    /// The frequency a decode job listens on, from its config; 0 when it names none.
    public static func frequencyHz(_ j: Leyline_V1_Job) -> UInt64 {
        if case .decode(let d)? = j.config { return d.frequencyHz }
        return 0
    }

    /// The page header's line while a job runs: its state and frequency, `Running · 1090.000
    /// MHz`. Not its detail, which the sidebar's line under the decoder already shows.
    public static func headerWords(_ j: Leyline_V1_Job) -> String {
        let hz = frequencyHz(j)
        return [stateWord(j), hz > 0 ? frequencyWords(hz) : ""].filter { !$0.isEmpty }
            .joined(separator: " · ")
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

    /// `ageWords` as a sentence ends it: `12 s ago`, or `just now`.
    public static func agoWords(_ seconds: TimeInterval) -> String {
        let age = ageWords(seconds)
        return age == "now" ? "just now" : age + " ago"
    }

    /// How many of `hexLines` the inspector's open Raw group shows before "Show all": 64 bytes.
    public static let rawLinesShown = 8

    /// The hex lines the open Raw group shows: all of them, or with `all` false the first
    /// `rawLinesShown`, and whether some were left for "Show all".
    public static func rawShown(_ d: Data, all: Bool) -> (lines: [String], cut: Bool) {
        let lines = hexLines(d)
        guard !all, lines.count > rawLinesShown else { return (lines, false) }
        return (Array(lines.prefix(rawLinesShown)), true)
    }

    /// A raw payload as hex, eight bytes a line in pairs: `8d 48 40 d6 20 2c 5e 76`. Sixteen do
    /// not fit the inspector's width in its type, and a line that wraps splits a byte's row.
    public static func hexLines(_ d: Data) -> [String] {
        let bytes = Array(d)
        return stride(from: 0, to: bytes.count, by: 8).map { start in
            bytes[start..<min(start + 8, bytes.count)]
                .map { DisplayTemplate.hex(Data([$0])) }.joined(separator: " ")
        }
    }

    /// The transmitters in the order the table and the map list them: by the name shown, then by
    /// id. `ley track` prints the newest first, which suits one listing; on a live page the
    /// rows of a decoder heard many times a second (ADS-B) would change places every second,
    /// and VoiceOver's order through the map's markers with them. The Last heard column and
    /// the log still say who spoke last.
    public static func byName(
        _ rows: [DecoderEntity], name: (DecoderEntity) -> String
    ) -> [DecoderEntity] {
        rows.map { (name($0), $0) }.sorted { a, b in
            switch a.0.localizedStandardCompare(b.0) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.1.deviceID < b.1.deviceID
            }
        }.map(\.1)
    }

    /// The table's heads around the display's columns: the name first, then how often, when and
    /// the newest line. LATEST, not LAST, which beside LAST HEARD read as a second time.
    public static let tableNameHead = "TRANSMITTER"
    public static let tableSeenHead = "SEEN"
    public static let tableHeardHead = "LAST HEARD"
    public static let tableLatestHead = "LATEST"

    /// Every head of the table, left to right, as drawn: `tableNameHead`, each column's
    /// `columnHead`, then the seen, heard and latest heads.
    public static func tableHeads(_ columns: [String], manifest: Leyline_V1_DecoderManifest)
        -> [String]
    {
        [tableNameHead] + columns.map { columnHead($0, manifest: manifest) }
            + [tableSeenHead, tableHeardHead, tableLatestHead]
    }

    /// The display's columns as the app's table shows them: a column the name column already
    /// shows is left out, when the display names a transmitter by that one field
    /// (`entity_name` `[{callsign}]` and a `callsign` column), so the page's width goes to the
    /// columns that say something new. `ley track` keeps it, beside its DEVICE.
    public static func tableColumns(_ display: Leyline_V1_DecoderDisplay?) -> [String] {
        let columns = display?.columns ?? []
        guard let t = display?.entityName, let segments = DisplayTemplate.parse(t) else {
            return columns
        }
        var names: [String] = []
        for s in segments {
            switch s {
            case .name(let n, _): names.append(n)
            case .open, .close: continue
            case .text(let x): if !x.trimmingCharacters(in: .whitespaces).isEmpty { return columns }
            }
        }
        guard names.count == 1 else { return columns }
        return columns.filter { DisplayTemplate.columnName($0) != names[0] }
    }

    /// A display column's header as `ley track` writes it (testdata/decoders/head-cases.json):
    /// the hint's label in upper case, or else the field's name, upper case with words split at
    /// underscores and, when the hint has a unit, the unit suffix the name carries dropped; a
    /// hint's unit follows in brackets (`ground_speed_kn` labelled `Ground speed` in kn is
    /// `GROUND SPEED (kn)`, `sog_kn` with no label `SOG (kn)`). An entry's precision
    /// (`ground_speed_kn:0`) is not part of the head.
    public static func columnHead(_ entry: String, manifest: Leyline_V1_DecoderManifest) -> String {
        let name = DisplayTemplate.columnName(entry)
        let word = { (s: String) in s.replacingOccurrences(of: "_", with: " ").uppercased() }
        guard let hint = manifest.fields.first(where: { $0.name == name }) else {
            return word(name)
        }
        var head = hint.label.uppercased()
        if head.isEmpty {
            var base = name
            if !hint.unit.isEmpty, let i = name.lastIndex(of: "_"), i > name.startIndex {
                base = String(name[..<i])
            }
            head = word(base)
        }
        return hint.unit.isEmpty ? head : head + " (" + unitWords(hint.unit) + ")"
    }

    /// Whether a column holds numbers, so it is set flush right.
    public static func columnIsNumeric(_ entry: String, manifest: Leyline_V1_DecoderManifest)
        -> Bool
    {
        let name = DisplayTemplate.columnName(entry)
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

    /// One field of the inspector: the field's name, the label its row shows (the hint's, else
    /// the name), its value with the hint's unit, and the hint's description.
    public struct FieldRow: Sendable, Equatable, Identifiable {
        public var name: String
        public var label: String
        public var value: String
        public var description: String
        public var id: String { name }
    }

    /// A record's fields for the inspector: those the manifest hints in its order first, then the
    /// rest by name; a field that does not print (an empty text, a false flag) is left out. A
    /// number keeps up to `DisplayTemplate.maxDecimals` decimals, because the inspector is where
    /// the whole value is read. A field whose value as printed is the record's whole `summary`,
    /// the line above the fields (speech's `{text}`), is left out, so it is not read twice.
    public static func fieldRows(
        _ fields: [String: Leyline_V1_FieldValue], manifest: Leyline_V1_DecoderManifest,
        summary: String = ""
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
            if !summary.isEmpty, value == summary { return nil }
            let label = hint?.label ?? ""
            return FieldRow(
                name: name, label: label.isEmpty ? name : label, value: value,
                description: hint?.description_p ?? "")
        }
    }

    /// A transmitter's altitude in the inspector, given the promoted metres: in the decoder's own
    /// unit when it also sends a field named `altitude_<unit>` (ADS-B's `altitude_ft`, `36000 ft`),
    /// so it reads as the table and the summary do; else the metres (`124 m`). A field the
    /// manifest hints comes first, then by name; the unit is the hint's, else the name's suffix.
    public static func altitudeWords(
        metres: Double, fields: [String: Leyline_V1_FieldValue],
        manifest: Leyline_V1_DecoderManifest
    ) -> String? {
        let own = { (n: String) in n.hasPrefix("altitude_") && n != "altitude_m" }
        let hinted = manifest.fields.map(\.name).filter(own)
        let names = hinted + fields.keys.filter { own($0) && !hinted.contains($0) }.sorted()
        for name in names {
            guard let v = DisplayTemplate.formatField(name, fields[name], decimals: 0) else {
                continue
            }
            let hint = manifest.fields.first { $0.name == name }?.unit ?? ""
            let unit = hint.isEmpty ? String(name.dropFirst("altitude_".count)) : unitWords(hint)
            return "\(v) \(unit)"
        }
        return DisplayTemplate.formatNumber(metres, decimals: 0).map { "\($0) m" }
    }

    /// A frequency in a sentence of the Decoders place, always in MHz (`1090.000 MHz`,
    /// `462.6125 MHz`), so a sentence that names two frequencies names them in one unit; the
    /// placement's reason is written the same way. Below 1 MHz, the bookmark spelling.
    public static func frequencyWords(_ hz: UInt64) -> String {
        guard hz >= 1_000_000 else { return BookmarkNaming.frequencyWords(hz) }
        return String(format: hz % 1_000 == 500 ? "%.4f MHz" : "%.3f MHz", Double(hz) / 1e6)
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

    /// Whether the log holds the record now.
    public func holds(_ recordID: String) -> Bool { ids.contains(recordID) }
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
