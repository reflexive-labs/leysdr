// SPDX-License-Identifier: Apache-2.0

// Region 5: the transport bar, in its final layout from the first release (docs/design/
// app-design-handoff.md, and the design's footer). Every block is a header on one line with
// its control under it: play, the one editable frequency in the window, mode, width, a
// divider, the squelch track with its words, and volume with the output's name. The signal
// readout stood between the divider and the squelch in M1 and left with M2's inspector, which
// says the same thing in words (the M1 handoff's one named exception to "nothing moves"); the
// slot went back to the squelch track. Absent for good: gain, elapsed time, recording, sample
// rate.

import LeylineClient
import LeylineProto
import SwiftUI

struct TransportBarView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            PlayButton()
                .frame(maxHeight: .infinity)
            FrequencyField()
            ModePopup()
            WidthPopup()
            // The full height of the bar's content, from the labels' top down.
            Rectangle().fill(Theme.border).frame(width: 1)
            SquelchTrack()
                .frame(maxWidth: .infinity)
            VolumeControl()
                .frame(width: 142)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Theme.chrome)
    }
}

/// A header and the control under it, the way every block of the bar is built.
struct Block<Content: View>: View {
    let header: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(text: header)
            content
        }
    }
}

struct PlayButton: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Button {
            Task { await session.togglePlay() }
        } label: {
            ZStack {
                Circle().fill(Theme.accent).frame(width: 44, height: 44)
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ground)
                    .offset(x: session.isPlaying ? 0 : 1.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(session.channel == nil)
        .help(session.isPlaying ? "Pause: the channel's audio is detached" : "Play")
    }
}

/// `146.520` in ink, `000` dimmed, `MHz`. Entry works the way a radio's keypad does, by
/// overwriting: click or ⌘L puts the caret on the first digit, each digit typed replaces the one
/// under the caret and moves on, `.` jumps to the kHz digits (dropping whatever MHz digits were
/// not retyped), Backspace steps back, Enter tunes, Escape or a click anywhere else puts the
/// daemon's number back. The sub-kHz digits are shown and never typed. The stepper against the
/// right edge does what the Tune menu's arrows do: the band's step, and the fine step with ⇧.
struct FrequencyField: View {
    @Environment(AppSession.self) private var session
    @State private var mhz: [Character] = []
    @State private var khz: [Character] = ["0", "0", "0"]
    @State private var caret = 0
    @State private var inKhz = false
    @State private var monitor: Any?
    /// The window the field was focused in, so the monitor below can tell its own keys from the
    /// device popover's. An identity is all that is compared, and it crosses actors where an
    /// `NSWindow` could not.
    @State private var ownWindow: ObjectIdentifier?
    @FocusState private var focused: Bool

