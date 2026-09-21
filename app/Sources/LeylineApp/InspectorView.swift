// SPDX-License-Identifier: Apache-2.0

// The inspector: the tuned channel as a thing with an identity and a reading, on the window's
// right (docs/design/app-design-handoff-m2.md, "The panel"). Six regions and no scroll view: a
// header that says `Channel`, the identity, the failure strip carried out of M1, the reading in
// words, the log of recent transmissions and the disclosure groups; the last two are in
// InspectorGroups.swift. Every word here is a presentation of a number the daemon measured, and
// the number is one click away in the popover under it, which is where invariant 12 lands in the
// app. The panel keeps no state of its own: it renders the session's copy of the mirror and the
// telemetry feed's log, and writes one thing, a bookmark's name, through the store both clients
// own (`AppSession.renameTuned`).

import AppKit
import LeylineClient
import LeylineProto
import SwiftUI

/// The toolbar's right-hand toggle, beside the device chip; `View ▸ Show Inspector` (⌥⌘I) is
/// the same switch (`LeylineApp.swift`).
struct InspectorToggle: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Button {
            session.toggleInspector()
        } label: {
            Image(systemName: "sidebar.right").font(.system(size: 13, weight: .medium))
                .foregroundStyle(session.inspectorShown ? Theme.inkSecondary : Theme.inkMuted)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .help(session.inspectorShown ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
    }
}

struct InspectorView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            IdentityView()
            FailureStrip()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ReadingsView()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            RecentLog()
            Spacer(minLength: 0)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            DisclosureSection()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }
}

/// The word `Channel` and a close control, nothing else: no tabs. The tab strip (`Channel` /
/// `Processors` / `＋`) is M4's and appears when there is a second thing to put in it; a one-tab
/// tab bar now is a promise the window cannot keep for two milestones (M2 handoff, "The panel").
struct InspectorHeader: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        HStack {
            Text("Channel").font(Theme.Font.menuTitle).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Button {
                session.toggleInspector()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.inkFaint)
            }
            .buttonStyle(.plain)
            .help("Hide Inspector (⌥⌘I)")
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.Layout.inspectorHeaderHeight)
        .background(Theme.panelHeader)
    }
}

/// Region 1: the channel's name first and the frequency demoted to a mono line, because the
/// transport bar owns the frequency as a number you edit and the panel owns the channel as a
/// thing with an identity. The name is the bookmark's; without one it is the band's, and the
/// pencil names it, which makes the bookmark.
struct IdentityView: View {
    @Environment(AppSession.self) private var session
    @State private var editing = false

    var body: some View {
        let bookmark = session.tunedBookmark
        let hz = session.tunedHz
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if editing {
                    NameField(initial: bookmark?.name ?? "", editing: $editing)
                } else {
                    Text(name(bookmark: bookmark, hz: hz))
                        .font(Theme.Font.name).tracking(Theme.nameTracking)
                        .foregroundStyle(hz == nil ? Theme.inkMuted : Theme.ink)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if hz != nil {
                        Button {
                            editing = true
                        } label: {
                            Image(systemName: "pencil").font(.system(size: 11))
                                .foregroundStyle(Theme.inkFaint)
                        }
                        .buttonStyle(.plain)
                        .help(
                            bookmark == nil
                                ? "Name this frequency; the name is kept as a bookmark"
                                : "Rename the bookmark")
                    }
                }
            }
            Text(detail(bookmark: bookmark, hz: hz))
                .font(Theme.Font.value).foregroundStyle(Theme.inkMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func name(bookmark: Bookmark?, hz: UInt64?) -> String {
        if let b = bookmark { return b.name }
        if let b = session.band { return b.name }
        if let hz { return Frequency.format(hz) }
        return "No channel"
    }

    /// `146.520 MHz · NFM 12.5 kHz`, and ` · bookmarked` when it is.
    private func detail(bookmark: Bookmark?, hz: UInt64?) -> String {
        guard let hz, let ch = session.channel else {
            return "Pick a band, or click the waterfall, to hear something"
        }
        var parts = [Frequency.format(hz), "\(ch.mode.word) \(Frequency.width(ch.bandwidthHz))"]
        if bookmark != nil { parts.append("bookmarked") }
        return parts.joined(separator: " · ")
    }
}

/// The name, edited in place. Enter commits through `AppSession.renameTuned`; Escape, or the
/// focus going elsewhere, puts the name back. While it has focus its window's bare space and
/// arrow keys are done to the field editor by hand: the Tune menu holds them as key equivalents
/// (`TuneCommands`), and a menu's equivalent is matched before a text field sees the key, so
/// typing `2 m Simplex` would pause the audio and tune the radio. The transport field keeps the
/// same keys the same way (`FrequencyField.watchClicks`), and as there only scalars cross into
/// the main actor.
struct NameField: View {
    @Environment(AppSession.self) private var session
    let initial: String
    @Binding var editing: Bool
    @State private var draft = ""
    @State private var monitor: Any?
    /// The window the field was focused in, compared by identity out on the monitor's side.
    @State private var ownWindow: ObjectIdentifier?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(Theme.Font.name)
            .foregroundStyle(Theme.ink)
            .focused($focused)
            .onSubmit { commit() }
            .onExitCommand { end() }
            .onAppear {
                draft = initial
                focused = true
            }
            .onChange(of: focused) { _, isFocused in
                if isFocused { watchKeys() } else { end() }
            }
            // A window that closes mid-edit never reports the focus lost; without this the
            // monitor would outlive the field and swallow keys for the process.
            .onDisappear { end() }
    }

