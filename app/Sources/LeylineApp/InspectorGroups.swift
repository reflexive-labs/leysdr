// SPDX-License-Identifier: Apache-2.0

// The inspector's lower half (docs/design/app-design-handoff-m2.md, Regions 4 and 5): the log
// of recent transmissions on the tuned channel, straight from the façade's `TransmissionLog`,
// and three disclosure groups holding the raw numbers behind the panel's word labels, the
// demodulator as text, and a link to the device menu. Nothing here controls the radio: the
// log's rows are not clickable (the shared selection with the waterfall is M3's, and a clickable
// row that highlights nothing would be misleading), and Demodulator displays what the transport
// bar edits, not a second set of controls.

import Foundation
import LeylineClient
import LeylineProto
import SwiftUI

/// Region 4: a section header, a three-column head, then the rows, newest first, the open one
/// on `raised` ground with `now` in `accent`. Time is wall clock when the anchor covers it and
/// relative (`−2:14`) when it does not; both formats can appear in one list, because the
/// alternative is a timestamp nobody measured. Tone is not a column: a CTCSS tone the daemon
/// reported is appended to that row's signal cell in `good`, and a row without one leaves the
/// tone blank.
struct RecentLog: View {
    @Environment(AppSession.self) private var session

    /// Five rows at the design's 820 pt window, the open one included.
    static let rows = 5

    var body: some View {
        let log = session.transmissions
        let open = log?.onAir
        let closed = Array((log?.closed ?? []).prefix(Self.rows - (open == nil ? 0 : 1)))
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(text: "Recent on this channel").padding(.bottom, 4)
            head
            if let open {
                LogRow(
                    time: Text("now").foregroundStyle(Theme.accent),
                    length: Reading.seconds(session.timeOnAirSeconds ?? .nan),
                    signal: signalWord(session.overNoiseDB), tone: open.tone, open: true)
            }
            ForEach(Array(closed.enumerated()), id: \.offset) { _, t in
                LogRow(
                    time: Text(timeWords(t.start)).foregroundStyle(Theme.inkSecondary),
                    length: Reading.seconds(t.seconds), signal: signalWord(t.peakSNRDB),
                    tone: t.tone, open: false)
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

    private var head: some View {
        HStack(spacing: 0) {
            Text("time").frame(width: Theme.Layout.logTimeWidth, alignment: .leading)
            Text("length").frame(width: Theme.Layout.logLengthWidth, alignment: .trailing)
            Text("signal").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(Theme.Font.columnHead).foregroundStyle(Theme.inkFaintest)
        .padding(.horizontal, 6).padding(.bottom, 2)
    }

    /// The same five words as the reading, lower-cased for a table cell; `—` before the meter
    /// warmed up.
    private func signalWord(_ overNoiseDB: Double?) -> String {
        SignalWord(overNoiseDB: overNoiseDB)?.word.lowercased() ?? "—"
    }

    private func timeWords(_ start: Leyline_V1_SampleTime) -> String {
        if let date = session.wallTime(of: start) { return WallClock.hms(date) }
        return Reading.relative(secondsAgo: session.secondsAgo(start) ?? .nan)
    }
}

/// One row of the log, mono and tabular; not styled as a control.
struct LogRow: View {
    let time: Text
    let length: String
    let signal: String
    let tone: CTCSSTone?
    let open: Bool

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
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(open ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }

    /// ` · PL 100.0` in `good` when the daemon reported a tone under this transmission.
    private var toneText: Text {
        guard let tone else { return Text("") }
        return Text(String(format: " · PL %.1f", tone.standardHz)).foregroundStyle(Theme.good)
    }
}

/// Region 5. Nothing in these groups is required for anything above them to work: the M1
/// handoff's sentence, kept findable here as the M2 handoff asks. They hold the numbers behind
/// the panel's word labels, the demodulator as text, and a link to the device menu.
/// Collapsed by default and remembered, per group, in the defaults.
struct DisclosureSection: View {
    @Environment(AppSession.self) private var session
    @AppStorage("inspector.measurementsOpen") private var measurementsOpen = false

    // One group, not the handoff's three: the demodulator's values are the transport bar's and
    // the device and gain are the header's chip, and showing either twice meant two places to
    // look (the owner, 2026-09-21).
    var body: some View {
        VStack(spacing: 0) {
            DisclosureRow(title: "Measurements", hint: "dBFS, Hz", open: $measurementsOpen) {
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

/// Every raw number the panel presents as a word, two mono columns, `—` where nothing was
/// measured. The floor and snr are the window's own (`AppSession.channelFloorDB`,
/// `overNoiseDB`), the rest the meter's.
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
            Row(id: "snr", value: Measure.db(session.overNoiseDB ?? .nan)),
            Row(id: "freq error", value: Measure.hz(m?.freqErrorHz ?? .nan, signed: true)),
            Row(id: "deviation", value: Measure.hz(m?.deviationHz ?? .nan)),
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
/// statics because a `DateFormatter` is not `Sendable`, and the panel is the only reader.
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
