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
        /// The capture's count of people's moves (`personMoves`) when the job read where it found
        /// it. A point noted after a person has moved the capture since is dropped.
        var personMoves = 0
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

    /// Notes where `claim`'s job found the capture before it moved it, unless a person has moved
    /// the capture since the job read `point.personMoves`: nothing goes back over their head.
    func noteReturnPoint(_ point: ReturnPoint, on id: CaptureID) {
        guard let entry = captures[id] else { return }
        guard entry.personMoves == point.personMoves else {
            log.info("\(id.string): a person moved the capture while a job was moving it, so nothing returns to where the job found it")
            return
        }
        captures[id]?.returns.append(point)
    }

    /// How many times a person has moved the capture. A job reads it before it moves the capture
    /// and hands it back with the return point.
    func personMoves(_ id: CaptureID) -> Int {
        captures[id]?.personMoves ?? 0
    }

    /// The claim a channel holds, for a lease that has to name it.
    func channelClaim(_ channelID: ChannelID, on id: CaptureID) -> ClaimID? {
        captures[id]?.claims.first { $0.need == .channel(channelID) }?.id
    }

    /// A move by a person clears every return: they are at the controls, and nothing goes back
    /// over their head. Called with every recorded move.
    func notePersonMove(_ id: CaptureID, by mover: ClientContext) {
        guard mover.kind != "job", mover.kind != "daemon", captures[id] != nil else { return }
        captures[id]?.personMoves += 1
        guard captures[id]?.returns.isEmpty == false else { return }
        captures[id]?.returns.removeAll()
        log.info("\(id.string): \(mover.kind) moved the capture, so nothing returns to where a job found it")
    }

    // MARK: After a release

    /// A claim is going (`released`, still in the ledger) or has gone (nil). A capture the
    /// allocator made is destroyed when nothing holds it; true when it was, or when it is closing
    /// already. Otherwise any return that is due is carried out.
    @discardableResult
    func claimReleased(_ id: CaptureID, without released: ClaimID?) async -> Bool {
        guard let entry = captures[id], !entry.closing else { return true }
        if entry.heldByClaims, !entry.claims.contains(where: { $0.id != released && Self.holds($0) }) {
            await destroyCapture(id: id, by: .daemon)
            return true
        }
        await settleReturns(id, without: released)
        return captures[id] == nil
    }

    /// Waits while a return is being worked out or carried out on the capture. A person's write
    /// waits here and lands after the return, so no return goes over it.
    func awaitReturn(_ id: CaptureID) async {
        await awaitCapture(id) { $0.settling }
    }

    /// Carries out every return that is due, one at a time: a release while one is in hand asks
    /// for another look once it is done. People's writes to the capture wait until it is over.
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
        wakeCaptureWaiters(id)
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
    /// one that does not stays, and is tried again at the next release, as is one the radio
    /// refuses or one a claim made while it was under way would lose by. True when one returned.
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
            return await carryOut(Array(now.returns[index...]), on: id, known: Set(now.claims.map(\.id)), held: held)
        }
        return false
    }

    /// Puts the capture back at the rate and centre of the first point of `taken`, which goes
    /// with every newer point, then publishes it as a write would be: the capture, its channels
    /// (back in capture), sinks at a new audio rate, and bulk audio streams on a rate change.
    /// Before each step it reads the ledger again, and a claim made since the return was decided
    /// (not in `known`) that the return would displace stops it. A stopped or refused return puts
    /// the capture back where it found it, as far as the radio lets it, and keeps its points for
    /// the next release. True when the capture returned.
    private func carryOut(_ taken: [ReturnPoint], on id: CaptureID, known: Set<ClaimID>, held: Set<ClaimID>) async -> Bool {
        guard let point = taken.first, let engine = captures[id]?.engine else { return false }
        let before = await engine.snapshot
        let rates = audioRates(captureID: id)
        let moves = before.sampleRate != point.sampleRate || before.centerHz != point.centerHz
        if moves { willMove(id, by: point.mover) }
        var failure: String?
        var rateTried = false
        do {
            if before.sampleRate != point.sampleRate {
                failure = await newcomerLoses(id, known: known, at: point)
                if failure == nil {
                    rateTried = true
                    try await engine.setSampleRate(point.sampleRate)
                }
            }
            if failure == nil, await engine.snapshot.centerHz != point.centerHz {
                failure = await newcomerLoses(id, known: known, at: point)
                if failure == nil { try await engine.retune(centerHz: point.centerHz) }
            }
        } catch {
            failure = "\(error)"
        }
        if let failure {
            log.warning("\(id.string) did not go back to \(CapturePlanner.fmt(point.centerHz)), so it stays where it was until the next release: \(failure)")
            let now = await engine.snapshot
            if now.sampleRate != before.sampleRate { try? await engine.setSampleRate(before.sampleRate) }
            if now.centerHz != before.centerHz { try? await engine.retune(centerHz: before.centerHz) }
        } else {
            if let gains = unwindGains(taken, held: held, from: before.gains, on: id) {
                await restoreGainStates(gains, on: engine)
            }
            captures[id]?.returnedGeneration = await engine.snapshot.tuningGeneration
        }
        await emitCapture(id, by: point.mover)
        // A return that did not move the capture leaves nobody named as about to.
        moveFailed(id, by: point.mover)
        if moves { await reconcileAudioRates(captureID: id, before: rates, by: point.mover) }
        if rateTried { await teardownHook?(.captureRate(id)) }
        return failure == nil
    }

    /// Why a claim made since the return was decided would lose by it, or nil when none would.
    private func newcomerLoses(_ id: CaptureID, known: Set<ClaimID>, at point: ReturnPoint) async -> String? {
        guard let entry = captures[id] else { return "the capture is gone" }
        let fresh = entry.claims.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return nil }
        let snap = await entry.engine.snapshot
        var cap = Leyline_V1_Capture()
        cap.claims = await claimProtos(id, fresh, centerHz: snap.centerHz, sampleRate: snap.sampleRate, note: false)
        let lost = CapturePlanner.displaced(cap, centerHz: point.centerHz, sampleRate: point.sampleRate)
        guard !lost.isEmpty else { return nil }
        return "it would displace " + lost.map { "\($0.kind) of \(CapturePlanner.who($0.holder))" }.joined(separator: ", ")
    }

    /// Takes the returned points off the capture and gives the gains to put back now, if any.
    /// The gains unwind newest point first while each job's are still the ones it left, so two
    /// jobs that each set a gain give back the first one's find in either order, and a gain
    /// somebody else wrote stays. When a newer job that set a gain still holds its claim, it
    /// keeps its gain while it runs: the unwound gains wait for it in a point of its own at the
    /// tuning the return lands on.
    private func unwindGains(_ taken: [ReturnPoint], held: Set<ClaimID>, from current: [GainState],
                             on id: CaptureID) -> [GainState]?
    {
        let gone = Set(taken.map(\.claim))
        captures[id]?.returns.removeAll { gone.contains($0.claim) }
        guard let point = taken.first else { return nil }
        var gains = current
        var unwound = false
        for p in taken.reversed() where !p.gains.isEmpty {
            guard p.gainsLeft == gains else { break }
            gains = p.gains
            unwound = true
        }
        guard unwound else { return nil }
        guard let keeper = taken.dropFirst().last(where: { held.contains($0.claim) && !$0.gains.isEmpty }) else { return gains }
        let waiting = ReturnPoint(claim: keeper.claim, mover: keeper.mover, centerHz: point.centerHz, sampleRate: point.sampleRate,
                                  gains: gains, gainsLeft: current, personMoves: personMoves(id))
        captures[id]?.returns.append(waiting)
        return nil
    }
}