    private func commit() {
        session.renameTuned(to: draft)
        end()
    }

    private func end() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        ownWindow = nil
        editing = false
    }

    private func watchKeys() {
        if monitor != nil { return }
        ownWindow = NSApp.keyWindow.map { ObjectIdentifier($0) }
        let own = ownWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Only scalars cross into the main actor: an NSEvent is not Sendable.
            guard let own, let window = event.window, ObjectIdentifier(window) == own else {
                return event
            }
            let code = event.keyCode
            // The arrows carry the keypad and function flags on their own; those are not
            // modifiers a person held.
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            guard held.isEmpty || held == [.shift] else { return event }
            let shift = held == [.shift]
            let taken: Bool = MainActor.assumeIsolated {
                Self.handToEditor(keyCode: code, shift: shift)
            }
            return taken ? nil : event
        }
    }

    /// Space and the two arrows, performed on the field editor from the key code. Anything else
    /// goes on to the menu and the field as usual. Returns true when the key was taken.
    @MainActor
    private static func handToEditor(keyCode: UInt16, shift: Bool) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        switch keyCode {
        case 49:  // Space: the Tune menu's Play/Pause, and a word break in a name
            editor.insertText(" ", replacementRange: editor.selectedRange())
            return true
        case 123:  // Left arrow: Tune Down, and Fine Tune Down with ⇧
            if shift { editor.moveLeftAndModifySelection(nil) } else { editor.moveLeft(nil) }
            return true
        case 124:  // Right arrow: likewise
            if shift { editor.moveRightAndModifySelection(nil) } else { editor.moveRight(nil) }
            return true
        default:
            return false
        }
    }
}

