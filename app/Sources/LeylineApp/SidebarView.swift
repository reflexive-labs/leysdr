// SPDX-License-Identifier: Apache-2.0

// Region 1: two sources under a `Radio | Recordings` control, and the recording store's footer
// under both (docs/design/app-design-handoff-m3.md, "In every screen"). Radio is the bands and
// bookmarks (docs/design/app-design-handoff.md): a band is a frequency range, a bookmark a saved
// station; selecting a band applies all of its settings and the expanded row shows them, and a
// bookmark that is recording has a dot. Recordings is the store grouped by channel, one row per
// frequency and mode and never one per recording, because a file on disk is not a place to tune
// and a flat list grew without bound ("What this replaces"). Selecting a row puts that channel's
// page in the centre column (`RecordingsPage.swift`).

import LeylineClient
import LeylineProto
import SwiftUI

struct SidebarView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            Picker(
                "Source",
                selection: Binding(
                    get: { session.sidebarSource }, set: { session.sidebarSource = $0 })
            ) {
                ForEach(SidebarSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .tint(Theme.selected)
            .padding(.horizontal, 14).padding(.top, 12)
            switch session.sidebarSource {
            case .radio: radio
            case .recordings: RecordingsSource()
            }
            if session.isLive { StoreFooter() }
        }
        .background(Theme.panel)
    }

    private var radio: some View {
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
/// frequency and mode, tuned or not and whoever started it, a 6 pt `accentRec` dot sits 6 pt
/// left of the frequency, whose ink does not change (M3 handoff, 8b). The row is an editor while
/// `editing`.
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
            // The dot sits against the frequency, 6 pt from it, not against the name (8b).
            HStack(spacing: Theme.Layout.bookmarkDotGap) {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(selected ? Theme.selected : Color.clear)
    }
}

/// The Recordings source: a search field, then one row per channel (`Recordings.channels`),
/// running ones first and then by most recent activity (M3 handoff, 8c). A click selects a row and
/// shows its channel page; a second click on it clears the selection and gives the centre column
/// back to the radio.
struct RecordingsSource: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let now = Date()
        let all = session.recordingChannels
        let rows = all.filter { $0.matches(session.recordingsQuery, now: now) }
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        // Two literals rather than one ternary, so the first renders its code
                        // span as the bookmarks' empty line does.
                        if all.isEmpty {
                            Text(
                                "Nothing recorded yet. Record transmissions in the inspector (⌘R) keeps the tuned channel; `ley recordings` lists the same store."
                            )
                        } else if rows.isEmpty {
                            Text("No recording matches “\(session.recordingsQuery)”.")
                        }
                    }
                    .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    ForEach(rows) { c in
                        let selected = session.selectedRecordingChannel == c.id
                        RecordingChannelRow(channel: c, selected: selected, now: now)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                session.selectedRecordingChannel = selected ? nil : c.id
                            }
                    }
                    Spacer(minLength: 12)
                }
            }
        }
    }
}

/// `GMRS CH3` over `4 recordings · latest now`: the title in `label`, a bookmark's name or the
/// frequency in mono; the subtitle in `footnote` `inkFaint`; a 6 pt `accentRec` dot at the right
/// while one of its recordings runs; `raised` ground when selected (M3 handoff, 8c). The tooltip
/// gives the frequency and mode a name hides.
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

/// The store footer at the sidebar's foot, in both sources (M3 handoff, "In every screen"): a 3 pt
/// bar, `border` track and `inkTertiary` fill for the used fraction, then `944 MB of 20 GB ·
/// oldest go first` in `footnote` `inkFaint`. Used is the listing's sizes summed; the cap is the
/// daemon's (`DaemonInfo.recordings_cap_bytes`). Read-only: the cap is `leylined
/// --recordings-cap`. Without a cap the bar has no fill and the line no `of …` clause.
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
