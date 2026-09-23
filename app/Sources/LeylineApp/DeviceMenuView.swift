// SPDX-License-Identifier: Apache-2.0

// The device menu: a chip in the toolbar that opens the gain controls, which have no other
// place in the window. The slider shows what auto chose, has detents where the radio has a
// table, and the label warns that auto gain is poor on weak signals. Sample rate is the only
// capture setting here; frequency correction and bias tee are not writable in the contract and
// are not shown. Clipping is shown here too, on the chip and in the menu's header, because its
// fix is the gain slider below it (plans/app.md, M2-6).

import LeylineClient
import LeylineProto
import SwiftUI

struct DeviceChip: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Button {
            if !session.deviceMenuShown { session.deviceMenuAskedAt = .now }
            session.deviceMenuShown.toggle()
        } label: {
            // The pop-ups' ground (`PopupButton`): the toolbar's glass is hidden for this item.
            HStack(spacing: 7) {
                Circle().fill(dotColour).frame(width: 7, height: 7)
                // `HackRF Pro · clipping` while the failure state holds; the state goes when
                // the level clears, so there is nothing to close.
                HStack(spacing: 0) {
                    Text(name).foregroundStyle(Theme.inkSecondary)
                    if clipping { Text(" · clipping").foregroundStyle(Theme.caution) }
                }
                .font(Theme.Font.label)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.border, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
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

    private var clipping: Bool {
        if case .clipping? = session.failure { return true }
        return false
    }

    private var dotColour: Color {
        guard session.isLive else { return Theme.recording }
        guard let d = session.device ?? session.state.devices.first else { return Theme.inkFaint }
        if d.state == .disconnected { return Theme.recording }
        return clipping ? Theme.caution : Theme.good
    }
}

struct DeviceMenuView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = session.device {
                header(d)
                Divider().overlay(Theme.border)
                ForEach(d.gainElements, id: \.name) { element in
                    GainControl(device: d, element: element)
                }
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
        .onAppear {
            // The menu reads the mirror and asks the daemon nothing, so a slow open is the main
            // actor busy elsewhere; the delay is logged to find out with what.
            guard let asked = session.deviceMenuAskedAt else { return }
            session.deviceMenuAskedAt = nil
            let ms = -asked.timeIntervalSinceNow * 1000
            log("session", String(format: "device menu shown after %.0f ms", ms))
        }
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
            if let f = session.failure {
                // One Text, so the sentence wraps as one: the headline in caution, the number
                // and the thing to try after it.
                let headline = Text(f.headline + ": ").foregroundStyle(Theme.caution)
                let detail = Text(f.detail).foregroundStyle(Theme.inkTertiary)
                Text("\(headline)\(detail)")
                    .font(Theme.Font.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Sample rate").font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
            Text(
                "Sets how wide a slice of radio spectrum is captured at once. Higher rates show more spectrum and use more processing."
            )
            .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
            .fixedSize(horizontal: false, vertical: true)
            Picker(
                "",
                selection: Binding(
                    get: { session.capture?.sampleRate ?? 0 }, set: { session.setSampleRate($0) })
            ) {
                ForEach(d.sampleRates, id: \.self) { r in Text(Frequency.format(r)).tag(r) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
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

/// One advertised gain stage, named and explained in receiver terms. Continuous/table stages use
/// a slider; a two-value stage such as HackRF's RF amp uses a two-position control.
struct GainControl: View {
    @Environment(AppSession.self) private var session
    let device: Leyline_V1_DeviceDescriptor
    let element: Leyline_V1_GainElement
    @State private var dragging: Double?

    var body: some View {
        let supportsAuto = element.supportsAuto
        let state = session.capture?.gains.first { $0.element == element.name }
        let auto = state?.auto ?? supportsAuto
        let db = dragging ?? state?.db ?? element.minDb
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
                Spacer()
                if supportsAuto {
                    Picker(
                        "",
                        selection: Binding(
                            get: { auto },
                            set: {
                                if $0 {
                                    session.setGainAuto(element: element.name)
                                } else {
                                    session.setGain(element: element.name, db: db)
                                }
                            })
                    ) {
                        Text("Auto").tag(true)
                        Text("Manual").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            Text(description)
                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                .fixedSize(horizontal: false, vertical: true)
            if let binaryValues {
                Picker(
                    "",
                    selection: Binding(
                        get: {
                            binaryValues.min { abs($0 - db) < abs($1 - db) } ?? binaryValues[0]
                        },
                        set: { session.setGain(element: element.name, db: $0) })
                ) {
                    Text(binaryLabel(binaryValues[0], low: true)).tag(binaryValues[0])
                    Text(binaryLabel(binaryValues[1], low: false)).tag(binaryValues[1])
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                GainSlider(element: element, db: db, dimmed: auto) { newDB, ended in
                    dragging = ended ? nil : newDB
                    if ended { session.setGain(element: element.name, db: newDB) }
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
            if supportsAuto {
                Text(
                    "Drag to take over. Auto is good enough for strong local signals and often not for weak ones."
                )
                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var binaryValues: [Double]? {
        guard !element.supportsAuto, element.validDb.count == 2 else { return nil }
        return element.validDb.sorted()
    }

    private var description: String {
        switch element.name.uppercased() {
        case "TUNER":
            "Controls how much the RTL-SDR amplifies the antenna signal. More can reveal weak signals; too much causes distortion."
        case "LNA":
            "Amplifies weak signals as they enter the radio. Too much can overload strong signals."
        case "VGA":
            "Adjusts the signal again just before it is digitized. Use it to bring up quieter signals."
        case "AMP":
            "Switches the extra RF amplifier on or off. On adds about 11 dB and can overload strong signals."
        default:
            "Controls how strongly this radio amplifies incoming signals."
        }
    }

    private var title: String {
        switch element.name.uppercased() {
        case "TUNER": "Receiver gain"
        default: device.gainElements.count == 1 ? "Gain" : "\(element.name) gain"
        }
    }

    private func binaryLabel(_ value: Double, low: Bool) -> String {
        if element.name.uppercased() == "AMP" {
            return low ? "Off · 0 dB" : String(format: "On · +%.0f dB", value)
        }
        return String(format: "%.1f dB", value)
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
