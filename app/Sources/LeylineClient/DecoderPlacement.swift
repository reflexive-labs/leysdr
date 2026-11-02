// SPDX-License-Identifier: Apache-2.0

// Where a decoder will land before it starts, from what `GetState` shows: the rules of the
// daemon's allocator (`engine/Sources/LeylineServer/Jobs/SessionCaptureAllocator.swift`) read
// back, because there is no dry run in the contract and one dongle makes the answer matter
// (docs/plans/decoders-app.md, "Decisions"). The prediction is advice for the Start button's
// line and its confirmation; the job's own state and detail are the truth, and the page shows
// them once it runs.

import Foundation
import LeylineProto

public enum DecoderPlacement: Sendable, Equatable {
    /// A capture already covers the frequency: the decoder runs beside whatever is on it.
    /// `listening` is whether the window's own channel is on that capture.
    case alongside(captureID: String, listening: Bool)
    /// A radio with nothing on it, or a capture nobody is using, which the decoder takes and
    /// tunes. `retune` is the second.
    case idleRadio(deviceID: String, model: String, retune: Bool)
    /// The radio that can hear it is somebody's; Start asks, then sends `take_over`.
    case needsRadio(captureID: String, reason: String)
    /// No radio here can tune the frequency.
    case unreachable(String)
    /// The decoder has no frequency of its own and the window has nothing tuned to give it.
    case needsFrequency

    /// How long after somebody's last interactive write a capture still counts as in use: the
    /// daemon's `dontDisturbNs`.
    public static let dontDisturbSeconds: Double = 60
    /// How far from the frequency a capture may be centred and still count as centred on it,
    /// for a decoder that `needs_dedicated_capture`.
    public static let centredWithinHz: UInt64 = 1_000

    /// The line under Start.
    public var words: String {
        switch self {
        case .alongside(_, let listening):
            return listening
                ? "Runs alongside what you are listening to."
                : "Runs on the radio's capture, which already covers it."
        case .idleRadio(_, let model, let retune):
            return retune
                ? "Takes the \(model), which nobody is using, and tunes it."
                : "Takes the idle radio, the \(model)."
        case .needsRadio(_, let reason):
            return "Needs the radio from you: \(reason)."
        case .unreachable(let why):
            return Self.sentence(why)
        case .needsFrequency:
            return "Has no frequency of its own: tune a channel first."
        }
    }

    /// Whether Start must confirm and then send `take_over`.
    public var needsTakeOver: Bool {
        if case .needsRadio = self { return true }
        return false
    }

    /// Whether Start is offered at all.
    public var canStart: Bool {
        switch self {
        case .unreachable, .needsFrequency: return false
        default: return true
        }
    }

    /// The frequency a decoder starts on: the first of its recipe's frequencies inside the span
    /// the window's capture covers, else the recipe's first, else the window's tuned frequency
    /// for a decoder with none of its own (speech). Nil when there is none of the three.
    public static func frequency(
        for manifest: Leyline_V1_DecoderManifest, capture: Leyline_V1_Capture?, tunedHz: UInt64?
    ) -> UInt64? {
        let recipe = manifest.recipe.frequenciesHz
        guard let first = recipe.first else { return tunedHz }
        if let cap = capture, cap.sampleRate > 0 {
            if let inside = recipe.first(where: {
                spanCovers(centerHz: cap.centerHz, rate: cap.sampleRate, frequencyHz: $0)
            }) {
                return inside
            }
        }
        return first
    }

