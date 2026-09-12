// SPDX-License-Identifier: GPL-3.0-or-later

// Stateless predicate evaluation (docs/design/decoders.md, "Predicates and delivery"): a record is
// judged by AND over the predicate's clauses before it reaches the hub, the store and the notifier.
// An empty predicate matches every record, which is what `ley decode` uses; `ley watch` sets one so
// a trigger fires with no client connected. Nothing here keeps state -- a clause sees one record.

import Foundation
import LeylineProto

/// A field resolved off a record: its text form and, when it parses as one, its numeric form. A
/// field that is not present on the record resolves to nil, which is how EXISTS and the comparisons
/// tell "missing" from "empty".
private struct Resolved {
    let text: String
    let number: Double?
}

/// True when the record satisfies the predicate. Empty predicate (no clauses) is true.
func matches(_ record: Leyline_V1_DecodeRecord, _ predicate: Leyline_V1_Predicate) -> Bool {
    for clause in predicate.all where !matches(record, clause) { return false }
    return true
}

private func matches(_ record: Leyline_V1_DecodeRecord, _ clause: Leyline_V1_Clause) -> Bool {
    switch clause.test {
    case .field(let test): return matches(record, test)
    case .geo(let test): return matches(record, test)
    case .none: return true  // an empty clause constrains nothing
    }
}

// MARK: Geo

private func matches(_ record: Leyline_V1_DecodeRecord, _ test: Leyline_V1_GeoTest) -> Bool {
    // A record with no position never matches a geo test (the design doc).
    guard record.hasPosition, test.radiusM > 0 else { return false }
    return haversineMetres(test.center, record.position) <= test.radiusM
}

// MARK: Field tests

private func matches(_ record: Leyline_V1_DecodeRecord, _ test: Leyline_V1_FieldTest) -> Bool {
    let have = resolve(record, test.field)
    switch test.op {
    case .predExists:
        // Present and non-empty; `values` is ignored.
        return have.map { !$0.text.isEmpty } ?? false
    case .predEq, .predNe:
        guard let have, let want = test.values.first else { return false }
        let equal = compareEqual(have, fieldValue: want)
        return test.op == .predEq ? equal : !equal
    case .predLt, .predLte, .predGt, .predGte:
        // Numeric-only, and false on anything that is not a number on either side.
        guard let have, let haveNum = have.number,
              let want = test.values.first, let wantNum = numberForm(want) else { return false }
        switch test.op {
        case .predLt: return haveNum < wantNum
        case .predLte: return haveNum <= wantNum
        case .predGt: return haveNum > wantNum
        case .predGte: return haveNum >= wantNum
        default: return false
        }
    case .predIn, .predNotIn:
        guard let have else { return test.op == .predNotIn }
        let member = test.values.contains { valueMatchesText(have, $0) }
        return test.op == .predIn ? member : !member
    case .predContains:
        // The field is a delimited list (a SAME FIPS list "006001-006013" or "006001 006013");
        // split it and match a whole token against one of `values`.
        guard let have else { return false }
        let tokens = tokenise(have.text)
        return test.values.contains { want in tokens.contains(normalise(textForm(want))) }
    case .unspecified, .UNRECOGNIZED:
        return false
    }
}

// MARK: Field resolution

/// Promoted names map to the record's own fields; `position.*` to the position; everything else is a
/// key in the open `fields` map (docs/design/decoders.md, record model). Empty promoted strings and
/// an absent position both resolve to nil so EXISTS and the comparisons see "missing", not "empty".
private func resolve(_ record: Leyline_V1_DecodeRecord, _ name: String) -> Resolved? {
    switch name {
    case "protocol": return promoted(record.protocol)
    case "device_id": return promoted(record.deviceID)
    case "kind": return promoted(record.kind)
    case "record_id": return promoted(record.recordID)
    case "position.latitude": return record.hasPosition ? numeric(record.position.latitude) : nil
    case "position.longitude": return record.hasPosition ? numeric(record.position.longitude) : nil
    case "position.altitude_m":
        return record.hasPosition && record.position.hasAltitudeM ? numeric(record.position.altitudeM) : nil
    default:
        guard let value = record.fields[name] else { return nil }
        return Resolved(text: textForm(value), number: numberForm(value))
    }
}

private func promoted(_ s: String) -> Resolved? {
    s.isEmpty ? nil : Resolved(text: s, number: Double(s))
}

private func numeric(_ d: Double) -> Resolved {
    Resolved(text: formatNumber(d), number: d)
}

// MARK: FieldValue helpers -- a value's text form and its number form (nil when not numeric)

func textForm(_ v: Leyline_V1_FieldValue) -> String {
    switch v.value {
    case .text(let s): return s
    case .integer(let i): return String(i)
    case .number(let d): return formatNumber(d)
    case .flag(let b): return b ? "true" : "false"
    case .data(let d): return d.map { String(format: "%02x", $0) }.joined()
    case .none: return ""
    }
}

func numberForm(_ v: Leyline_V1_FieldValue) -> Double? {
    switch v.value {
    case .integer(let i): return Double(i)
    case .number(let d): return d
    case .text(let s): return Double(s)
    case .flag, .data, .none: return nil
    }
}

/// EQ/NE: numeric when both sides parse as numbers, else a normalised text compare.
private func compareEqual(_ have: Resolved, fieldValue want: Leyline_V1_FieldValue) -> Bool {
    if let a = have.number, let b = numberForm(want) { return a == b }
    return normalise(have.text) == normalise(textForm(want))
}

private func valueMatchesText(_ have: Resolved, _ want: Leyline_V1_FieldValue) -> Bool {
    if let a = have.number, let b = numberForm(want) { return a == b }
    return normalise(have.text) == normalise(textForm(want))
}

/// Whole-number doubles print without a trailing ".0" so "006001" round-trips and 5000.0 reads 5000.
private func formatNumber(_ d: Double) -> String {
    if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
    return String(d)
}

/// Membership and CONTAINS compare case-folded and trimmed: FIPS codes are digits, callsigns are
/// upper, and neither should turn on surrounding space or case.
private func normalise(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespaces).lowercased()
}

/// A delimited list split on comma, space and '-', so "006001-006013" and "006001 006013" both
/// yield ["006001", "006013"] (docs/design/decoders.md: SAME's FIPS county list).
private func tokenise(_ s: String) -> [String] {
    s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "-" })
        .map { normalise(String($0)) }
        .filter { !$0.isEmpty }
}
