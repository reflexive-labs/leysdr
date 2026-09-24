// SPDX-License-Identifier: Apache-2.0

// The inspector's lower half (docs/design/app-design-handoff-m2.md, Regions 4 and 5): the log
// of recent transmissions on the tuned channel, straight from the façade's `TransmissionLog`,
// with the Record transmissions switch at its head (docs/design/app-design-handoff-m3.md, 8a and
// 8b), and the Measurements group holding the raw levels the reading rows do not print. A row is
// not clickable (the shared selection with the waterfall is M3's, and a clickable row that
// highlights nothing would be misleading); the switch and a kept row's ▶ are the only controls.

import Foundation
import LeylineClient
import LeylineProto
import SwiftUI

/// Region 4: `TRANSMISSIONS` with the newest row's day at the right, the Record transmissions
/// switch and its line, then the rows, newest first, the open one on `raised` ground with `now`
/// in `accent`; no column head and no count, as the recording handoff's screens draw it
/// (docs/design/app-design-handoff-m3.md, "In every screen"). The log takes the height the panel
/// leaves it and shows as many rows as fit, five at least, which is the handoff's count at its
/// 820 pt window. Time is wall clock when the anchor covers it and relative (`−2:14`) when it
/// does not; both formats can appear in one list, because the alternative is a timestamp nobody
/// measured. Tone is not a column: a CTCSS tone the daemon reported is appended to that row's
/// signal cell in `good`, and a row without one leaves the tone blank. Every row is a transmission heard live; the log never back-fills from a
/// recording (M3 handoff, "The rule"). A row whose transmission lies inside a part of the tuned
/// channel's recording is kept: its time and length in `ink`, ▶ in a ring at its right, and
/// Show in Finder in its context menu. A heard row's time and length are `inkTertiary` and it has
/// no ▶, because nothing of it is on disk.
struct RecentLog: View {
    @Environment(AppSession.self) private var session

    static let minRows = 5
    /// The height above and below the rows: the padding and the section header, rounded up so
    /// the count errs toward one row fewer rather than a clipped one.
    static let chromeHeight: CGFloat = 44
    /// The switch's row, its line under it at two lines (the status line wraps at the panel's
    /// width, and the region gives it the room rather than a row) and the gap before the rows,
    /// rounded up the same way.
    static let switchHeight: CGFloat = 62

    var body: some View {
        GeometryReader { geo in
            let fit = Int(
                (geo.size.height - Self.chromeHeight - Self.switchHeight)
                    / Theme.Layout.logRowHeight)
            content(rows: max(Self.minRows, fit))
        }
        .frame(
            minHeight: Self.chromeHeight + Self.switchHeight + CGFloat(Self.minRows)
                * Theme.Layout.logRowHeight
        )
        .clipped()
    }

