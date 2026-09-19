// SPDX-License-Identifier: Apache-2.0

// Region 1: bands and bookmarks (docs/design/app-design-handoff.md). A band is a place to look;
// a bookmark is a station to return to. Selecting a band configures everything it implies and
// the expanded row says what that was.

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
                    // A band the radio cannot reach stays listed, disabled, and the hover says
                    // why: a click that could only fail is not offered.
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
                    BookmarkRow(
                        bookmark: b, tuned: session.tunedHz == b.hz,
                        inSpan: session.visibleRange?.contains(b.hz) ?? false
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { session.tune(bookmark: b) }
                    .contextMenu {
                        Button("Tune") { session.tune(bookmark: b) }
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
    /// with the zeros a person would not say dropped.
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

struct BookmarkRow: View {
    let bookmark: Bookmark
    let tuned: Bool
    let inSpan: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tuned ? Theme.ground : (inSpan ? Theme.good : Theme.borderStrong)).frame(
                width: 6, height: 6)
            Text(bookmark.name).font(Theme.Font.label).foregroundStyle(
                tuned ? Theme.ground : Theme.inkSecondary
            ).lineLimit(1)
            Spacer()
            Text(Frequency.fieldParts(bookmark.hz).major)
                .font(Theme.Font.valueSmall)
                .foregroundStyle(tuned ? Theme.ground : Theme.inkTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(tuned ? Theme.accent : Color.clear)
    }
}