/// Region 2: what the band's numbers say is wrong (`FailureState`), or a channel the capture no
/// longer covers, carried out of M1's strip over the waterfall (docs/plans/app.md, "Carried out
/// of M1"): the sentence in ink, the number and the thing to try under it, and where the thing
/// to try is the gain, a button that opens the device menu at the slider rather than saying
/// where to look. `FailureState` and `ley tune`'s line do not change; this is presentation, and
/// the close control keeps M1's rule that a closed state stays closed until a different one is
/// named. Absent when nothing is wrong, not empty.
struct FailureStrip: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if let words = session.outOfCaptureWords {
            block(sentence: words, detail: nil, namesGain: false) {
                session.dismissOutOfCapture()
            }
        } else if let f = session.failureShown {
            block(sentence: f.headline + ".", detail: f.detail, namesGain: f.namesGain) {
                session.dismissFailure()
            }
        }
    }

    private func block(
        sentence: String, detail: String?, namesGain: Bool, dismiss: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(sentence).font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
                    .help("Close until a different state is named")
            }
            if let detail {
                Text(detail).font(Theme.Font.aside).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if namesGain {
                Button {
                    session.deviceMenuShown = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Open the gain slider").font(Theme.Font.aside)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Theme.inkSecondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warnGround, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.warnBorder))
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

/// Region 3: the reading, in words, label in a fixed column. This is the region that has to be
/// in words and the one most likely to be built as numbers, because numbers are what the meter
/// carries; the numbers are in the popovers and in Measurements. A row whose measurement is NaN
/// (tuning outside FM or with the squelch closed, deviation outside FM) is hidden rather than
/// dashed: a row that says `—` most of the time teaches that the row is broken.
struct ReadingsView: View {
    @Environment(AppSession.self) private var session

    /// The signal bar's reach: 0 to 40 dB over the noise (M2 handoff, "Signal"), so `Strong`
    /// (`SignalWord.thresholdsDB` last) begins past the middle and a repeater at full quieting
    /// reaches the cream end.
    static let signalBarRangeDB: Double = 40
    /// The design's copy in the Signal popover ("Voice is fully readable above about 12 dB"),
    /// asserted from listening and not measured (M2 handoff, "Open for the owner"); the words'
    /// own steps are `SignalWord.thresholdsDB`.
    static let readableDB: Double = 12

    /// The deviation the meter shows: fast up, slow down (`DeviationMeter.hold`).
    @State private var heldDeviationHz: Double = .nan

    var body: some View {
        let m = session.meter
        let ch = session.channel
        VStack(alignment: .leading, spacing: 8) {
            signal(overNoise: session.overNoiseDB, meter: m)
            if let m, let ch,
                let word = TuningWord(freqErrorHz: m.freqErrorHz, bandwidthHz: ch.bandwidthHz)
            {
                tuning(word, errorHz: m.freqErrorHz, channel: ch)
            }
            if let m, let ch,
                let word = DeviationWord(
                    deviationHz: m.deviationHz, mode: ch.mode, bandwidthHz: ch.bandwidthHz)
            {
                deviation(word, deviationHz: m.deviationHz, channel: ch)
            }
            onAir
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func signal(overNoise: Double?, meter m: Leyline_V1_Meter?) -> some View {
        let word = SignalWord(overNoiseDB: overNoise)
        let sentence =
            overNoise.map {
                String(
                    format:
                        "%.0f dB above the noise floor. Voice is fully readable above about %.0f dB.",
                    $0, Self.readableDB)
            }
            ?? "No signal measured yet: the floor is read from the first spectrum row, and the level from the channel's meter."
        let raw: String
        if let m, let floor = session.channelFloorDB {
            raw = "\(Measure.dbfs(m.powerDbfs)) · floor \(Measure.dbfs(floor))"
        } else {
            raw = "—"
        }
        return ReadingRow(label: "Signal", sentence: sentence, raw: raw) {
            HStack(spacing: 10) {
                SignalBar(fraction: overNoise.map { $0 / Self.signalBarRangeDB } ?? .nan)
                Text(word?.word ?? "—").reading()
                    .foregroundStyle(word == nil ? Theme.inkFaint : Theme.inkSecondary)
            }
        }
    }

    /// A centre-zero meter and the word: the marker sits where the tuning is against the
    /// transmitter, the way the waterfall shows it, and the word flips only past a tenth of the
    /// channel's width. A number that moves at
    /// 10 Hz wants a needle, not a label that flickers (the owner, 2026-09-21).
    private func tuning(_ word: TuningWord, errorHz: Double, channel ch: Leyline_V1_Channel)
        -> some View
    {
        let sentence =
            "The transmitter sits \(Measure.hz(abs(errorHz))) \(errorHz >= 0 ? "above" : "below") the channel's centre, \(word.isOffTune ? "past" : "within") a tenth of its \(Frequency.width(ch.bandwidthHz)) width."
        let raw = "freq error \(Measure.hz(errorHz, signed: true)) · width \(ch.bandwidthHz) Hz"
        return ReadingRow(label: "Tuning", sentence: sentence, raw: raw) {
            HStack(spacing: 8) {
                // Inverted from the error: the marker is where the tuning sits against the
                // signal, so it points the way the waterfall's marker does (a transmitter above
                // the channel has the marker to the left of it).
                CentreMeter(
                    fraction: -errorHz / Double(ch.bandwidthHz), offCentre: word.isOffTune
                )
                .frame(width: Theme.Layout.readingMeterWidth)
                Text(word.word).reading()
                    .foregroundStyle(word.isOffTune ? Theme.caution : Theme.inkSecondary)
            }
        }
    }

    /// A level meter against the mode's nominal, peak-held so speech reads as a swing rather
    /// than a flicker, with the held number beside it; the tick is the nominal, and the fill
    /// past it is the caution ink.
    private func deviation(
        _ word: DeviationWord, deviationHz: Double, channel ch: Leyline_V1_Channel
    ) -> some View {
        let nominal: Double? = DeviationWord.nominalHz(mode: ch.mode, bandwidthHz: ch.bandwidthHz)
        let sentence =
            "Deviating \(Measure.hz(deviationHz)) against a nominal \(nominal.map { Measure.hz($0) } ?? "—") for \(ch.mode.word) at \(Frequency.width(ch.bandwidthHz))."
        let raw =
            "deviation \(Measure.hz(deviationHz)) · nominal \(nominal.map { Measure.hz($0) } ?? "—")"
        return ReadingRow(label: "Deviation", sentence: sentence, raw: raw) {
            HStack(spacing: 8) {
                DeviationMeter(
                    levelHz: heldDeviationHz.isFinite ? heldDeviationHz : deviationHz,
                    nominalHz: nominal ?? 1
                )
                .frame(width: Theme.Layout.readingMeterWidth)
                Text(Measure.hz(heldDeviationHz.isFinite ? heldDeviationHz : deviationHz))
                    .font(Theme.Font.value)
                    .foregroundStyle(
                        word == .overdeviating ? Theme.caution : Theme.inkSecondary)
            }
        }
        .onChange(of: deviationHz, initial: true) { _, new in
            heldDeviationHz = DeviationMeter.hold(heldDeviationHz, new, nominalHz: nominal ?? 1)
        }
    }

    /// `4.2 s · 23 since 11:38` while the squelch is open, `Idle · 23 since 11:38` when it is
    /// closed. The count is the log's, the session's first transmission its oldest, and `since`
    /// is that one's wall clock when the anchor dates it; otherwise `23 this session`, because a
    /// clock the daemon never kept is not printed (M2-1's rule).
    private var onAir: some View {
        let log = session.transmissions
        let open = log?.onAir
        let count = (log?.closed.count ?? 0) + (open == nil ? 0 : 1)
        let seconds = session.timeOnAirSeconds
        let first = log?.closed.last?.start ?? open?.since
        let since = first.flatMap { session.wallTime(of: $0) }
        let clause: String
        // "10 heard since 16:35": the count is of transmissions, and the word says so.
        let heard = count == 1 ? "1 heard" : "\(count) heard"
        if count == 0 {
            clause = "none heard this session"
        } else if let since {
            clause = "\(heard) since \(WallClock.hm(since))"
        } else {
            clause = "\(heard) this session"
        }
        let state: String
        if let seconds {
            state = "On air " + Reading.seconds(seconds)
        } else {
            state = open == nil ? "Idle" : "On air"
        }
        let sentence: String
        let raw: String
        if let open {
            sentence =
                "On the air for \(seconds.map { Reading.seconds($0) } ?? "an unknown time"); \(count) logged\(since.map { ", the first at \(WallClock.hms($0))" } ?? " this session")."
            raw = "open edge at sample \(open.since.sampleIndex) · \(log?.captureRate ?? 0) S/s"
        } else if let last = log?.closed.first {
            sentence =
                "Idle. The last transmission ran \(Reading.seconds(last.seconds)); \(count) logged\(since.map { ", the first at \(WallClock.hms($0))" } ?? " this session")."
            raw =
                "last \(Reading.seconds(last.seconds)) · peak \(Measure.db(last.peakSNRDB)) over noise"
        } else {
            sentence = "Idle. Nothing has opened the squelch on this channel yet."
            raw = "—"
        }
        return ReadingRow(label: "On air", sentence: sentence, raw: raw) {
            Text(state).reading()
                .foregroundStyle(seconds == nil ? Theme.inkTertiary : Theme.inkSecondary)
                + Text(" · \(clause)").font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
        }
    }
}

extension Text {
    /// A value in the reading: the dotted underline that says a number is one click away.
    func reading() -> Text {
        font(Theme.Font.label).underline(pattern: .dot, color: Theme.inkFaintest)
    }
}

/// A label at the fixed column and a value; a click on the value opens its number.
struct ReadingRow<Value: View>: View {
    let label: String
    let sentence: String
    let raw: String
    @ViewBuilder let value: Value
    @State private var open = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
                .frame(width: Theme.Layout.readingLabelWidth, alignment: .leading)
            value
                .contentShape(Rectangle())
                .onTapGesture { open = true }
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    NumberPopover(sentence: sentence, raw: raw)
                }
        }
    }
}

/// Two lines: the sentence with the number in it, then the raw measurement in mono. The word
/// is a presentation of a number, the number is always one click away, and the popover never
/// states a confidence the measurement does not have.
struct NumberPopover: View {
    let sentence: String
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sentence).font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(raw).font(Theme.Font.value).foregroundStyle(Theme.inkTertiary)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(Theme.chrome)
    }
}

