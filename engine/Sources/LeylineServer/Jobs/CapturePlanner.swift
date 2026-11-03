// SPDX-License-Identifier: GPL-3.0-or-later

// One decision, `plan` (docs/design/claims.md, "One decision: plan"): where a new need goes, or
// what a retune would move, answered from a snapshot of the daemon's state and nothing else. The
// allocator carries out the answer for jobs, and `Control.Plan` returns it without carrying it out.

import EngineCore
import Foundation
import LeylineProto

/// A placement question.
enum PlanRequest: Sendable {
    /// A job's channel at a frequency (a decode on audio, an audio recording).
    case channel(frequencyHz: UInt64, bandwidthHz: UInt32, mode: DemodMode, deviceID: String?, takeOver: Bool)
    /// A job's IQ reader around a frequency (an IQ decoder, an IQ recording). `dedicated` is the
    /// manifest's `needs_dedicated_capture`: only a capture centred on the frequency at the rate
    /// will do.
    case iq(frequencyHz: UInt64, sampleRateHz: UInt64, deviceID: String?, takeOver: Bool, dedicated: Bool)
    /// A sweep or a monitor: a whole radio, exclusive while it runs.
    case sweep(rangeHz: ClosedRange<UInt64>, deviceID: String?, takeOver: Bool)
    /// A write that moves a capture: a person's (PERSON) or a job's (JOB). `sampleRateHz` 0
    /// keeps the capture's rate.
    case retune(captureID: String, centerHz: UInt64, sampleRateHz: UInt64, by: Leyline_V1_ClientInfo,
                priority: Leyline_V1_ClaimPriority, takeOver: Bool)
}

/// The answer.
enum Plan: Sendable, Equatable {
    /// Satisfied by a capture as it is: nothing moves.
    case share(captureID: String)
    /// A capture made on an idle radio.
    case create(deviceID: String, centerHz: UInt64, sampleRateHz: UInt64)
    /// A capture moved, and the claims the move leaves unsatisfied.
    case retune(captureID: String, centerHz: UInt64, sampleRateHz: UInt64, displacing: [Leyline_V1_Claim])
    /// Nowhere, with why, its stable code and the claims in the way.
    case decline(code: String, reason: String, blocking: [Leyline_V1_Claim])
}

/// The order `plan` tried things in, with why it passed each one over. `plan` is the first
/// attempt; the allocator walks every step, because carrying out an attempt can fail (a radio that
/// will not open, a retune the tuner refuses) and the next candidate is then the answer. The
/// decline a walk ends in names the last reason it met, a failed attempt's included.
struct PlanWalk: Sendable {
    enum Step: Sendable, Equatable {
        case attempt(Plan)
        /// A candidate passed over. `code` nil leaves the decline's code as it was.
        case pass(reason: String, code: String?, blocking: [Leyline_V1_Claim])
    }

    var steps: [Step] = []
    /// Whether any radio was a candidate at all: a walk that saw none declines `NO_DEVICE`.
    var sawDevice = false
    /// The reason when nothing passed anything over.
    var firstReason: String

    var plan: Plan {
        var reason = firstReason
        var code = EngineError.Code.deviceBusy
        var blocking: [Leyline_V1_Claim] = []
        for step in steps {
            switch step {
            case .attempt(let plan):
                return plan
            case .pass(let why, let c, let blockers):
                reason = why
                if let c { code = c }
                for b in blockers where !blocking.contains(where: { $0.claimID == b.claimID }) {
                    blocking.append(b)
                }
            }
        }
        return .decline(code: sawDevice ? code : EngineError.Code.noDevice, reason: reason, blocking: blocking)
    }
}

/// The planner: pure functions of a state snapshot and the time.
enum CapturePlanner {
    /// How far a capture's centre may sit from where a dedicated IQ decoder would put it and still
    /// count as centred: a tuner's own step, not a fraction of the span.
    static let centredToleranceHz: UInt64 = 1_000

    /// The plan for `request` against `state`, as of `nowNs` (the don't-disturb window's clock).
    static func plan(_ request: PlanRequest, state: Leyline_V1_GetStateResponse,
                     nowNs: Int64 = WallClock.realNowNs()) -> Plan
    {
        if case .retune(let captureID, let centre, let rate, let by, let priority, let takeOver) = request {
            return planRetune(captureID: captureID, centerHz: centre, sampleRateHz: rate, by: by,
                              priority: priority, takeOver: takeOver, state: state, nowNs: nowNs)
        }
        return walk(request, state: state, nowNs: nowNs).plan
    }

