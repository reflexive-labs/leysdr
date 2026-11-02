// SPDX-License-Identifier: Apache-2.0

// The names a person gives the transmitters a decoder hears: `labels.json`, the file
// `go/pkg/labels` and `ley label` read and write, beside `bookmarks.json`. Labels are user data,
// not daemon state (docs/design/decoders.md, section 3 and section 5, "Registry devices"); a label
// is keyed by `device_id` alone, so it applies whichever decoder hears that transmitter next, and
// the protocol is kept only as a note. The store follows `BookmarkStore`: read whole, written
// whole through a temporary neighbour and a rename, and never written until a read succeeded.

import Foundation

/// One transmitter's name. `protocol` notes where it was named; `updated_ns` is when, wall clock.
public struct DeviceLabel: Codable, Equatable, Sendable {
    public var deviceID: String
    public var name: String
    public var protocolName: String?
    public var updatedNs: Int64

    public init(deviceID: String, name: String, protocolName: String? = nil, updatedNs: Int64) {
        self.deviceID = deviceID
        self.name = name
        self.protocolName = protocolName
        self.updatedNs = updatedNs
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case protocolName = "protocol"
        case updatedNs = "updated_ns"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(name, forKey: .name)
        // `omitempty` in Go: an empty protocol is left out rather than written as "".
        if let p = protocolName, !p.isEmpty { try c.encode(p, forKey: .protocolName) }
        try c.encode(updatedNs, forKey: .updatedNs)
    }
}

public enum LabelError: Error, Equatable, Sendable {
    case malformed(String)
    /// No load has succeeded, so the file on disk is unknown and nothing may be written over it.
    case notLoaded(String)
}

public struct LabelStore: Sendable {
    public static let pathEnv = "LEYLINE_LABELS"

    public let path: String
    public private(set) var labels: [String: DeviceLabel] = [:]
    /// Whether the last `load()` succeeded; until one has, `set` refuses, because `save` writes
    /// the whole file and would lose names somebody gave in a file this store could not read.
    public private(set) var loaded = false
    /// The clock `set` stamps with, so a test can hold time still.
    public var now: @Sendable () -> Date = { Date() }

    public init(path: String) { self.path = path }

    /// Where labels live: `LEYLINE_LABELS`, else `~/Library/Application Support/Leyline/labels.json`
    /// (macOS) or `$XDG_DATA_HOME/leyline` (`go/pkg/labels.ResolvePath`).
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let p = environment[pathEnv], !p.isEmpty { return p }
        let home = environment["HOME"] ?? NSHomeDirectory()
        #if os(macOS)
            return home + "/Library/Application Support/Leyline/labels.json"
        #else
            if let dir = environment["XDG_DATA_HOME"], !dir.isEmpty {
                return dir + "/leyline/labels.json"
            }
            return home + "/.local/share/leyline/labels.json"
        #endif
    }

    private struct File: Codable {
        var labels: [String: DeviceLabel]
    }

    /// Reads the file. A missing file is an empty store, loaded; a malformed one throws and
    /// leaves the store unloaded.
    public mutating func load() throws {
        loaded = false
        guard FileManager.default.fileExists(atPath: path) else {
            labels = [:]
            loaded = true
            return
        }
        labels = try Self.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        loaded = true
    }

    /// The file's labels, each keyed by its map key, which wins over the entry's own
    /// `device_id` as it does in Go.
    public static func decode(_ data: Data) throws -> [String: DeviceLabel] {
        do {
            var map = try JSONDecoder().decode(File.self, from: data).labels
            for (id, var l) in map {
                l.deviceID = id
                map[id] = l
            }
            return map
        } catch {
            throw LabelError.malformed("\(error)")
        }
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(File(labels: labels))
    }

    /// The name given to a transmitter, or nil.
    public func name(of deviceID: String) -> String? {
        labels[deviceID].map(\.name)
    }

    /// Names a transmitter, or with an empty name removes its label, and saves the file, as
    /// `ley label` does. The name is trimmed.
    public mutating func set(deviceID: String, name: String, protocolName: String) throws {
        guard loaded else { throw LabelError.notLoaded(path) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            guard labels.removeValue(forKey: deviceID) != nil else { return }
        } else {
            labels[deviceID] = DeviceLabel(
                deviceID: deviceID, name: name,
                protocolName: protocolName.isEmpty ? nil : protocolName,
                updatedNs: Int64(now().timeIntervalSince1970 * 1e9))
        }
        try save()
    }

    /// Writes the whole file through a temporary neighbour and a rename, so a reader never sees
    /// half a file (`BookmarkStore.save`).
    public func save() throws {
        guard loaded else { throw LabelError.notLoaded(path) }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try encoded().write(to: tmp, options: .atomic)
        guard rename(tmp.path, url.path) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
    }
}
