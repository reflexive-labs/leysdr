// SPDX-License-Identifier: GPL-3.0-or-later

// Prefixed ULIDs: `dev_`, `cap_`, `chan_`, `sink_`, `job_`, `strm_`, `cli_` (AGENTS.md conventions).
// Wire form is `<prefix>_<26-char Crockford base32 ULID>`; the same strings appear in proto messages,
// `ley://` URIs and log lines.

import Foundation

/// A 128-bit ULID (https://github.com/ulid/spec): 48-bit millisecond timestamp + 80 random bits.
/// Lexicographic order of the string form equals creation order within a millisecond resolution.
public struct ULID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let decodeTable: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() {
            table[c] = UInt8(i)
            table[Character(c.lowercased())] = UInt8(i)
        }
        // Crockford aliases
        table["O"] = 0; table["o"] = 0
        table["I"] = 1; table["i"] = 1; table["L"] = 1; table["l"] = 1
        return table
    }()

    /// Monotonic generator state: ids minted within the same millisecond increment the random
    /// part instead of redrawing it, so ids always sort in creation order (clients number rows by it).
    private static let monotonic = MonotonicState()
    private final class MonotonicState: @unchecked Sendable {
        let lock = NSLock()
        var lastMs: UInt64 = 0
        var hi: UInt64 = 0
        var lo: UInt64 = 0
    }

    /// New ULID from the current time and the system RNG, monotonic within a millisecond.
    public init() {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let st = ULID.monotonic
        st.lock.lock()
        let ms: UInt64
        if now > st.lastMs {
            var r = SystemRandomNumberGenerator()
            st.lastMs = now
            st.hi = r.next() & 0xFFFF   // 16 random bits; the low 64 come next
            st.lo = r.next() & 0x7FFF_FFFF_FFFF_FFFF // leave headroom so increments cannot overflow
            ms = now
        } else {
            // Same (or earlier, on clock steps) millisecond: bump the random part.
            st.lo &+= 1
            if st.lo == 0 { st.hi &+= 1 }
            ms = st.lastMs
        }
        let hi = st.hi, lo = st.lo
        st.lock.unlock()
        bytes = (
            UInt8(truncatingIfNeeded: ms >> 40), UInt8(truncatingIfNeeded: ms >> 32),
            UInt8(truncatingIfNeeded: ms >> 24), UInt8(truncatingIfNeeded: ms >> 16),
            UInt8(truncatingIfNeeded: ms >> 8), UInt8(truncatingIfNeeded: ms),
            UInt8(truncatingIfNeeded: hi >> 8), UInt8(truncatingIfNeeded: hi),
            UInt8(truncatingIfNeeded: lo >> 56), UInt8(truncatingIfNeeded: lo >> 48),
            UInt8(truncatingIfNeeded: lo >> 40), UInt8(truncatingIfNeeded: lo >> 32),
            UInt8(truncatingIfNeeded: lo >> 24), UInt8(truncatingIfNeeded: lo >> 16),
            UInt8(truncatingIfNeeded: lo >> 8), UInt8(truncatingIfNeeded: lo)
        )
    }

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 16, "ULID needs 16 bytes")
        self.bytes = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
    }

    /// Parses the 26-character Crockford base32 form. Case-insensitive; rejects overflow (first char > '7').
    public init?(string: String) {
        let chars = Array(string)
        guard chars.count == 26 else { return nil }
        var value: (UInt64, UInt64) = (0, 0) // (high 64, low 64)
        for c in chars {
            guard let d = ULID.decodeTable[c] else { return nil }
            // value = value << 5 | d, over 128 bits
            let carry = value.1 >> 59
            value.1 = (value.1 << 5) | UInt64(d)
            value.0 = (value.0 << 5) | carry
        }
        // 26*5 = 130 bits; the top 2 bits must be zero.
        guard ULID.decodeTable[chars[0]]! <= 7 else { return nil }
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { out[i] = UInt8(truncatingIfNeeded: value.0 >> (56 - 8 * UInt64(i))) }
        for i in 0..<8 { out[8 + i] = UInt8(truncatingIfNeeded: value.1 >> (56 - 8 * UInt64(i))) }
        self.init(bytes: out)
    }

    public var byteArray: [UInt8] {
        [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
         bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15]
    }

    /// Millisecond timestamp encoded in the ULID.
    public var timestampMs: UInt64 {
        var t: UInt64 = 0
        for b in byteArray.prefix(6) { t = (t << 8) | UInt64(b) }
        return t
    }

    /// 26-character Crockford base32 string.
    public var string: String {
        let b = byteArray
        var hi: UInt64 = 0, lo: UInt64 = 0
        for i in 0..<8 { hi = (hi << 8) | UInt64(b[i]) }
        for i in 8..<16 { lo = (lo << 8) | UInt64(b[i]) }
        var out = [Character](repeating: "0", count: 26)
        var h = hi, l = lo
        for i in stride(from: 25, through: 0, by: -1) {
            out[i] = ULID.alphabet[Int(l & 0x1F)]
            l = (l >> 5) | ((h & 0x1F) << 59)
            h >>= 5
        }
        return String(out)
    }

    public var description: String { string }

    /// The 128 bits as two big-endian halves. Comparison, ordering and hashing go through these
    /// rather than `byteArray`: these ids key the control plane's dictionaries, and a 16-element
    /// Array per probe is a heap allocation on the path every event and poll takes.
    @inline(__always)
    var halves: (hi: UInt64, lo: UInt64) {
        let b = bytes
        let hi = UInt64(b.0) << 56 | UInt64(b.1) << 48 | UInt64(b.2) << 40 | UInt64(b.3) << 32
            | UInt64(b.4) << 24 | UInt64(b.5) << 16 | UInt64(b.6) << 8 | UInt64(b.7)
        let lo = UInt64(b.8) << 56 | UInt64(b.9) << 48 | UInt64(b.10) << 40 | UInt64(b.11) << 32
            | UInt64(b.12) << 24 | UInt64(b.13) << 16 | UInt64(b.14) << 8 | UInt64(b.15)
        return (hi, lo)
    }

    public static func == (lhs: ULID, rhs: ULID) -> Bool { lhs.halves == rhs.halves }

    /// Big-endian halves order exactly as the bytes do, which is the string order too.
    public static func < (lhs: ULID, rhs: ULID) -> Bool {
        let l = lhs.halves, r = rhs.halves
        return l.hi == r.hi ? l.lo < r.lo : l.hi < r.hi
    }

    public func hash(into hasher: inout Hasher) {
        let h = halves
        hasher.combine(h.hi)
        hasher.combine(h.lo)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let u = ULID(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid ULID \(s)"))
        }
        self = u
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }
}