    private func content(rows: Int) -> some View {
        let log = session.transmissions
        let open = log?.onAir
        let room = rows - (open == nil ? 0 : 1)
        let closed = Array((log?.closed ?? []).prefix(max(0, room)))
        // The live dot: a part is being written while the job runs and the squelch is open.
        let writing = open != nil && session.recordingJob?.state == .running
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(text: "Transmissions")
                Spacer(minLength: 8)
                Text(dayWords(log)).font(Theme.Font.columnHead).foregroundStyle(Theme.inkFaint)
                    .lineLimit(1)
            }
            .padding(.bottom, 6)
            RecordSwitch().padding(.bottom, 8)
            if let open {
                LogRow(
                    time: Text("now").foregroundStyle(Theme.accent),
                    length: Reading.seconds(session.timeOnAirSeconds ?? .nan),
                    lengthInk: Theme.inkSecondary,
                    signal: session.channelReading?.signalWord?.word ?? Reading.absent,
                    tone: open.tone, open: true, trailing: writing ? .writing : .empty)
            }
            // Keyed by capture and start sample, so a new transmission adds a row instead of
            // changing what every row's position means.
            ForEach(closed, id: \.start) { t in
                let uri = session.keptPartURI(t)
                let ink = uri == nil ? Theme.inkTertiary : Theme.ink
                LogRow(
                    time: Text(timeWords(t)).foregroundStyle(ink),
                    length: Reading.seconds(t.seconds), lengthInk: ink,
                    signal: SignalWord(overNoiseDB: t.peakSNRDB)?.word ?? Reading.absent,
                    tone: t.tone, open: false,
                    trailing: uri.map { LogRow.Trailing.part(part($0)) } ?? .empty
                )
                .contextMenu {
                    if let uri {
                        Button("Show in Finder") {
                            Task { await session.revealInFinder(partURI: uri) }
                        }
                    }
                }
            }
            if open == nil, closed.isEmpty {
                Text(
                    log == nil
                        ? "No channel."
                        : "Nothing yet. A transmission is logged when the squelch closes behind it."
                )
                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                .padding(.horizontal, 6).padding(.top, 4)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// The header's day: `today`, `yesterday`, a weekday, of the newest row's start as wall
    /// clock through the tuned capture's anchor (`Recordings.dayWords`); blank with no row or no
    /// anchor, because a day nobody measured is not printed (M2-1's rule).
    private func dayWords(_ log: TransmissionLog?) -> String {
        guard let newest = log?.onAir?.since ?? log?.closed.first?.start,
            let date = session.wallTime(of: newest)
        else { return "" }
        return Recordings.dayWords(date, now: Date())
    }

    /// A row's wall clock through the tuned capture's anchor; relative when it does not date it.
    private func timeWords(_ t: Transmission) -> String {
        if let date = session.wallTime(of: t.start) { return WallClock.hms(date) }
        return Reading.relative(secondsAgo: session.secondsAgo(t.start) ?? .nan)
    }

    /// A kept row's play control on the part at `uri`.
    private func part(_ uri: String) -> LogRow.Part {
        let playing = session.playingURI == uri
        return LogRow.Part(
            playing: playing, progress: playing ? session.playbackProgress : nil
        ) {
            Task {
                if playing {
                    await session.stopPlayback()
                } else {
                    await session.play(partURI: uri)
                }
            }
        }
    }
}

/// The head of the log (M3 handoff, 8a and 8b): `Record transmissions` and a switch, then one
/// line. Off, the line says what switching on does, and it is the region's only explanatory
/// copy. On, it is the recording's status: since when, its parts and bytes from the manifest,
/// and that it outlives a retune; while the job is degraded, the daemon's `status_detail` in
/// `caution`. The switch shows the record job on the tuned channel's frequency and mode, whoever
/// started it (`AppSession.recordingJob`), and remembers nothing of its own clicks; between a
/// click and the job's event it shows the click (`AppSession.recordSwitchOn`).
struct RecordSwitch: View {
    @Environment(AppSession.self) private var session

    static let help = "Each transmission becomes a part, cut at dead air."

    var body: some View {
        let job = session.recordingJob
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Record transmissions").font(Theme.Font.label)
                    .foregroundStyle(Theme.inkSecondary).lineLimit(1)
                Spacer(minLength: 8)
                Toggle(
                    "Record transmissions",
                    isOn: Binding(
                        get: { session.recordSwitchOn },
                        set: { on in Task { await session.setRecording(on) } })
                )
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .tint(Theme.accentRec)
                .disabled(session.tunedHz == nil)
                .help(
                    job == nil
                        ? "Record this channel while its squelch is open (⌘R). The daemon keeps recording after the window closes."
                        : "Stop recording \(job?.jobID ?? "") (⌘R); its parts stay on disk")
            }
            Group {
                if let job {
                    Text(Recordings.statusLine(job: job, manifest: session.recording))
                        .foregroundStyle(job.state == .degraded ? Theme.caution : Theme.inkTertiary)
                } else {
                    Text(Self.help).foregroundStyle(Theme.inkTertiary)
                }
            }
            .font(Theme.Font.aside).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One row of the log, mono and tabular; not styled as a control: time, length, word, then a
/// trailing 20 pt column that holds a kept row's ▶ (`play.fill`, `inkSecondary`) in an 18 pt ring
/// with a `border` stroke, ■ (`stop.fill`) while that part plays with a 2 pt `accent` line along
/// the row's bottom as far as it has played, on the open row a 6 pt `accentRec` dot while a part
/// is being written, and on a heard row nothing.
struct LogRow: View {
    /// A recorded part's control on the row.
    struct Part {
        let playing: Bool
        /// 0 to 1; nil before the first position arrives or when the length is unknown.
        let progress: Double?
        let toggle: () -> Void
    }

