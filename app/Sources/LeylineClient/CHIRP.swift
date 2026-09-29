// SPDX-License-Identifier: Apache-2.0

// CHIRP's CSV export read into bookmarks: how a ham's hundred repeaters reach the sidebar
// without being typed twice (docs/design/channels.md, "CHIRP import"). The mapping is the
// design's and `go/pkg/chirp` applies the same rules from `ley bookmarks import`; both are
// held to fixtures/chirp/sample.csv and expected.json, so a rule changed in one is a test
// failed in the other. `parse` turns the file into rows and `apply` files them through the
// store's own add-or-update, so the update semantics are the store's and a re-import never
// clears a value typed in the inspector. The CSV reader is here rather than a dependency
// because the format is small (RFC 4180, quoted fields with doubled quotes, CRLF or LF) and
// the plan forbids a new package for it.

import Foundation
import LeylineProto

public enum CHIRPError: Error, Equatable, Sendable {
    /// The header has no Frequency column: the file is not a CHIRP export, and nothing is
    /// imported rather than every row skipped.
    case noFrequencyColumn
}

public enum CHIRP {
    /// One memory as the bookmark it becomes. `name` may be blank, in which case `apply` names
    /// it. `hz` is the Frequency column (MHz) rounded to whole hertz. `mode` and `bandwidthHz`
    /// are CHIRP's Mode mapped: FM is NFM at 25 kHz and NFM is NFM at 12.5 kHz, since CHIRP's
    /// two are the same demodulator at two widths; AM, USB, LSB, CW and WFM are themselves at
    /// the mode's default width; anything else (DV, DN, P25, a digital mode ley does not
    /// decode) is the band's default mode and width, and `modeFromBand` says so. `tone` is the
    /// store's spelling, validated by `Tone.parse`, or empty. `warnings` are the fields that
    /// could not be taken as written, one sentence each, for the person: the row is still
    /// imported without them.
    public struct Row: Sendable, Hashable {
        public var line: Int
        public var name: String
        public var hz: UInt64
        public var mode: Leyline_V1_DemodMode
        public var bandwidthHz: UInt32
        public var modeFromBand = false
        public var tone = ""
        public var note = ""
        /// CHIRP's `+`, `-`, `split` or `off`, or empty for simplex. `offsetHz` is the signed
        /// offset in hertz under `+` and `-`; under `split` CHIRP's Offset column holds the
        /// transmit frequency itself, so it is that frequency minus `hz`. Under `off` and blank
        /// it is 0: CHIRP writes its 0.600000 default into the column of a simplex row too, so
        /// the column is only read when the duplex says it applies.
        public var duplex = ""
        public var offsetHz: Int64 = 0
        public var warnings: [String] = []

        public init(
            line: Int, name: String, hz: UInt64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32
        ) {
            self.line = line
            self.name = name
            self.hz = hz
            self.mode = mode
            self.bandwidthHz = bandwidthHz
        }

        fileprivate mutating func warn(_ sentence: String) { warnings.append(sentence) }
    }

    /// A row that became no bookmark, with the file line it was on and why; `Result.warnings`
    /// reuses the shape for a row's warning against its line.
    public struct Skipped: Sendable, Hashable {
        public var line: Int
        public var reason: String

        public init(line: Int, reason: String) {
            self.line = line
            self.reason = reason
        }
    }

    /// What `apply` did: the bookmarks it made, the ones it updated, the rows the store refused
    /// (a row `parse` produced is always nameable, so this is empty unless the store changes)
    /// and every row's warnings against its line. `skipped` is a `var` so the caller can fold
    /// the parse's skipped rows in before `summary`, which counts both as the verb does.
    public struct Result: Sendable, Hashable {
        public var added: [Bookmark] = []
        public var updated: [Bookmark] = []
        public var skipped: [Skipped] = []
        public var warnings: [Skipped] = []

        public init() {}
    }

