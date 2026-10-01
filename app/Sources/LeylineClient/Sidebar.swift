// SPDX-License-Identifier: Apache-2.0

// The sidebar's rules, kept out of the views so each has a Linux test (docs/design/channels.md,
// "Bands are the spine of the sidebar"). The sidebar is one
// list of bands in frequency order with a group standing in for its parts, because a plan that
// hangs off GMRS would otherwise have no row; the band lookups `AppSession` keeps reading
// (`Bands.plain`, `band(containing:)`) still answer parts, and a part maps to its group only
// here. The bands the radio cannot tune fold to one line, the filter flattens everything into
// one ordered list with disabled rows the Return key skips, and a new bookmark takes the name
// of the plan channel it sits on. Nothing here holds state: the views build an index from the
// session's copy of the mirror and read it.

import Foundation
import LeylineProto

// MARK: The fold

extension Bands {
    /// The sidebar's rows: the table with each group in place of its parts, in frequency order
    /// (a group sorts by its `minHz`, which is its first part's). Plain bands in no group keep
    /// the table's order, which is already by frequency.
    public static func sidebar(in bands: [Band] = builtIn) -> [Band] {
        let parts = Set(bands.flatMap(\.parts))
        let rows = bands.filter { $0.isGroup || !parts.contains($0.id) }
        return rows.enumerated().sorted {
            ($0.element.minHz, $0.offset) < ($1.element.minHz, $1.offset)
        }.map(\.element)
    }

    /// The group `band` is a part of, else nil. Unlike `planOwner` this answers regardless of
    /// whether the part carries a plan, because the sidebar files by membership, not by plan.
    public static func group(of band: Band, in bands: [Band] = builtIn) -> Band? {
        bands.first { $0.isGroup && $0.parts.contains(band.id) }
    }

    /// The sidebar row a frequency files under: the group when the band containing it is a
    /// part (a bookmark at 462.6625 MHz sits under `GMRS`), else the band, else nil, which the
    /// sidebar shows as `Other`.
    public static func sidebarRow(for hz: UInt64, in bands: [Band] = builtIn) -> Band? {
        guard let part = band(containing: hz, in: bands) else { return nil }
        return group(of: part, in: bands) ?? part
    }
}

// MARK: The out-of-range line

/// The rows the radio cannot tune and the one dim line that stands in for them: `7 bands below
/// what this radio tunes`, `above`, or `outside` when they lie on both sides of its reach or in
/// a gap between two of its ranges. The line counts bands, not their bookmarks, which the
/// filter still lists as disabled rows. `Bands.outOfRangeWords` is the same judgement for one
/// band, with the reach spelled out; this one is for the fold and leaves the numbers to the
/// expanded rows.
public struct OutOfRangeFold: Sendable, Hashable {
    public var bands: [Band]
    public var words: String

    public init(bands: [Band], words: String) {
        self.bands = bands
        self.words = words
    }

    /// Nil when every row is tunable, so the sidebar draws no line.
    public init?(rows: [Band], ranges: [Leyline_V1_FrequencyRange]) {
        let out = rows.filter { !Bands.tunable($0, ranges: ranges) }
        guard !out.isEmpty, let lo = ranges.map(\.minHz).min(), let hi = ranges.map(\.maxHz).max()
        else { return nil }
        let side =
            out.allSatisfy { $0.maxHz < lo }
            ? "below" : out.allSatisfy { $0.minHz > hi } ? "above" : "outside"
        let noun = out.count == 1 ? "band" : "bands"
        self.init(bands: out, words: "\(out.count) \(noun) \(side) what this radio tunes")
    }
}

// MARK: The filter

/// What a filter row stands for. A bookmark's row is nil when its frequency lies in no band
/// (`Other`); a channel always has the row whose plan holds it.
public enum SidebarRowKind: Sendable, Hashable {
    case band(Band)
    case bookmark(Bookmark, row: Band?)
    case channel(PlanChannel, row: Band)
}

/// One row of the filtered list: the flat view of bands, bookmarks and plan channels, each
/// naming the band it belongs to. `hz` is what Return tunes for a bookmark or channel and nil
/// for a band, which tunes as a click on its row would. A disabled row is one the radio cannot
/// tune; it is listed and never the Return target.
public struct SidebarMatch: Sendable, Hashable, Identifiable {
    public var kind: SidebarRowKind
    public var disabled: Bool
    public var hz: UInt64?
    public var label: String
    /// The band's name, or `Other`.
    public var rowName: String

    public init(kind: SidebarRowKind, disabled: Bool, hz: UInt64?, label: String, rowName: String) {
        self.kind = kind
        self.disabled = disabled
        self.hz = hz
        self.label = label
        self.rowName = rowName
    }

    /// The band's id, the bookmark's id, or the row and channel ids joined by a slash: a
    /// channel's own id is its plan-prefixed alias, which is unique across plans, but the row
    /// makes the pair readable in a list of ids.
    public var id: String {
        switch kind {
        case .band(let band): band.id
        case .bookmark(let bookmark, _): bookmark.id
        case .channel(let channel, let row): "\(row.id)/\(channel.id)"
        }
    }
}

/// The filter's match and order, built once from the session's bands, bookmarks, tuned frequency
/// and the radio's reach, then asked per keystroke. A match is a
/// case-insensitive prefix of a name or of any alias, so `5` finds channel 5 and not `ch15`.
/// The order is the tuned band's matches first, then the rest, and within each: bookmarks and
/// channels by frequency with a bookmark before a channel on the same one, then band rows by
/// their low edge, so Return on a band's name tunes its first entry rather than the band. A
/// tuned frequency in no band has no tuned group, and `Other`'s bookmarks sort with the rest.
public struct SidebarIndex: Sendable {
    private struct Entry: Sendable {
        var match: SidebarMatch
        /// The lower-cased name and aliases a query is a prefix of.
        var keys: [String]
    }

