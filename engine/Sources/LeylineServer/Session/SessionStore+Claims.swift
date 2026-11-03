// SPDX-License-Identifier: GPL-3.0-or-later

// The claims ledger (docs/design/claims.md): what every consumer of a capture needs from its
// tuning, kept beside the capture and carried on its events as `Capture.claims`. Clients never
// make a claim; the store and the allocator make one when a consumer starts and release it when
// the consumer ends. CL-1 only records them: the don't-disturb test reads them, and nothing yet
// places, retunes or returns by them.

import EngineCore
import Foundation
import LeylineProto

extension SessionStore {
    /// What a claim needs from the tuning.
    enum ClaimNeed: Sendable, Equatable {
        /// Nothing in particular: a person's presence, a spectrum view, take the capture as it is.
        case none
        /// A frequency and bandwidth inside the span.
        case covers(frequencyHz: UInt64, bandwidthHz: UInt32)
        /// The centre itself, within a tolerance (a dedicated IQ decoder).
        case centred(frequencyHz: UInt64, toleranceHz: UInt64)
        /// A channel's frequency and bandwidth, read from the channel each time: its offset
        /// follows every retune and write.
        case channel(ChannelID)
    }

    struct ClaimEntry: Sendable {
        var id = ClaimID()
        var holder: ClientContext
        var kind: Leyline_V1_ClaimKind
        var priority: Leyline_V1_ClaimPriority
        var need: ClaimNeed
        var sampleRateHz: UInt64 = 0
    }

    /// One interactive client's presence on one capture: its LISTEN claim, held while the client
    /// has a channel or a live audio sink there and for `presenceWindowNs` after its last write.
    struct PresenceWindow {
        var claimID: ClaimID
        var lastWriteNs: Int64 = 0
        var lapse: Task<Void, Never>?
    }

    /// What a sweep's claim on a capture came to.
    enum SweepClaim: Sendable {
        case claimed(ClaimID)
        /// Another sweep holds it.
        case taken
        /// The capture is gone.
        case gone
    }

    // MARK: Making and releasing claims

    /// Adds a claim to the capture's ledger and publishes the capture, attributed to the holder.
    /// nil when the capture is gone.
    @discardableResult
    func addClaim(on id: CaptureID, holder: ClientContext, kind: Leyline_V1_ClaimKind,
                  priority: Leyline_V1_ClaimPriority, need: ClaimNeed = .none, sampleRateHz: UInt64 = 0) async -> ClaimID?
    {
        guard captures[id] != nil else { return nil }
        let claim = ClaimEntry(holder: holder, kind: kind, priority: priority, need: need, sampleRateHz: sampleRateHz)
        captures[id]?.claims.append(claim)
        await emitCapture(id, by: holder)
        return claim.id
    }

    /// Takes a claim off the capture's ledger and returns what is left on it. `publish: false` is
    /// for a release inside the capture's own teardown, whose tombstone follows.
    @discardableResult
    func releaseClaim(_ claimID: ClaimID, on id: CaptureID, publish: Bool = true) async -> [ClaimEntry] {
        guard let before = captures[id]?.claims.count else { return [] }
        captures[id]?.claims.removeAll { $0.id == claimID }
        let left = captures[id]?.claims ?? []
        if publish, left.count != before { await emitCapture(id, by: .daemon) }
        return left
    }

    /// A sweep's exclusive claim, checked and made in one step on the actor: two scans racing for
    /// one tuner cannot both pass (the allocator's old `leased` set did this before the ledger).
    /// The need is the range the sweep walks.
    func claimSweep(on id: CaptureID, job: JobID, range: ClosedRange<UInt64>) async -> SweepClaim {
        guard captures[id] != nil else { return .gone }
        guard !isSwept(id) else { return .taken }
        let width = range.upperBound - range.lowerBound
        let claim = ClaimEntry(holder: .job(job), kind: .claimSweep, priority: .priorityJob,
                               need: .covers(frequencyHz: range.lowerBound + width / 2,
                                             bandwidthHz: UInt32(clamping: width)))
        captures[id]?.claims.append(claim)
        await emitCapture(id, by: .job(job))
        return .claimed(claim.id)
    }

    // MARK: A person's presence

    /// Sets the presence window for the windows armed from now on (tests).
    func setPresenceWindow(_ ns: UInt64) { presenceWindowNs = ns }