    /// Every step `plan` takes for a new need, in order. A retune is one step and has no walk.
    static func walk(_ request: PlanRequest, state: Leyline_V1_GetStateResponse,
                     nowNs: Int64 = WallClock.realNowNs()) -> PlanWalk
    {
        switch request {
        case .channel(let hz, let bw, let mode, let device, let takeOver):
            return walkChannel(frequencyHz: hz, bandwidthHz: bw == 0 ? mode.defaultBandwidthHz : bw,
                               deviceID: device, takeOver: takeOver, state: state, nowNs: nowNs)
        case .iq(let hz, let rate, let device, let takeOver, let dedicated):
            return walkIQ(frequencyHz: hz, sampleRateHz: rate, deviceID: device, takeOver: takeOver,
                          dedicated: dedicated, state: state, nowNs: nowNs)
        case .sweep(let range, let device, let takeOver):
            return walkSweep(range: range, deviceID: device, takeOver: takeOver, state: state, nowNs: nowNs)
        case .retune:
            var w = PlanWalk(firstReason: "")
            w.sawDevice = true
            w.steps = [.attempt(plan(request, state: state, nowNs: nowNs))]
            return w
        }
    }

    // MARK: A channel

    /// A capture that already covers the frequency on any device, else a device with no capture,
    /// else a capture whose retune displaces nothing the request may not displace, else a decline
    /// naming who has the radio (docs/design/decoders.md, "Decisions": "A decode job is a job").
    private static func walkChannel(frequencyHz: UInt64, bandwidthHz bw: UInt32, deviceID wanted: String?,
                                    takeOver: Bool, state: Leyline_V1_GetStateResponse, nowNs: Int64) -> PlanWalk
    {
        var w = PlanWalk(firstReason: "no radio here can hear \(fmt(frequencyHz))")

        // 1. A capture that already covers the frequency. This disturbs nobody: the channel sits
        //    inside a span somebody is already listening to.
        for cap in state.captures {
            if let want = wanted, cap.deviceID != want { continue }
            guard !isSwept(cap) else { continue }
            w.sawDevice = true
            let offset = Int64(frequencyHz) - Int64(cap.centerHz)
            guard SessionStore.fits(offsetHz: offset, bandwidthHz: bw, sampleRate: cap.sampleRate) else { continue }
            w.steps.append(.attempt(.share(captureID: cap.captureID)))
        }

        // 2. A radio with nothing on it. The capture is centred a quarter-span below the channel,
        //    so the channel sits clear of the tuner's own DC spike and inside the flat part of the
        //    passband.
        for device in state.devices where device.state != .disconnected {
            if let want = wanted, device.deviceID != want { continue }
            guard state.captures.first(where: { $0.deviceID == device.deviceID }) == nil else { continue }
            guard DeviceID(string: device.deviceID) != nil else { continue }
            w.sawDevice = true
            let rate = defaultRate(device)
            guard let centre = channelCentre(frequencyHz: frequencyHz, bandwidthHz: bw, device: device, rate: rate) else {
                w.steps.append(cannotTune(device, frequencyHz))
                continue
            }
            w.steps.append(.attempt(.create(deviceID: device.deviceID, centerHz: centre, sampleRateHz: rate)))
        }

        // 3. A capture retuned, when the retune displaces nothing the job may not displace. This is
        //    the first step that disturbs anything, so it is the last one tried.
        for cap in state.captures {
            if let want = wanted, cap.deviceID != want { continue }
            guard let device = state.devices.first(where: { $0.deviceID == cap.deviceID }) else { continue }
            w.sawDevice = true
            if isSwept(cap) {
                w.steps.append(sweeping(cap, device: device, state: state))
                continue
            }
            guard let centre = channelCentre(frequencyHz: frequencyHz, bandwidthHz: bw, device: device, rate: cap.sampleRate) else {
                w.steps.append(cannotTune(device, frequencyHz))
                continue
            }
            let moved = displaced(cap, centerHz: centre, sampleRate: cap.sampleRate)
            if !takeOver, let refusal = refusal(cap, displacing: moved, state: state, nowNs: nowNs) {
                w.steps.append(refusal)
                continue
            }
            w.steps.append(.attempt(.retune(captureID: cap.captureID, centerHz: centre, sampleRateHz: cap.sampleRate,
                                            displacing: moved)))
        }
        return w
    }

