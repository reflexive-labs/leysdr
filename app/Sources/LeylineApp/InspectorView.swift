// SPDX-License-Identifier: Apache-2.0

// The inspector: the tuned channel as a thing with an identity and a reading, on the window's
// right (docs/design/app-design-handoff-m2.md, "The panel"). Seven regions and no scroll view: a
// header that says `Channel`, the identity, the failure strip carried out of M1, the reading,
// the audio ladder, the log of recent transmissions and the disclosure groups; the ladder is in
// AudioLevelsView.swift, the last two in InspectorGroups.swift and the reading's meter in
// MeterTrack.swift. Every word label here is derived from a number the daemon measured, and the
// number is printed beside it, which is how the app meets invariant 12. The panel keeps no radio
// state of its own: it renders the session's copy of the mirror, the feeds and the session's
// steadied reading, and writes one thing, a bookmark's name, through the store both clients own
// (`AppSession.renameTuned`).

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
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Theme.border, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
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
            AudioLevelsView()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            // The log takes the height the other regions leave, and fills it with rows.
            RecentLog()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            DisclosureSection()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }
}

/// The word `Channel`, nothing else: no tabs, and no close control, because the toolbar's
/// toggle beside it already hides the panel. The tab strip (`Channel` / `Processors` / `＋`) is
/// M4's and appears when there is a second tab to put in it; a one-tab tab bar now would
/// advertise tabs that do not exist until M4 (M2 handoff, "The panel").
struct InspectorHeader: View {
    var body: some View {
        HStack {
            Text("Channel").font(Theme.Font.menuTitle).foregroundStyle(Theme.inkSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.Layout.inspectorHeaderHeight)
        .background(Theme.panelHeader)
    }
}

/// Region 1: the channel's name first and the frequency demoted to a mono line, because the
/// frequency is edited in the transport bar and this panel identifies the channel. The name is
/// the bookmark's; without one it is the band's, and naming it with the pencil creates the
/// bookmark.
struct IdentityView: View {
    @Environment(AppSession.self) private var session
    @State private var editing = false