/// A 6 pt bar filled with the level ramp over the bar's whole width and clipped at the reading,
/// so the colour at the bar's end agrees with the word beside it. Empty for NaN.
struct SignalBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            let f = fraction.isFinite ? fraction.clamped(to: 0...1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                LinearGradient(
                    colors: Theme.levelStops, startPoint: .leading, endPoint: .trailing
                )
                .mask(alignment: .leading) { Capsule().frame(width: geo.size.width * f) }
            }
        }
        .frame(height: Theme.Layout.signalBarHeight)
    }
}

/// A centre-zero meter: a track with a tick at the middle and a marker at `fraction` of the
/// track's half-width either side, clamped to the ends. The marker is `inkSecondary` inside the
/// centred tenth and `caution` past it.
struct CentreMeter: View {
    /// Error over bandwidth: ±0.5 is the channel's edge.
    let fraction: Double
    let offCentre: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = fraction.isFinite ? fraction.clamped(to: -0.5...0.5) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Rectangle().fill(Theme.borderStrong).frame(width: 1, height: 10)
                    .offset(x: w / 2 - 0.5)
                Capsule().fill(offCentre ? Theme.caution : Theme.inkSecondary)
                    .frame(width: 3, height: 10)
                    .offset(x: (w * (0.5 + f)).clamped(to: 0...max(0, w - 3)))
            }
        }
        .frame(height: 10)
    }
}

