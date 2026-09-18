// SPDX-License-Identifier: Apache-2.0

// Bookmarks: the stations a person wants back, in a file both clients own (docs/design/
// app-design-handoff.md, "Bands and bookmarks are files"). Interpretation state, client-side,
// on the pattern `go/pkg/labels` set and `go/pkg/bookmarks` mirrors: one JSON file beside
// `labels.json`, a map keyed by id so a write of one entry leaves the rest untouched, read
// whole and written whole. The daemon never learns a bookmark exists.

import Foundation
import LeylineProto

public struct Bookmark: Sendable, Hashable, Codable, Identifiable {
    /// `bm_` and a ULID.
    public var id: String
    public var name: String
    public var hz: UInt64
    /// The mode's enum name (`NFM`); `mode` resolves it.
    public var modeName: String
    /// 0 is the mode's default.
    public var bandwidthHz: UInt32
    /// When it was last set, wall clock, nanoseconds since the epoch.
    public var updatedNs: Int64

    enum CodingKeys: String, CodingKey {
        case name, hz
        case modeName = "mode"
        case bandwidthHz = "bandwidth_hz"
        case updatedNs = "updated_ns"
    }

    public init(id: String, name: String, hz: UInt64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32 = 0, updatedNs: Int64 = 0) {
        self.id = id
        self.name = name
        self.hz = hz
        self.modeName = mode.wireName
        self.bandwidthHz = bandwidthHz
        self.updatedNs = updatedNs
    }

    // The id is the map key on disk, not a field of the entry, so it is set by the store.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ""
        name = try c.decode(String.self, forKey: .name)
        hz = try c.decode(UInt64.self, forKey: .hz)
        modeName = try c.decodeIfPresent(String.self, forKey: .modeName) ?? ""
        bandwidthHz = try c.decodeIfPresent(UInt32.self, forKey: .bandwidthHz) ?? 0
        updatedNs = try c.decodeIfPresent(Int64.self, forKey: .updatedNs) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(hz, forKey: .hz)
        try c.encode(modeName, forKey: .modeName)
        try c.encode(bandwidthHz, forKey: .bandwidthHz)
        try c.encode(updatedNs, forKey: .updatedNs)
    }

    public var mode: Leyline_V1_DemodMode { Leyline_V1_DemodMode.named(modeName) ?? .unspecified }
}

public enum BookmarkError: Error, Equatable, Sendable {
    case emptyName
    case malformed(String)
    /// Nothing matched, or more than one did; the candidates are the names that came close.
    case noSuchBookmark(String, candidates: [String])
}

/// The bookmarks file loaded into memory. `load()` reads the whole file, the mutators write
/// it whole; there is no long-lived writer to coordinate with, and `ley bookmarks` follows
/// the same rule. Not thread-safe by design: the app holds one on the main actor.
public struct BookmarkStore: Sendable {
    public static let pathEnv = "LEYLINE_BOOKMARKS"

    public let path: String
    public private(set) var bookmarks: [String: Bookmark] = [:]
    /// The clock the mutators stamp with, so a test can hold time still.
    public var now: @Sendable () -> Date = { Date() }

    public init(path: String) { self.path = path }

    /// Where bookmarks live: `LEYLINE_BOOKMARKS`, else beside `labels.json` under
    /// `~/Library/Application Support/Leyline` (macOS) or `$XDG_DATA_HOME/leyline`.
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = environment[pathEnv], !p.isEmpty { return p }
        let home = environment["HOME"] ?? NSHomeDirectory()
        #if os(macOS)
        return home + "/Library/Application Support/Leyline/bookmarks.json"
        #else
        if let dir = environment["XDG_DATA_HOME"], !dir.isEmpty { return dir + "/leyline/bookmarks.json" }
        return home + "/.local/share/leyline/bookmarks.json"
        #endif
    }

    private struct File: Codable {
        var bookmarks: [String: Bookmark]
    }

    /// Reads the file. A missing file is an empty store: nobody has bookmarked anything yet. A
    /// malformed one is an error rather than an empty store, because the next save would
    /// overwrite what the person meant to keep.
    public mutating func load() throws {
        guard FileManager.default.fileExists(atPath: path) else {
            bookmarks = [:]
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        bookmarks = try Self.decode(data)
    }

    public static func decode(_ data: Data) throws -> [String: Bookmark] {
        do {
            var map = try JSONDecoder().decode(File.self, from: data).bookmarks
            for (id, var b) in map {
                b.id = id
                map[id] = b
            }
            return map
        } catch {
            throw BookmarkError.malformed("\(error)")
        }
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(File(bookmarks: bookmarks))
    }

    /// Writes the whole file through a temporary neighbour and a rename, so a reader never
    /// sees half a file.
    public func save() throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        try encoded().write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// In list order: by frequency, then name.
    public var list: [Bookmark] {
        bookmarks.values.sorted { ($0.hz, $0.name, $0.id) < ($1.hz, $1.name, $1.id) }
    }

    /// Adds a bookmark, or updates the one that already has this name on this frequency.
    /// Does not save.
    @discardableResult
    public mutating func add(name: String, hz: UInt64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32 = 0) throws -> Bookmark {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BookmarkError.emptyName }
        let stamp = Int64(now().timeIntervalSince1970 * 1e9)
        if var existing = bookmarks.values.first(where: { $0.hz == hz && $0.name == name }) {
            existing.modeName = mode.wireName
            existing.bandwidthHz = bandwidthHz
            existing.updatedNs = stamp
            bookmarks[existing.id] = existing
            return existing
        }
        let b = Bookmark(id: ULID.new(now: now()).string(prefix: "bm_"), name: name, hz: hz, mode: mode, bandwidthHz: bandwidthHz, updatedNs: stamp)
        bookmarks[b.id] = b
        return b
    }

    /// Removes by exact id, else exact name, else a case-insensitive name that matches exactly
    /// one bookmark. Does not save.
    @discardableResult
    public mutating func remove(_ idOrName: String) throws -> Bookmark {
        if let b = bookmarks[idOrName] {
            bookmarks[idOrName] = nil
            return b
        }
        let exact = bookmarks.values.filter { $0.name == idOrName }
        if exact.count == 1, let b = exact.first {
            bookmarks[b.id] = nil
            return b
        }
        let loose = bookmarks.values.filter { $0.name.lowercased() == idOrName.lowercased() }
        if exact.isEmpty, loose.count == 1, let b = loose.first {
            bookmarks[b.id] = nil
            return b
        }
        let candidates = (exact.isEmpty ? loose : exact).map { "\($0.name) (\($0.id))" }.sorted()
        throw BookmarkError.noSuchBookmark(idOrName, candidates: candidates)
    }

    /// The bookmark nearest a frequency, for `Snap to Nearest Bookmark`.
    public func nearest(to hz: UInt64) -> Bookmark? {
        list.min { distance($0.hz, hz) < distance($1.hz, hz) }
    }

    private func distance(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : b - a }
}

extension Leyline_V1_DemodMode {
    /// The enum's own name, as the file and proto3 JSON spell it.
    public var wireName: String {
        switch self {
        case .am: "AM"
        case .nfm: "NFM"
        case .wfm: "WFM"
        case .usb: "USB"
        case .lsb: "LSB"
        case .cw: "CW"
        case .rawIq: "RAW_IQ"
        default: "DEMOD_MODE_UNSPECIFIED"
        }
    }
}