    /// Predicts where `manifest` lands at `frequencyHz`, by the allocator's order: a capture that
    /// already hears it, else a radio with nothing on it, else a capture nobody is using (the
    /// don't-disturb test), else the reason it is somebody's, else that nothing can hear it.
    /// `swept` holds the devices a sweep holds, whose captures no decoder can join; `selfID` is
    /// the window's client id, so its own channel reads "you are listening".
    public static func predict(
        _ manifest: Leyline_V1_DecoderManifest, frequencyHz: UInt64?, state: MirrorState,
        swept: Set<String> = [], selfID: String, now: Date = Date()
    ) -> DecoderPlacement {
        guard let hz = frequencyHz else { return .needsFrequency }
        let iq = manifest.input.signal == .signalIq
        let captures = state.captures.filter {
            $0.state != .unspecified && !swept.contains($0.deviceID)
        }
        let devices = state.devices.filter { $0.state != .disconnected }
        let bw = bandwidth(manifest)

        // 1. A capture that already covers the frequency, which disturbs nobody.
        for cap in captures where cap.sampleRate > 0 {
            let covers: Bool
            if iq {
                covers =
                    manifest.needsDedicatedCapture
                    ? centred(cap, on: hz, rate: manifest.recipe.sampleRate)
                    : spanCovers(centerHz: cap.centerHz, rate: cap.sampleRate, frequencyHz: hz)
            } else {
                covers = fits(
                    offsetHz: Int64(hz) - Int64(cap.centerHz), bandwidthHz: bw,
                    sampleRate: cap.sampleRate)
            }
            if covers {
                let listening = state.channels.contains {
                    $0.captureID == cap.captureID && $0.owner.clientID == selfID
                }
                return .alongside(captureID: cap.captureID, listening: listening)
            }
        }

        // 2. A radio with nothing on it that can tune the frequency.
        var lastReason = "no radio here can hear \(mhz(hz))"
        for d in devices where !state.captures.contains(where: { $0.deviceID == d.deviceID }) {
            let rate = iq ? iqRate(manifest.recipe.sampleRate, device: d) : defaultRate(d)
            if canTune(d, hz: hz, bandwidthHz: bw, rate: rate, iq: iq) {
                return .idleRadio(deviceID: d.deviceID, model: model(d), retune: false)
            }
            lastReason = "\(model(d)) cannot tune \(mhz(hz))"
        }

        // 3. A capture nobody is using, retuned; else the first reason one is somebody's.
        var busy: (captureID: String, reason: String)?
        for cap in captures {
            guard let d = devices.first(where: { $0.deviceID == cap.deviceID }) else { continue }
            let rate =
                iq && manifest.needsDedicatedCapture
                ? iqRate(manifest.recipe.sampleRate, device: d) : cap.sampleRate
            guard canTune(d, hz: hz, bandwidthHz: bw, rate: rate, iq: iq) else {
                lastReason = "\(model(d)) cannot tune \(mhz(hz))"
                continue
            }
            if let why = inUse(cap, state: state, selfID: selfID, now: now) {
                if busy == nil { busy = (cap.captureID, why) }
                continue
            }
            return .idleRadio(deviceID: d.deviceID, model: model(d), retune: true)
        }
        if let busy { return .needsRadio(captureID: busy.captureID, reason: busy.reason) }
        return .unreachable(lastReason)
    }

    /// The don't-disturb test, as the daemon's `inUse`: a reason when the capture is somebody's,
    /// nil when it is free. A channel on it, audio playing from it, or a write that tuned it
    /// under a minute ago.
    public static func inUse(
        _ cap: Leyline_V1_Capture, state: MirrorState, selfID: String, now: Date
    ) -> String? {
        if let ch = state.channels.first(where: { $0.captureID == cap.captureID }) {
            let hz = UInt64(clamping: max(0, Int64(cap.centerHz) + ch.offsetHz))
            let at = mhz(hz > 0 ? hz : cap.centerHz)
            if ch.owner.clientID == selfID { return "you are listening on \(at)" }
            return "\(who(ch.owner)) is listening on \(at)"
        }
        if cap.activity.liveAudioSinks > 0 { return "audio is playing from this radio" }
        let last = cap.activity.lastInteractiveWriteNs
        let nowNs = Int64(now.timeIntervalSince1970 * 1e9)
        if last > 0, nowNs > last, Double(nowNs - last) / 1e9 < dontDisturbSeconds {
            return "somebody was tuning this radio \((nowNs - last) / 1_000_000_000) s ago"
        }
        return nil
    }

    /// A client by its kind, as the daemon names one in a refusal.
    static func who(_ c: Leyline_V1_ClientInfo) -> String {
        switch c.kind {
        case "cli": return "a terminal"
        case "app": return "the app"
        case "mcp": return "an agent"
        case "job": return "another job"
        default: return c.label.isEmpty ? "another client" : c.label
        }
    }

    // MARK: The allocator's arithmetic

