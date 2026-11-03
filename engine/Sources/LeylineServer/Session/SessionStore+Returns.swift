// SPDX-License-Identifier: GPL-3.0-or-later

// Returning and sharing (docs/design/claims.md, "Displacement, uniformly"; plan CL-4). When a job
// moves a capture (a take_over retune, a dedicated decoder's retune, a sweep), the store keeps
// where it found the capture. When that job lets go, the capture goes back there, rate and gain
// included, unless somebody would lose by it. A capture the allocator made for a job lives while
// any channel, IQ or sweep claim holds it, whoever made the claim (DEC-19).

import EngineCore
import Foundation
import LeylineProto

extension SessionStore {
    /// Where a job found a capture before it moved it.
    struct ReturnPoint: Sendable {
        /// The claim of the job that moved it. The return waits while it is held.
        var claim: ClaimID
        /// That job, which a return names as the mover.
        var mover: ClientContext
        var centerHz: UInt64
        var sampleRate: UInt64
        /// The gains it found, put back with the tuning; empty when the job set none.
        var gains: [GainState] = []
        /// The gains the job left. Its gains are put back only while these are still set, so a
        /// gain somebody wrote since stays.
        var gainsLeft: [GainState] = []
    }

    /// The kinds of claim that hold a capture the allocator made: a view or a presence takes the
    /// capture as it is and does not keep a radio open.
    private static func holds(_ c: ClaimEntry) -> Bool {
        c.kind == .claimChannel || c.kind == .claimIq || c.kind == .claimSweep
    }

    /// Marks a capture the allocator made for a job: it is destroyed when its last holding claim
    /// is released, not when the job that made it ends.
    func holdByClaims(_ id: CaptureID) {
        captures[id]?.heldByClaims = true
    }

    /// Notes where `claim`'s job found the capture before it moved it.
    func noteReturnPoint(_ point: ReturnPoint, on id: CaptureID) {
        guard captures[id] != nil else { return }
        captures[id]?.returns.append(point)
    }

    /// The claim a channel holds, for a lease that has to name it.
    func channelClaim(_ channelID: ChannelID, on id: CaptureID) -> ClaimID? {
        captures[id]?.claims.first { $0.need == .channel(channelID) }?.id
    }

    /// A move by a person clears every return: they are at the controls, and nothing goes back
    /// over their head. Called with every recorded move.
    func notePersonMove(_ id: CaptureID, by mover: ClientContext) {
        guard mover.kind != "job", mover.kind != "daemon", captures[id]?.returns.isEmpty == false else { return }
        captures[id]?.returns.removeAll()
        log.info("\(id.string): \(mover.kind) moved the capture, so nothing returns to where a job found it")
    }

    // MARK: After a release

    /// A claim is going (`released`, still in the ledger) or has gone (nil). A capture the
    /// allocator made is destroyed when nothing holds it; true when it was. Otherwise any return
    /// that is due is carried out.
    @discardableResult
    func claimReleased(_ id: CaptureID, without released: ClaimID?) async -> Bool {
        guard let entry = captures[id] else { return true }
        if entry.heldByClaims, !entry.claims.contains(where: { $0.id != released && Self.holds($0) }) {
            await destroyCapture(id: id, by: .daemon)
            return true
        }
        await settleReturns(id, without: released)
        return captures[id] == nil
    }

    /// Carries out every return that is due, one at a time: a release while one is in hand asks
    /// for another look once it is done.
    private func settleReturns(_ id: CaptureID, without released: ClaimID?) async {
        guard let entry = captures[id], !entry.returns.isEmpty else { return }
        if entry.settling {
            captures[id]?.settleAgain = true
            return
        }
        captures[id]?.settling = true
        repeat {
            captures[id]?.settleAgain = false
            while await returnOnce(id, without: released) {}
        } while captures[id]?.settleAgain == true
        captures[id]?.settling = false
    }

    /// The return rule, in order, over the points newest first. A point whose job still holds its
    /// claim waits. A point whose job has let go returns the capture to where that job found it:
    ///
    /// 1. When nobody moved the capture since that job did (or the last move was a return), the
    ///    return goes ahead unless it would displace a claim satisfied now: a claim made since,
    ///    on the new tuning, keeps it.
    /// 2. When somebody else moved it since (another job, the daemon), only if every claim left
    ///    is satisfied there.
    ///
    /// A move by a person cleared every point before this runs (`notePersonMove`). A return that
    /// goes ahead takes every newer point with it, since every claim is satisfied where it lands;
    /// one that does not stays, and is tried again at the next release. True when one returned.
    private func returnOnce(_ id: CaptureID, without released: ClaimID?) async -> Bool {
        guard let entry = captures[id], !entry.returns.isEmpty,
              var cap = await captureProto(id) else { return false }
        let now = captures[id] ?? entry
        cap.claims.removeAll { $0.claimID == released?.string }
        let held = Set(now.claims.filter { $0.id != released }.map(\.id))
        let satisfied = Set(cap.claims.filter { $0.state == .claimSatisfied }.map(\.claimID))
        for index in now.returns.indices.reversed() {
            let point = now.returns[index]
            if held.contains(point.claim) { continue }
            let isTop = index == now.returns.count - 1
            let lastWasItsOwn = now.lastMove == nil || now.lastMove?.by == point.mover
                || now.returnedGeneration == now.published.generation
            let lost = CapturePlanner.displaced(cap, centerHz: point.centerHz, sampleRate: point.sampleRate)
            let blocking = isTop && lastWasItsOwn ? lost.filter { satisfied.contains($0.claimID) } : lost
            guard blocking.isEmpty else {
                let why = isTop && lastWasItsOwn ? "it would displace" : "the capture moved since, and it would leave unsatisfied"
                let mover = await describe(point.mover)
                let whom = blocking.map { "\($0.kind) of \(CapturePlanner.who($0.holder))" }.joined(separator: ", ")
                log.info("\(id.string) stays: \(mover) let go, but returning to \(CapturePlanner.fmt(point.centerHz)) \(why) \(whom)")
                continue
            }
            captures[id]?.returns.removeSubrange(index...)
            await carryOut(point, on: id)
            return true
        }
        return false
    }

    /// Puts the capture back at the point's rate and centre, and its gains when they are still
    /// the ones the job left, then publishes it as a write would be: the capture, its channels
    /// (back in capture), sinks at a new audio rate, and bulk audio streams on a rate change.
    private func carryOut(_ point: ReturnPoint, on id: CaptureID) async {
        guard let engine = captures[id]?.engine else { return }
        let before = await engine.snapshot
        let rates = audioRates(captureID: id)
        let moves = before.sampleRate != point.sampleRate || before.centerHz != point.centerHz
        if moves { willMove(id, by: point.mover) }
        do {
            if before.sampleRate != point.sampleRate { try await engine.setSampleRate(point.sampleRate) }
            if await engine.snapshot.centerHz != point.centerHz { try await engine.retune(centerHz: point.centerHz) }
        } catch {
            log.info("\(id.string) could not go back to \(CapturePlanner.fmt(point.centerHz)): \(error)")
        }
        if !point.gains.isEmpty, before.gains == point.gainsLeft {
            await restoreGainStates(point.gains, on: engine)
        }
        captures[id]?.returnedGeneration = await engine.snapshot.tuningGeneration
        await emitCapture(id, by: point.mover)
        if moves { await reconcileAudioRates(captureID: id, before: rates, by: point.mover) }
        if before.sampleRate != point.sampleRate { await teardownHook?(.captureRate(id)) }
    }
}
