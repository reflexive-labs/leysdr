// SPDX-License-Identifier: Apache-2.0

// The Recordings source's channel page (docs/design/app-design-handoff-m3.md, 8c, and "The
// screens, read against the prose", 8c): the centre column while the source shows and a channel
// row is selected. A 56 pt header with the channel's name, what it is and how much is kept, the
// same Record transmissions switch as the log's (one job state, read from the mirror) and Tune;
// under it the recordings as cards grouped by day, newest first, each card's parts as chips that
// wrap. A click on a chip plays that part through the playback path the log's ▶ uses and selects
// it for the inspector (`PartInspector`); Play all plays the parts in order. The page keeps no
// state of its own beyond hover: which cards are open, the selected part and the queue are the
// session's, and every card is built from the listing and the manifests the session read
// (`Recordings.groups`, `Recordings.days`).

import LeylineClient
import LeylineProto
import SwiftUI

struct RecordingsPage: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        ZStack {
            Theme.ground
            if let channel = session.selectedChannel {
                content(channel)
            } else {
                // The row was selected and every recording on it has gone since (a delete here,
                // `ley recordings delete`, retention).
                Text(
                    "Nothing is kept on this channel any more. Pick another row, or Radio to listen."
                )
                .font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .padding(20)
            }
        }
        // Opaque and taking the clicks, so nothing of the live canvas under it is tuned.
        .contentShape(Rectangle())
    }

    private func content(_ channel: RecordingChannel) -> some View {
        let now = Date()
        let groups = session.pageGroups(for: channel)
        let days = Recordings.days(groups, now: now)
        return VStack(spacing: 0) {
            RecordingsPageHeader(channel: channel, groups: groups)
                .frame(height: Theme.Layout.pageHeaderHeight)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(days) { day in
                        SectionHeader(text: day.title)
                            .padding(.top, Theme.Layout.pageDayGap).padding(.bottom, 10)
                        ForEach(day.recordings) { g in
                            RecordingCard(
                                group: g,
                                collapsed: day.collapsed
                                    && !session.openedRecordings.contains(g.uri),
                                foldable: day.collapsed, now: now
                            )
                            .padding(.bottom, Theme.Layout.cardGap)
                        }
                    }
                }
                .padding(.horizontal, Theme.Layout.pageInset)
                .padding(.bottom, Theme.Layout.pageInset)
            }
        }
    }
}

/// `GMRS CH3` over `462.6125 MHz · NFM 12.5 kHz · 4 recordings · 13.1 MB`, and at the right
/// `Record transmissions`, its switch, and a bordered `Tune` (8c, "The channel page").
struct RecordingsPageHeader: View {
    let channel: RecordingChannel
    let groups: [RecordingGroup]
    @Environment(AppSession.self) private var session

    var body: some View {
        let job = session.activeRecordJob(for: channel)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.title)
                    .font(Theme.Font.name).tracking(Theme.nameTracking)
                    .foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                Text(detail).font(Theme.Font.value).foregroundStyle(Theme.inkMuted).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text("Record transmissions").font(Theme.Font.label)
                .foregroundStyle(Theme.inkSecondary).lineLimit(1)
            Toggle(
                "Record transmissions",
                isOn: Binding(
                    get: { session.pageSwitchOn(for: channel) },
                    set: { on in Task { await session.setRecording(on, channel: channel) } })
            )
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
            .tint(Theme.accentRec)
            .disabled(!session.isLive)
            .help(
                job == nil
                    ? "Record this channel while its squelch is open, at the daemon's auto squelch. The daemon keeps recording after the window closes."
                    : "Stop recording \(job?.jobID ?? ""); its parts stay on disk")
            Button("Tune") { session.tune(recordingChannel: channel) }
                .buttonStyle(.bordered)
                .help("Back to Radio, tuned to \(Frequency.format(channel.frequencyHz))")
        }
        .padding(.horizontal, Theme.Layout.pageInset)
    }

    /// `462.6125 MHz · NFM 12.5 kHz · 4 recordings · 13.1 MB`; the mode and width are left out
    /// when the recordings name none.
    private var detail: String {
        var parts = [Frequency.format(channel.frequencyHz)]
        if channel.mode != .unspecified {
            let width = Recordings.channelWidth(groups, channel: channel)
            parts.append(
                width.map { "\(channel.mode.word) \(Frequency.width($0))" } ?? channel.mode.word)
        }
        parts.append(Recordings.pageWords(groups))
        return parts.joined(separator: " · ")
    }
}

