// SPDX-License-Identifier: Apache-2.0

// The channel page (docs/design/app-design-handoff-m3.md, 8c, revised by "10a · The Library,
// revised"): the Library's centre column. A 56 pt header with the channel's name, what it is and
// how much is kept, the same Record transmissions switch as the log's (one job state, read from
// the mirror) and Tune; under it the parts as rows, by the day each started. A day opens with its
// head (`TODAY  7 parts · 1 m 17 s`, `Play day`) and a 24-hour strip; a recording of several
// parts is a bracket in the gutter and recordings are separated by a gap; days older than two are
// EARLIER, one line each, opening in place. A click on a row plays that part through the playback
// path the log's ▶ uses and selects it for the inspector (`PartInspector`) and the player; a click
// on the playing row pauses or resumes it. The page keeps no state of its own: the selection, the
// opened days, the queue and the level graphs are the session's, and every row is built from the
// listing and the manifests the session read (`Recordings.dayRows`). 8c's notice strip is gone
// with 10a: a refusal is the session's notice, which the Radio shows over its canvas.

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
            } else if session.selectedRecordingChannel != nil {
                // The row was selected and every recording on it has gone since (a delete here,
                // `ley recordings delete`, retention). With no row selected the store is empty,
                // and the sidebar's sentence says so.
                Text(
                    "Nothing is kept on this channel any more. Pick another row, or Radio to listen."
                )
                .font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .padding(20)
            }
        }
        .contentShape(Rectangle())
    }

    private func content(_ channel: RecordingChannel) -> some View {
        let groups = session.pageGroups(for: channel)
        let days = Recordings.dayRows(groups, now: Date())
        let recent = days.filter { !$0.earlier }
        let earlier = days.filter(\.earlier)
        return VStack(spacing: 0) {
            RecordingsPageHeader(channel: channel, groups: groups)
                .frame(height: Theme.Layout.pageHeaderHeight)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(recent) { day in
                        DaySection(day: day)
                            .padding(.top, Theme.Layout.pageDayGap)
                    }
                    if !earlier.isEmpty {
                        SectionHeader(text: "Earlier")
                            .padding(.top, Theme.Layout.pageDayGap).padding(.bottom, 8)
                        ForEach(earlier) { day in
                            EarlierDay(day: day, opened: session.openedDays.contains(day.id))
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
/// `Record transmissions`, its switch, and a bordered `Tune`, which goes to the Radio and tunes
/// there (8c, "The channel page").
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
            // One tint, always, as the log's switch (`RecordSwitch`).
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

    /// `462.6125 MHz · NFM 12.5 kHz · 4 recordings · 13.1 MB`.
    private var detail: String {
        "\(Self.tuningWords(channel, groups)) · \(Recordings.pageWords(groups))"
    }

    /// `462.6125 MHz · NFM 12.5 kHz`: the header's first clauses and the Library inspector's
    /// second line (`ChannelSummary`); the mode and width are left out when the recordings name
    /// none.
    static func tuningWords(_ channel: RecordingChannel, _ groups: [RecordingGroup]) -> String {
        var parts = [Frequency.format(channel.frequencyHz)]
        if channel.mode != .unspecified {
            let width = Recordings.channelWidth(groups, channel: channel)
            parts.append(
                width.map { "\(channel.mode.word) \(Frequency.width($0))" } ?? channel.mode.word)
        }
        return parts.joined(separator: " · ")
    }
}

/// A day of the page (10a): `TODAY` in `section` with `7 parts · 1 m 17 s` in `value` `inkMuted`
/// and `Play day` in `accent` at the right, then the 24-hour strip, the column head and the rows.
struct DaySection: View {
    let day: DayRows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionHeader(text: day.title)
                Text(day.headWords).font(Theme.Font.value).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                PlayDayButton(day: day)
            }
            .padding(.bottom, 10)
            DayBody(day: day)
        }
    }
}

/// `Play day`: the day's parts oldest first, as Play all plays a recording's
/// (`AppSession.playDay`).
struct PlayDayButton: View {
    let day: DayRows
    @Environment(AppSession.self) private var session

    var body: some View {
        Button {
            Task { await session.playDay(day) }
        } label: {
            Text("Play day").font(Theme.Font.label).foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .help("Play day")
    }
}

/// The strip, the column head and the rows of one day: under its head, or under an EARLIER line
/// that has been opened.
struct DayBody: View {
    let day: DayRows
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DayStrip(marks: day.marks, playingURI: session.playingURI)
                .frame(height: Theme.Layout.stripHeight)
                .padding(.bottom, 12)
            PartColumnHead().padding(.bottom, 4)
            ForEach(day.rows) { row in
                PartRowView(row: row)
                    .padding(.top, row.gapBefore ? Theme.Layout.recordingGap : 0)
            }
        }
    }
}

