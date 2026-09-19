// SPDX-License-Identifier: Apache-2.0

// The device menu: a chip in the toolbar, and behind it the one important control with nowhere
// else to live, gain. The slider shows what auto chose, has detents where the radio has a
// table, and the copy is honest about auto being poor on weak signals. Sample rate is the one
// capture setting here; frequency correction and bias tee are not writable in the contract and
// are not named.

import LeylineClient
import LeylineProto
import SwiftUI

struct DeviceChip: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Button {
            session.deviceMenuShown.toggle()
        } label: {
            // No ground of its own: the toolbar gives every item a glass one, and a chip with
            // a ground inside it was a button in a button.
            HStack(spacing: 7) {
                Circle().fill(dotColour).frame(width: 7, height: 7)
                Text(name).font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $session.deviceMenuShown, arrowEdge: .bottom) { DeviceMenuView() }
    }

    private var name: String {
        if let d = session.device { return d.model.isEmpty ? d.driver : d.model }
        if let d = session.state.devices.first(where: { $0.state != .disconnected }) {
            return d.model.isEmpty ? d.driver : d.model
        }
        return session.isLive ? "No radio" : "No daemon"
    }

    private var dotColour: Color {
        guard session.isLive else { return Theme.recording }
        guard let d = session.device ?? session.state.devices.first else { return Theme.inkFaint }
        return d.state == .disconnected ? Theme.recording : Theme.good
    }
}

struct DeviceMenuView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = session.device {
                header(d)
                Divider().overlay(Theme.border)
                GainControl(device: d)
                Divider().overlay(Theme.border)
                sampleRate(d)
            } else {
                Text(session.isLive ? "No capture yet: pick a band." : "The daemon is not running.")
                    .font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
            }
            others
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.chrome)
    }

    private func header(_ d: Leyline_V1_DeviceDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle().fill(d.state == .disconnected ? Theme.recording : Theme.good).frame(
                    width: 7, height: 7)
                Text(d.model.isEmpty ? d.driver : d.model).font(Theme.Font.menuTitle)
                    .foregroundStyle(Theme.ink)
            }
            Text("\(stateWord(d.state))\(d.serial.isEmpty ? "" : " · serial \(d.serial)")")
                .font(Theme.Font.valueSmall).foregroundStyle(Theme.inkMuted)
        }
    }

    private func stateWord(_ s: Leyline_V1_DeviceState) -> String {
        switch s {
        case .available: "connected"
        case .inUse: "connected, in use"
        case .disconnected: "unplugged"
        default: "unknown"
        }
    }

    private func sampleRate(_ d: Leyline_V1_DeviceDescriptor) -> some View {
        HStack {
            Text("Sample rate").font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Picker(
                "",
                selection: Binding(
                    get: { session.capture?.sampleRate ?? 0 }, set: { session.setSampleRate($0) })
            ) {
                ForEach(d.sampleRates, id: \.self) { r in Text(Frequency.format(r)).tag(r) }
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }

    @ViewBuilder
    private var others: some View {
        let others = session.state.devices.filter {
            $0.deviceID != session.device?.deviceID && $0.state != .disconnected
        }
        if !others.isEmpty {
            Divider().overlay(Theme.border)
            SectionHeader(text: "Choose another device")
            ForEach(others, id: \.deviceID) { d in
                Button {
                    session.deviceMenuShown = false
                    Task { await session.choose(device: d) }
                } label: {
                    HStack {
                        Text(d.model.isEmpty ? d.driver : d.model).font(Theme.Font.label)
                            .foregroundStyle(Theme.inkSecondary)
                        Spacer()
                        Text(d.serial).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Auto or manual, a slider with detents where the radio has a gain table, and what auto chose
/// shown at auto's position so taking over does not jump the gain.
struct GainControl: View {
    @Environment(AppSession.self) private var session
    let device: Leyline_V1_DeviceDescriptor
    @State private var dragging: Double?

    var body: some View {
        let element = device.gainElements.first
        let supportsAuto = element?.supportsAuto ?? false
        let state = session.capture?.gains.first
        let auto = state?.auto ?? true
        let db = dragging ?? state?.db ?? element?.minDb ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gain").font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { auto },
                        set: { if $0 { session.setGainAuto() } else { session.setGain(db: db) } })
                ) {
                    // Only the modes the radio has, and the picker is never disabled: a device
                    // that reports auto without supporting it used to leave Manual unreachable.
                    if supportsAuto { Text("Auto").tag(true) }
                    Text("Manual").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
            if let element {
                GainSlider(element: element, db: db, dimmed: auto) { newDB, ended in
                    dragging = ended ? nil : newDB
                    if ended { session.setGain(db: newDB) }
                }
                HStack {
                    Text(String(format: "%.0f dB", element.minDb)).font(Theme.Font.valueSmall)
                        .foregroundStyle(Theme.inkFaint)
                    Spacer()
                    Text(
                        auto
                            ? String(format: "auto chose %.1f dB", state?.db ?? 0)
                            : String(format: "%.1f dB", db)
                    )
                    .font(Theme.Font.valueSmall).foregroundStyle(Theme.inkTertiary)
                    Spacer()
                    Text(String(format: "%.1f", element.maxDb)).font(Theme.Font.valueSmall)
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            Text(
                "Drag to take over. Auto is good enough for strong local signals and often not for weak ones."
            )
            .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A track with a detent at every value the radio has, or a continuous one when it does not.
struct GainSlider: View {
    let element: Leyline_V1_GainElement
    let db: Double
    let dimmed: Bool
    let onChange: (Double, Bool) -> Void

    private var values: [Double] { element.validDb.isEmpty ? [] : element.validDb.sorted() }
    private var lo: Double { values.first ?? element.minDb }
    private var hi: Double { values.last ?? element.maxDb }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.border).frame(height: 2)
                ForEach(values, id: \.self) { v in
                    Rectangle().fill(Theme.borderStrong).frame(width: 1, height: 6).offset(
                        x: x(of: v, width: w))
                }
                Circle().fill(dimmed ? Theme.inkMuted : Theme.ink).frame(width: 12, height: 12)
                    .offset(x: x(of: db, width: w) - 6)
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in onChange(snap(value(atX: v.location.x, width: w)), false) }
                    .onEnded { v in onChange(snap(value(atX: v.location.x, width: w)), true) })
        }
        .frame(height: 14)
    }

    private func x(of v: Double, width: CGFloat) -> CGFloat {
        guard hi > lo else { return 0 }
        return Scale.x(of: v, in: lo...hi, width: width)
    }

    private func value(atX x: CGFloat, width: CGFloat) -> Double {
        guard hi > lo else { return lo }
        return Scale.value(atX: x, in: lo...hi, width: width)
    }

    /// The nearest entry of the radio's table, else the nearest step.
    private func snap(_ v: Double) -> Double {
        if !values.isEmpty { return values.min { abs($0 - v) < abs($1 - v) } ?? v }
        guard element.stepDb > 0 else { return v }
        return lo + ((v - lo) / element.stepDb).rounded() * element.stepDb
    }
}