    /// The channel width a decoder's recipe asks for: its own, else its mode's default.
    static func bandwidth(_ m: Leyline_V1_DecoderManifest) -> UInt32 {
        if m.recipe.bandwidthHz > 0 { return m.recipe.bandwidthHz }
        switch m.recipe.mode {
        case .wfm: return 200_000
        case .am: return 10_000
        case .usb, .lsb: return 3_000
        case .cw: return 500
        default: return 12_500
        }
    }

    /// Whether a channel at `offsetHz` from the centre, `bandwidthHz` wide, sits inside the span
    /// (`SessionStore.fits`).
    static func fits(offsetHz: Int64, bandwidthHz: UInt32, sampleRate: UInt64) -> Bool {
        Double(offsetHz.magnitude) + Double(bandwidthHz) / 2 <= Double(sampleRate) / 2
    }

    /// Whether a capture's whole span covers the frequency at all: an IQ decoder's reuse test.
    static func spanCovers(centerHz: UInt64, rate: UInt64, frequencyHz: UInt64) -> Bool {
        let half = Int64(rate / 2)
        let f = Int64(frequencyHz)
        return f >= Int64(centerHz) - half && f <= Int64(centerHz) + half
    }

    /// Whether a capture is centred on the frequency, within `centredWithinHz`, at the recipe's
    /// rate (any rate when the recipe names none).
    static func centred(_ cap: Leyline_V1_Capture, on hz: UInt64, rate: UInt64) -> Bool {
        let off = cap.centerHz > hz ? cap.centerHz - hz : hz - cap.centerHz
        return off <= centredWithinHz && (rate == 0 || cap.sampleRate == rate)
    }

    /// Whether a device at `rate` can put the frequency inside its span: a channel a quarter-span
    /// off centre for an audio decoder, the frequency at the centre for an IQ one, each clamped to
    /// the nearest point the device tunes (a file device tunes one point).
    static func canTune(
        _ d: Leyline_V1_DeviceDescriptor, hz: UInt64, bandwidthHz: UInt32, rate: UInt64, iq: Bool
    ) -> Bool {
        guard rate > 0 else { return false }
        let desired = iq ? hz : (hz > rate / 8 ? hz - rate / 8 : hz)
        guard let centre = nearestTunable(desired, device: d) else { return false }
        return iq
            ? spanCovers(centerHz: centre, rate: rate, frequencyHz: hz)
            : fits(offsetHz: Int64(hz) - Int64(centre), bandwidthHz: bandwidthHz, sampleRate: rate)
    }

    static func nearestTunable(_ hz: UInt64, device: Leyline_V1_DeviceDescriptor) -> UInt64? {
        var best: UInt64?
        var bestDistance = UInt64.max
        for r in device.tuningRanges {
            let clamped = min(max(hz, r.minHz), max(r.minHz, r.maxHz))
            let d = clamped > hz ? clamped - hz : hz - clamped
            if d < bestDistance {
                bestDistance = d
                best = clamped
            }
        }
        return best
    }

    /// The rate a channel job opens a capture at: a file's own, else 2.4 MSPS when offered, else
    /// the fastest.
    static func defaultRate(_ d: Leyline_V1_DeviceDescriptor) -> UInt64 {
        let standard: UInt64 = 2_400_000
        if d.driver == "file" { return d.sampleRates.first ?? standard }
        if d.sampleRates.isEmpty || d.sampleRates.contains(standard) { return standard }
        return d.sampleRates.max() ?? standard
    }

    /// The rate an IQ job opens a capture at: the recipe's when the device offers it.
    static func iqRate(_ wanted: UInt64, device d: Leyline_V1_DeviceDescriptor) -> UInt64 {
        if wanted != 0, d.sampleRates.isEmpty || d.sampleRates.contains(wanted) { return wanted }
        return defaultRate(d)
    }

    static func model(_ d: Leyline_V1_DeviceDescriptor) -> String {
        d.model.isEmpty ? "radio" : d.model
    }

    static func mhz(_ hz: UInt64) -> String { String(format: "%.3f MHz", Double(hz) / 1e6) }

    /// A clause as a sentence: capitalised and stopped.
    static func sentence(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst() + (s.hasSuffix(".") ? "" : ".")
    }
}