/// An EARLIER day (10a): `›  Monday  5 parts · 3 recordings` between hairlines; a click opens the
/// day's strip and rows in place under the line, the chevron turned down, and a second click
/// folds it. The session holds which are open (`openedDays`).
struct EarlierDay: View {
    let day: DayRows
    let opened: Bool
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right").font(Theme.Font.glyph)
                    .foregroundStyle(Theme.inkFaint)
                    .rotationEffect(.degrees(opened ? 90 : 0))
                    .frame(width: Theme.Layout.ringColumnWidth)
                Text(day.title).font(Theme.Font.label).foregroundStyle(Theme.ink).lineLimit(1)
                    .frame(width: Theme.Layout.earlierDayWidth, alignment: .leading)
                Text(day.earlierWords).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if opened { PlayDayButton(day: day) }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { session.toggleOpened(day: day.id) }
            .help(opened ? "Fold \(day.title)" : "Show \(day.title)'s parts")
            if opened {
                DayBody(day: day).padding(.top, 4).padding(.bottom, 12)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// The day's 24-hour strip (10a): a `border` track `stripTrackHeight` tall, ticks at 00, 06, 12,
/// 18 and 24 in `ground` with their labels under in `columnHead` `inkFaintest`, and a 2 pt mark
/// at each part's start in `inkSecondary`, the playing part's in `accent` and drawn last, so it
/// is never under another. A mark is placed by its fraction of the day and kept inside the track.
struct DayStrip: View {
    let marks: [DayMark]
    let playingURI: String?

    var body: some View {
        Canvas { ctx, size in
            // Local rather than a static of this view: a view's static is main-actor isolated,
            // and the renderer is not guaranteed to be (docs/dev/swift-style.md, "Working as an
            // agent on this repository").
            let hours = [0, 6, 12, 18, 24]
            let track = Theme.Layout.stripTrackHeight
            let markHeight = Theme.Layout.stripMarkHeight
            let trackTop = (markHeight - track) / 2
            ctx.fill(
                Path(
                    roundedRect: CGRect(x: 0, y: trackTop, width: size.width, height: track),
                    cornerRadius: 2), with: .color(Theme.border))
            for h in hours {
                let x = min(max(0, size.width * CGFloat(h) / 24), size.width - 1)
                if h != 0, h != 24 {
                    ctx.fill(
                        Path(CGRect(x: x, y: trackTop, width: 1, height: track)),
                        with: .color(Theme.ground))
                }
                let anchor: UnitPoint = h == 0 ? .topLeading : h == 24 ? .topTrailing : .top
                ctx.draw(
                    Text(String(format: "%02d", h)).font(Theme.Font.columnHead)
                        .foregroundStyle(Theme.inkFaintest),
                    at: CGPoint(
                        x: h == 0 ? 0 : h == 24 ? size.width : x,
                        y: markHeight + Theme.Layout.stripLabelGap),
                    anchor: anchor)
            }
            let width = Theme.Layout.stripMarkWidth
            let ordered =
                marks.filter { $0.uri != playingURI } + marks.filter { $0.uri == playingURI }
            for m in ordered {
                let f = m.fraction.isFinite ? m.fraction : 0
                let x = min(max(0, size.width * CGFloat(f) - width / 2), size.width - width)
                ctx.fill(
                    Path(CGRect(x: x, y: 0, width: width, height: markHeight)),
                    with: .color(m.uri == playingURI ? Theme.accent : Theme.inkSecondary))
            }
        }
        .accessibilityLabel("\(marks.count) parts through the day")
    }
}

/// `STARTS  LENGTH  LEVEL  …  PEAK  SIZE` in `columnHead` `inkFaintest`, on the rows' columns.
struct PartColumnHead: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Theme.Layout.ringColumnWidth + Theme.Layout.bracketColumnWidth)
            head("Starts").frame(width: Theme.Layout.startsWidth, alignment: .leading)
            head("Length").frame(width: Theme.Layout.lengthWidth, alignment: .leading)
            head("Level").frame(maxWidth: .infinity, alignment: .leading)
            head("Peak").frame(width: Theme.Layout.peakWidth, alignment: .trailing)
            head("Size").frame(width: Theme.Layout.sizeWidth, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Layout.partRowInset)
    }

    private func head(_ text: String) -> some View {
        Text(text.uppercased()).font(Theme.Font.columnHead).tracking(Theme.sectionTracking)
            .foregroundStyle(Theme.inkFaintest).lineLimit(1)
    }
}

