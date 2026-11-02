// SPDX-License-Identifier: Apache-2.0

// The display template language a manifest's `DecoderDisplay` is written in, the Swift port of
// `go/pkg/records/template.go`, and the line a client prints when no template renders, the port
// of `records.Summary` (`summary.go`). The rules are in proto/leyline/v1/decode.proto above
// `DecoderDisplay` and in docs/reference/writing-a-decoder.md, "Display";
// testdata/decoders/summary-cases.json pins them for both clients, so the app and `ley decode`
// print the same line for the same record. Presentation only: nothing is decoded here
// (AGENTS.md, invariant 2).

import Foundation
import LeylineProto

public enum DisplayTemplate {
    /// How many decimals a NUMBER keeps when its name carries no precision.
    public static let defaultDecimals = 2
    /// The largest precision `{name:N}` accepts.
    public static let maxDecimals = 6

    /// The line for one record under a decoder's display: the template for the record's kind,
    /// else the `""` template, else `RecordSummary.line`. A template that does not render gives
    /// way to that line too, so a manifest can only add to what a client prints. `label` is the
    /// person's name for the transmitter, empty when there is none.
    public static func summary(
        _ display: Leyline_V1_DecoderDisplay?, record: Leyline_V1_DecodeRecord, label: String = ""
    ) -> String {
        if let t = template(display, kind: record.kind),
            let line = render(t, record: record, label: label)
        {
            return line
        }
        return RecordSummary.line(record)
    }

    /// The template a display gives a kind: its own, else the default `""`.
    public static func template(_ display: Leyline_V1_DecoderDisplay?, kind: String) -> String? {
        guard let display else { return nil }
        return display.summaries[kind] ?? display.summaries[""]
    }

    /// Renders one template over one record; nil when the template is malformed, when a name
    /// outside an optional group did not resolve, or when the line is empty once trimmed.
    public static func render(
        _ template: String, record: Leyline_V1_DecodeRecord, label: String = ""
    ) -> String? {
        guard let segments = parse(template) else { return nil }
        var out = ""
        var group = ""
        var inGroup = false
        var groupOK = true
        for s in segments {
            switch s {
            case .open:
                inGroup = true
                groupOK = true
                group = ""
            case .close:
                if groupOK { out += group }
                inGroup = false
            case .text(let t):
                if inGroup { group += t } else { out += t }
            case .name(let name, let decimals):
                let v = resolve(record, label: label, name: name, decimals: decimals)
                if v == nil {
                    if !inGroup { return nil }
                    groupOK = false
                }
                if inGroup { group += v ?? "" } else { out += v ?? "" }
            }
        }
        let line = trimmed(out)
        return line.isEmpty ? nil : line
    }

    /// Whether a template parses: a malformed one in a manifest falls back on every record.
    public static func isValid(_ template: String) -> Bool { parse(template) != nil }

    /// A transmitter's name under a display: the `entity_name` template over the entity's record
    /// (the newest value of every field it has sent), else its `device_id`.
    public static func entityName(
        _ display: Leyline_V1_DecoderDisplay?, record: Leyline_V1_DecodeRecord, label: String = ""
    ) -> String {
        if let t = display?.entityName, !t.isEmpty,
            let name = render(t, record: record, label: label)
        {
            return name
        }
        return record.deviceID
    }

    /// One `columns` entry, `name` or `name:N`, as a template prints `{name}` or `{name:N}`: a
    /// cell of the transmitter table. Nil when the record has not sent it or the entry is
    /// malformed.
    public static func column(
        _ entry: String, record: Leyline_V1_DecodeRecord, label: String = ""
    ) -> String? {
        guard let (name, decimals) = parseName(entry) else { return nil }
        return resolve(record, label: label, name: name, decimals: decimals)
    }

