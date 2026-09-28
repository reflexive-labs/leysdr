// SPDX-License-Identifier: Apache-2.0

// JSONValue: any JSON, kept as it arrived. `Bookmark` carries the keys of an entry it does not
// know in a map of these, so a field a newer client wrote survives this client's load, edit and
// save (docs/design/channels.md, "Bookmarks gain three fields": unknown keys are preserved by
// both readers so an older `ley` never strips a newer app's fields). `go/pkg/bookmarks` holds
// the same keys as raw messages; this is the typed equivalent, because `Codable` has no raw
// message and a `Hashable` value keeps `Bookmark`'s synthesized `Hashable`.

import Foundation

/// One JSON value of any shape. Decoding tries the cases in declaration order, so a `1` is a
/// number and never a bool, and `true` is never a number.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    /// Every JSON number, as JSON has one number type. A whole number that fits a 64-bit
    /// integer is written back without a fractional part, so a `1` read from the file goes back
    /// as `1` and not `1.0`: the day a key becomes known, the file needs no migration, and
    /// `go/pkg/bookmarks` writes the same bytes. A whole number above 2^53 loses precision
    /// here; no foreign key carries one, and the known `updated_ns` is decoded as `Int64`.
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:
            try c.encodeNil()
        case .bool(let b):
            try c.encode(b)
        case .number(let n):
            // `Double(Int64.max)` rounds up to 2^63, which `Int64(_:)` would trap on, so the
            // comparison is strict and that one value goes out as a double.
            if n.isFinite, n == n.rounded(), abs(n) < Double(Int64.max) {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        case .string(let s):
            try c.encode(s)
        case .array(let a):
            try c.encode(a)
        case .object(let o):
            try c.encode(o)
        }
    }
}
