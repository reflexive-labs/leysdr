// SPDX-License-Identifier: Apache-2.0

// The inspector's lower half (docs/design/app-design-handoff-m2.md, Regions 4 and 5): the log
// of recent transmissions on the tuned channel, straight from the façade's `TransmissionLog`
// and merged with the parts of the tuned frequency's recording (`RecordingParts.merge`), and the
// Measurements group holding the raw levels the reading rows do not print. Nothing here controls
// the radio: a row is not clickable (the shared selection with the waterfall is M3's, and a
// clickable row that highlights nothing would be misleading); the play glyph in a recorded row's
// trailing column is the one control (docs/design/app-design-handoff-m3.md, "Region 2").

import Foundation
import LeylineClient
import LeylineProto
import SwiftUI

/// Region 4: a section header with the count beside it, a three-column head, then the rows,
/// newest first, the open one on `raised` ground with `now` in `accent`. The log takes the
/// height the panel leaves it and shows as many rows as fit, five at least, which is the
/// handoff's count at its 820 pt window. Time is wall clock when the anchor covers it and
/// relative (`−2:14`) when it does not; both formats can appear in one list, because the
/// alternative is a timestamp nobody measured. Tone is not a column: a CTCSS tone the daemon
/// reported is appended to that row's signal cell in `good`, and a row without one leaves the
/// tone blank. A row whose transmission lies inside a recorded part plays it; a part no live row
/// lies inside is a row of its own, with the part's wall time through the manifest's anchor, its
/// length, and its peak in dBFS in the signal cell, since a part has no floor to give a word. A
/// line under the header names the recording the rows come from.
struct RecentLog: View {
    @Environment(AppSession.self) private var session

    static let minRows = 5
    /// The height above and below the rows: the padding, the section header and the column
    /// head, rounded up so the count errs toward one row fewer rather than a clipped one.
    static let chromeHeight: CGFloat = 60

    var body: some View {
        GeometryReader { geo in
            let fit = Int((geo.size.height - Self.chromeHeight) / Theme.Layout.logRowHeight)
            content(rows: max(Self.minRows, fit))
        }
        .frame(minHeight: Self.chromeHeight + CGFloat(Self.minRows) * Theme.Layout.logRowHeight)
        .clipped()
    }

