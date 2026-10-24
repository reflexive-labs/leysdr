// SPDX-License-Identifier: Apache-2.0

// Bookmarks that share a frequency, drawn as one (docs/plans/app.md, MC-5). Leyline has no tone
// squelch (`ChannelConfig`'s reserved field 13), so one frequency is one channel, and two
// entries on it with different tones are two names for who is talking there, not two things to
// hear. The file keeps every entry (`bookmarks.json`, the CHIRP import, `ley bookmarks`); the
// merge is only how the app draws them: one sidebar row per frequency, the inspector listing
// each entry, and the tone the daemon decodes naming the entry that is talking. The mode is not
// part of the key: two entries on one frequency in different modes are still one channel, and
// the first entry's mode is the one a click tunes. The entries keep the file's order, so the
// first is the one added first (a CHIRP import's first row), not the first by name. Nothing here
// holds state.

import Foundation

/// The bookmarks on one frequency in the file's order: by id, which is the order they were added
/// in, since an id is a ULID and its time comes first (`bookmarks.json` writes its keys sorted,
/// and a CHIRP import adds its rows top to bottom). The first entry leads, and is the one the
/// row, the title, the volume caption and the log's fallback name.
public struct BookmarkGroup: Sendable, Hashable, Identifiable {
    /// Never empty; by id.
    public let entries: [Bookmark]

    /// Nil for an empty list. The entries are sorted into the file's order.
    public init?(entries: [Bookmark]) {
        guard !entries.isEmpty else { return nil }
        self.entries = entries.sorted { $0.id < $1.id }
    }

    public var lead: Bookmark { entries[0] }
    public var hz: UInt64 { lead.hz }
    /// The lead's id, so the row keeps the identity it had before a later entry joined it.
    public var id: String { lead.id }
    /// How many entries besides the lead; 0 for a bookmark alone on its frequency.
    public var others: Int { entries.count - 1 }
    public var isMerged: Bool { others > 0 }

    /// `+1`, faint after the lead's name; nil when the bookmark is alone.
    public var countWords: String? { isMerged ? "+\(others)" : nil }

    /// `Club repeater +1`, or the lead's name alone: what names "the bookmark at this frequency"
    /// outside the inspector's list.
    public var words: String {
        countWords.map { "\(lead.name) \($0)" } ?? lead.name
    }

    /// The bookmarks grouped by frequency, each group where its first entry in `bookmarks` was,
    /// entries in the file's order. Bookmarks at one frequency always file under one sidebar row
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
