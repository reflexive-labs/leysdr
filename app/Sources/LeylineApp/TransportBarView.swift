// SPDX-License-Identifier: Apache-2.0

// Region 5: the transport bar, in its final layout from the first release (docs/design/
// app-design-handoff.md, and the design's footer). Every block is a header on one line with
// its control under it: play, the one editable frequency in the window, mode, width, a
// divider, the signal readout (M1 only), the squelch track with its words, and volume with the
// output's name. Absent for good: gain, elapsed time, recording, sample rate.

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
            Rectangle().fill(Theme.border).frame(width: 1).padding(.vertical, 14)
            SignalReadout()
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
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(text: header)
            content
        }
    }
}

struct PlayButton: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Button { Task { await session.togglePlay() } } label: {
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

/// `146.520` in ink, `000` dimmed, `MHz`. One text field, always, right-aligned at a fixed
/// width so editing changes nothing but the caret: clicking into it or ⌘L edits in place, Enter
/// tunes, Escape or clicking away puts the daemon's number back. The arrow keys step by the
/// band's step (the Tune menu), so there is no stepper.
struct FrequencyField: View {
    @Environment(AppSession.self) private var session
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let hz = session.displayHz
        Block(header: "Tuning") {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.frequency)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(hz == nil && !focused ? Theme.inkDisabled : Theme.ink)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { focused = false }
                    .frame(width: 124)
                Text(Frequency.fieldParts(hz ?? 0).minor)
                    .font(Theme.Font.frequency).tracking(Theme.frequencyTracking).foregroundStyle(Theme.inkDisabled)
                    .opacity(focused ? 0 : 1)
                Rectangle().fill(Theme.accent).frame(width: 1.5, height: 26).padding(.horizontal, 4)
                Text("MHz").font(Theme.Font.value).foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Theme.accent : Theme.borderFocus))
        }
        .onAppear { text = major(hz) }
        .onChange(of: hz) { _, new in
            if !focused { text = major(new) }
        }
        .onChange(of: focused) { _, isFocused in
            session.frequencyEntryShown = isFocused
            if !isFocused { text = major(hz) }
        }
        .onChange(of: session.frequencyEntryShown) { _, shown in
            if shown, !focused { focused = true }
        }
    }

    private func major(_ hz: UInt64?) -> String { hz.map { Frequency.fieldParts($0).major } ?? "" }

    private func commit() {
        if let v = Frequency.parse(text) {
            log("tune", "typed \(text) -> \(v) Hz")
            session.tune(to: v)
        }
        focused = false
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
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: 106)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
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
            PopupButton(choices: TuneCommands.modes, label: { $0.word }, current: session.channel?.mode ?? .nfm) { session.setMode($0) }
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
        let choices = (mode.offeredBandwidthsHz + (mode.offeredBandwidthsHz.contains(current) ? [] : [current])).sorted()
        Block(header: "Width") {
            PopupButton(choices: choices, label: { Frequency.width($0) }, current: current) { session.setBandwidth($0) }
                .disabled(session.channel == nil)
        }
    }
}

/// `−38` with a small `dBFS`, and `26 dB over noise` under it: the channel meter's numbers. M1
/// only; the inspector takes this over in M2.
struct SignalReadout: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let m = session.meter
        Block(header: "Signal") {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(m.map { $0.powerDbfs.isFinite ? String(format: "%.0f", $0.powerDbfs) : "—" } ?? "—")
                        .font(Theme.Font.readout).foregroundStyle(Theme.ink)
                    Text("dBFS").font(Theme.Font.value).foregroundStyle(Theme.inkMuted)
                }
                Text(m.flatMap { $0.snrDb.isFinite ? String(format: "%.0f dB over noise", $0.snrDb) : nil } ?? " ")
                    .font(Theme.Font.footnote).foregroundStyle(Theme.good)
            }
        }
        .frame(width: 112, alignment: .leading)
    }
}

/// A track with a marked threshold: muted left of it, heard right of it, the level as a
/// ramp-filled bar the height of the track, the marker draggable and written as it moves. The
/// words are the point.
struct SquelchTrack: View {
    @Environment(AppSession.self) private var session
    @State private var dragDb: Double?

    static let minDb: Double = -120
    static let maxDb: Double = 0

    var body: some View {
        let squelch = dragDb ?? session.channel?.squelchDb ?? .nan
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
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.ground)
                    Rectangle().fill(Theme.good.opacity(0.09)).frame(width: max(0, w - markerX)).offset(x: markerX)
                    LinearGradient(colors: Theme.levelStops, startPoint: .leading, endPoint: .trailing)
                        .frame(width: w)
                        .mask(alignment: .leading) { RoundedRectangle(cornerRadius: 3).frame(width: max(0, levelX)) }
                    Rectangle().fill(Theme.ink).frame(width: 2.5)
                        .overlay(alignment: .top) { Circle().fill(Theme.ink).frame(width: 7, height: 7).offset(y: -2) }
                        .offset(x: markerX - 1.25)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let d = db(atX: v.location.x, width: w)
                        dragDb = d
                        session.setSquelch(d)  // coalesced: one write a tick, the last value wins
                    }
                    .onEnded { v in
                        let d = db(atX: v.location.x, width: w)
                        dragDb = nil
                        session.setSquelch(d)
                    })
            }
            .frame(height: 16)
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
        return open ? String(format: "open · %.0f dB above the marker", d) : String(format: "muted · %.0f dB below the marker", -d)
    }

    private func x(of db: Double, width: CGFloat) -> CGFloat {
        CGFloat(((db - Self.minDb) / (Self.maxDb - Self.minDb)).clamped(to: 0...1)) * width
    }

    private func db(atX x: CGFloat, width: CGFloat) -> Double {
        Self.minDb + Double((x / max(width, 1)).clamped(to: 0...1)) * (Self.maxDb - Self.minDb)
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
