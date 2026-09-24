// SPDX-License-Identifier: Apache-2.0

// Region 1: bands and bookmarks (docs/design/app-design-handoff.md). A band is a frequency range;
// a bookmark is a saved station. Selecting a band applies all of its settings and the expanded
// row shows them. Recordings are not listed here: a file on disk is not a place to tune, and the
// list grew without bound (docs/design/app-design-handoff-m3.md, "What this replaces"). They are
// reached through Finder until M3's Recordings source (8c); a bookmark that is recording has a
// dot.

import LeylineClient
import LeylineProto
import SwiftUI

struct SidebarView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header("Bands") { EmptyView() }
                ForEach(session.bands) { band in
                    // A band the radio cannot reach stays listed, disabled, and the tooltip
                    // explains why: a click that could only fail is not offered.
                    let why = session.outOfRangeWords(band)
                    BandRow(
                        band: band, selected: session.band?.id == band.id,
                        squelchDb: session.channel?.squelchDb, disabled: why != nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { if why == nil { Task { await session.select(band: band) } } }
                    .help(why.map { "\(band.name) is \($0)" } ?? "")
                }
                header("Bookmarks") {
                    Button {
                        session.bookmarkCurrent()
                    } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkTertiary)
                    .disabled(session.tunedHz == nil)
                    .help("Bookmark the tuned frequency (⌘D)")
                }
                if session.bookmarks.list.isEmpty {
                    Text(
                        "Nothing saved yet. ＋ keeps the tuned frequency; `ley bookmarks` shows the same list."
                    )
                    .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
                ForEach(session.bookmarks.list) { b in
                    let tuned = session.tunedHz == b.hz
                    BookmarkRow(
                        bookmark: b, selected: tuned, modified: tuned && session.bookmarkModified,
                        recording: session.isRecording(b),
                        editing: Binding(
                            get: { session.editingBookmarkID == b.id },
                            set: {
                                if !$0, session.editingBookmarkID == b.id {
                                    session.editingBookmarkID = nil
                                }
                            })
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if session.editingBookmarkID != b.id { session.tune(bookmark: b) }
                    }
                    .contextMenu {
                        Button("Tune") { session.tune(bookmark: b) }
                        Button("Rename") { session.editingBookmarkID = b.id }
                        if tuned, session.bookmarkModified {
                            Button("Save mode and width") { session.saveTunedBookmark() }
                        }
                        // Moves the bookmark to the tuned frequency: the name stays, the
                        // frequency, mode and width become the channel's. Shown only when the
                        // tuned frequency differs from the bookmark's.
                        if let hz = session.tunedHz, hz != b.hz {
                            Button("Replace with \(Frequency.format(hz))") {
                                session.replace(bookmark: b)
                            }
                        }
                        Button("Remove", role: .destructive) { session.remove(bookmark: b) }
                    }
                }
                Spacer(minLength: 12)
            }
        }
        .background(Theme.panel)
    }

    private func header(_ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            SectionHeader(text: text)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

struct BandRow: View {
    let band: Band
    let selected: Bool
    let squelchDb: Double?
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(band.name).font(Theme.Font.label)
                    .foregroundStyle(
                        disabled ? Theme.inkDisabled : selected ? Theme.ink : Theme.inkSecondary)
                Spacer()
                Text(band.modeWord).font(Theme.Font.valueSmall).foregroundStyle(
                    disabled ? Theme.inkDisabled : Theme.inkFaint)
            }
            if selected {
                Text(detail).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, selected ? 7 : 5)
        .background(selected ? Theme.selected : Color.clear)
    }

    /// `87.5 – 108 MHz · 200 kHz · sq −28`, one line: the band's range, never the capture's,
    /// with trailing zeros dropped.
    private var detail: String {
        var parts = [
            "\(Frequency.mhz(band.minHz)) – \(Frequency.mhz(band.maxHz)) MHz",
            Frequency.width(band.bandwidthHz),
        ]
        if let s = squelchDb {
            parts.append(
                s.isNaN
                    ? "sq off"
                    : "sq \(String(Int(s.rounded())).replacingOccurrences(of: "-", with: "−"))")
        }
        return parts.joined(separator: " · ")
    }
}

/// The same "selected" style as the band row's: `selected` ground and a `good` dot on the tuned
/// bookmark, a faint dot on the rest (the in-span meaning the dot carried in M1 was not read
/// as one; the owner, 2026-09-21). `changed` in `caution` where the frequency was, when the
/// bookmark's settings and the channel's disagree. While a record job runs on the bookmark's
/// frequency and mode, tuned or not and whoever started it, an `accentRec` dot sits before the
/// frequency (M3 handoff, 8b). The row is an editor while `editing`.
struct BookmarkRow: View {
    let bookmark: Bookmark
    let selected: Bool
    let modified: Bool
    let recording: Bool
    @Binding var editing: Bool
    @Environment(AppSession.self) private var session

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(selected ? Theme.good : Theme.borderStrong).frame(width: 6, height: 6)
            if editing {
                NameField(initial: bookmark.name, font: Theme.Font.label, editing: $editing) {
                    session.rename(bookmark: bookmark, to: $0)
                }
            } else {
                Text(bookmark.name).font(Theme.Font.label)
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary).lineLimit(1)
            }
            Spacer()
            if recording {
                RecordingDot(size: Theme.Layout.sidebarDot)
                    .help("Recording \(bookmark.name) while its squelch is open")
            }
            if modified {
                Text("changed").font(Theme.Font.valueSmall).foregroundStyle(Theme.caution)
            } else {
                Text(Frequency.fieldParts(bookmark.hz).major)
                    .font(Theme.Font.valueSmall)
                    .foregroundStyle(selected ? Theme.inkTertiary : Theme.inkFaint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(selected ? Theme.selected : Color.clear)
    }
}
