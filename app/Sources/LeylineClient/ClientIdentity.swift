// SPDX-License-Identifier: Apache-2.0

// Process identity on the wire (docs/dev/engine-internals.md, "Client identity and ownership").
// gRPC has no connection identity, so every RPC carries three metadata keys and the daemon
// attributes every event it causes to them. The id is minted once per process, as `ley` mints its
// `cli_` id, so a window and its coalescer are one client to the daemon.

import Foundation
import GRPCCore
import Synchronization

/// The identity sent on every RPC.
public struct ClientIdentity: Sendable, Hashable {
    public static let idKey = "leyline-client-id"
    public static let kindKey = "leyline-client-kind"
    public static let labelKey = "leyline-client-label"

    /// A prefixed ULID: `app_01J…` for the app; tests and tools pick their own prefix.
    public var id: String
    /// `app` | `cli` | `mcp` | `job`. The daemon's don't-disturb signal counts every kind but `job`
    /// as interactive.
    public var kind: String
    /// Free text the daemon shows beside the id (`ley state` prints it).
    public var label: String

    public init(id: String, kind: String, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }

    /// A fresh identity with a new id.
    public static func fresh(
        kind: String = "app", label: String = ProcessInfo.processInfo.processName
    ) -> ClientIdentity {
        ClientIdentity(id: ULID.new().string(prefix: kind + "_"), kind: kind, label: label)
    }

    /// The one identity this process sends by default. Minted on first use.
    public static let process: ClientIdentity = .fresh()

    /// The metadata a request carries.
    public var metadata: Metadata {
        var out = Metadata()
        out.addString(id, forKey: Self.idKey)
        out.addString(kind, forKey: Self.kindKey)
        out.addString(label, forKey: Self.labelKey)
        return out
    }
}

/// A 128-bit ULID (48-bit millisecond time, 80-bit entropy), Crockford base32, 26 characters.
/// Ids from one process are monotonic within a millisecond, so two minted back to back sort in the
/// order they were made. The engine has its own `ULID` in `EngineCore`; this one exists because the
/// app never links that module (docs/decisions/D2-licensing.md).
public struct ULID: Sendable, Hashable, Comparable {
    public var bytes: [UInt8]  // 16

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    /// Monotonic entropy: the last id minted and its millisecond, so the next in the same
    /// millisecond is the previous plus one rather than a fresh draw.
    private static let last = Mutex<(ms: UInt64, entropy: [UInt8])>((0, []))

    public static func new(now: Date = Date()) -> ULID {
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        let entropy: [UInt8] = last.withLock { state in
            if state.ms == ms, state.entropy.count == 10 {
                var e = state.entropy
                var i = 9
                while i >= 0 {
                    if e[i] == 255 {
                        e[i] = 0
                        i -= 1
                    } else {
                        e[i] += 1
                        break
                    }
                }
                state.entropy = e
                return e
            }
            var e = [UInt8](repeating: 0, count: 10)
            for i in e.indices { e[i] = UInt8.random(in: 0...255) }
            state = (ms, e)
            return e
        }
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { b[i] = UInt8((ms >> (8 * UInt64(5 - i))) & 0xff) }
        for i in 0..<10 { b[6 + i] = entropy[i] }
        return ULID(bytes: b)
    }

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 16, "a ULID is 16 bytes")
        self.bytes = bytes
    }

    /// The 26-character Crockford base32 form, most significant first.
    public var string: String {
        // 128 bits into 26 five-bit groups, left-padded with two zero bits.
        var out = [UInt8](repeating: 0, count: 26)
        var acc: UInt64 = 0
        var nbits = 0
        var pos = 25
        for byte in bytes.reversed() {
            acc |= UInt64(byte) << UInt64(nbits)
            nbits += 8
            while nbits >= 5, pos >= 0 {
                out[pos] = Self.alphabet[Int(acc & 0x1f)]
                acc >>= 5
                nbits -= 5
                pos -= 1
            }
        }
        if pos >= 0 { out[pos] = Self.alphabet[Int(acc & 0x1f)] }
        return String(decoding: out, as: UTF8.self)
    }

    public func string(prefix: String) -> String { prefix + string }

    public static func < (lhs: ULID, rhs: ULID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}