    // MARK: An IQ reader

    /// The channel's order (docs/design/decoders.md, "Multiplexing"), but an IQ reader takes the
    /// whole capture band, so "covers" is the span and a created capture is centred on the
    /// frequency. A dedicated need takes only a capture centred within `centredToleranceHz` at the
    /// rate it would open one at, and a device that cannot be centred there is no candidate,
    /// `take_over` or not: "<model> cannot tune to <f>", `NO_DEVICE` like every other "cannot
    /// reach this frequency".
    private static func walkIQ(frequencyHz: UInt64, sampleRateHz wantedRate: UInt64, deviceID wanted: String?,
                               takeOver: Bool, dedicated: Bool, state: Leyline_V1_GetStateResponse,
                               nowNs: Int64) -> PlanWalk
    {
        var w = PlanWalk(firstReason: "no radio here can hear \(fmt(frequencyHz))")

        // 1. A capture whose span already covers the frequency (centred on it, for a dedicated
        //    decoder). This disturbs nobody.
        for cap in state.captures {
            if let want = wanted, cap.deviceID != want { continue }
            guard !isSwept(cap) else { continue }
            w.sawDevice = true
            if dedicated {
                guard let device = state.devices.first(where: { $0.deviceID == cap.deviceID }),
                      isCentred(centerHz: cap.centerHz, sampleRate: cap.sampleRate, on: frequencyHz,
                                rate: iqRate(wantedRate, device: device))
                else { continue }
            }
            guard spanCovers(centerHz: cap.centerHz, rate: cap.sampleRate, frequencyHz: frequencyHz) else { continue }
            w.steps.append(.attempt(.share(captureID: cap.captureID)))
        }

        // 2. A radio with nothing on it, centred on the frequency (clamped to a tunable point).
        for device in state.devices where device.state != .disconnected {
            if let want = wanted, device.deviceID != want { continue }
            guard state.captures.first(where: { $0.deviceID == device.deviceID }) == nil else { continue }
            guard DeviceID(string: device.deviceID) != nil else { continue }
            w.sawDevice = true
            let rate = iqRate(wantedRate, device: device)
            guard let centre = iqCentre(frequencyHz: frequencyHz, device: device, rate: rate) else {
                w.steps.append(cannotTune(device, frequencyHz))
                continue
            }
            if dedicated, !isCentred(centerHz: centre, sampleRate: rate, on: frequencyHz, rate: rate) {
                w.steps.append(.pass(reason: cannotCentre(device, on: frequencyHz), code: EngineError.Code.noDevice, blocking: []))
                continue
            }
            w.steps.append(.attempt(.create(deviceID: device.deviceID, centerHz: centre, sampleRateHz: rate)))
        }

        // 3. A capture retuned onto the frequency (and set to the rate, for a dedicated decoder),
        //    when the retune displaces nothing the job may not displace.
        for cap in state.captures {
            if let want = wanted, cap.deviceID != want { continue }
            guard let device = state.devices.first(where: { $0.deviceID == cap.deviceID }) else { continue }
            w.sawDevice = true
            if isSwept(cap) {
                w.steps.append(sweeping(cap, device: device, state: state))
                continue
            }
            let rate = dedicated ? iqRate(wantedRate, device: device) : cap.sampleRate
            // A radio that cannot be centred there is no candidate, whoever is using it: taking it
            // over would only move it to where the decoder still cannot read.
            guard let centre = iqCentre(frequencyHz: frequencyHz, device: device, rate: rate) else {
                w.steps.append(dedicated ? .pass(reason: cannotCentre(device, on: frequencyHz), code: EngineError.Code.noDevice, blocking: [])
                    : cannotTune(device, frequencyHz))
                continue
            }
            if dedicated, !isCentred(centerHz: centre, sampleRate: rate, on: frequencyHz, rate: rate) {
                w.steps.append(.pass(reason: cannotCentre(device, on: frequencyHz), code: EngineError.Code.noDevice, blocking: []))
                continue
            }
            let moved = displaced(cap, centerHz: centre, sampleRate: rate)
            if !takeOver, let refusal = refusal(cap, displacing: moved, state: state, nowNs: nowNs) {
                w.steps.append(refusal)
                continue
            }
            w.steps.append(.attempt(.retune(captureID: cap.captureID, centerHz: centre, sampleRateHz: rate,
                                            displacing: moved)))
        }
        return w
    }