    /// The field a `columns` entry names, its precision dropped: what the column is headed by.
    public static func columnName(_ entry: String) -> String {
        String(entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    /// Whether a `columns` entry parses: a name, then optionally a colon and a precision 0 to 6.
    public static func isValidColumn(_ entry: String) -> Bool { parseName(entry) != nil }

    // MARK: Parsing

    enum Segment: Equatable {
        case text(String)
        case name(String, decimals: Int)
        case open
        case close
    }

    /// Splits a template into literal text, names and group marks; nil when it is malformed. A
    /// backslash escapes the next `{`, `}`, `[`, `]` or `\`; any other character after one is
    /// malformed. Read by scalar, as Go reads bytes: every mark is ASCII.
    static func parse(_ template: String) -> [Segment]? {
        let s = Array(template.unicodeScalars)
        var segments: [Segment] = []
        var literal = String.UnicodeScalarView()
        func flush() {
            if !literal.isEmpty {
                segments.append(.text(String(literal)))
                literal = String.UnicodeScalarView()
            }
        }
        var inGroup = false
        var i = 0
        while i < s.count {
            let c = s[i]
            switch c {
            case "\\":
                guard i + 1 < s.count, "{}[]\\".unicodeScalars.contains(s[i + 1]) else {
                    return nil
                }
                literal.append(s[i + 1])
                i += 1
            case "{":
                guard let end = s[(i + 1)...].firstIndex(of: "}") else { return nil }
                var inner = String.UnicodeScalarView()
                inner.append(contentsOf: s[(i + 1)..<end])
                guard let (name, decimals) = parseName(String(inner)) else { return nil }
                flush()
                segments.append(.name(name, decimals: decimals))
                i = end
            case "}":
                return nil
            case "[":
                if inGroup { return nil }
                flush()
                segments.append(.open)
                inGroup = true
            case "]":
                if !inGroup { return nil }
                flush()
                segments.append(.close)
                inGroup = false
            default:
                literal.append(c)
            }
            i += 1
        }
        if inGroup { return nil }
        flush()
        return segments
    }

    /// `name` or `name:N`, N a precision from 0 to `maxDecimals`.
    static func parseName(_ s: String) -> (String, Int)? {
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        guard !name.isEmpty,
            !name.unicodeScalars.contains(where: { "{[]\\".unicodeScalars.contains($0) })
        else { return nil }
        guard parts.count == 2 else { return (name, defaultDecimals) }
        let spec = Array(parts[1].unicodeScalars)
        guard spec.count == 1, let d = Int(String(spec[0])), d >= 0, d <= maxDecimals else {
            return nil
        }
        return (name, d)
    }

    // MARK: Values

    /// One name's text: a promoted name first, then a field. Nil when it does not resolve.
    static func resolve(
        _ record: Leyline_V1_DecodeRecord, label: String, name: String, decimals: Int
    ) -> String? {
        switch name {
        case "device_id": return nonEmpty(sanitize(record.deviceID))
        case "kind": return nonEmpty(sanitize(record.kind))
        case "label": return nonEmpty(sanitize(label))
        case "position":
            guard record.hasPosition, record.position.latitude.isFinite,
                record.position.longitude.isFinite
            else { return nil }
            return formatPosition(record.position)
        case "altitude_m":
            guard record.hasPosition, record.position.hasAltitudeM else { return nil }
            return formatNumber(record.position.altitudeM, decimals: decimals)
        case "rssi_dbfs": return formatNumber(record.rssiDbfs, decimals: decimals)
        case "snr_db": return formatNumber(record.snrDb, decimals: decimals)
        default: return formatField(name, record.fields[name], decimals: decimals)
        }
    }

    /// A field's value as a template prints it: TEXT as sent with control characters as spaces,
    /// INTEGER in decimal, NUMBER with up to `decimals` decimals, FLAG as the field's name when
    /// true, DATA as hex. Nil for an absent field, empty text, a NaN or infinite number and a
    /// false flag.
    public static func formatField(
        _ name: String, _ value: Leyline_V1_FieldValue?, decimals: Int = defaultDecimals
    ) -> String? {
        switch value?.value {
        case .text(let t)?: return nonEmpty(sanitize(t))
        case .integer(let i)?: return String(i)
        case .number(let n)?: return formatNumber(n, decimals: decimals)
        case .flag(let f)?: return f ? name : nil
        case .data(let d)?: return d.isEmpty ? nil : hex(d)
        case nil: return nil
        }
    }

    /// A number with up to `decimals` decimals, trailing zeros and a bare point dropped, never
    /// `-0`: printf's `%.Nf`, which rounds the double itself as Go's `FormatFloat` does. Nil
    /// for NaN or infinity.
    public static func formatNumber(_ v: Double, decimals: Int = defaultDecimals) -> String? {
        guard v.isFinite else { return nil }
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    /// A position as a chart's axis writes it, degrees with the hemisphere letter, so a minus
    /// sign is never read as a range dash: `37.7600N 122.4200W` (`records.FormatPosition`).
    public static func formatPosition(_ p: Leyline_V1_Position) -> String {
        coordinate(p.latitude, "N", "S") + " " + coordinate(p.longitude, "E", "W")
    }

    /// One axis to four decimals with its letter; a value that rounds to zero takes the positive
    /// letter, so -0.00001 is `0.0000N`.
    private static func coordinate(_ v: Double, _ pos: String, _ neg: String) -> String {
        let s = String(format: "%.4f", abs(v))
        return v < 0 && s != "0.0000" ? s + neg : s + pos
    }

    /// Lower-case hex, as Go's `hex.EncodeToString`.
    public static func hex(_ d: Data) -> String {
        let digits = Array("0123456789abcdef".unicodeScalars)
        var out = String.UnicodeScalarView()
        for b in d {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(out)
    }

    /// Every control character (C0, DEL and C1, a newline and a tab among them) as one space, so
    /// a value cannot break the line it is printed in.
    static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            out.append(u.properties.generalCategory == .control ? " " : u)
        }
        return String(out)
    }

    /// Trimmed of Unicode whitespace at both ends, a no-break space included (Go's
    /// `strings.TrimSpace`).
    static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}

/// The line a client prints for a record no template renders, in the protocol's own terms: the
/// port of `records.Summary` (`go/pkg/records/summary.go`), so a decoder with no display, or a
/// record its template cannot render, reads in the app as it does in `ley decode`.
public enum RecordSummary {
    public static func line(_ r: Leyline_V1_DecodeRecord) -> String {
        switch r.kind {
        case "position", "object", "item": return position(r)
        case "weather": return weather(r)
        case "message": return message(r)
        case "status":
            return first(text(r, "text"), text(r, "status"), text(r, "comment"), raw(r))
        case "telemetry": return telemetry(r)
        default: break
        }
        if r.hasPosition { return position(r) }
        return first(text(r, "text"), text(r, "comment"), raw(r))
    }

    private static func position(_ r: Leyline_V1_DecodeRecord) -> String {
        var parts: [String] = []
        if r.hasPosition {
            parts.append(DisplayTemplate.formatPosition(r.position))
            if r.position.hasAltitudeM {
                parts.append(String(format: "%.0f m", r.position.altitudeM))
            }
        }
        let name = text(r, "object_name")
        if !name.isEmpty { parts.append(name) }
        let sym = text(r, "symbol")
        if !sym.isEmpty { parts.append(sym) }
        if let course = number(r, "course_deg") {
            if let speed = number(r, "speed_kmh") {
                parts.append(String(format: "%.0f km/h @ %.0f°", speed, course))
            } else {
                parts.append(String(format: "@ %.0f°", course))
            }
        }
        let comment = text(r, "comment")
        if !comment.isEmpty { parts.append(comment) }
        return parts.joined(separator: " ")
    }

    private static func weather(_ r: Leyline_V1_DecodeRecord) -> String {
        var parts: [String] = []
        if let v = number(r, "temp_c") { parts.append(String(format: "%.1f °C", v)) }
        if let v = number(r, "wind_kmh") {
            var wind = String(format: "wind %.0f km/h", v)
            if let dir = number(r, "wind_dir_deg") { wind += String(format: " @ %.0f°", dir) }
            parts.append(wind)
        }
        if let v = number(r, "gust_kmh") { parts.append(String(format: "gust %.0f km/h", v)) }
        if let v = number(r, "rain_mm_1h") { parts.append(String(format: "rain %.1f mm/h", v)) }
        if let v = number(r, "humidity_pct") {
            parts.append(String(format: "humidity %.0f%%", v))
        }
        if let v = number(r, "pressure_hpa") { parts.append(String(format: "%.1f hPa", v)) }
        return parts.isEmpty ? raw(r) : parts.joined(separator: " ")
    }

    private static func message(_ r: Leyline_V1_DecodeRecord) -> String {
        let to = text(r, "addressee")
        let body = text(r, "text")
        guard !to.isEmpty else { return first(body, raw(r)) }
        var line = "→ " + to
        if !body.isEmpty { line += ": " + body }
        let id = text(r, "msg_id")
        if !id.isEmpty { line += " {" + id + "}" }
        return line
    }

    private static func telemetry(_ r: Leyline_V1_DecodeRecord) -> String {
        var head = "T#"
        if let seq = integer(r, "seq") { head += String(format: "%03lld", seq) }
        var vals: [String] = []
        for name in ["a1", "a2", "a3", "a4", "a5"] {
            if let v = number(r, name) { vals.append(shortest(v)) }
        }
        let digital = text(r, "digital")
        if !digital.isEmpty { vals.append(digital) }
        if vals.isEmpty { return first(head, raw(r)) }
        return head + " " + vals.joined(separator: " ")
    }

    /// Go's `%g` for the values telemetry carries: a whole number without a point, else the
    /// shortest decimal that reads back as the same double.
    private static func shortest(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    static func text(_ r: Leyline_V1_DecodeRecord, _ name: String) -> String {
        if case .text(let t)? = r.fields[name]?.value { return t }
        return ""
    }

    /// A number as sent, or an integer widened to one.
    static func number(_ r: Leyline_V1_DecodeRecord, _ name: String) -> Double? {
        switch r.fields[name]?.value {
        case .number(let n)?: return n
        case .integer(let i)?: return Double(i)
        default: return nil
        }
    }

    /// An integer, or a whole number sent as a number.
    static func integer(_ r: Leyline_V1_DecodeRecord, _ name: String) -> Int64? {
        switch r.fields[name]?.value {
        case .integer(let i)?: return i
        case .number(let n)?:
            guard n.isFinite, n == n.rounded(.towardZero), abs(n) < 9.2e18 else { return nil }
            return Int64(n)
        default: return nil
        }
    }

    /// The payload as text, which every record keeps, with control bytes and undecodable bytes
    /// dropped: an AX.25 frame carries bytes no font has a glyph for.
    static func raw(_ r: Leyline_V1_DecodeRecord) -> String {
        let s = String(decoding: r.raw, as: UTF8.self)
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\u{FFFD}" { continue }
            if u.properties.generalCategory == .control, u != "\t" { continue }
            out.append(u)
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func first(_ vals: String...) -> String {
        vals.first { !$0.isEmpty } ?? ""
    }
}
