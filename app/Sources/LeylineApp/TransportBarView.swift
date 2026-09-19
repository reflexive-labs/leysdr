// SPDX-License-Identifier: Apache-2.0

// Region 5: the transport bar, in its final layout from the first release. Play/pause, the one
// editable frequency in the window, mode, width, the signal readout (M1 only), the squelch
// track with its words, and volume with the output's name. Absent for good: gain, elapsed
// time, recording, sample rate.

import LeylineClient
import LeylineProto
import SwiftUI

struct TransportBarView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        HStack(spacing: 18) {
            PlayButton()
            FrequencyField()
            ModePopup()
            WidthPopup()
            SignalReadout()
            SquelchTrack()
                .frame(maxWidth: .infinity)
            VolumeControl()
                .frame(width: 142)
        }
        .padding(.horizontal, 18)
        .background(Theme.chrome)
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

/// `146.520` in ink, `000` dimmed, `MHz`. One text field, always: clicking into it or ⌘L edits
/// it in place, Enter tunes, Escape or clicking away puts the daemon's number back. The arrow
/// keys step by the band's step (the Tune menu), so there is no stepper.
struct FrequencyField: View {
    @Environment(AppSession.self) private var session
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let hz = session.displayHz
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.frequency)
                .foregroundStyle(hz == nil && !focused ? Theme.inkDisabled : Theme.ink)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { focused = false }
                .frame(width: 122)
            if !focused {
                Text(Frequency.fieldParts(hz ?? 0).minor)
                    .font(Theme.Font.frequency).tracking(Theme.frequencyTracking).foregroundStyle(Theme.inkDisabled)
            }
            Rectangle().fill(Theme.accent).frame(width: 1.5, height: 26).padding(.horizontal, 4)
            Text("MHz").font(Theme.Font.value).foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.ground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Theme.accent : Theme.borderFocus))
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

struct ModePopup: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        LabeledPopup(label: "Mode") {
            Picker("", selection: Binding(get: { session.channel?.mode ?? .nfm }, set: { session.setMode($0) })) {
                ForEach(TuneCommands.modes, id: \.rawValue) { m in Text(m.word).tag(m) }
            }
            .labelsHidden()
            .frame(width: 106)
            .disabled(session.channel == nil)
        }
    }
}

struct WidthPopup: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let mode = session.channel?.mode ?? .nfm
        let current = session.channel?.bandwidthHz ?? mode.defaultBandwidthHz
        let choices = mode.offeredBandwidthsHz.contains(current) ? mode.offeredBandwidthsHz : [current] + mode.offeredBandwidthsHz
        LabeledPopup(label: "Width") {
            Picker("", selection: Binding(get: { current }, set: { session.setBandwidth($0) })) {
                ForEach(choices, id: \.self) { bw in Text(Frequency.width(bw)).tag(bw) }
            }
            .labelsHidden()
            .frame(width: 106)
            .disabled(session.channel == nil)
        }
    }
}

struct LabeledPopup<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(text: label)
            content
        }
    }
}

/// `−38 dBFS` and `26 dB over noise`, the channel meter's numbers. M1 only; the inspector takes
/// this over in M2.
struct SignalReadout: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(text: "Signal")
            let m = session.meter
            Text(m.map { $0.powerDbfs.isFinite ? String(format: "%.0f dBFS", $0.powerDbfs) : "—" } ?? "—")
                .font(Theme.Font.readout).foregroundStyle(Theme.ink)
            Text(m.flatMap { $0.snrDb.isFinite ? String(format: "%.0f dB over noise", $0.snrDb) : nil } ?? " ")
                .font(Theme.Font.footnote).foregroundStyle(Theme.good)
        }
        .frame(width: 112, alignment: .leading)
    }
}

/// A track with a marked threshold: muted left of it, heard right of it, the level as a
/// ramp-filled bar, the marker draggable. The words are the point.
struct SquelchTrack: View {
    @Environment(AppSession.self) private var session
    @State private var dragDb: Double?

    static let minDb: Double = -120
    static let maxDb: Double = 0

    var body: some View {
        let squelch = dragDb ?? session.channel?.squelchDb ?? .nan
        let open = session.meter?.squelchOpen ?? false
        let power = session.meter?.powerDbfs ?? .nan
        VStack(alignment: .leading, spacing: 4) {
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
                    Rectangle()
                        .fill(LinearGradient(colors: Theme.levelStops, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, levelX), height: 8)
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, levelX)) }
                    Marker().offset(x: markerX - 1.25)
                }
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
        return open ? String(format: "open · %.0f dB above the marker", d) : String(format: "muted · %.0f dB below the marker", -d)
    }

    private func x(of db: Double, width: CGFloat) -> CGFloat {
        CGFloat(((db - Self.minDb) / (Self.maxDb - Self.minDb)).clamped(to: 0...1)) * width
    }

    private func db(atX x: CGFloat, width: CGFloat) -> Double {
        Self.minDb + Double((x / max(width, 1)).clamped(to: 0...1)) * (Self.maxDb - Self.minDb)
    }

    struct Marker: View {
        var body: some View {
            VStack(spacing: 0) {
                Triangle().fill(Theme.ink).frame(width: 7, height: 4)
                Rectangle().fill(Theme.ink).frame(width: 2.5, height: 14)
            }
        }
    }

    struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.closeSubpath()
            return p
        }
    }
}

struct VolumeControl: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let sink = session.sink
        let volume = sink.map { $0.systemAudio.hasVolume ? $0.systemAudio.volume : 1 } ?? 1
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(text: "Volume")
            Slider(value: Binding(get: { volume }, set: { session.setVolume($0) }), in: 0...1)
                .controlSize(.small)
                .tint(Theme.inkTertiary)
                .disabled(sink == nil)
            Text(outputName(sink))
                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest).lineLimit(1)
        }
    }

    private func outputName(_ sink: Leyline_V1_Sink?) -> String {
        guard let sink else { return "not playing" }
        return AudioOutputName.lookup(uid: sink.systemAudio.audioDeviceUid) ?? "the daemon's output"
    }
}