    var body: some View {
        let hz = session.displayHz
        Block(header: "Tuning") {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                digits(mhz, active: focused && !inKhz, dim: hz == nil && !focused)
                Text(".").font(Theme.Font.frequency).foregroundStyle(
                    hz == nil && !focused ? Theme.inkDisabled : Theme.ink)
                digits(khz, active: focused && inKhz, dim: hz == nil && !focused)
                // Sub-kHz digits only when there are any: a drag lands between kHz, a keypad never does.
                if let hz, hz % 1_000 != 0, !focused {
                    Text(Frequency.fieldParts(hz).minor)
                        .font(Theme.Font.frequency).tracking(Theme.frequencyTracking)
                        .foregroundStyle(Theme.inkDisabled)
                }
                Rectangle().fill(Theme.accent).frame(width: 1.5, height: 26).padding(.horizontal, 4)
                Text("MHz").font(Theme.Font.value).foregroundStyle(Theme.inkMuted)
            }
            // The trailing side leaves room for the stepper.
            .padding(.leading, 10).padding(.trailing, 32).padding(.vertical, 5)
            .frame(minWidth: 232, alignment: .trailing)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(focused ? Theme.accent : Theme.borderFocus)
            )
            .contentShape(Rectangle())
            .onTapGesture { begin() }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress { handle($0) }
            // Above the focusable field, not inside it, so a click on an arrow never takes the
            // field's focus. During an edit the field's own monitor ends the edit on the
            // mouse-down, so the arrow steps the daemon's number, never the digits being typed.
            .overlay(alignment: .trailing) {
                StepArrows(enabled: session.channel != nil).padding(.trailing, 9)
            }
        }
        .onAppear { load(hz) }
        .onChange(of: hz) { _, new in
            if !focused { load(new) }
        }
        .onChange(of: focused) { _, isFocused in
            session.frequencyEntryShown = isFocused
            if isFocused { watchClicks() } else { end() }
        }
        .onChange(of: session.frequencyEntryShown) { _, shown in
            if shown, !focused { begin() }
        }
        .onDisappear {
            // A window that closes while the field has focus never reports the focus lost, so
            // without this the monitor outlives the field and swallows keys for the process.
            focused = false
            session.frequencyEntryShown = false
            end()
        }
    }

    /// Each digit its own glyph, the one under the caret on an accent ground while editing, and
    /// a bar after the last when the caret is past it.
    private func digits(_ chars: [Character], active: Bool, dim: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, c in
                Text(String(c))
                    .font(Theme.Font.frequency).tracking(Theme.frequencyTracking)
                    .foregroundStyle(dim ? Theme.inkDisabled : Theme.ink)
                    .background(active && i == caret ? Theme.accent.opacity(0.3) : Color.clear)
            }
            if active, caret >= chars.count {
                Rectangle().fill(Theme.accent).frame(width: 2, height: 28).offset(y: 4)
            }
        }
    }

    private func load(_ hz: UInt64?) {
        guard let hz else {
            mhz = []
            khz = ["0", "0", "0"]
            return
        }
        mhz = Array(String(hz / 1_000_000))
        khz = Array(String(format: "%03d", (hz % 1_000_000) / 1_000))
    }

    private func begin() {
        load(session.displayHz)
        caret = 0
        inKhz = false
        focused = true
    }

    private func end() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        ownWindow = nil
        inKhz = false
        caret = 0
        load(session.displayHz)
    }

    /// Nothing below 500 kHz (AM broadcast starts at 530) or above 6 GHz is a frequency a radio
    /// here can be tuned to, and the keypad makes both easy to type: a `.` into an empty MHz part
    /// followed by three digits reads as 0.500. A refused number keeps the field focused, so it
    /// can be finished rather than sending the radio somewhere nobody asked for.
    private func commit() {
        let whole = UInt64(String(mhz)) ?? 0
        let thousandths = UInt64(String(khz)) ?? 0
        let hz = whole * 1_000_000 + thousandths * 1_000
        if hz < 500_000 || hz > 6_000_000_000 {
            log("field", "refused \(String(mhz)).\(String(khz))")
            return
        }
        log("tune", "typed \(String(mhz)).\(String(khz)) -> \(hz) Hz")
        session.tune(to: hz)
        focused = false
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .return {
            commit()
            return .handled
        }
        if press.key == .escape {
            focused = false
            return .handled
        }
        return handleEditingKey(press.key, press.characters)
    }

    private func forwardDelete() {
        if inKhz {
            if caret < khz.count { khz[caret] = "0" }
        } else if caret < mhz.count, mhz.count > 1 {
            mhz.remove(at: caret)
        }
    }

    private func handleEditingKey(_ key: KeyEquivalent, _ characters: String) -> KeyPress.Result {
        if key == .leftArrow {
            if inKhz {
                if caret > 0 {
                    caret -= 1
                } else {
                    inKhz = false
                    caret = mhz.count
                }
            } else if caret > 0 {
                caret -= 1
            }
            return .handled
        }
        if key == .rightArrow {
            if inKhz {
                if caret < khz.count { caret += 1 }
            } else if caret < mhz.count {
                caret += 1
            } else {
                inKhz = true
                caret = 0
            }
            return .handled
        }
        if key == .delete {
            if inKhz {
                if caret > 0 {
                    caret -= 1
                    khz[caret] = "0"
                } else {
                    inKhz = false
                    caret = mhz.count
                }
            } else if caret > 0 {
                caret -= 1
                mhz.remove(at: caret)
            }
            return .handled
        }
        guard let c = characters.first else { return .ignored }
        if c == "." || c == "," {
            if !inKhz {
                mhz = Array(mhz.prefix(max(caret, 1)))
                inKhz = true
                caret = 0
            }
            return .handled
        }
        guard c.isNumber else { return .ignored }
        if inKhz {
            if caret < khz.count {
                khz[caret] = c
                caret += 1
            }
        } else if caret < mhz.count {
            mhz[caret] = c
            caret += 1
        } else if mhz.count < 4 {
            mhz.append(c)
            caret += 1
        }
        return .handled
    }

    /// While the field has focus its own window's events are watched directly: SwiftUI hands a
    /// focusable view its digits but not reliably Return or Escape, and it moves focus for no
    /// click on a view that takes none. A local monitor sees the whole application, so an event
    /// of any other window — Escape in the device popover — passes through untouched, and only
    /// the window that was key when focus began is the field's. Any mouse-down there ends the
    /// edit (a click on the field itself begins a fresh one through its tap); Return tunes,
    /// Escape restores, the arrows move the caret and space does nothing, all swallowed so the
    /// Tune menu's key equivalents do not fire on top of typing.
    private func watchClicks() {
        if monitor != nil { return }
        let blur = $focused
        ownWindow = NSApp.keyWindow.map { ObjectIdentifier($0) }
        let own = ownWindow
        log("field", "editing")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .keyDown,
        ]) { event in
            // Only the two values the field needs cross into the main actor; an NSEvent is not
            // Sendable and an ObjectIdentifier is, so the window is compared out here.
            guard let own, let window = event.window, ObjectIdentifier(window) == own else {
                return event
            }
            let type = event.type
            let code = event.keyCode
            let swallow: Bool = MainActor.assumeIsolated {
                react(to: type, keyCode: code, blur: blur)
            }
            return swallow ? nil : event
        }
    }

    /// Returns true when the key was the field's and nothing else should see it.
    private func react(to type: NSEvent.EventType, keyCode: UInt16, blur: FocusState<Bool>.Binding)
        -> Bool
    {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            log("field", "click ends the edit")
            blur.wrappedValue = false
            return false
        case .keyDown:
            switch keyCode {
            case 36, 76:  // Return, keypad Enter
                commit()
                return true
            case 53:  // Escape
                log("field", "escape restores")
                blur.wrappedValue = false
                return true
            case 51:  // Backspace: step back, clearing what was there
                _ = handleEditingKey(.delete, "")
                return true
            case 117:  // Forward delete: clear the digit under the caret, staying put
                forwardDelete()
                return true
            case 123:  // Left arrow: the caret's, not the Tune menu's step
                _ = handleEditingKey(.leftArrow, "")
                return true
            case 124:  // Right arrow: likewise
                _ = handleEditingKey(.rightArrow, "")
                return true
            case 49:  // Space: no part of a frequency, and not play/pause while one is typed
                return true
            default:
                return false
            }
        default:
            return false
        }
    }
}

