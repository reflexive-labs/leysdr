// SPDX-License-Identifier: Apache-2.0

// Bookmarks: saved stations, in a file both clients own (docs/design/
// app-design-handoff.md, "Bands and bookmarks are files"). Interpretation state, client-side,
// on the pattern `go/pkg/labels` set and `go/pkg/bookmarks` mirrors: one JSON file beside
// `labels.json`, a map keyed by id so a write of one entry leaves the rest untouched, read
// whole and written whole. The daemon never sees bookmarks.

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
    /// Every key of the entry this client does not know, written back as it arrived, so a
    /// field a newer client added survives this one's load, edit and save
    /// (docs/design/channels.md, "Bookmarks gain three fields"). The mutators change the
    /// fetched value in place, which is what keeps it; a new bookmark starts with none.
    public var extra: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case name, hz
        case modeName = "mode"
        case bandwidthHz = "bandwidth_hz"
        case updatedNs = "updated_ns"
    }

    public init(
        id: String, name: String, hz: UInt64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32 = 0,
        updatedNs: Int64 = 0, extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.hz = hz
        self.modeName = mode.wireName
        self.bandwidthHz = bandwidthHz
        self.updatedNs = updatedNs
        self.extra = extra
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
        // A second view of the same object, keyed by whatever is there: the keys `CodingKeys`
        // does not name are the foreign ones.
        let any = try decoder.container(keyedBy: AnyCodingKey.self)
        var extra: [String: JSONValue] = [:]
        for key in any.allKeys where CodingKeys(stringValue: key.stringValue) == nil {
            extra[key.stringValue] = try any.decode(JSONValue.self, forKey: key)
        }
        self.extra = extra
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(hz, forKey: .hz)
        try c.encode(modeName, forKey: .modeName)
        try c.encode(bandwidthHz, forKey: .bandwidthHz)
        try c.encode(updatedNs, forKey: .updatedNs)
        // The known keys were written first and win: a foreign key that later becomes known
        // is read into its field on the next load, and `extra` never carries one of these
        // names, because the decoder filters them out.
        var any = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extra where CodingKeys(stringValue: key) == nil {
            try any.encode(value, forKey: AnyCodingKey(key))
        }
    }

    public var mode: Leyline_V1_DemodMode { Leyline_V1_DemodMode.named(modeName) ?? .unspecified }
}