    // MARK: A sweep

    /// A device that can hear any of the range, one with no capture first (creating and destroying
    /// disturbs nobody), then one whose capture holds nothing the sweep may not displace: a sweep
    /// walks the whole range, so it displaces every claim that needs the tuning. Never a capture
    /// another sweep holds, `take_over` or not.
    private static func walkSweep(range: ClosedRange<UInt64>, deviceID wanted: String?, takeOver: Bool,
                                  state: Leyline_V1_GetStateResponse, nowNs: Int64) -> PlanWalk
    {
        var candidates: [(Leyline_V1_DeviceDescriptor, Leyline_V1_Capture?)] = []
        for d in state.devices where d.state != .disconnected {
            if let want = wanted, d.deviceID != want { continue }
            // What a capture on this device can cover, not just where it can point: a capture
            // centred at the edge of the tuning range still covers half a span either side of it,
            // which is how a file device can serve a sweep at all. The fractions the sweep uses.
            let edge = SweepPlan.edgeFraction * Double(bestRate(d))
            let audible = d.tuningRanges.contains { r in
                Double(r.minHz) - edge <= Double(range.upperBound) && Double(r.maxHz) + edge >= Double(range.lowerBound)
            }
            guard audible else { continue }
            candidates.append((d, state.captures.first { $0.deviceID == d.deviceID }))
        }
        guard !candidates.isEmpty else {
            if let want = wanted {
                return PlanWalk(firstReason: "\(want) cannot tune \(fmt(range.lowerBound)) to \(fmt(range.upperBound)), or is not here")
            }
            return PlanWalk(firstReason: "no radio here can tune \(fmt(range.lowerBound)) to \(fmt(range.upperBound))")
        }
        candidates.sort { ($0.1 == nil ? 0 : 1) < ($1.1 == nil ? 0 : 1) }

        var w = PlanWalk(firstReason: "the radio is in use")
        w.sawDevice = true
        for (device, existing) in candidates {
            guard DeviceID(string: device.deviceID) != nil else { continue }
            let rate = bestRate(device)
            let start = startCentre(range, device: device)
            guard let cap = existing else {
                w.steps.append(.attempt(.create(deviceID: device.deviceID, centerHz: start, sampleRateHz: rate)))
                continue
            }
            if isSwept(cap) {
                w.steps.append(.pass(reason: "another scan already has \(device.model)", code: EngineError.Code.deviceBusy,
                                     blocking: cap.claims.filter { $0.kind == .claimSweep }))
                continue
            }
            // A sweep walks the whole range, so every claim that needs the tuning is displaced.
            let moved = cap.claims.filter(needsTuning)
            if !takeOver, let refusal = refusal(cap, displacing: moved, state: state, nowNs: nowNs) {
                w.steps.append(refusal)
                continue
            }
            w.steps.append(.attempt(.retune(captureID: cap.captureID, centerHz: start, sampleRateHz: cap.sampleRate,
                                            displacing: moved)))
        }
        return w
    }

    // MARK: A retune