/// One recording (8c): a card on `panel` with a 1 pt `border`, `accentRec` at 40 % while it
/// runs. The header line is `● 09:12 — now` in mono (the dot only while running), `3 parts · 24 s
/// · 1.1 MB` beside it, and at the right `recording` or Play all; the parts wrap under it as
/// chips. A card in the earlier group is its header line alone with a chevron until clicked open,
/// and a click on an open one folds it again.
struct RecordingCard: View {
    let group: RecordingGroup
    let collapsed: Bool
    /// In the earlier group, so the header line opens and folds it.
    let foldable: Bool
    let now: Date
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !collapsed, !group.chips.isEmpty {
                FlowLayout(spacing: Theme.Layout.chipGap, lineSpacing: Theme.Layout.chipGap) {
                    ForEach(group.chips) { chip in
                        PartChip(
                            chip: chip, playing: session.playingURI == chip.uri,
                            selected: session.selectedPartURI == chip.uri
                        ) {
                            Task { await session.clickChip(chip.uri) }
                        }
                    }
                }
            }
        }
        .padding(Theme.Layout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Layout.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.cardRadius)
                .stroke(group.running ? Theme.accentRec.opacity(0.4) : Theme.border))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if group.running { RecordingDot() }
            Text(group.rangeWords(collapsed: foldable, now: now))
                .font(Theme.Font.value).foregroundStyle(Theme.ink).lineLimit(1)
            Text(group.countWords(collapsed: collapsed))
                .font(Theme.Font.label).foregroundStyle(Theme.inkMuted).lineLimit(1)
            Spacer(minLength: 8)
            if group.running {
                Text("recording").font(Theme.Font.label).foregroundStyle(Theme.accentRec)
            } else if !collapsed {
                playAll
            }
            if foldable {
                // An opened card keeps its chevron, turned down, and its header folds it again.
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.inkFaint)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if foldable { session.toggleOpened(group.uri) } }
    }

    private var playAll: some View {
        Button {
            Task { await session.playAll(group) }
        } label: {
            Text("Play all").font(Theme.Font.label)
                .foregroundStyle(group.chips.isEmpty ? Theme.inkDisabled : Theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(group.chips.isEmpty)
        .help("Play the \(RecordingSummary.partsWords(group.chips.count)) in order")
    }
}

/// `▶ 09:12:40 · 8 s` in `valueSmall` mono on `ground` with a `border` stroke; while that part
/// plays `■` on `accent` at 15 % with an `accent` stroke. The selected part (the last one
/// clicked, which the inspector shows) has a `borderFocus` stroke when it is not playing.
struct PartChip: View {
    let chip: RecordingChip
    let playing: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: playing ? "stop.fill" : "play.fill").font(Theme.Font.glyph)
                Text(chip.words()).font(Theme.Font.valueSmall).lineLimit(1)
            }
            .foregroundStyle(playing ? Theme.accent : Theme.inkSecondary)
            .padding(.horizontal, Theme.Layout.chipInsetH)
            .padding(.vertical, Theme.Layout.chipInsetV)
            .background(
                playing ? Theme.accent.opacity(0.15) : Theme.ground,
                in: RoundedRectangle(cornerRadius: Theme.Layout.chipRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.chipRadius)
                    .stroke(playing ? Theme.accent : selected ? Theme.borderFocus : Theme.border)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Layout.chipRadius))
        }
        .buttonStyle(.plain)
        .help(
            playing
                ? "Stop the part; the channel's audio comes back"
                : "Play part \(chip.part) through the daemon's speakers; the channel's audio is held silent until it ends"
        )
    }
}

/// Subviews left to right, a subview moved to the next line when it would cross the proposed
/// width, by `FlowRows.lines` so the rule is the one the façade tests. Each subview takes its
/// ideal size.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let limit: CGFloat
        if let w = proposal.width, w.isFinite {
            limit = w
        } else {
            limit = .greatestFiniteMagnitude
        }
        let lines = lineIndices(sizes, width: limit)
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for (n, line) in lines.enumerated() {
            var lineWidth: CGFloat = 0
            var lineHeight: CGFloat = 0
            for (k, i) in line.enumerated() {
                lineWidth += sizes[i].width + (k == 0 ? 0 : spacing)
                lineHeight = max(lineHeight, sizes[i].height)
            }
            widest = max(widest, lineWidth)
            height += lineHeight + (n == 0 ? 0 : lineSpacing)
        }
        let width = limit == .greatestFiniteMagnitude ? widest : limit
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in lineIndices(sizes, width: bounds.width) {
            var x = bounds.minX
            var lineHeight: CGFloat = 0
            for i in line {
                subviews[i].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
                lineHeight = max(lineHeight, sizes[i].height)
            }
            y += lineHeight + lineSpacing
        }
    }

    private func lineIndices(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        FlowRows.lines(
            widths: sizes.map { Double($0.width) }, spacing: Double(spacing), width: Double(width))
    }
}