/// The two-arrow stepper on the tuning field: up and down by the band's step, the fine step
/// with ⇧ held, exactly the Tune menu's arrows. `inkMuted` at rest as the pop-ups' carets are,
/// `ink` under the pointer, `inkDisabled` with no channel to step.
struct StepArrows: View {
    @Environment(AppSession.self) private var session
    let enabled: Bool

    var body: some View {
        VStack(spacing: 3) {
            StepArrow(symbol: "chevron.up", enabled: enabled) { step(1) }
                .help("Tune up by the band's step; ⇧ for the fine step")
            StepArrow(symbol: "chevron.down", enabled: enabled) { step(-1) }
                .help("Tune down by the band's step; ⇧ for the fine step")
        }
        .disabled(!enabled)
    }

    private func step(_ direction: Int) {
        session.step(direction, fine: NSEvent.modifierFlags.contains(.shift))
    }
}

struct StepArrow: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
                .foregroundStyle(
                    !enabled ? Theme.inkDisabled : hovering ? Theme.ink : Theme.inkMuted
                )
                .frame(width: 16, height: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A pop-up as the design draws it: a raised button with the value and a chevron, a menu of
/// the choices behind it. It previews the choice until the daemon's event confirms it, so the
/// button does not snap back for the tick the write takes.
struct PopupButton<T: Hashable>: View {
    let choices: [T]
    let label: (T) -> String
    let current: T
    let choose: (T) -> Void
    @State private var pending: T?

    var body: some View {
        Menu {
            ForEach(choices, id: \.self) { c in
                Button(label(c)) {
                    pending = c
                    choose(c)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label(pending ?? current)).font(Theme.Font.body).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: 106)
            // A control's ground inside the chrome is the border token; the label is ink and
            // the caret inkMuted.
            .background(Theme.border, in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onChange(of: current) { _, _ in pending = nil }
    }
}

struct ModePopup: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Block(header: "Mode") {
            PopupButton(
                choices: TuneCommands.modes, label: { $0.word },
                current: session.channel?.mode ?? .nfm
            ) { session.setMode($0) }
            .disabled(session.channel == nil)
        }
    }
}

struct WidthPopup: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let mode = session.channel?.mode ?? .nfm
        let current = session.channel?.bandwidthHz ?? mode.defaultBandwidthHz
        // The mode's widths in order, and the channel's own if it is not one of them, so the
        // list never reorders under the pointer.
        let choices =
            (mode.offeredBandwidthsHz
            + (mode.offeredBandwidthsHz.contains(current) ? [] : [current])).sorted()
        Block(header: "Width") {
            PopupButton(choices: choices, label: { Frequency.width($0) }, current: current) {
                session.setBandwidth($0)
            }
            .disabled(session.channel == nil)
        }
    }
}

