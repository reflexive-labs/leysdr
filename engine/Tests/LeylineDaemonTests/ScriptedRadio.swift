// SPDX-License-Identifier: GPL-3.0-or-later

// A synthetic radio with the faults a real dongle can show: it is listed before anything could
// open it, so it has no gain table until it opens, as an RTL-SDR first probed while rtl_tcp held
// it (2026-11-03); its stream can be told to stop delivering while it still says it is
// streaming; and its opens can be told to fail, as a dongle's do once it stops answering
// (2026-11-09). It plays the synthetic band underneath (`SyntheticBandDevice`).

import EngineCore
import Foundation

/// Unchecked Sendable: its own state is in `LockedValue`s; the rest is the inner device's.
final class ScriptedRadio: VirtualDevice, @unchecked Sendable {
    /// The R820T's table, as librtlsdr reports it once the dongle is open.
    static let r820tTableDB: [Double] = [0, 0.9, 1.4, 2.7, 3.7, 7.7, 8.7, 12.5, 14.4, 15.7, 16.6, 19.7, 20.7, 22.9,
                                         25.4, 28.0, 29.7, 32.8, 33.8, 36.4, 37.2, 38.6, 40.2, 42.1, 43.4, 43.9,
                                         44.5, 48.0, 49.6]

    private let inner: SyntheticBandDevice
    /// Whether an open has read the gain table; false until the first `open`, when
    /// `tableUntilOpen` is false.
    let tableKnown: LockedValue<Bool>
    /// While true the stream delivers nothing, and the radio still says it is streaming.
    let stalled = LockedValue(false)
    /// While true every `open` fails with DEVICE_IO, as `rtlsdr_open` does for a dongle that got
    /// past the claim and did not answer (librtlsdr's register writes time out, -7).
    let failsOpen = LockedValue(false)
    /// `open` calls so far, failed ones included.
    let opens = LockedValue(0)
    private let gain = LockedValue(GainState(element: "TUNER", value: .auto))

    private let learnsTableOnOpen: Bool

    /// `tableUntilOpen` false is the dongle first listed while another program held it;
    /// `learnsTableOnOpen` false is one whose open could not read the table either.
    init(tableUntilOpen: Bool = true, learnsTableOnOpen: Bool = true) {
        inner = SyntheticBandDevice(carriers: [], driver: "rtlsdr")
        tableKnown = LockedValue(tableUntilOpen)
        self.learnsTableOnOpen = learnsTableOnOpen
    }

    var descriptor: DeviceDescriptor {
        var d = inner.descriptor
        d.model = "Scripted RTL"
        let table = tableKnown.value ? Self.r820tTableDB : []
        d.gainElements = [GainElement(name: "TUNER", minDB: table.min() ?? 0, maxDB: table.max() ?? 0, stepDB: 0,
                                      supportsAuto: true, validDB: table)]
        d.features["tuner"] = .text(tableKnown.value ? "R820T" : "unknown")
        return d
    }

    var gains: [GainState] { [gain.value] }
    var inFlightSamples: UInt64 { inner.inFlightSamples }

    func assignID(_ id: DeviceID) { inner.assignID(id) }
    func setState(_ state: DeviceState) { inner.setState(state) }
    func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) { inner.setOnStateChange(hook) }

    /// Reads the gain table from the "handle", as `RTLSDRDevice.open` does.
    func open() async throws {
        opens.value += 1
        if failsOpen.value { throw EngineError.deviceIO("rtlsdr_open failed: -7", target: descriptor.id.string) }
        try await inner.open()
        if learnsTableOnOpen { tableKnown.value = true }
    }

    func close() async { await inner.close() }
    func tune(centerHz: UInt64) async throws { try await inner.tune(centerHz: centerHz) }
    func setSampleRate(_ hz: UInt64) async throws { try await inner.setSampleRate(hz) }

    /// The driver's rule (`RTLSDRDevice.setGain`): a level snaps to the table, and a level asked of
    /// a stage with no table is refused rather than clamped to 0 dB.
    func setGain(element: String, value: GainValue) async throws {
        guard element == "TUNER", let el = descriptor.gainElement(named: element) else {
            throw EngineError.gainElementUnknown(element, target: descriptor.id.string)
        }
        switch value {
        case .auto:
            gain.value = GainState(element: element, value: .auto)
        case .db(let requested):
            guard el.isKnown else {
                throw EngineError.gainTableUnknown(requested, model: descriptor.model, target: descriptor.id.string)
            }
            gain.value = GainState(element: element, value: .db(el.snapped(requested)))
        }
    }

    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        let stalled = stalled
        try await inner.startStreaming(captureID: captureID) { buffer, time in
            if !stalled.value { deliver(buffer, time) }
        }
    }

    func stopStreaming() async { await inner.stopStreaming() }
}