    private func content(rows: Int) -> some View {
        let log = session.transmissions
        let open = log?.onAir
        let recordingWords = recordingLine(session.recording)
        let room = rows - (open == nil ? 0 : 1) - (recordingWords == nil ? 0 : 1)
        let entries = Array(session.logEntries.prefix(max(0, room)))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(text: "Recent on this channel")
                Spacer(minLength: 8)
                if let summary = summary(log) {
                    Text(summary).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }
            }
            .padding(.bottom, 6)
            if let recordingWords {
                // Beside the count it did not fit the panel's 280 pt; a line of its own under
                // the header, the height of one row (M3 handoff, "Decided 2026-09-24").
                HStack(spacing: 6) {
                    if session.recordingJob != nil { RecordingDot() }
                    Text(recordingWords).font(Theme.Font.valueSmall)
                        .foregroundStyle(Theme.inkFaint).lineLimit(1)
                }
                .frame(height: Theme.Layout.logRowHeight)
            }
            head
            if let open {
                LogRow(
                    time: Text("now").foregroundStyle(Theme.accent),
                    length: Reading.seconds(session.timeOnAirSeconds ?? .nan),
                    signal: session.channelReading?.signalWord?.word ?? Reading.absent,
                    tone: open.tone, open: true)
            }
            // Keyed by capture and start sample, so a new transmission adds a row instead of
            // changing what every row's position means.
            ForEach(entries) { e in
                let t = e.transmission
                LogRow(
                    time: Text(timeWords(e)).foregroundStyle(Theme.inkSecondary),
                    length: Reading.seconds(t.seconds),
                    signal: e.fromPart
                        ? Measure.dbfs(t.peakAudioDBFS)
                        : SignalWord(overNoiseDB: t.peakSNRDB)?.word ?? Reading.absent,
                    tone: t.tone, open: false, part: part(e))
            }
            if open == nil, entries.isEmpty {
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

    private var head: some View {
        HStack(spacing: 0) {
            Text("time").frame(width: Theme.Layout.logTimeWidth, alignment: .leading)
            Text("length").frame(width: Theme.Layout.logLengthWidth, alignment: .trailing)
            Text("signal").frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(width: Theme.Layout.logPlayWidth, height: 1)
        }
        .font(Theme.Font.columnHead).foregroundStyle(Theme.inkFaintest)
        .padding(.horizontal, 6).padding(.bottom, 2)
    }

    /// `23 since 11:38`: the log's count, the open one included, and the wall clock of the
    /// oldest transmission it holds when the anchor dates it; otherwise `23 this session`,
    /// because a wall-clock time is printed only when the daemon's anchor provides one (M2-1's
    /// rule). nil with nothing logged, where the empty line says so.
    private func summary(_ log: TransmissionLog?) -> String? {
        guard let log else { return nil }
        let count = log.closed.count + (log.onAir == nil ? 0 : 1)
        guard count > 0 else { return nil }
        let first = log.closed.last?.start ?? log.onAir?.since
        if let since = first.flatMap({ session.wallTime(of: $0) }) {
            return "\(count) since \(WallClock.hm(since))"
        }
        return "\(count) this session"
    }

    /// A live row's wall clock through the tuned capture's anchor, a part row's through the
    /// manifest's; relative when neither dates it.
    private func timeWords(_ e: LogEntry) -> String {
        let start = e.transmission.start
        if let date = e.startDate ?? session.wallTime(of: start) { return WallClock.hms(date) }
        return Reading.relative(secondsAgo: session.secondsAgo(start) ?? .nan)
    }

    /// `recording since 18:09` while the job runs, `recorded Tue 18:09` after; nil with no
    /// recording on the tuned frequency.
    private func recordingLine(_ m: RecordingManifest?) -> String? {
        guard let m else { return nil }
        let running = session.recordingJob?.jobID == m.jobID
        guard let started = m.startedAt else { return running ? "recording" : "recorded" }
        return running
            ? "recording since \(WallClock.hm(started))" : "recorded \(WallClock.dayHM(started))"
    }

    /// The row's play control, when a part holds it.
    private func part(_ e: LogEntry) -> LogRow.Part? {
        guard let uri = e.partURI else { return nil }
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

/// One row of the log, mono and tabular; not styled as a control. The trailing 16 pt column holds
/// `play.fill` when a recorded part holds the row and `stop.fill` while that part plays, with a
/// 2 pt `accent` line along the row's bottom as far as it has played.
struct LogRow: View {
    /// A recorded part's control on the row.
    struct Part {
        let playing: Bool
        /// 0 to 1; nil before the first position arrives or when the length is unknown.
        let progress: Double?
        let toggle: () -> Void
    }

    let time: Text
    let length: String
    let signal: String
    let tone: SubAudibleTone?
    let open: Bool
    var part: Part?

    var body: some View {
        HStack(spacing: 0) {
            time.font(Theme.Font.valueSmall)
                .frame(width: Theme.Layout.logTimeWidth, alignment: .leading)
            Text(length).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkSecondary)
                .frame(width: Theme.Layout.logLengthWidth, alignment: .trailing)
            HStack(spacing: 0) {
                Text(signal).foregroundStyle(Theme.inkTertiary)
                toneText
            }.font(Theme.Font.valueSmall)
                .frame(maxWidth: .infinity, alignment: .trailing)
            playColumn.frame(width: Theme.Layout.logPlayWidth)
        }
        .padding(.horizontal, 6)
        .frame(height: Theme.Layout.logRowHeight)
        .background(open ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottomLeading) { progressLine }
    }

    @ViewBuilder private var playColumn: some View {
        if let part {
            Button(action: part.toggle) {
                Image(systemName: part.playing ? "stop.fill" : "play.fill")
                    .font(Theme.Font.glyph).foregroundStyle(Theme.inkTertiary)
                    .frame(width: Theme.Layout.logPlayWidth, height: Theme.Layout.logRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                part.playing
                    ? "Stop the clip; the channel's audio comes back"
                    : "Play the recorded part through the daemon's speakers; the channel's audio is detached until it ends"
            )
        } else {
            Color.clear
        }
    }

    /// As far as the clip has played, along the row's bottom edge.
    @ViewBuilder private var progressLine: some View {
        if let part, part.playing, let progress = part.progress {
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

/// `11:41:58` for the log, `11:38` for the On air row and `Tue 18:09` for a recording, in the
/// machine's zone. Main-actor statics because a `DateFormatter` is not `Sendable`, and the
/// views are the only readers.
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

    @MainActor private static let dayHMFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    @MainActor static func hms(_ date: Date) -> String { hmsFormatter.string(from: date) }
    @MainActor static func hm(_ date: Date) -> String { hmFormatter.string(from: date) }
    /// `Tue 18:09`: a recording's start in the sidebar and the log's recording line.
    @MainActor static func dayHM(_ date: Date) -> String { dayHMFormatter.string(from: date) }
}
