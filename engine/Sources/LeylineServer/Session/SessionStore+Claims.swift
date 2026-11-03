// SPDX-License-Identifier: GPL-3.0-or-later

// The claims ledger (docs/design/claims.md): what every consumer of a capture needs from its
// tuning, kept beside the capture and carried on its events as `Capture.claims`. Clients never
// make a claim; the store and the allocator make one when a consumer starts and release it when
// the consumer ends. The planner places by them (CL-2); a move of the capture marks the claims it
// leaves unsatisfied DISPLACED with who moved it and since when (CL-3). Nothing returns by them
// yet (CL-4).

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
        /// While DISPLACED: who last moved the capture away from what this claim needs, and when
        /// it first went. Set and cleared as the capture is published (`claimProtos`).
        var displacedBy: ClientContext?
        var displacedSinceNs: Int64 = 0
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
    /// A view's claim is not an event of its own: it rides the next one (`noteViewChange`). nil
    /// when the capture is gone.
    @discardableResult
    func addClaim(on id: CaptureID, holder: ClientContext, kind: Leyline_V1_ClaimKind,
                  priority: Leyline_V1_ClaimPriority, need: ClaimNeed = .none, sampleRateHz: UInt64 = 0) async -> ClaimID?
    {
        guard captures[id] != nil else { return nil }
        let claim = ClaimEntry(holder: holder, kind: kind, priority: priority, need: need, sampleRateHz: sampleRateHz)
        captures[id]?.claims.append(claim)
        if priority == .priorityView {
            noteViewChange(id)
        } else {
            await emitCapture(id, by: holder)
        }
        return claim.id
    }

    /// Takes a claim off the capture's ledger and returns what is left on it. `publish: false` is
    /// for a release inside the capture's own teardown, whose tombstone follows. A view's release
    /// rides the next event, as its arrival did.
    @discardableResult
    func releaseClaim(_ claimID: ClaimID, on id: CaptureID, publish: Bool = true) async -> [ClaimEntry] {
        guard let gone = captures[id]?.claims.first(where: { $0.id == claimID }) else { return captures[id]?.claims ?? [] }
        captures[id]?.claims.removeAll { $0.id == claimID }
        let left = captures[id]?.claims ?? []
        if publish {
            if gone.priority == .priorityView {
                noteViewChange(id)
            } else {
                await emitCapture(id, by: .daemon)
            }
        }
        return left
    }

    // MARK: Views, coalesced

    /// How long a view's arrival or release may wait for an event to ride: at most one capture
    /// event a second comes of views alone, so a client opening and closing streams cannot push
    /// the events that matter out of the replay window (`eventHistoryLimit`).
    static let viewCoalesceNs: UInt64 = 1_000_000_000

    /// A VIEW claim came or went. The next capture event carries it; if none comes within
    /// `viewCoalesceNs`, one is published then.
    func noteViewChange(_ id: CaptureID) {
        guard captures[id] != nil else { return }
        captures[id]?.viewChanged = true
        guard captures[id]?.viewFlush == nil else { return }
        captures[id]?.viewFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.viewCoalesceNs)
            guard !Task.isCancelled, let self else { return }
            await self.flushViewChange(id)
        }
    }

    private func flushViewChange(_ id: CaptureID) async {
        captures[id]?.viewFlush = nil
        guard captures[id]?.viewChanged == true else { return }
        await emitCapture(id, by: .daemon)
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
    /// starts the window again; nil is a sink attached, which holds the claim by itself. Only a
    /// person has a presence: a job's sink or write makes none.
    func notePresence(_ id: CaptureID, client: ClientContext, wroteAtNs: Int64?) {
        guard client.isInteractive, captures[id] != nil else { return }
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

    // MARK: Moves

    /// `by` is about to move the capture (a retune or a rate change). The event that first sees
    /// the move names them, whoever publishes it.
    func willMove(_ id: CaptureID, by: ClientContext) {
        captures[id]?.pendingMover = by
    }

    /// The move `willMove` announced did not happen.
    func moveFailed(_ id: CaptureID, by: ClientContext) {
        if captures[id]?.pendingMover == by { captures[id]?.pendingMover = nil }
    }

    /// Compares the capture's tuning with what its last event carried, and records a move: the
    /// mover is the one `willMove` named, else the writer of this event, else the daemon. A change
    /// of generation with the centre and rate unchanged (the radio lost and found) is no move.
    func noteTuning(_ id: CaptureID, _ snap: CaptureSnapshot, by: ClientContext?) {
        guard let entry = captures[id], snap.tuningGeneration != entry.published.generation else { return }
        let now = PublishedTuning(centerHz: snap.centerHz, sampleRate: snap.sampleRate, generation: snap.tuningGeneration)
        if snap.centerHz != entry.published.centerHz || snap.sampleRate != entry.published.sampleRate {
            captures[id]?.lastMove = CaptureMove(by: entry.pendingMover ?? by ?? .daemon, from: entry.published, to: now,
                                                 atNs: WallClock.realNowNs())
        } else if var move = entry.lastMove, move.to.centerHz == now.centerHz, move.to.sampleRate == now.sampleRate {
            // Back where the last move left it: that move still says how it got here.
            move.to.generation = now.generation
            captures[id]?.lastMove = move
        }
        captures[id]?.published = now
        captures[id]?.pendingMover = nil
    }

    /// Who moved the capture to where it is now, as a job's DEGRADED detail says it: "the app
    /// tuned NESDR SMArt v5 to 146.520 MHz". nil while the latest move is not published yet (the
    /// caller asks again), and when nothing has moved the capture since it was made.
    func whoMoved(_ id: CaptureID) async -> String? {
        guard let entry = captures[id], let move = entry.lastMove else { return nil }
        let snap = await entry.engine.snapshot
        guard snap.tuningGeneration == move.to.generation else { return nil }
        let model = devices[entry.deviceID]?.model ?? "the radio"
        let who = await describe(move.by)
        if move.to.centerHz == move.from.centerHz {
            return "\(who) set \(model) to " + String(format: "%.3f MSPS", Double(move.to.sampleRate) / 1e6)
        }
        return "\(who) tuned \(model) to \(CapturePlanner.fmt(move.to.centerHz))"
    }

    /// A mover by what it is: "the app", "a terminal", "an agent", "a scan", "a recording", "the
    /// adsb decoder", and "the daemon" for a move nobody asked for.
    func describe(_ client: ClientContext) async -> String {
        switch client.kind {
        case "job":
            let job = await jobsProvider?().first { $0.jobID == client.id }
            switch job?.config {
            case .scan?: return "a scan"
            case .monitor?: return "a monitor"
            case .record?: return "a recording"
            case .decode(let d)?: return "the \(d.decoder) decoder"
            default: return "a job"
            }
        case "daemon": return "the daemon"
        default: return CapturePlanner.who(client.proto)
        }
    }

    // MARK: On the wire

    /// The ledger as `Capture.claims`: each need read now (a channel's from the channel) and each
    /// state from whether the capture at `centerHz` and `sampleRate` gives the claim what it needs.
    /// A claim that is newly unsatisfied goes DISPLACED by the capture's last mover, from now; one
    /// still unsatisfied after another move names that mover; a satisfied one is cleared.
    func claimProtos(_ id: CaptureID, _ claims: [ClaimEntry], centerHz: UInt64, sampleRate: UInt64) async -> [Leyline_V1_Claim] {
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
            let (by, since) = noteDisplacement(id, claim: c.id, satisfied: satisfied)
            if let by {
                p.displacedBy = by.proto
                p.displacedSinceNs = since
            }
            out.append(p)
        }
        return out
    }

    /// Keeps a claim's `displaced_by` and `displaced_since_ns` in step with its state and returns
    /// them.
    private func noteDisplacement(_ id: CaptureID, claim: ClaimID, satisfied: Bool) -> (ClientContext?, Int64) {
        guard let i = captures[id]?.claims.firstIndex(where: { $0.id == claim }), let entry = captures[id] else { return (nil, 0) }
        var c = entry.claims[i]
        if satisfied {
            c.displacedBy = nil
            c.displacedSinceNs = 0
        } else {
            let mover = entry.lastMove?.by ?? .daemon
            if c.displacedBy == nil { c.displacedSinceNs = WallClock.realNowNs() }
            c.displacedBy = mover
        }
        captures[id]?.claims[i] = c
        return (c.displacedBy, c.displacedSinceNs)
    }

    private static func span(_ hz: UInt64, _ bw: UInt32) -> Leyline_V1_Span {
        var s = Leyline_V1_Span()
        s.frequencyHz = hz
        s.bandwidthHz = bw
        return s
    }
}