    /// Reads a CHIRP CSV export. Columns are found by name in the header row, so the order does
    /// not matter and columns this version does not read are ignored. A row whose frequency is
    /// not a positive number is skipped, and everything else about a row is a warning on it.
    public static func parse(_ text: String) throws(CHIRPError) -> (rows: [Row], skipped: [Skipped])
    {
        var records = CSV.records(text)
        guard !records.isEmpty else { throw CHIRPError.noFrequencyColumn }
        let header = records.removeFirst()
        var columns: [String: Int] = [:]
        for (i, cell) in header.fields.enumerated() {
            // A BOM on the first cell is what a spreadsheet leaves when it re-saves the file.
            var name = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("\u{FEFF}") { name.removeFirst() }
            columns[name.lowercased()] = i
        }
        guard columns["frequency"] != nil else { throw CHIRPError.noFrequencyColumn }
        var rows: [Row] = []
        var skipped: [Skipped] = []
        for record in records {
            // A blank line, which a hand-edited export may end with.
            if record.fields.count == 1 && record.fields[0].isEmpty { continue }
            let field: (String) -> String = { name in
                guard let i = columns[name], i < record.fields.count else { return "" }
                return record.fields[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            do {
                rows.append(try parseRow(line: record.line, field: field))
            } catch {
                skipped.append(Skipped(line: record.line, reason: error.sentence))
            }
        }
        return (rows, skipped)
    }

    /// A row that is skipped, carrying the sentence rather than a case: the reasons are prose
    /// for the person and nothing switches on them.
    private struct SkipReason: Error {
        let sentence: String
    }

    private static func parseRow(line: Int, field: (String) -> String) throws(SkipReason) -> Row {
        let hz = try parseMHz(field("frequency"))
        let (mode, bandwidthHz, fromBand) = mapMode(field("mode"), hz: hz)
        var row = Row(line: line, name: field("name"), hz: hz, mode: mode, bandwidthHz: bandwidthHz)
        row.note = field("comment")
        row.modeFromBand = fromBand
        if fromBand {
            let what =
                Bands.band(containing: hz).map { "the \($0.name) band's default" }
                ?? "no band recognised"
            row.warn(
                "mode \"\(field("mode"))\" is not one ley decodes; kept as \(mode.wireName.lowercased()), \(what)"
            )
        }
        let (tone, spelled) = mapTone(field)
        if !tone.isEmpty {
            if (try? Tone.parse(tone)) == nil {
                row.warn("tone \"\(spelled)\" is not a CTCSS tone or a DCS code; left empty")
            } else {
                row.tone = tone
            }
        }
        mapDuplex(&row, duplex: field("duplex"), offset: field("offset"))
        return row
    }

    /// CHIRP's Frequency column, megahertz with six decimals, to whole hertz. A value the
    /// `UInt64` cannot hold is refused as not a number rather than converted (swift-style.md,
    /// rule 9); no export carries one.
    private static func parseMHz(_ s: String) throws(SkipReason) -> UInt64 {
        if s.isEmpty { throw SkipReason(sentence: "frequency is blank") }
        guard let mhz = Double(s), mhz.isFinite else {
            throw SkipReason(sentence: "frequency \"\(s)\" is not a number")
        }
        guard mhz > 0 else { throw SkipReason(sentence: "frequency \"\(s)\" is not above 0") }
        let hz = (mhz * 1e6).rounded()
        guard hz < 1.8e19 else { throw SkipReason(sentence: "frequency \"\(s)\" is not a number") }
        return UInt64(hz)
    }

    /// The Mode column as the design maps it; the third result says the band decided. Go's
    /// `mapMode`, with `BandwidthFor`'s rule inline: the band's width when the band's mode is
    /// the one chosen, else the mode's default.
    private static func mapMode(_ mode: String, hz: UInt64) -> (
        Leyline_V1_DemodMode, UInt32, Bool
    ) {
        let upper = mode.uppercased()
        switch upper {
        case "FM": return (.nfm, 25_000, false)
        case "NFM": return (.nfm, 12_500, false)
        case "AM", "USB", "LSB", "CW", "WFM":
            let m = Leyline_V1_DemodMode.named(upper) ?? .nfm
            return (m, m.defaultBandwidthHz, false)
        default:
            let m = Bands.defaultMode(at: hz)
            if let band = Bands.band(containing: hz), band.bandwidthHz > 0, band.mode(at: hz) == m {
                return (m, band.bandwidthHz, true)
            }
            return (m, m.defaultBandwidthHz, true)
        }
    }

    /// The tone the radio transmits, by the Tone column's mode: `Tone` takes rToneFreq, `TSQL`
    /// takes cToneFreq, `DTCS` takes DtcsCode with the transmit half of DtcsPolarity, `Cross`
    /// takes the transmit side of CrossMode (the part before `->`), and anything else has no
    /// tone. The second result is the column's own spelling, for the warning when the tone
    /// does not validate.
    private static func mapTone(_ field: (String) -> String) -> (tone: String, spelled: String) {
        func ctcss(_ column: String) -> (String, String) {
            let s = field(column)
            return (s, s)
        }
        func dcs() -> (String, String) {
            var code = field("dtcscode")
            if code.isEmpty { return ("", "") }
            // CHIRP writes the code as three digits and the polarity as two letters, transmit
            // then receive, N for normal and R for reversed; the store spells reversed as I.
            if code.count < 3 { code = String(repeating: "0", count: 3 - code.count) + code }
            let polarity = field("dtcspolarity")
            return ("D" + code + (polarity.hasPrefix("R") ? "I" : "N"), code + " " + polarity)
        }
        switch field("tone") {
        case "Tone": return ctcss("rtonefreq")
        case "TSQL": return ctcss("ctonefreq")
        case "DTCS": return dcs()
        case "Cross":
            let cross = field("crossmode")
            let transmit = cross.range(of: "->").map { String(cross[..<$0.lowerBound]) } ?? cross
            switch transmit {
            case "Tone": return ctcss("rtonefreq")
            case "DTCS": return dcs()
            default: return ("", "")
            }
        default: return ("", "")
        }
    }

    /// The Duplex and Offset columns into the row as `Row.duplex` describes.
    private static func mapDuplex(_ row: inout Row, duplex: String, offset: String) {
        switch duplex {
        case "":
            return
        case "off":
            row.duplex = duplex
            return
        case "+", "-", "split":
            break
        default:
            row.warn("duplex \"\(duplex)\" is not one of +, -, split or off; left empty")
            return
        }
        guard let mhz = Double(offset), mhz.isFinite, mhz >= 0, mhz * 1e6 < 9.2e18 else {
            row.warn("offset \"\(offset)\" is not a number; duplex \(duplex) left empty")
            return
        }
        let hz = Int64((mhz * 1e6).rounded())
        row.duplex = duplex
        switch duplex {
        case "-": row.offsetHz = -hz
        case "+": row.offsetHz = hz
        default: row.offsetHz = hz - Int64(clamping: row.hz)
        }
    }

    /// Files rows in the store through its add-or-update and saves nothing: the caller saves.
    /// `tag` joins every bookmark's tags, the file's basename without its extension, so `ley
    /// bookmarks --tag <file>` lists what one import filed. A row's name is its own when it has
    /// one, else the plan channel's radio-printed name when the frequency sits on one, else the
    /// frequency's words (`BookmarkNaming`, the plan's KTD7), so a blank name is never an empty
    /// row. The mode and width are always the row's (`add`'s rule); a tone and a note only when
    /// non-blank, a duplex and an offset only when the row has them, and the tag joins the set:
    /// a blank column never clears a value typed in the inspector. An unloaded store throws, as
    /// every mutator does; a row the store refuses is skipped with its reason.
    public static func apply(_ rows: [Row], to store: inout BookmarkStore, tag: String) throws
        -> Result
    {
        guard store.loaded else { throw BookmarkError.notLoaded(store.path) }
        var result = Result()
        for row in rows {
            var name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = BookmarkNaming.name(for: row.hz) }
            for warning in row.warnings {
                result.warnings.append(Skipped(line: row.line, reason: warning))
            }
            // The tone is checked before anything is written, as `go/pkg/bookmarks.Keep` checks
            // it, so a refused row leaves no half-updated bookmark behind.
            if !row.tone.isEmpty, (try? Tone.parse(row.tone)) == nil {
                result.skipped.append(Skipped(line: row.line, reason: ToneError.sentence))
                continue
            }
            let existed = store.bookmarks.values.contains { $0.hz == row.hz && $0.name == name }
            let kept: Bookmark
            do {
                var b = try store.add(
                    name: name, hz: row.hz, mode: row.mode, bandwidthHz: row.bandwidthHz)
                if !row.tone.isEmpty { b = try store.setTone(b.id, to: row.tone) }
                if !row.note.isEmpty { b = try store.setNote(b.id, to: row.note) }
                if !tag.isEmpty { b = try store.addTags(b.id, [tag]) }
                if !row.duplex.isEmpty || row.offsetHz != 0 {
                    b = try store.setDuplex(
                        b.id, row.duplex.isEmpty ? nil : row.duplex,
                        offsetHz: row.offsetHz == 0 ? nil : row.offsetHz)
                }
                kept = b
            } catch BookmarkError.emptyName {
                result.skipped.append(Skipped(line: row.line, reason: "a bookmark needs a name"))
                continue
            } catch BookmarkError.unspecifiedMode {
                result.skipped.append(Skipped(line: row.line, reason: "a bookmark needs a mode"))
                continue
            }
            if existed {
                result.updated.append(kept)
            } else {
                result.added.append(kept)
            }
        }
        return result
    }

    /// The verb's summary line, word for word (`go/internal/cli/bookmarks.go`, `import`):
    /// `Imported 9 from sample.csv: 8 added, 1 updated, 1 skipped`.
    public static func summary(_ r: Result, file: String) -> String {
        "Imported \(r.added.count + r.updated.count) from \(file): \(r.added.count) added, "
            + "\(r.updated.count) updated, \(r.skipped.count) skipped"
    }

    /// The app's sentence for `noFrequencyColumn`.
    public static func refusalWords(file: String) -> String {
        "\(file) has no Frequency column; is it a CHIRP CSV export?"
    }
}

/// The CSV reader `CHIRP.parse` uses: RFC 4180 with the leniencies Go's `encoding/csv` has
/// under `LazyQuotes`, since that is what `ley bookmarks import` reads with. A quoted field may
/// hold commas, newlines and doubled quotes; a quote inside an unquoted field is a character; a
/// lone quote inside a quoted field that is not followed by a comma or a line end is a
/// character too. CRLF and LF both end a record, an empty line is no record, and each record
/// carries the 1-based line it started on, for the skipped and warning lines.
enum CSV {
    struct Record: Equatable {
        var line: Int
        var fields: [String]
    }