/// A track with a marked threshold: muted left of it, heard right of it, the level as a
/// ramp-filled bar the height of the track, the marker draggable and written as it moves. The
/// words are the point.
struct SquelchTrack: View {
    @Environment(AppSession.self) private var session
    @State private var dragDB: Double?

    static let minDB: Double = -120
    static let maxDB: Double = 0

    var body: some View {
        let squelch = dragDB ?? session.channel?.squelchDb ?? .nan
        let open = session.meter?.squelchOpen ?? false
        let power = session.meter?.powerDbfs ?? .nan
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionHeader(text: "Squelch")
                Spacer()
                Text(headerWords(squelch: squelch, power: power, open: open))
                    .font(Theme.Font.valueSmall).foregroundStyle(open ? Theme.good : Theme.inkMuted)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let markerX = squelch.isNaN ? 0 : x(of: squelch, width: w)
                let levelX = power.isNaN ? 0 : x(of: power, width: w)
                let inset: CGFloat = 3
                ZStack(alignment: .leading) {
                    // The container: black at the left to the ramp's first stop, the near-black
                    // teal, at the right.
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.black, Theme.levelStops[0]], startPoint: .leading,
                                endPoint: .trailing))
                    // The colour region, inset, as long as the level: dark teal at its left to
                    // the ramp's yellow at its right whatever its length, as the design draws it.
                    LinearGradient(
                        colors: Array(Theme.levelStops[1...3]), startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(0, levelX - inset))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.vertical, inset)
                    .offset(x: inset)
                    Rectangle().fill(Theme.ink).frame(width: 2.5)
                        .overlay(alignment: .top) {
                            Circle().fill(Theme.ink).frame(width: 7, height: 7).offset(y: -2)
                        }
                        .offset(x: markerX - 1.25)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let d = db(atX: v.location.x, width: w)
                            dragDB = d
                            session.setSquelch(d)  // coalesced: one write a tick, the last value wins
                        }
                        .onEnded { v in
                            let d = db(atX: v.location.x, width: w)
                            dragDB = nil
                            session.setSquelch(d)
                        })
            }
            .frame(height: 18)
            HStack {
                Text("muted below").font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                Spacer()
                Text(squelch.isNaN ? "squelch off" : String(format: "marker %.0f dBFS", squelch))
                    .font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
                Spacer()
                Text("heard above").font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
            }
        }
        .disabled(session.channel == nil)
    }

    private func headerWords(squelch: Double, power: Double, open: Bool) -> String {
        guard power.isFinite else { return "no signal measured yet" }
        guard squelch.isFinite else { return "open · squelch off" }
        let d = power - squelch
        return open
            ? String(format: "open · %.0f dB above the marker", d)
            : String(format: "muted · %.0f dB below the marker", -d)
    }

    private func x(of db: Double, width: CGFloat) -> CGFloat {
        Scale.x(of: db, in: Self.minDB...Self.maxDB, width: width)
    }

    private func db(atX x: CGFloat, width: CGFloat) -> Double {
        Scale.value(atX: x, in: Self.minDB...Self.maxDB, width: width)
    }
}

struct VolumeControl: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let sink = session.sink
        let volume = sink.map { $0.systemAudio.hasVolume ? $0.systemAudio.volume : 1 } ?? 1
        Block(header: "Volume") {
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: Binding(get: { volume }, set: { session.setVolume($0) }), in: 0...1)
                    .controlSize(.small)
                    .tint(Theme.inkTertiary)
                    .disabled(sink == nil)
                Text(outputName(sink))
                    .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest).lineLimit(1)
            }
        }
    }

    private func outputName(_ sink: Leyline_V1_Sink?) -> String {
        guard let sink else { return "not playing" }
        return AudioOutputName.lookup(uid: sink.systemAudio.audioDeviceUid) ?? "the daemon's output"
    }
}
