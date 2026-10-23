// SPDX-License-Identifier: Apache-2.0

// Bookmarks that share a frequency, drawn as one (docs/plans/app.md, MC-5). Leyline has no tone
// squelch (`ChannelConfig`'s reserved field 13), so one frequency is one channel, and two
// entries on it with different tones are two names for who is talking there, not two things to
// hear. The file keeps every entry (`bookmarks.json`, the CHIRP import, `ley bookmarks`); the
// merge is only how the app draws them: one sidebar row per frequency, the inspector listing
// each entry, and the tone the daemon decodes naming the entry that is talking. The mode is not
// part of the key: two entries on one frequency in different modes are still one channel, and
// the first entry's mode is the one a click tunes. Nothing here holds state.

import Foundation

/// The bookmarks on one frequency, in the order the sidebar lists them (`BookmarkStore.list`:
/// by name, then id); the first entry leads, and is the one the row, the title and the volume
/// caption name.
public struct BookmarkGroup: Sendable, Hashable, Identifiable {
    /// Never empty.
    public let entries: [Bookmark]

    /// Nil for an empty list.
    public init?(entries: [Bookmark]) {
        guard !entries.isEmpty else { return nil }
        self.entries = entries
    }

    public var lead: Bookmark { entries[0] }
    public var hz: UInt64 { lead.hz }
    /// The lead's id, so the row keeps the identity it had before a second entry joined it.
    public var id: String { lead.id }
    /// How many entries besides the lead; 0 for a bookmark alone on its frequency.
    public var others: Int { entries.count - 1 }
    public var isMerged: Bool { others > 0 }

    /// `+1`, faint after the lead's name; nil when the bookmark is alone.
    public var countWords: String? { isMerged ? "+\(others)" : nil }

    /// `Club net +1`, or the lead's name alone: what names "the bookmark at this frequency"
    /// outside the inspector's list.
    public var words: String {
        countWords.map { "\(lead.name) \($0)" } ?? lead.name
    }

    /// The bookmarks grouped by frequency, each group where its first entry was, entries in the
    /// order given. Bookmarks at one frequency always file under one sidebar row
    /// (`Bands.sidebarRow(for:)`), so grouping a row's list and grouping the whole file agree.
    public static func grouped(_ bookmarks: [Bookmark]) -> [BookmarkGroup] {
        var order: [UInt64] = []
        var byHz: [UInt64: [Bookmark]] = [:]
        for b in bookmarks {
            if byHz[b.hz] == nil { order.append(b.hz) }
            byHz[b.hz, default: []].append(b)
        }
        return order.compactMap { BookmarkGroup(entries: byHz[$0] ?? []) }
    }

    /// The group at `hz` among `bookmarks`, or nil when none is there.
    public static func at(_ hz: UInt64, in bookmarks: [Bookmark]) -> BookmarkGroup? {
        BookmarkGroup(entries: bookmarks.filter { $0.hz == hz })
    }

    /// The entry whose tone the daemon heard (`Tone.matches`), the first of them when two
    /// share it; nil with no tone heard or none matching.
    public func speaker(heard: SubAudibleTone?) -> Bookmark? {
        guard let heard else { return nil }
        return entries.first { $0.toneMatches(heard) }
    }

    /// The entry a transmission is logged under: the one whose tone was heard under it, else the
    /// lead.
    public func entry(heard: SubAudibleTone?) -> Bookmark {
        speaker(heard: heard) ?? lead
    }
}

extension Bookmark {
    /// Whether the tone this bookmark records is the one heard. A tone the file holds that
    /// `Tone.parse` refuses, or none, matches nothing.
    public func toneMatches(_ heard: SubAudibleTone) -> Bool {
        guard !tone.isEmpty, let t = try? Tone.parse(tone) else { return false }
        return t.matches(heard)
    }
}
