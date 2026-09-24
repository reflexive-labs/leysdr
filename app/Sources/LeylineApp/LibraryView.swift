// SPDX-License-Identifier: Apache-2.0

// The Library, the window's second place (docs/design/app-design-handoff-m3.md, "Decided
// 2026-09-25: the Library"): what has been kept, in place of the whole body under the toolbar.
// A 236 pt sidebar with the search field, the channels and the store footer; the channel page in
// the centre (`RecordingsPage.swift`, 8c); in the inspector the part (`PartInspector.swift`) or,
// with none selected, the channel's lines; and the player in the transport bar's place
// (`PlayerBar.swift`). The live radio keeps running underneath: its capture, channel and feeds
// are the session's, and a part that plays holds the live channel silent until it ends
// (`AppSession.play(partURI:)`). Nothing here is state of its own beyond the delete alert's:
// the selection, the query and the opened cards are the session's.

import LeylineClient
import LeylineProto
import SwiftUI

struct LibraryBody: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LibrarySidebar()
                    .frame(width: Theme.Layout.sidebarWidth)
                Rectangle().fill(Theme.border).frame(width: 1)
                RecordingsPage()
                if session.inspectorShown {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    LibraryInspector()
                        .frame(width: Theme.Layout.inspectorWidth)
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            PlayerBar()
                .frame(height: Theme.Layout.transportHeight)
        }
    }
}

/// The search field at the top, a `CHANNELS` section with one row per channel
/// (`Recordings.channels`, running ones first and then by most recent activity, 8c), and the store
/// footer at the foot. A click selects a row and shows its page; a click on the selected row keeps
/// it, so the centre is never blank. With nothing kept the body is one sentence.
struct LibrarySidebar: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let now = Date()
        let all = session.recordingChannels
        let rows = all.filter { $0.matches(session.recordingsQuery, now: now) }
        VStack(alignment: .leading, spacing: 0) {
            if all.isEmpty {
                Text(
                    "Nothing kept yet. Switch on Record transmissions on a channel, or run ley record."
                )
                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.top, 14)
                Spacer(minLength: 0)
            } else {
                search
                SectionHeader(text: "Channels")
                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if rows.isEmpty {
                            Text("No channel matches “\(session.recordingsQuery)”.")
                                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                        }
                        ForEach(rows) { c in
                            RecordingChannelRow(
                                channel: c, selected: session.selectedRecordingChannel == c.id,
                                now: now
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { session.selectedRecordingChannel = c.id }
                        }
                        Spacer(minLength: 12)
                    }
                }
            }
            if session.isLive { StoreFooter() }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    /// `⌕ Search recordings` on `ground` with a `border` (8c): matches a channel's name, its
    /// frequency and the days its recordings started (`RecordingChannel.matches`).
    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10))
                .foregroundStyle(Theme.inkFaint)
            TextField(
                "Search recordings",
                text: Binding(
                    get: { session.recordingsQuery }, set: { session.recordingsQuery = $0 })
            )
            .textFieldStyle(.plain).font(Theme.Font.label).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Theme.ground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
        .padding(.horizontal, 14).padding(.top, 12)
    }
}

/// The Library's inspector: the selected or playing part (`PartInspector`, 8c), else the selected
/// channel's lines (`ChannelSummary`), else the panel's ground.
struct LibraryInspector: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if let p = session.inspectedPart {
            PartInspector(manifest: p.manifest, part: p.part, group: p.group)
        } else if let c = session.selectedChannel {
            ChannelSummary(channel: c, groups: session.pageGroups(for: c))
        } else {
            Theme.panel
        }
    }
}

/// With no part selected, the channel's lines: the name in `name`, `462.6125 MHz · NFM 12.5 kHz`
/// and `4 recordings · 13.1 MB` in `value` `inkMuted` (the page header's words, on two lines),
/// and a bordered `Show in Finder` for the channel's newest recording, whose directory holds its
/// parts.
struct ChannelSummary: View {
    let channel: RecordingChannel
    let groups: [RecordingGroup]
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(channel.title)
                    .font(Theme.Font.name).tracking(Theme.nameTracking)
                    .foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                Text(RecordingsPageHeader.tuningWords(channel, groups))
                    .font(Theme.Font.value).foregroundStyle(Theme.inkMuted).lineLimit(1)
                Text(Recordings.pageWords(groups))
                    .font(Theme.Font.value).foregroundStyle(Theme.inkMuted).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let newest = channel.recordings.first {
                Button("Show in Finder") {
                    Task { await session.revealInFinder(uri: newest.uri) }
                }
                .buttonStyle(.bordered)
                .help("Show the newest recording of \(channel.title) in Finder")
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }
}

/// `GMRS CH3` over `4 recordings · latest now`: the title in `label`, a bookmark's name or the
/// frequency in mono; the subtitle in `footnote` `inkFaint`; a 6 pt `accentRec` dot at the right
/// while one of its recordings runs; `raised` ground when selected (M3 handoff, 8c, kept by the
/// Library). The tooltip gives the frequency and mode a name hides.
struct RecordingChannelRow: View {
    let channel: RecordingChannel
    let selected: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title)
                    .font(channel.bookmarkName == nil ? Theme.Font.labelMono : Theme.Font.label)
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary).lineLimit(1)
                Text(channel.subtitle(now: now)).font(Theme.Font.footnote)
                    .foregroundStyle(Theme.inkFaint).lineLimit(1)
            }
            Spacer(minLength: 8)
            if channel.running { RecordingDot(size: Theme.Layout.sidebarDot) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(selected ? Theme.raised : Color.clear)
        .help(help)
    }

    private var help: String {
        let mode = channel.mode == .unspecified ? "" : " \(channel.mode.word)"
        let running = channel.running ? "; recording now" : ""
        return "\(Frequency.format(channel.frequencyHz))\(mode)\(running)"
    }
}

/// The store footer at the Library sidebar's foot (M3 handoff, "In every screen", moved to the
/// Library by "Decided 2026-09-25: the Library", where it is about the thing listed): a 3 pt bar,
/// `border` track and `inkTertiary` fill for the used fraction, then `3.3 GB of 20 GB · oldest go
/// first` in `footnote` `inkFaint`. Used is the listing's sizes summed; the cap is the daemon's
/// (`DaemonInfo.recordings_cap_bytes`). Read-only: the cap is `leylined --recordings-cap`.
/// Without a cap the bar has no fill and the line no `of …` clause.
struct StoreFooter: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let used = session.storeUsedBytes
        let cap = session.storeCapBytes
        let fraction = Recordings.storeFraction(usedBytes: used, capBytes: cap)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.border)
                    if let fraction {
                        Rectangle().fill(Theme.inkTertiary)
                            .frame(width: geo.size.width * fraction)
                    }
                }
            }
            .frame(height: Theme.Layout.storeBarHeight)
            Text(Recordings.storeWords(usedBytes: used, capBytes: cap))
                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .help(
            cap > 0
                ? "The daemon's recordings cap is \(Recordings.storeSizeWords(cap)) (leylined --recordings-cap); past it the oldest recordings are removed first"
                : "This daemon does not report its recordings cap")
    }
}