    /// A write that moves a capture. A person's is never declined but by a sweep, which refuses
    /// writes while it runs; a job's is declined when it would displace a person's or another
    /// job's claim, or a person is at the controls, unless `take_over`. The displaced claims are
    /// the ones the new tuning leaves unsatisfied, the writer's own aside.
    private static func planRetune(captureID: String, centerHz: UInt64, sampleRateHz: UInt64,
                                   by: Leyline_V1_ClientInfo, priority: Leyline_V1_ClaimPriority, takeOver: Bool,
                                   state: Leyline_V1_GetStateResponse, nowNs: Int64) -> Plan
    {
        guard let cap = state.captures.first(where: { $0.captureID == captureID }) else {
            let e = EngineError.captureNotFound(captureID)
            return .decline(code: e.code, reason: e.message, blocking: [])
        }
        if isSwept(cap) {
            let e = EngineError.deviceSweeping(captureID)
            return .decline(code: e.code, reason: e.message, blocking: cap.claims.filter { $0.kind == .claimSweep })
        }
        let rate = sampleRateHz == 0 ? cap.sampleRate : sampleRateHz
        if let device = state.devices.first(where: { $0.deviceID == cap.deviceID }) {
            if !device.tuningRanges.isEmpty, !device.tuningRanges.contains(where: { $0.minHz <= centerHz && centerHz <= $0.maxHz }) {
                let e = EngineError.freqOutOfRange(centerHz, target: captureID)
                return .decline(code: e.code, reason: e.message, blocking: [])
            }
            if rate != cap.sampleRate, !device.sampleRates.isEmpty, !device.sampleRates.contains(rate) {
                let e = EngineError.rateUnsupported(rate, target: captureID)
                return .decline(code: e.code, reason: e.message, blocking: [])
            }
        }
        let moved = displaced(cap, centerHz: centerHz, sampleRate: rate).filter { $0.holder.clientID != by.clientID }
        if priority != .priorityPerson, !takeOver,
           case .pass(let why, _, let blocking)? = refusal(cap, displacing: moved, state: state, nowNs: nowNs)
        {
            return .decline(code: EngineError.Code.deviceBusy, reason: why, blocking: blocking)
        }
        return .retune(captureID: captureID, centerHz: centerHz, sampleRateHz: rate, displacing: moved)
    }

    // MARK: The don't-disturb test

    /// Whether a sweep holds the capture.
    static func isSwept(_ cap: Leyline_V1_Capture) -> Bool { cap.claims.contains { $0.kind == .claimSweep } }

    /// The don't-disturb test for a job's retune, read from the claims it would displace: a pass
    /// naming the first one in its way, `DEVICE_BUSY`, or nil when the retune may go ahead. A
    /// person's or another job's channel or IQ reader that the retune leaves satisfied is no
    /// reason, and neither is a view. A person at the controls (a live audio sink, a write in the
    /// last minute) is one whatever the retune displaces: their claim takes the capture as it is.
    static func refusal(_ cap: Leyline_V1_Capture, displacing moved: [Leyline_V1_Claim],
                        state: Leyline_V1_GetStateResponse, nowNs: Int64) -> PlanWalk.Step?
    {
        let blocking = moved.filter { $0.priority == .priorityPerson || $0.priority == .priorityJob }
        let presence = cap.claims.filter { $0.kind == .claimListen }
        func pass(_ why: String, _ claims: [Leyline_V1_Claim]) -> PlanWalk.Step {
            .pass(reason: why, code: EngineError.Code.deviceBusy, blocking: claims)
        }
        if let ch = blocking.first(where: { $0.kind == .claimChannel }) {
            return pass("\(who(ch.holder)) is listening on \(fmt(ch.covers.frequencyHz))", blocking)
        }
        // A person's presence is held by a live audio sink or by a write in the last minute; the
        // capture's activity says which, and how long ago.
        if !presence.isEmpty, cap.activity.liveAudioSinks > 0 {
            return pass("audio is playing from this radio", blocking + presence)
        }
        if let reader = blocking.first(where: { $0.kind == .claimIq }) {
            // An IQ decode job or an IQ recording has no channel to show it is there, and a
            // retune moves the whole band it reads.
            let job = state.jobs.first { $0.jobID == reader.holder.clientID }
            switch job?.config {
            case .decode(let d)?: return pass("another job is reading this radio (decode \(d.decoder))", blocking)
            case .record?: return pass("another job is reading this radio (record)", blocking)
            default: return pass("another job is reading this radio", blocking)
            }
        }
        let now = UInt64(max(0, nowNs))
        let last = UInt64(max(0, cap.activity.lastInteractiveWriteNs))
        if !presence.isEmpty, last > 0, now > last, now - last < dontDisturbNs {
            return pass("somebody was tuning this radio \(Int((now - last) / 1_000_000_000)) s ago", blocking + presence)
        }
        // Any other claim of a person's or a job's the retune would leave unsatisfied.
        if let other = blocking.first {
            return pass("\(who(other.holder)) is using this radio", blocking)
        }
        return nil
    }