/// A coding key for any name, so an entry's foreign keys can be read and written without
/// naming them. JSON has no integer keys, so `intValue` is never set.
private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public enum BookmarkError: Error, Equatable, Sendable {
    case emptyName
    /// A bookmark carries the mode to restore, so `.unspecified` is refused rather than
    /// written as `DEMOD_MODE_UNSPECIFIED`, which `ley bookmarks` would then list with no mode.
    case unspecifiedMode
    case malformed(String)
    /// No load has succeeded, so the file on disk is unknown and nothing may be written over it.
    case notLoaded(String)
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
    /// Whether the last `load()` succeeded. Until one has, `add`, `remove` and `save` refuse:
    /// a store that could not read the file does not know what is in it, and `save` writes the
    /// whole file, so writing would lose a list somebody built by hand. `go/pkg/bookmarks`
    /// enforces the same rule by returning no store at all from `Open`.
    public private(set) var loaded = false
    /// The clock the mutators stamp with, so a test can hold time still.
    public var now: @Sendable () -> Date = { Date() }

    public init(path: String) { self.path = path }

    /// Where bookmarks live: `LEYLINE_BOOKMARKS`, else beside `labels.json` under
    /// `~/Library/Application Support/Leyline` (macOS) or `$XDG_DATA_HOME/leyline`.
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let p = environment[pathEnv], !p.isEmpty { return p }
        let home = environment["HOME"] ?? NSHomeDirectory()
        #if os(macOS)
            return home + "/Library/Application Support/Leyline/bookmarks.json"
        #else
            if let dir = environment["XDG_DATA_HOME"], !dir.isEmpty {
                return dir + "/leyline/bookmarks.json"
            }
            return home + "/.local/share/leyline/bookmarks.json"
        #endif
    }

    private struct File: Codable {
        var bookmarks: [String: Bookmark]
    }

    /// Reads the file. A missing file is an empty store, loaded: nobody has bookmarked anything
    /// yet. A malformed one throws and leaves the store unloaded, so the mutators refuse until a
    /// read succeeds — otherwise the next save would overwrite the user's existing bookmarks.
    public mutating func load() throws {
        loaded = false
        guard FileManager.default.fileExists(atPath: path) else {
            bookmarks = [:]
            loaded = true
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        bookmarks = try Self.decode(data)
        loaded = true
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
    /// sees half a file. The neighbour is removed whether or not the rename works: a `.tmp`
    /// left beside the file is one the next run would neither read nor clean up.
    public func save() throws {
        guard loaded else { throw BookmarkError.notLoaded(path) }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try encoded().write(to: tmp, options: .atomic)
        // rename(2) rather than FileManager's replaceItemAt: one step, replacing whatever is
        // there, which is what `go/pkg/bookmarks` does with os.Rename. replaceItemAt unlinks
        // the original first, so a failure there loses the file the temp was meant to protect.
        guard rename(tmp.path, url.path) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
    }

    /// In list order: by frequency, then name.
    public var list: [Bookmark] {
        bookmarks.values.sorted { ($0.hz, $0.name, $0.id) < ($1.hz, $1.name, $1.id) }
    }

    /// Adds a bookmark, or updates the one that already has this name on this frequency.
    /// Does not save.
    @discardableResult
    public mutating func add(
        name: String, hz: UInt64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32 = 0
    ) throws -> Bookmark {
        guard loaded else { throw BookmarkError.notLoaded(path) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BookmarkError.emptyName }
        guard mode != .unspecified else { throw BookmarkError.unspecifiedMode }
        let stamp = Int64(now().timeIntervalSince1970 * 1e9)
        if var existing = bookmarks.values.first(where: { $0.hz == hz && $0.name == name }) {
            existing.modeName = mode.wireName
            existing.bandwidthHz = bandwidthHz
            existing.updatedNs = stamp
            bookmarks[existing.id] = existing
            return existing
        }
        let b = Bookmark(
            id: ULID.new(now: now()).string(prefix: "bm_"), name: name, hz: hz, mode: mode,
            bandwidthHz: bandwidthHz, updatedNs: stamp)
        bookmarks[b.id] = b
        return b
    }

    /// Renames the bookmark with this id in place, keeping its frequency, mode and width: the
    /// inspector's pencil, where `add` would make a second bookmark on the same frequency under
    /// the new name. Not `rename`, which would shadow the `rename(2)` `save` calls. Does not
    /// save.
    @discardableResult
    public mutating func renameBookmark(_ id: String, to name: String) throws -> Bookmark {
        guard loaded else { throw BookmarkError.notLoaded(path) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BookmarkError.emptyName }
        guard var b = bookmarks[id] else {
            throw BookmarkError.noSuchBookmark(id, candidates: [])
        }
        b.name = name
        b.updatedNs = Int64(now().timeIntervalSince1970 * 1e9)
        bookmarks[id] = b
        return b
    }

    /// Gives the bookmark with this id the channel's current mode and width, and the
    /// frequency when one is given, keeping its name: the inspector's "save" on a bookmark whose
    /// settings were changed after it was tuned, and the sidebar's "replace" on one that should
    /// move to the tuned frequency (`ley bookmarks move` for the frequency). Does not save.
    @discardableResult
    public mutating func updateBookmark(
        _ id: String, hz: UInt64? = nil, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32
    ) throws -> Bookmark {
        guard loaded else { throw BookmarkError.notLoaded(path) }
        guard mode != .unspecified else { throw BookmarkError.unspecifiedMode }
        guard var b = bookmarks[id] else {
            throw BookmarkError.noSuchBookmark(id, candidates: [])
        }
        if let hz { b.hz = hz }
        b.modeName = mode.wireName
        b.bandwidthHz = bandwidthHz
        b.updatedNs = Int64(now().timeIntervalSince1970 * 1e9)
        bookmarks[id] = b
        return b
    }

    /// Removes by exact id, else exact name, else a case-insensitive name that matches exactly
    /// one bookmark. The argument is trimmed first, as `go/pkg/bookmarks` trims it, so a name
    /// pasted with a trailing space still matches its bookmark. Does not save.
    @discardableResult
    public mutating func remove(_ idOrName: String) throws -> Bookmark {
        guard loaded else { throw BookmarkError.notLoaded(path) }
        let arg = idOrName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let b = bookmarks[arg] {
            bookmarks[arg] = nil
            return b
        }
        let exact = bookmarks.values.filter { $0.name == arg }
        if exact.count == 1, let b = exact.first {
            bookmarks[b.id] = nil
            return b
        }
        let loose = bookmarks.values.filter { $0.name.lowercased() == arg.lowercased() }
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