/// One part (10a): the ring, the gutter's bracket, `STARTS`, `LENGTH`, the level graph, `PEAK`
/// and `SIZE`. The ring is 18 pt with ▶ in `inkSecondary`; the playing row's is a 28 pt `accent`
/// circle with ⏸, or ▶ while paused, and the row sits on `raised`. The whole row is the button:
/// a click plays the part, and on the playing row pauses or resumes it (`AppSession.clickRow`).
/// The level graph is read as the row appears (`AppSession.loadLevelGraph`).
struct PartRowView: View {
    let row: PartRow
    @Environment(AppSession.self) private var session

    var body: some View {
        let playing = session.playingURI == row.uri
        let paused = playing && session.isPaused
        let words = row.words()
        Button {
            Task { await session.clickRow(row.uri) }
        } label: {
            HStack(spacing: 0) {
                ring(playing: playing, paused: paused)
                    .frame(width: Theme.Layout.ringColumnWidth)
                bracket.frame(width: Theme.Layout.bracketColumnWidth)
                Text(words.starts).font(Theme.Font.value).foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .frame(width: Theme.Layout.startsWidth, alignment: .leading)
                Text(words.length).font(Theme.Font.value).foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .frame(width: Theme.Layout.lengthWidth, alignment: .leading)
                LevelBars(levels: session.levelGraphs[row.uri] ?? [], playing: playing)
                    .frame(height: Theme.Layout.levelGraphHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(words.peak).font(Theme.Font.value)
                    .foregroundStyle(row.clipped ? Theme.accentRec : Theme.inkSecondary)
                    .lineLimit(1)
                    .frame(width: Theme.Layout.peakWidth, alignment: .trailing)
                Text(words.size).font(Theme.Font.value).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .frame(width: Theme.Layout.sizeWidth, alignment: .trailing)
            }
            .padding(.horizontal, Theme.Layout.partRowInset)
            .frame(height: Theme.Layout.partRowHeight)
            .background(
                playing ? Theme.raised : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Layout.partRowRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(playing ? (paused ? "Resume" : "Pause") : "Play")
        .onAppear { session.loadLevelGraph(row) }
    }

    @ViewBuilder private func ring(playing: Bool, paused: Bool) -> some View {
        if playing {
            let size = Theme.Layout.playingRingSize
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(Theme.Font.playingGlyph).foregroundStyle(Theme.ground)
                .frame(width: size, height: size)
                .background(Theme.accent, in: Circle())
        } else {
            let size = Theme.Layout.logRingSize
            Image(systemName: "play.fill")
                .font(Theme.Font.glyph).foregroundStyle(Theme.inkSecondary)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Theme.border))
        }
    }

    /// The recording's bracket down the gutter: a 2 pt `border` line at the column's centre,
    /// from the top of this row's text down on its first row, through the middle rows, and to
    /// the bottom of the text on its last, so the line spans the recording's rows from the first
    /// part's words to the last's (the owner, 2026-09-25: a line that started at the row's
    /// middle stopped half way up the text). The rows of one recording have no gap between
    /// them, so the pieces join.
    @ViewBuilder private var bracket: some View {
        let line = Rectangle().fill(Theme.border).frame(width: Theme.Layout.bracketWidth)
        switch row.bracket {
        case .none:
            Color.clear
        case .first:
            line.frame(maxHeight: .infinity).padding(.top, Theme.Layout.bracketTextInset)
        case .middle:
            line.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .last:
            line.frame(maxHeight: .infinity).padding(.bottom, Theme.Layout.bracketTextInset)
        }
    }
}

/// The part's level graph (10a): one bar a column (`LevelGraph`), `levelBarWidth` wide at
/// `levelBarPitch`, centred on the row's middle, its height the column's level over the graph's
/// height with `levelBarMinHeight` for the floor so silence still shows the part's length;
/// `inkTertiary`, the playing part's `accent`. Empty while the file is read or when it cannot be.
/// Columns that would cross the space given are left out.
struct LevelBars: View {
    let levels: [Float]
    let playing: Bool

    var body: some View {
        Canvas { ctx, size in
            let pitch = Theme.Layout.levelBarPitch
            let width = Theme.Layout.levelBarWidth
            let colour = playing ? Theme.accent : Theme.inkTertiary
            for (i, v) in levels.enumerated() {
                let x = CGFloat(i) * pitch
                guard x + width <= size.width else { break }
                let level = v.isFinite ? CGFloat(min(max(v, 0), 1)) : 0
                let h = max(Theme.Layout.levelBarMinHeight, level * size.height)
                ctx.fill(
                    Path(CGRect(x: x, y: (size.height - h) / 2, width: width, height: h)),
                    with: .color(colour))
            }
        }
        .accessibilityHidden(true)
    }
}