/// The deviation on the Signal row's own bar (`SignalBar`, the level ramp), with a tick at the
/// mode's nominal; the track spans one and a half nominals. Drawn from a level the caller
/// holds with `hold`, because deviation follows syllables and a bar that follows every 100 ms
/// interval is a flicker. A caution fill past the tick was tried and read as a yellow
/// background (the owner, 2026-09-21); the number beside the bar carries the caution instead.
struct DeviationMeter: View {
    let levelHz: Double
    let nominalHz: Double

    /// The meter's span, in nominals.
    static let spanNominals: Double = 1.5
    /// How much of the held level is let go per meter interval: ten intervals from full to a
    /// tenth, the release a VU meter has.
    static let releasePerInterval: Double = 0.2

    /// Fast up, slow down: the larger of the new level and the held one released a step.
    static func hold(_ held: Double, _ new: Double, nominalHz: Double) -> Double {
        guard new.isFinite else { return held }
        guard held.isFinite else { return new }
        return Swift.max(new, held - releasePerInterval * nominalHz)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f =
                levelHz.isFinite
                ? (levelHz / (nominalHz * Self.spanNominals)).clamped(to: 0...1) : 0
            let tick = w / Self.spanNominals
            ZStack(alignment: .leading) {
                SignalBar(fraction: f)
                Rectangle().fill(Theme.borderStrong).frame(width: 1, height: 10)
                    .offset(x: tick - 0.5)
            }
        }
        .frame(height: Theme.Layout.signalBarHeight)
    }
}