    var body: some View {
        let bookmark = session.tunedBookmark
        let hz = session.tunedHz
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if editing {
                    NameField(initial: bookmark?.name ?? "", editing: $editing) {
                        session.renameTuned(to: $0)
                    }
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
            if session.bookmarkModified, !editing {
                // The channel's settings differ from the bookmark's: say so on a line of its
                // own, with Revert (restore the channel) and Save (update the bookmark) as real
                // buttons. Beside the name they shortened it and read as labels.
                HStack(spacing: 8) {
                    Text("Changed from the bookmark").font(Theme.Font.aside)
                        .foregroundStyle(Theme.caution).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Revert") { session.revertToTunedBookmark() }
                        .help("Back to the bookmark's saved mode and width")
                    Button("Save") { session.saveTunedBookmark() }
                        .help("The bookmark takes the mode and width it is heard with now")
                }
                .buttonStyle(.bordered).controlSize(.mini)
                .padding(.top, 4)
            }
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
/// arrow keys are sent to the field editor directly: the Tune menu holds them as key
/// equivalents (`TuneCommands`), and a menu's equivalent is matched before a text field sees
/// the key, so typing `2 m Simplex` would pause the audio and tune the radio. The transport
/// field handles the same keys the same way (`FrequencyField.watchClicks`), and as there only
/// scalars cross into the main actor.
struct NameField: View {
    let initial: String
    var font: Font = Theme.Font.name
    @Binding var editing: Bool
    /// What the name becomes on Return; Escape and a lost focus end the edit without it.
    let onCommit: (String) -> Void
    @State private var draft = ""
    @State private var monitor: Any?
    /// The window the field was focused in, compared by identity out on the monitor's side.
    @State private var ownWindow: ObjectIdentifier?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(font)
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
        onCommit(draft)
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
            // modifiers the user held.
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

/// Region 2: the problem the band's levels indicate (`FailureState`), or a channel the capture no
/// longer covers, carried out of M1's strip over the waterfall (docs/plans/app.md, "Carried out
/// of M1"): the sentence in ink, the number and the thing to try under it, and where the thing
/// to try is the gain, a button that opens the device menu at the slider rather than text
/// describing where to find it. `FailureState` and `ley tune`'s line do not change; this is
/// presentation, and the close control keeps M1's rule that a closed state stays closed until a
/// different one is detected. Absent when nothing is wrong, not empty.
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

/// Region 3: the reading, four rows in four fixed columns (label, meter, word, number), so a
/// word that changes never moves a meter or a number. The number sits beside its word rather
/// than one click away in a popover, and the sentence explaining it is the row's tooltip
/// (decided 2026-09-23, docs/design/app-design-handoff-m2.md). Rows draw from
/// `AppSession.channelReading`, the meter steadied with ballistics and hysteresis
/// (`ChannelReading`), and the raw numbers stay in Measurements. Tuning and Deviation show for
/// the FM modes, which are the only modes that measure them. While the squelch is closed the
/// two rows stay and hold the last transmission's values dimmed, so the panel does not change
/// height with every transmission, and you can still see how the last one was tuned.
struct ReadingsView: View {
    @Environment(AppSession.self) private var session

    /// The signal bar's reach: 0 to 40 dB over the noise (M2 handoff, "Signal"), so `Strong`
    /// (`SignalWord.thresholdsDB` last) begins past the middle and a repeater at full quieting
    /// reaches the cream end.
    static let signalBarRangeDB: Double = 40
    /// The design's copy in the Signal tooltip ("Voice is fully readable above about 12 dB"),
    /// asserted from listening and not measured (M2 handoff, "Open for the owner"); the words'
    /// own steps are `SignalWord.thresholdsDB`.
    static let readableDB: Double = 12
    /// The deviation meter's span, in nominals: the nominal tick sits at two thirds.
    static let deviationSpanNominals: Double = 1.5
    /// How far a held reading (the last transmission's, squelch closed) is dimmed.
    static let heldOpacity: Double = 0.45

    var body: some View {
        let reading = session.channelReading
        let ch = session.channel
        let nominal = ch.flatMap {
            DeviationWord.nominalHz(mode: $0.mode, bandwidthHz: $0.bandwidthHz)
        }
        VStack(alignment: .leading, spacing: 8) {
            signal(reading)
            if let ch, let nominal {
                tuning(reading, channel: ch)
                deviation(reading, channel: ch, nominalHz: nominal)
            }
            onAir
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// The ramp bar against 0 to 40 dB over the noise, with the squelch as a tick on the same
    /// scale, so whether a signal is loud enough to open the squelch can be read off one bar.
    private func signal(_ r: ChannelReading?) -> some View {
        let overNoise = r?.overNoiseDB ?? .nan
        let squelch = session.squelchOverNoiseDB
        let word = r?.signalWord
        return ReadingRow(
            label: "Signal", help: signalHelp(overNoise: overNoise, squelch: squelch),
            number: Measure.db(overNoise)
        ) {
            MeterTrack(
                range: 0...Self.signalBarRangeDB, fill: .ramp, level: overNoise, ticks: [squelch])
        } word: {
            Text(word?.word ?? Reading.absent)
                .foregroundStyle(word == nil ? Theme.inkFaint : Theme.inkSecondary)
        }
    }

    private func signalHelp(overNoise: Double, squelch: Double) -> String {
        guard overNoise.isFinite else {
            return
                "No signal measured yet: the floor is read from the first spectrum row, and the level from the channel's meter."
        }
        var parts = [
            "\(Measure.db(overNoise)) above the noise floor. Voice is fully readable above about \(Measure.db(Self.readableDB))."
        ]
        if squelch.isFinite {
            let open = session.meter?.squelchOpen ?? false
            parts.append(
                "The tick is the squelch, \(Measure.db(squelch)) over the floor; the channel is \(open ? "above it and heard" : "below it and muted")."
            )
        } else {
            parts.append("The squelch is off.")
        }
        if let m = session.meter, let floor = session.channelFloorDB {
            parts.append("\(Measure.dbfs(m.powerDbfs)) against a floor of \(Measure.dbfs(floor)).")
        }
        return parts.joined(separator: " ")
    }

    /// A centre-zero needle: it sits where the tuning is against the transmitter, the way the
    /// waterfall shows it, so a transmitter above the channel puts the needle left of centre.
    /// The word flips only past a tenth of the channel's width, with hysteresis.
    private func tuning(_ r: ChannelReading?, channel ch: Leyline_V1_Channel) -> some View {
        let errorHz = r?.freqErrorHz ?? .nan
        let word = r?.tuningWord
        let offTune = word?.isOffTune ?? false
        let held = !(r?.isLive ?? false)
        let help: String
        if errorHz.isFinite, let word {
            help =
                "\(held ? "The last transmission sat" : "The transmitter sits") \(Measure.hz(abs(errorHz))) \(errorHz >= 0 ? "above" : "below") the channel's centre, \(word.isOffTune ? "past" : "within") a tenth of its \(Frequency.width(ch.bandwidthHz)) width. The needle is where the tuning sits against the signal, as on the waterfall."
        } else {
            help = "Measured while the squelch is open. Nothing has been heard on this channel yet."
        }
        return ReadingRow(
            label: "Tuning", help: help, held: held, number: Measure.hz(errorHz, signed: true)
        ) {
            MeterTrack(
                range: -0.5...0.5, ticks: [0], needle: -errorHz / Double(ch.bandwidthHz),
                needleInk: offTune ? Theme.caution : Theme.inkSecondary)
        } word: {
            // `Off tune` alone: the direction is the needle's side and the number's sign, and
            // `Off tune · high` does not fit the word column.
            Text(word.map { $0.isOffTune ? "Off tune" : "Centred" } ?? Reading.absent)
                .foregroundStyle(
                    word == nil ? Theme.inkFaint : offTune ? Theme.caution : Theme.inkSecondary)
        }
    }

    /// The held peak against the mode's nominal (the tick), neutral up to the overdeviation
    /// limit and caution past it.
    private func deviation(
        _ r: ChannelReading?, channel ch: Leyline_V1_Channel, nominalHz: Double
    ) -> some View {
        let deviationHz = r?.deviationHz ?? .nan
        let word = r?.deviationWord
        let held = !(r?.isLive ?? false)
        let help: String
        if deviationHz.isFinite {
            help =
                "\(held ? "The last transmission deviated" : "Deviating") \(Measure.hz(deviationHz)) at its peak, against a nominal \(Measure.hz(nominalHz)) for \(ch.mode.word) at \(Frequency.width(ch.bandwidthHz)) (the tick). Past \(Measure.hz(nominalHz * DeviationWord.overFraction)) is overdeviating."
        } else {
            help = "Measured while the squelch is open. Nothing has been heard on this channel yet."
        }
        return ReadingRow(
            label: "Deviation", help: help, held: held, number: Measure.hz(deviationHz)
        ) {
            MeterTrack(
                range: 0...(nominalHz * Self.deviationSpanNominals),
                fill: .neutral(cautionAbove: nominalHz * DeviationWord.overFraction),
                level: deviationHz, ticks: [nominalHz])
        } word: {
            Text(word.map(Self.shortWord) ?? Reading.absent)
                .foregroundStyle(
                    word == nil
                        ? Theme.inkFaint
                        : word == .overdeviating ? Theme.caution : Theme.inkSecondary)
        }
    }

    /// `Over` for overdeviating, which does not fit the word column; the tooltip says it in
    /// full.
    private static func shortWord(_ word: DeviationWord) -> String {
        word == .overdeviating ? "Over" : word.word
    }

    /// `Now` in `good` and the seconds in the number column while the squelch is open;
    /// `Idle · last heard 2 min ago` when it is closed. The count of transmissions is the log's
    /// header, not this row's.
    private var onAir: some View {
        let log = session.transmissions
        let open = log?.onAir
        let seconds = session.timeOnAirSeconds
        let last = log?.closed.first
        let clause: String? =
            open != nil ? nil : last.map { "last heard \(lastHeard($0))" } ?? "nothing heard yet"
        let help: String
        if open != nil {
            help =
                "The squelch is open: on the air for \(seconds.map { Reading.seconds($0) } ?? "an unknown time")."
        } else if let last {
            help =
                "Idle. The last transmission ran \(Reading.seconds(last.seconds))\(session.wallTime(of: last.end).map { " and ended at \(WallClock.hms($0))" } ?? "")."
        } else {
            help = "Idle. Nothing has opened the squelch on this channel yet."
        }
        return HStack(spacing: 0) {
            ReadingLabel(text: "On air")
            HStack(spacing: 0) {
                Text(open == nil ? "Idle" : "Now")
                    .foregroundStyle(open == nil ? Theme.inkTertiary : Theme.good)
                if let clause {
                    Text(" · \(clause)").foregroundStyle(Theme.inkMuted)
                }
            }
            .font(Theme.Font.label).monospacedDigit().lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if open != nil {
                Text(Reading.seconds(seconds ?? .nan))
                    .font(Theme.Font.value).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                    .frame(width: Theme.Layout.readingNumberWidth, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .help(help)
    }

    /// `2 min ago` on the capture's clock; the wall clock when the transmission is on another
    /// timeline but the anchor dates it.
    private func lastHeard(_ t: Transmission) -> String {
        if let s = session.secondsAgo(t.end) { return Reading.ago(seconds: s) }
        if let date = session.wallTime(of: t.end) { return "at \(WallClock.hm(date))" }
        return "earlier"
    }
}

/// A reading row's label, in the fixed first column.
struct ReadingLabel: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
            .frame(width: Theme.Layout.readingLabelWidth, alignment: .leading)
    }
}

/// One reading: the label, then the meter, the word and the number in fixed columns, dimmed
/// together when `held`. The tooltip is the sentence with the number in it.
struct ReadingRow<Meter: View, Word: View>: View {
    let label: String
    let help: String
    var held = false
    let number: String
    @ViewBuilder let meter: Meter
    @ViewBuilder let word: Word

    var body: some View {
        HStack(spacing: 0) {
            ReadingLabel(text: label)
            HStack(spacing: 0) {
                meter.frame(width: Theme.Layout.readingMeterWidth)
                word.font(Theme.Font.label).lineLimit(1)
                    .padding(.leading, Theme.Layout.readingWordGap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(number).font(Theme.Font.value).foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                    .frame(width: Theme.Layout.readingNumberWidth, alignment: .trailing)
            }
            .opacity(held ? ReadingsView.heldOpacity : 1)
        }
        .contentShape(Rectangle())
        .help(help)
    }
}
