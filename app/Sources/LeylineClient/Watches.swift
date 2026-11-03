// SPDX-License-Identifier: Apache-2.0

// Watches (docs/plans/decoders-app.md, DA-10): a decode job whose `DecodeConfig` carries a
// predicate, which the daemon judges on every record before delivery, with a macOS notification
// as its notifier, so a match reaches the person with the app closed (docs/design/decoders.md,
// "Predicates and delivery"). The Notify Me… sheet builds the predicate as `ley watch` builds it
// from `--where`, `--county`, `--near` and `--radius`: the same parsing, the same clauses in the
// same order, pinned by testdata/decoders/watch-cases.json, which the Go test reads too. The
// sheet's fields come from the manifest's hints, never from a decoder's name: SAME's county is
// its `fips` field like any other.

import Foundation
import LeylineProto

public enum Watches {
    /// Why a filter could not be built, in words for the sheet.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    // MARK: The predicate, as `ley watch` builds it

    /// The filter `ley watch` sends for these flags (`buildPredicate` in go/internal/cli): each
    /// `where` token's clause, then one CONTAINS clause on `fips` for the counties, then the geo
    /// clause, ANDed. No clause is nil, which the daemon matches against everything.
    public static func predicate(
        where tokens: [String] = [], counties: [String] = [], near: String = "",
        radius: String = ""
    ) throws -> Leyline_V1_Predicate? {
        var clauses = try tokens.map(clause(where:))
        if !counties.isEmpty {
            let codes = try counties.map(countyFIPS)
            clauses.append(
                .with {
                    $0.field = .with {
                        $0.field = "fips"
                        $0.op = .predContains
                        $0.values = codes.map(text)
                    }
                })
        }
        switch (near.isEmpty, radius.isEmpty) {
        case (false, true):
            throw Refusal("A place needs a radius: give one, such as 10km.")
        case (true, false):
            throw Refusal(
                "A radius needs a place to measure from: give one, such as 37.76,-122.42.")
        case (false, false):
            let centre = try place(near)
            let metres = try distance(radius)
            clauses.append(
                .with {
                    $0.geo = .with {
                        $0.center = centre
                        $0.radiusM = metres
                    }
                })
        case (true, true):
            break
        }
        return clauses.isEmpty ? nil : .with { $0.all = clauses }
    }

    /// A `where` token's operator, its predicate op and whether its value is a number. Longest
    /// first, so `!=` is not read as `=`.
    static let operators: [(token: String, op: Leyline_V1_PredicateOp, number: Bool)] = [
        ("!=", .predNe, false),
        (">=", .predGte, true),
        ("<=", .predLte, true),
        ("~", .predContains, false),
        (">", .predGt, true),
        ("<", .predLt, true),
        ("=", .predEq, false),
    ]

    /// One `where` token, `field=value`, `field!=value`, `field~value`, `field>value` and the
    /// rest: the first operator found from the left splits it. A numeric operator carries its
    /// value as a number, the others as text, as `ley watch` sends them.
    static func clause(where token: String) throws -> Leyline_V1_Clause {
        let chars = Array(token)
        for i in chars.indices {
            let rest = String(chars[i...])
            for o in operators where rest.hasPrefix(o.token) {
                let field = String(chars[..<i])
                let value = String(rest.dropFirst(o.token.count))
                guard !field.isEmpty else { throw Refusal("Choose a field to test.") }
                guard !value.isEmpty else { throw Refusal("Give \(field) a value to match.") }
                var test = Leyline_V1_FieldTest()
                test.field = field
                test.op = o.op
                if o.number {
                    guard let n = Double(value), n.isFinite else {
                        throw Refusal("\(field) compares as a number, and \(value) is not one.")
                    }
                    test.values = [.with { $0.number = n }]
                } else {
                    test.values = [text(value)]
                }
                return .with { $0.field = test }
            }
        }
        throw Refusal("\(token) has no test in it, such as field=value.")
    }

    /// The five-digit FIPS code a SAME record's `fips` lists, from that code or the six-digit
    /// SAME code PSSCCC, whose first digit names a part of the county and is dropped.
    public static func countyFIPS(_ code: String) throws -> String {
        let c = code.trimmingCharacters(in: .whitespaces)
        let digits = !c.isEmpty && c.allSatisfy { ("0"..."9").contains($0) }
        if digits, c.count == 5 { return c }
        if digits, c.count == 6 { return String(c.dropFirst()) }
        throw Refusal(
            "\(code) is not a county code: give the five-digit FIPS code (06009) or the six-digit SAME code (006009)."
        )
    }