    static func records(_ text: String) -> [Record] {
        // Bytes, not characters: every delimiter is ASCII, so scanning UTF-8 never splits a
        // scalar, and a field is decoded once at its end.
        let bytes = Array(text.utf8)
        let quote = UInt8(ascii: "\"")
        let comma = UInt8(ascii: ",")
        let lf = UInt8(ascii: "\n")
        let cr = UInt8(ascii: "\r")
        var records: [Record] = []
        var fields: [String] = []
        var field: [UInt8] = []
        var line = 1
        var recordLine = 1
        var quoted = false
        // Whether the current field opened with a quote, so `""` alone is a field, not a blank
        // line.
        var sawQuote = false
        var i = 0

        func endField() {
            fields.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            sawQuote = false
        }
        func endRecord() {
            // A record with nothing in it is a blank line, which is no record at all.
            if !fields.isEmpty || !field.isEmpty || sawQuote {
                endField()
                records.append(Record(line: recordLine, fields: fields))
                fields.removeAll()
            }
            recordLine = line
        }

        while i < bytes.count {
            let b = bytes[i]
            if quoted {
                if b == quote {
                    let next = i + 1 < bytes.count ? bytes[i + 1] : nil
                    if next == quote {
                        field.append(quote)
                        i += 2
                        continue
                    }
                    if next == nil || next == comma || next == lf
                        || (next == cr && i + 2 < bytes.count && bytes[i + 2] == lf)
                    {
                        quoted = false
                        i += 1
                        continue
                    }
                    field.append(quote)  // lazy: a bare quote inside a quoted field
                } else {
                    if b == lf { line += 1 }
                    if b == cr, i + 1 < bytes.count, bytes[i + 1] == lf {
                        i += 1
                        continue
                    }
                    field.append(b)
                }
                i += 1
                continue
            }
            switch b {
            case quote where field.isEmpty && !sawQuote:
                quoted = true
                sawQuote = true
            case comma:
                endField()
            case lf:
                line += 1
                endRecord()
            case cr where i + 1 < bytes.count && bytes[i + 1] == lf:
                i += 1
                line += 1
                endRecord()
            default:
                field.append(b)
            }
            i += 1
        }
        if !fields.isEmpty || !field.isEmpty || sawQuote {
            endField()
            records.append(Record(line: recordLine, fields: fields))
        }
        return records
    }
}