    enum Trailing {
        /// A heard row: nothing of it is on disk.
        case empty
        /// The open row while the recording writes a part.
        case writing
        case part(Part)
    }

    let time: Text
    let length: String
    let lengthInk: Color
    let signal: String
    let tone: SubAudibleTone?
    let open: Bool
    var trailing: Trailing = .empty

    var body: some View {
        HStack(spacing: 0) {
            time.font(Theme.Font.valueSmall)
                .frame(width: Theme.Layout.logTimeWidth, alignment: .leading)
            Text(length).font(Theme.Font.valueSmall).foregroundStyle(lengthInk)
                .frame(width: Theme.Layout.logLengthWidth, alignment: .trailing)
            HStack(spacing: 0) {
                Text(signal).foregroundStyle(Theme.inkTertiary)
                toneText
            }.font(Theme.Font.valueSmall)
                .frame(maxWidth: .infinity, alignment: .trailing)
            trailingColumn.frame(width: Theme.Layout.logPlayWidth, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: Theme.Layout.logRowHeight)
        .background(open ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottomLeading) { progressLine }
    }

    @ViewBuilder private var trailingColumn: some View {
        switch trailing {
        case .empty:
            Color.clear
        case .writing:
            RecordingDot().help("Recording: this transmission is being written to a part")
        case .part(let part):
            Button(action: part.toggle) {
                Image(systemName: part.playing ? "stop.fill" : "play.fill")
                    .font(Theme.Font.glyph).foregroundStyle(Theme.inkSecondary)
                    .frame(width: Theme.Layout.logRingSize, height: Theme.Layout.logRingSize)
                    .overlay(Circle().stroke(Theme.border))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(
                part.playing
                    ? "Stop the part; the channel's audio comes back"
                    : "Play the kept part through the daemon's speakers; the channel's audio is held silent until it ends"
            )
        }
    }

    /// As far as the clip has played, along the row's bottom edge.
    @ViewBuilder private var progressLine: some View {
        if case .part(let part) = trailing, part.playing, let progress = part.progress {
            GeometryReader { geo in
                Rectangle().fill(Theme.accent)
                    .frame(
                        width: geo.size.width * min(max(progress, 0), 1),
                        height: Theme.Layout.logProgressHeight
                    )
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
        }
    }

    /// ` · PL 100.0` or ` · DCS 023` in `good` when the daemon reported a CTCSS tone or DCS code
    /// under this transmission.
    private var toneText: Text {
        guard let tone else { return Text("") }
        return Text(" · " + tone.words).foregroundStyle(Theme.good)
    }
}

/// Region 5. Nothing in these groups is required for anything above them to work: the M1
/// handoff's sentence, kept findable here as the M2 handoff asks. Measurements holds the raw
/// levels the reading rows do not print. Collapsed by default and remembered, per group, in the
/// defaults.
struct DisclosureSection: View {
    @Environment(AppSession.self) private var session
    @AppStorage("inspector.measurementsOpen") private var measurementsOpen = false

    // One group, not the handoff's three: the demodulator's values are the transport bar's and
    // the device and gain are the header's chip, and showing either twice meant two places to
    // look (the owner, 2026-09-21).
    var body: some View {
        VStack(spacing: 0) {
            DisclosureRow(title: "Measurements", hint: "dBFS", open: $measurementsOpen) {
                MeasurementsGroup()
            }
        }
    }
}

/// A collapsed row that opens to its content and remembers whether it was open.
struct DisclosureRow<Content: View>: View {
    let title: String
    let hint: String?
    @Binding var open: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open.toggle()
            } label: {
                DisclosureLabel(title: title, hint: hint, open: open)
            }
            .buttonStyle(.plain)
            if open {
                content.padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
    }
}

/// `▸ Measurements … dBFS, Hz`: the triangle in `inkFaintest`, the title in `inkTertiary`, the
/// hint in `inkFaint`.
struct DisclosureLabel: View {
    let title: String
    let hint: String?
    let open: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.inkFaintest)
                .rotationEffect(.degrees(open ? 90 : 0))
            Text(title).font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
            Spacer()
            if let hint, !hint.isEmpty {
                Text(hint).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// The raw levels the reading rows do not print, two mono columns, `—` where nothing was
/// measured: the channel's power and floor behind Signal's dB over noise, the audio, and the
/// radio's own level. Signal, Tuning and Deviation print their numbers in their rows since
/// 2026-09-23, so they are not repeated here. These numbers are unsmoothed, straight from the
/// meter. The floor is the window's own (`AppSession.channelFloorDB`).
struct MeasurementsGroup: View {
    @Environment(AppSession.self) private var session

    private struct Row: Identifiable {
        let id: String
        let value: String
    }

    /// `0.00 %` of the newest interval's samples at the rails, or `—` before a reading.
    private var clippedWords: String {
        guard let l = session.captureLevel.level, l.totalSamples > 0 else { return "—" }
        return String(format: "%.2f %%", 100 * Double(l.clippedSamples) / Double(l.totalSamples))
    }

    var body: some View {
        let m = session.meter
        let level = session.captureLevel.level
        let rows = [
            Row(id: "power", value: Measure.dbfs(m?.powerDbfs ?? .nan)),
            Row(id: "floor", value: Measure.dbfs(session.channelFloorDB ?? .nan)),
            Row(id: "audio", value: Measure.dbfs(m?.audioDbfs ?? .nan)),
            Row(id: "peak", value: Measure.dbfs(m?.audioPeakDbfs ?? .nan)),
            // The radio's own level (`CaptureLevel`): where "near full scale" now lives, as a
            // number rather than a state, and the clipped fraction the failure state is read from.
            Row(id: "radio peak", value: Measure.dbfs(level?.peakDbfs ?? .nan)),
            Row(id: "clipped", value: clippedWords),
        ]
        VStack(spacing: 3) {
            ForEach(rows) { row in
                HStack {
                    Text(row.id).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
                    Spacer()
                    Text(row.value).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkTertiary)
                }
            }
        }
    }
}

/// Measured numbers as the inspector prints them: `—` for anything not measured (NaN, and the
/// −inf a digitally silent block reports for its peak), and the writing guide's minus sign.
enum Measure {
    static func dbfs(_ v: Double) -> String { v.isFinite ? "\(fixed(v, 0)) dBFS" : "—" }
    static func db(_ v: Double) -> String { v.isFinite ? "\(fixed(v, 0)) dB" : "—" }
    /// `−18`: a whole number with no unit, where a column or a slot already names it.
    static func bare(_ v: Double) -> String { v.isFinite ? fixed(v, 0) : "—" }

    /// `+1.1 kHz`, `−250 Hz`, `3.4 kHz`: a hertz reading, with a `+` only where the sign is the
    /// reading (a tuning error).
    static func hz(_ v: Double, signed: Bool = false) -> String {
        guard v.isFinite else { return "—" }
        let plus = signed && v > 0 ? "+" : ""
        return abs(v) >= 1_000 ? "\(plus)\(fixed(v / 1_000, 1)) kHz" : "\(plus)\(fixed(v, 0)) Hz"
    }

    private static func fixed(_ v: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", v).replacingOccurrences(of: "-", with: "−")
    }
}

/// `11:41:58` for the log and `11:38` for the On air row, in the machine's zone. Main-actor
/// statics because a `DateFormatter` is not `Sendable`, and the views are the only readers.
enum WallClock {
    @MainActor private static let hmsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    @MainActor private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    @MainActor static func hms(_ date: Date) -> String { hmsFormatter.string(from: date) }
    @MainActor static func hm(_ date: Date) -> String { hmFormatter.string(from: date) }
}