/// A ULID with a fixed kind prefix. All engine identifiers are one of these.
public protocol PrefixedID: Hashable, Codable, Sendable, CustomStringConvertible {
    static var prefix: String { get }
    var ulid: ULID { get }
    init(ulid: ULID)
}

extension PrefixedID {
    public init() { self.init(ulid: ULID()) }

    /// Parses `<prefix>_<ulid>`; nil on wrong prefix or malformed ULID.
    public init?(string: String) {
        let p = Self.prefix + "_"
        guard string.hasPrefix(p), let u = ULID(string: String(string.dropFirst(p.count))) else { return nil }
        self.init(ulid: u)
    }

    public var string: String { Self.prefix + "_" + ulid.string }
    public var description: String { string }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = Self(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid \(Self.prefix) id \(s)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }
}

public struct DeviceID: PrefixedID { public static let prefix = "dev"; public var ulid: ULID; public init(ulid: ULID) { self.ulid = ulid } }
public struct CaptureID: PrefixedID { public static let prefix = "cap"; public var ulid: ULID; public init(ulid: ULID) { self.ulid = ulid } }
public struct ChannelID: PrefixedID { public static let prefix = "chan"; public var ulid: ULID; public init(ulid: ULID) { self.ulid = ulid } }
public struct SinkID: PrefixedID { public static let prefix = "sink"; public var ulid: ULID; public init(ulid: ULID) { self.ulid = ulid } }
public struct JobID: PrefixedID { public static let prefix = "job"; public var ulid: ULID; public init(ulid: ULID) { self.ulid = ulid } }
public struct ScanID: PrefixedID { public static let prefix = "scan"; public var ulid: ULID; public init(ulid: ULID) { self.ulid = ulid } }
public struct StreamID: PrefixedID { public static let prefix = "strm"; public var ulid: ULID; public init(ulid: ULID) { self.ulid = ulid } }
/// Daemon-assigned per connection; used for attribution on events.
public struct ClientID: PrefixedID { public static let prefix = "cli"; public var ulid: ULID; public init(ulid: ULID) { self.ulid = ulid } }
/// A recording the daemon is playing through its own audio device (docs/design/recording.md).
public struct PlaybackID: PrefixedID { public static let prefix = "pb"; public var ulid: ULID; public init(ulid: ULID) { self.ulid = ulid } }