    /// A radio a sweep holds: nothing else is placed on it while the sweep runs, `take_over` or not.
    /// `DEVICE_BUSY`, naming the sweep.
    private static func sweeping(_ cap: Leyline_V1_Capture, device: Leyline_V1_DeviceDescriptor,
                                 state: Leyline_V1_GetStateResponse) -> PlanWalk.Step
    {
        let sweeps = cap.claims.filter { $0.kind == .claimSweep }
        let job = state.jobs.first { $0.jobID == sweeps.first?.holder.clientID }
        let what = if case .monitor? = job?.config { "monitor" } else { "scan" }
        return .pass(reason: "a \(what) is sweeping \(device.model); it is free again when the \(what) ends",
                     code: EngineError.Code.deviceBusy, blocking: sweeps)
    }

    /// A radio that cannot reach the frequency at all: `NO_DEVICE`, however it arises.
    private static func cannotTune(_ device: Leyline_V1_DeviceDescriptor, _ frequencyHz: UInt64) -> PlanWalk.Step {
        .pass(reason: "\(device.model) cannot tune \(fmt(frequencyHz))", code: EngineError.Code.noDevice, blocking: [])
    }

    /// Whether a claim asks anything of the tuning: a presence and a view take the capture as it is.
    private static func needsTuning(_ c: Leyline_V1_Claim) -> Bool { c.need != nil || c.sampleRateHz != 0 }

    /// The claims on `cap` a capture at `centerHz` and `sampleRate` would not satisfy.
    static func displaced(_ cap: Leyline_V1_Capture, centerHz: UInt64, sampleRate: UInt64) -> [Leyline_V1_Claim] {
        cap.claims.filter { c in
            guard needsTuning(c) else { return false }
            if c.sampleRateHz != 0, c.sampleRateHz != sampleRate { return true }
            switch c.need {
            case .covers(let s)?:
                return !SessionStore.fits(offsetHz: Int64(s.frequencyHz) - Int64(centerHz), bandwidthHz: s.bandwidthHz,
                                          sampleRate: sampleRate)
            case .centred(let k)?:
                let off = centerHz > k.frequencyHz ? centerHz - k.frequencyHz : k.frequencyHz - centerHz
                return off > k.toleranceHz
            case nil:
                return false
            }
        }
    }

    /// Describes a client by its kind rather than the label it chose: "ley is listening" makes no
    /// sense to a user who typed `ley`.
    static func who(_ ci: Leyline_V1_ClientInfo) -> String {
        switch ci.kind {
        case "cli": return "a terminal"
        case "app": return "the app"
        case "mcp": return "an agent"
        case "job": return "another job"
        default: return ci.label.isEmpty ? "another client" : ci.label
        }
    }

    // MARK: Where to tune

    /// Why `device` is no capture for a dedicated decoder on `frequencyHz`. A file radio says what
    /// it is, since nothing can move where its recording was made.
    static func cannotCentre(_ device: Leyline_V1_DeviceDescriptor, on frequencyHz: UInt64) -> String {
        let why = device.driver == FilePlaybackDevice.driverName ? " (a file radio plays what it recorded)" : ""
        return "\(device.model) cannot tune to \(fmt(frequencyHz))\(why)"
    }

    /// Whether a capture at `centerHz` and `sampleRate` is the one a dedicated IQ decoder needs:
    /// at exactly `rate`, centred within `centredToleranceHz` of the frequency itself. Not of the
    /// nearest point the device tunes: a file radio's only point is where its recording was made,
    /// and a capture there is centred on whatever that was.
    static func isCentred(centerHz: UInt64, sampleRate: UInt64, on frequencyHz: UInt64, rate: UInt64) -> Bool {
        guard sampleRate == rate else { return false }
        let off = centerHz > frequencyHz ? centerHz - frequencyHz : frequencyHz - centerHz
        return off <= centredToleranceHz
    }

    /// Whether a capture centred at `centerHz` running at `rate` covers `frequencyHz` at all: the
    /// frequency inside [centre - rate/2, centre + rate/2]. An IQ reader takes the whole span, so
    /// this is the reuse test rather than the channel-fit `SessionStore.fits`.
    static func spanCovers(centerHz: UInt64, rate: UInt64, frequencyHz: UInt64) -> Bool {
        let half = Int64(rate / 2)
        let f = Int64(frequencyHz)
        return f >= Int64(centerHz) - half && f <= Int64(centerHz) + half
    }