    /// Makes or refreshes `client`'s presence on the capture. `wroteAtNs` is a write's time, which
    /// starts the window again; nil is a sink attached, which holds the claim by itself.
    func notePresence(_ id: CaptureID, client: ClientContext, wroteAtNs: Int64?) {
        guard captures[id] != nil else { return }
        var window: PresenceWindow
        if let held = captures[id]?.presences[client.id] {
            window = held
        } else {
            let claim = ClaimEntry(holder: client, kind: .claimListen, priority: .priorityPerson, need: .none)
            captures[id]?.claims.append(claim)
            window = PresenceWindow(claimID: claim.id)
        }
        if let at = wroteAtNs {
            window.lastWriteNs = at
            window.lapse?.cancel()
            window.lapse = armPresenceLapse(id, clientID: client.id, afterNs: presenceWindowNs)
        }
        captures[id]?.presences[client.id] = window
    }

    /// Ends `clientID`'s presence on the capture if nothing holds it any more: no channel, no live
    /// audio sink, and the window since its last write has run out. Returns whether it ended. The
    /// caller publishes the capture.
    @discardableResult
    func lapsePresenceIfDue(_ id: CaptureID, clientID: String) -> Bool {
        guard let window = captures[id]?.presences[clientID] else { return false }
        if holdsPresence(id, clientID: clientID) { return false }
        let now = WallClock.realNowNs()
        let left = window.lastWriteNs + Int64(clamping: presenceWindowNs) - now
        if window.lastWriteNs > 0, left > 0 {
            // A write inside the window: the lapse already armed for it ends the claim.
            if window.lapse == nil {
                captures[id]?.presences[clientID]?.lapse = armPresenceLapse(id, clientID: clientID, afterNs: UInt64(left))
            }
            return false
        }
        captures[id]?.presences[clientID] = nil
        captures[id]?.claims.removeAll { $0.id == window.claimID }
        return true
    }

    private func holdsPresence(_ id: CaptureID, clientID: String) -> Bool {
        if channels.values.contains(where: { $0.captureID == id && $0.owner.id == clientID }) { return true }
        return sinks.values.contains { s in
            s.isSystemAudio && s.owner.id == clientID && channels[s.channelID]?.captureID == id
        }
    }

    private func armPresenceLapse(_ id: CaptureID, clientID: String, afterNs: UInt64) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: afterNs)
            guard !Task.isCancelled, let self else { return }
            await self.presenceWindowEnded(id, clientID: clientID)
        }
    }

    private func presenceWindowEnded(_ id: CaptureID, clientID: String) async {
        // A write that landed while this task hopped onto the actor cancelled it and armed its own.
        guard !Task.isCancelled else { return }
        // This lapse task has run; a later check arms a fresh one if it needs to.
        captures[id]?.presences[clientID]?.lapse = nil
        if lapsePresenceIfDue(id, clientID: clientID) { await emitCapture(id, by: .daemon) }
    }

    // MARK: On the wire

    /// The ledger as `Capture.claims`: each need read now (a channel's from the channel) and each
    /// state from whether the capture at `centerHz` and `sampleRate` gives the claim what it needs.
    func claimProtos(_ claims: [ClaimEntry], centerHz: UInt64, sampleRate: UInt64) async -> [Leyline_V1_Claim] {
        var out: [Leyline_V1_Claim] = []
        for c in claims {
            var p = Leyline_V1_Claim()
            p.claimID = c.id.string
            p.holder = c.holder.proto
            p.kind = c.kind
            p.priority = c.priority
            p.sampleRateHz = c.sampleRateHz
            var satisfied = c.sampleRateHz == 0 || c.sampleRateHz == sampleRate
            switch c.need {
            case .none:
                break
            case .covers(let hz, let bw):
                p.covers = Self.span(hz, bw)
                satisfied = satisfied && Self.fits(offsetHz: Int64(hz) - Int64(centerHz), bandwidthHz: bw, sampleRate: sampleRate)
            case .centred(let hz, let tolerance):
                var centre = Leyline_V1_Centre()
                centre.frequencyHz = hz
                centre.toleranceHz = tolerance
                p.centred = centre
                let off = centerHz > hz ? centerHz - hz : hz - centerHz
                satisfied = satisfied && off <= tolerance
            case .channel(let chID):
                guard let engine = channels[chID]?.engine else { continue }
                let config = await engine.config
                // The channel's absolute frequency, as the don't-disturb test has always named it.
                let hz = Int64(centerHz) + config.offsetHz
                p.covers = Self.span(hz > 0 ? UInt64(hz) : centerHz, config.bandwidthHz)
                satisfied = await engine.state != .outOfCapture
            }
            p.state = satisfied ? .claimSatisfied : .claimDisplaced
            out.append(p)
        }
        return out
    }

    private static func span(_ hz: UInt64, _ bw: UInt32) -> Leyline_V1_Span {
        var s = Leyline_V1_Span()
        s.frequencyHz = hz
        s.bandwidthHz = bw
        return s
    }
}