    /// Every row in its final order; a query keeps the ones it matches.
    private let entries: [Entry]

    public init(
        bands: [Band] = Bands.builtIn, bookmarks: [Bookmark], tunedHz: UInt64?,
        ranges: [Leyline_V1_FrequencyRange]
    ) {
        let rows = Bands.sidebar(in: bands)
        let tunedRow = tunedHz.flatMap { Bands.sidebarRow(for: $0, in: bands) }
        var tuned: [Entry] = []
        var rest: [Entry] = []
        func file(_ entry: Entry, under row: Band?) {
            if let row, row == tunedRow { tuned.append(entry) } else { rest.append(entry) }
        }
        for bookmark in bookmarks {
            let row = Bands.sidebarRow(for: bookmark.hz, in: bands)
            let disabled =
                row.map { !Bands.tunable($0, ranges: ranges) }
                ?? !SidebarIndex.reaches(bookmark.hz, ranges: ranges)
            let match = SidebarMatch(
                kind: .bookmark(bookmark, row: row), disabled: disabled, hz: bookmark.hz,
                label: bookmark.name, rowName: row?.name ?? "Other")
            file(Entry(match: match, keys: [Plans.presetKey(bookmark.name)]), under: row)
        }
        for row in rows {
            let disabled = !Bands.tunable(row, ranges: ranges)
            for channel in row.channels {
                let match = SidebarMatch(
                    kind: .channel(channel, row: row),
                    disabled: !SidebarIndex.reaches(channel.hz, ranges: ranges), hz: channel.hz,
                    label: channel.name, rowName: row.name)
                let keys = [Plans.presetKey(channel.name)] + channel.aliases.map(Plans.presetKey)
                file(Entry(match: match, keys: keys), under: row)
            }
            let match = SidebarMatch(
                kind: .band(row), disabled: disabled, hz: nil, label: row.name, rowName: row.name)
            let keys = [Plans.presetKey(row.name)] + row.aliases.map(Plans.presetKey)
            file(Entry(match: match, keys: keys), under: row)
        }
        entries = SidebarIndex.ordered(tuned) + SidebarIndex.ordered(rest)
    }

    /// The rows whose name or an alias begins with `query`, case-insensitive, in the index's
    /// order; none for an empty or blank query.
    public func matches(_ query: String) -> [SidebarMatch] {
        let key = Plans.presetKey(query)
        guard !key.isEmpty else { return [] }
        return entries.filter { $0.keys.contains { $0.hasPrefix(key) } }.map(\.match)
    }

    /// What Return tunes: the first match the radio can tune, or nil.
    public func firstTarget(_ query: String) -> SidebarMatch? {
        matches(query).first { !$0.disabled }
    }

    /// Entries by frequency, a bookmark before a channel on a tie and otherwise the order they
    /// were filed in (plan order for channels, the store's order for bookmarks), then the band
    /// rows by their low edge.
    private static func ordered(_ group: [Entry]) -> [Entry] {
        group.enumerated().sorted { a, b in
            sortKey(a.element, a.offset) < sortKey(b.element, b.offset)
        }.map(\.element)
    }

    private static func sortKey(_ entry: Entry, _ index: Int) -> (Int, UInt64, Int, Int) {
        switch entry.match.kind {
        case .bookmark(let bookmark, _): (0, bookmark.hz, 0, index)
        case .channel(let channel, _): (0, channel.hz, 1, index)
        case .band(let band): (1, band.minHz, 0, index)
        }
    }

    /// Whether the radio tunes `hz` at all, for a bookmark in no band; no ranges means the radio
    /// reported none and everything is offered, as `Bands.tunable` reads it.
    private static func reaches(_ hz: UInt64, ranges: [Leyline_V1_FrequencyRange]) -> Bool {
        ranges.isEmpty || ranges.contains { $0.minHz <= hz && hz <= $0.maxHz }
    }
}

// MARK: Naming

/// The one rule for what a new bookmark is called (docs/design/channels.md, "A new bookmark is
/// named after the channel it sits on"): ⌘D, the inspector's pencil, Find
/// active's ＋ and a CHIRP row with no name all come here.
public enum BookmarkNaming {
    /// The radio-printed name of the plan channel within `Plans.toleranceHz` of `hz` (`ch5`,
    /// `calling`), else the frequency's words.
    public static func name(for hz: UInt64, in bands: [Band] = Bands.builtIn) -> String {
        Plans.name(at: hz, in: bands) ?? frequencyWords(hz)
    }

    /// `146.520 MHz`, `462.6625 MHz`, `1.766 GHz`: the guide's spelling, a space before the
    /// unit, and the one rule the app's `Frequency.format` delegates to, so a bookmark named
    /// here reads as the transport bar shows the same hertz. The fourth decimal appears only on
    /// an exact half-kilohertz, which every 12.5 kHz plan has (GMRS channel 3 is 462.6125 MHz)
    /// and no measurement lands on by chance, so a measured centre keeps the three decimals
    /// its bin width can resolve: `ley`'s rule.
    public static func frequencyWords(_ hz: UInt64) -> String {
        if hz >= 1_000_000_000 { return String(format: "%.3f GHz", Double(hz) / 1e9) }
        if hz >= 1_000_000 {
            return String(format: hz % 1_000 == 500 ? "%.4f MHz" : "%.3f MHz", Double(hz) / 1e6)
        }
        if hz >= 1_000 { return String(format: "%.1f kHz", Double(hz) / 1e3) }
        return "\(hz) Hz"
    }
}