    /// `37.76,-122.42` as a position, as `ley watch --near` reads it.
    public static func place(_ s: String) throws -> Leyline_V1_Position {
        let parts = s.trimmingCharacters(in: .whitespaces).split(
            separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let refusal = Refusal("\(s) is not a latitude and longitude; try 37.76,-122.42.")
        guard parts.count == 2,
            let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
            let lon = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else { throw refusal }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else {
            throw Refusal(
                "\(s) is off the globe: latitude is -90 to 90 and longitude -180 to 180.")
        }
        return .with {
            $0.latitude = lat
            $0.longitude = lon
        }
    }

    /// The units a radius takes, longest suffix first so `nm` is not read as `m`.
    static let distanceUnits: [(suffix: String, metres: Double)] = [
        ("km", 1000), ("nm", 1852), ("mi", 1609.344), ("m", 1),
    ]

    /// A radius with its unit in metres: `10km`, `500m`, `5nm`, `3mi`. A bare number is refused,
    /// as `ley watch --radius` refuses it: ten could be metres or kilometres.
    public static func distance(_ s: String) throws -> Double {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        for u in distanceUnits where t.hasSuffix(u.suffix) {
            let number = t.dropLast(u.suffix.count).trimmingCharacters(in: .whitespaces)
            guard let n = Double(number), n > 0, n.isFinite else {
                throw Refusal("\(s) is not a distance; try 10km, 500m, 5nm or 3mi.")
            }
            return n * u.metres
        }
        throw Refusal("\(s) has no unit; a distance needs one: 10km, 500m, 5nm or 3mi.")
    }

    private static func text(_ s: String) -> Leyline_V1_FieldValue { .with { $0.text = s } }

    // MARK: The sheet

    /// What the sheet tests a field with, each written as a `where` operator.
    public enum Test: String, Sendable, CaseIterable, Identifiable {
        case equals, contains, above, below

        public var id: String { rawValue }
        /// The word the sheet's menu and the condition use.
        public var title: String {
            switch self {
            case .equals: "is"
            case .contains: "contains"
            case .above: "is over"
            case .below: "is under"
            }
        }
        var token: String {
            switch self {
            case .equals: "="
            case .contains: "~"
            case .above: ">"
            case .below: "<"
            }
        }
    }

    /// A field the sheet offers: its name, the label its pop-up shows, its type and the hint's
    /// description.
    public struct Field: Sendable, Equatable, Identifiable {
        public var name: String
        public var label: String
        public var type: Leyline_V1_FieldType
        public var description: String
        public var id: String { name }
    }

    /// What the promoted `device_id` reads as, in the sheet and in a condition's words.
    public static let deviceIDLabel = "Transmitter"

    /// The label a person reads for a field of `m`: `Transmitter` for `device_id`, else the
    /// hint's `label`, else the field's name. `m` nil is no manifest: names alone, but for
    /// `device_id`.
    public static func label(of field: String, in m: Leyline_V1_DecoderManifest?) -> String {
        if field == "device_id" { return deviceIDLabel }
        let label = m?.fields.first { $0.name == field }?.label ?? ""
        return label.isEmpty ? field : label
    }

    /// The fields a watch can test: `device_id`, which every decoder that names its
    /// transmitters fills, then the manifest's TEXT and INTEGER hints in its order. A NUMBER is
    /// a measurement, which a threshold suits better than a value, and FLAG and DATA have no
    /// value to type.
    public static func fields(_ m: Leyline_V1_DecoderManifest) -> [Field] {
        var out = [
            Field(
                name: "device_id", label: deviceIDLabel, type: .text,
                description: "the transmitter, as the decoder names it")
        ]
        for h in m.fields where (h.type == .text || h.type == .integer) && h.name != "device_id" {
            out.append(
                Field(
                    name: h.name, label: label(of: h.name, in: m), type: h.type,
                    description: h.description_p))
        }
        return out
    }

    /// The tests a field takes: a text is equal to a value or holds it among its words; an
    /// integer is equal to it, over it or under it.
    public static func tests(for type: Leyline_V1_FieldType) -> [Test] {
        type == .integer ? [.equals, .above, .below] : [.equals, .contains]
    }

    /// The `where` token the sheet's choice is: `fips~06009`.
    public static func token(field: String, test: Test, value: String) -> String {
        field + test.token + value.trimmingCharacters(in: .whitespaces)
    }

    /// The sheet's choices as the predicate: the field test when a value is given, and the
    /// place when both a place and a radius are, or an error when neither is.
    public static func predicate(
        field: String, test: Test, value: String, near: String = "", radius: String = ""
    ) throws -> Leyline_V1_Predicate {
        let v = value.trimmingCharacters(in: .whitespaces)
        let tokens = v.isEmpty ? [] : [token(field: field, test: test, value: v)]
        guard
            let p = try predicate(
                where: tokens, near: near.trimmingCharacters(in: .whitespaces),
                radius: radius.trimmingCharacters(in: .whitespaces))
        else { throw Refusal("Give a value, or a place and a radius, to watch for.") }
        return p
    }

    /// The kept job a watch is: the decoder on the frequency Start would use, with the
    /// predicate and a macOS notification. Never `take_over`: a watch waits for what it is told,
    /// so it does not take a radio somebody is using.
    public static func config(
        decoder: String, frequencyHz: UInt64, predicate: Leyline_V1_Predicate
    ) -> Leyline_V1_DecodeConfig {
        .with {
            $0.decoder = decoder
            $0.frequencyHz = frequencyHz
            $0.keep = true
            $0.predicate = predicate
            $0.notify = .with { $0.macosNotification = true }
        }
    }

    // MARK: Reading a watch back

    /// Whether a job is a watch: a decode job whose config carries a predicate, whoever started
    /// it. A plain run (Start, `ley decode`) carries none.
    public static func isWatch(_ j: Leyline_V1_Job) -> Bool {
        if case .decode(let d)? = j.config { return d.hasPredicate }
        return false
    }

    /// The live watches of a decoder that read a radio, newest first.
    public static func watches(of m: Leyline_V1_DecoderManifest, in jobs: [Leyline_V1_Job])
        -> [Leyline_V1_Job]
    {
        jobs.filter { j in
            guard case .decode(let d)? = j.config, d.hasPredicate, d.sourceUri.isEmpty,
                DecoderPages.isLive(j)
            else { return false }
            return d.decoder == m.name || m.aliases.contains(d.decoder)
        }
        .sorted { $0.jobID > $1.jobID }
    }

    /// A watch's condition in words, from its job's predicate, so a watch `ley watch` started
    /// reads as one the sheet started, each field by its label in `m` (`label(of:in:)`):
    /// `County contains 06009`, `Transmitter is N0CALL-3 and within 10 km of 37.7600N
    /// 122.4200W`.
    public static func words(_ j: Leyline_V1_Job, manifest m: Leyline_V1_DecoderManifest?)
        -> String
    {
        guard case .decode(let d)? = j.config else { return "" }
        return words(d.predicate, manifest: m)
    }

    public static func words(_ p: Leyline_V1_Predicate, manifest m: Leyline_V1_DecoderManifest?)
        -> String
    {
        let parts = p.all.compactMap { c -> String? in
            switch c.test {
            case .field(let t): return words(t, label: label(of: t.field, in: m))
            case .geo(let g):
                return "within \(distanceWords(g.radiusM)) of "
                    + DisplayTemplate.formatPosition(g.center)
            case .none: return nil
            }
        }
        return parts.isEmpty ? "every record" : parts.joined(separator: " and ")
    }

    /// One field test in words, the field called `label`: `County is 06009`, `Callsign
    /// contains K6`, `Altitude is over 10000`; several values are `or`ed (`County contains 06009
    /// or 06013`, what `ley watch --county` twice builds).
    static func words(_ t: Leyline_V1_FieldTest, label: String) -> String {
        let values = t.values.map(valueWords)
        let one = values.first ?? ""
        let any = values.joined(separator: " or ")
        switch t.op {
        case .predEq: return "\(label) is \(one)"
        case .predNe: return "\(label) is not \(one)"
        case .predLt: return "\(label) is under \(one)"
        case .predLte: return "\(label) is at most \(one)"
        case .predGt: return "\(label) is over \(one)"
        case .predGte: return "\(label) is at least \(one)"
        case .predIn: return "\(label) is \(any)"
        case .predNotIn: return "\(label) is none of \(values.joined(separator: ", "))"
        case .predContains: return "\(label) contains \(any)"
        case .predExists: return "\(label) is set"
        default: return label
        }
    }

    static func valueWords(_ v: Leyline_V1_FieldValue) -> String {
        switch v.value {
        case .text(let s): return s
        case .integer(let i): return String(i)
        case .number(let n): return DisplayTemplate.formatNumber(n) ?? String(n)
        case .flag(let b): return b ? "true" : "false"
        case .data(let d): return DisplayTemplate.hex(d)
        case .none: return ""
        }
    }

    /// A radius as a person says it: `500 m`, `10 km`, `9.26 km`.
    static func distanceWords(_ metres: Double) -> String {
        if metres < 1000 {
            return (DisplayTemplate.formatNumber(metres, decimals: 0) ?? "0") + " m"
        }
        return (DisplayTemplate.formatNumber(metres / 1000) ?? "0") + " km"
    }
}