    /// The rate for a created IQ capture: what the recipe asked for when the device offers it, else
    /// the device's default (`defaultRate`), matching what a channel job opens at.
    static func iqRate(_ wanted: UInt64, device: Leyline_V1_DeviceDescriptor) -> UInt64 {
        if wanted != 0, device.sampleRates.isEmpty || device.sampleRates.contains(wanted) { return wanted }
        return defaultRate(device)
    }

    /// Where to point an IQ capture: on the frequency, clamped to the nearest tunable point. A file
    /// device's range is the single point its recording was made at, and the frequency still falls
    /// inside the span there. nil when the frequency would fall outside the span even so.
    static func iqCentre(frequencyHz: UInt64, device: Leyline_V1_DeviceDescriptor, rate: UInt64) -> UInt64? {
        guard let centre = nearestTunable(frequencyHz, device: device),
              spanCovers(centerHz: centre, rate: rate, frequencyHz: frequencyHz) else { return nil }
        return centre
    }

    /// Where to point a capture so the channel lands a quarter-span off centre, clamped to what the
    /// device can tune -- a file device's range is the single point its recording was made at, and
    /// the channel still fits inside the span. nil when the channel would fall outside it.
    static func channelCentre(frequencyHz: UInt64, bandwidthHz: UInt32,
                              device: Leyline_V1_DeviceDescriptor, rate: UInt64) -> UInt64?
    {
        let quarter = rate / 8
        let desired = frequencyHz > quarter ? frequencyHz - quarter : frequencyHz
        guard let centre = nearestTunable(desired, device: device) else { return nil }
        guard SessionStore.fits(offsetHz: Int64(frequencyHz) - Int64(centre), bandwidthHz: bandwidthHz, sampleRate: rate) else { return nil }
        return centre
    }

    /// Where to point the radio when a sweep creates the capture. The sweep retunes from here
    /// immediately, so this only has to be somewhere the device accepts; aiming at the middle of
    /// the range and clamping to the nearest tunable point keeps the first hop short.
    static func startCentre(_ range: ClosedRange<UInt64>, device: Leyline_V1_DeviceDescriptor) -> UInt64 {
        let want = range.lowerBound + (range.upperBound - range.lowerBound) / 2
        return nearestTunable(want, device: device) ?? want
    }

    /// The point of the device's tuning ranges nearest `hz`; nil for a device that lists none.
    private static func nearestTunable(_ hz: UInt64, device: Leyline_V1_DeviceDescriptor) -> UInt64? {
        var best: UInt64?
        var bestDistance = UInt64.max
        for r in device.tuningRanges {
            let clamped = Swift.min(Swift.max(hz, r.minHz), Swift.max(r.minHz, r.maxHz))
            let d = clamped > hz ? clamped - hz : hz - clamped
            if d < bestDistance {
                bestDistance = d
                best = clamped
            }
        }
        return best
    }

    /// The fastest rate the device offers: fewer steps for a sweep, and the detector's resolution
    /// comes from the bin count rather than the span.
    static func bestRate(_ d: Leyline_V1_DeviceDescriptor) -> UInt64 { d.sampleRates.max() ?? 0 }

    /// The rate a capture for one channel opens at: what `CreateCapture` picks for `sample_rate
    /// == 0`, the recording's own rate for a file and 2.4 MSPS for a dongle. Not the fastest the
    /// device offers, which a sweep wants: an RTL-SDR at 3.2 MSPS drops samples over USB, and the
    /// channel's audio rate follows the capture rate (49.2 kHz at 3.2 MSPS against the 48 kHz a
    /// decoder written for the default expects).
    static func defaultRate(_ d: Leyline_V1_DeviceDescriptor) -> UInt64 {
        if d.driver == "file" { return d.sampleRates.first ?? SessionStore.defaultSampleRate }
        if d.sampleRates.isEmpty || d.sampleRates.contains(SessionStore.defaultSampleRate) { return SessionStore.defaultSampleRate }
        return bestRate(d)
    }

    static func fmt(_ hz: UInt64) -> String { String(format: "%.3f MHz", Double(hz) / 1e6) }
}
