import CRTLSDR
import Foundation
import XCTest
@testable import EngineCore

/// Registry probe caching: a dongle first seen while busy (degraded probe) is refreshed once a real
/// probe arrives, and a later degraded probe never downgrades it. Drives `applyProbes` directly
/// because the stub librtlsdr enumerates no hardware.
final class RegistryProbeTests: XCTestCase {
    private func probe(tuner: String, gains: [Double], openError: Int32? = nil) -> RTLSDRProbe {
        RTLSDRProbe(index: 0, name: "Generic RTL2832U", manufacturer: "Realtek", product: "RTL2838UHIDIR",
                    serial: "00000001", tuner: tuner, gainsDB: gains,
                    tuningRanges: RTLSDRDevice.tunerInfo(tuner == "unknown" ? RTLSDR_TUNER_UNKNOWN : RTLSDR_TUNER_R820T).ranges,
                    openError: openError)
    }

    /// A dongle another program holds (probe open fails) is reported IN_USE with `held_externally`,
    /// re-probed on a doubling backoff (2 s, 4 s, ...) instead of every poll, and goes back to
    /// AVAILABLE with the real tuner data once an open succeeds.
    func testHeldDongleReportsInUseAndBacksOff() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000)
        var events = reg.events().makeAsyncIterator()
        let busy = probe(tuner: "unknown", gains: [], openError: -3)

        // Tick 1: first sight, open fails.
        _ = await reg.advanceTickAndProbeGate()
        await reg.applyProbes([busy])
        guard case .arrived(let first)? = await events.next() else { return XCTFail("expected arrived") }
        XCTAssertEqual(first.state, .inUse)
        XCTAssertEqual(first.features["held_externally"], .flag(true))
        XCTAssertEqual(first.features["tuner"], .text("unknown"))

        // Backoff 2 s: tick 2 must not open; tick 3 may.
        var gate = await reg.advanceTickAndProbeGate()   // tick 2
        XCTAssertFalse(gate(busy), "inside the 2 s backoff the probe must not open the dongle")
        gate = await reg.advanceTickAndProbeGate()       // tick 3
        XCTAssertTrue(gate(busy), "after the backoff the probe may retry")

        // Second failure: no new event (nothing changed), backoff doubles to 4 s (ticks 4..6 skip, 7 opens).
        await reg.applyProbes([busy])
        for tick in 4...6 {
            gate = await reg.advanceTickAndProbeGate()
            XCTAssertFalse(gate(busy), "tick \(tick) is inside the 4 s backoff")
        }
        gate = await reg.advanceTickAndProbeGate()       // tick 7
        XCTAssertTrue(gate(busy))
        let held = await reg.devices
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held.first?.state, .inUse)

        // The other program quits: a real probe flips it back to available with the gain table.
        await reg.applyProbes([probe(tuner: "R820T", gains: [0, 0.9, 49.6])])
        guard case .changed(let freed)? = await events.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(freed.id, first.id)
        XCTAssertEqual(freed.state, .available)
        XCTAssertNil(freed.features["held_externally"])
        XCTAssertEqual(freed.features["tuner"], .text("R820T"))
        XCTAssertEqual(freed.gainElements.first?.validDB, [0, 0.9, 49.6])
        // Probed successfully: later polls never open it again.
        gate = await reg.advanceTickAndProbeGate()
        XCTAssertFalse(gate(busy))
    }

    /// Our own capture opening the dongle proves the hold is over: `markInUse` clears the flag and
    /// the schedule even though the state stays IN_USE.
    func testOwnCaptureClearsExternalHold() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000)
        var events = reg.events().makeAsyncIterator()
        _ = await reg.advanceTickAndProbeGate()
        await reg.applyProbes([probe(tuner: "unknown", gains: [], openError: -6)])
        guard case .arrived(let first)? = await events.next() else { return XCTFail("expected arrived") }

        try await reg.markInUse(id: first.id, true)
        guard case .changed(let ours)? = await events.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(ours.state, .inUse)
        XCTAssertNil(ours.features["held_externally"])
        // Ours now: the poll treats it as claimed and never probes it.
        let gate = await reg.advanceTickAndProbeGate()
        XCTAssertFalse(gate(probe(tuner: "unknown", gains: [])))

        try await reg.markInUse(id: first.id, false)
        guard case .changed(let released)? = await events.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(released.state, .available)
        XCTAssertNil(released.features["held_externally"])
    }

    /// A capture's own failed claim (rtlsdr_open ACCESS/BUSY after the dongle was probed fine, e.g.
    /// rtl_tcp restarted and grabbed it) marks the dongle held exactly like a failed probe.
    func testCaptureClaimFailureMarksHeld() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000)
        var events = reg.events().makeAsyncIterator()
        _ = await reg.advanceTickAndProbeGate()
        await reg.applyProbes([probe(tuner: "R820T", gains: [0, 0.9, 49.6])])
        guard case .arrived(let first)? = await events.next() else { return XCTFail("expected arrived") }
        XCTAssertEqual(first.state, .available)

        await reg.markHeldExternally(id: first.id)
        guard case .changed(let held)? = await events.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(held.state, .inUse)
        XCTAssertEqual(held.features["held_externally"], .flag(true))
        XCTAssertEqual(held.gainElements.first?.validDB, [0, 0.9, 49.6], "the probed gain table is kept")
        // Re-probed with backoff: tick 2 skips, tick 3 may open (the cached good probe no longer exempts it).
        var gate = await reg.advanceTickAndProbeGate()
        XCTAssertFalse(gate(probe(tuner: "unknown", gains: [])))
        gate = await reg.advanceTickAndProbeGate()
        XCTAssertTrue(gate(probe(tuner: "unknown", gains: [])))
        // A skipped probe on a held dongle changes nothing; a successful one frees it.
        await reg.applyProbes([probe(tuner: "unknown", gains: [])])
        let still = await reg.devices
        XCTAssertEqual(still.first?.state, .inUse)
        await reg.applyProbes([probe(tuner: "R820T", gains: [0, 0.9, 49.6])])
        guard case .changed(let freed)? = await events.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(freed.state, .available)
        XCTAssertNil(freed.features["held_externally"])
        // Ours or virtual: no-op.
        try await reg.markInUse(id: first.id, true)
        guard case .changed? = await events.next() else { return XCTFail("expected changed") }
        await reg.markHeldExternally(id: first.id)
        let ours = await reg.devices
        XCTAssertNil(ours.first?.features["held_externally"])
        XCTAssertTrue(RTLSDRDevice.isClaimFailure(-3))
        XCTAssertTrue(RTLSDRDevice.isClaimFailure(-6))
        XCTAssertFalse(RTLSDRDevice.isClaimFailure(-1))
    }

    /// Unplugging a held dongle removes it like any other; a re-arrival starts a fresh schedule.
    func testRemovalClearsHoldSchedule() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000)
        var events = reg.events().makeAsyncIterator()
        let busy = probe(tuner: "unknown", gains: [], openError: -3)
        _ = await reg.advanceTickAndProbeGate()
        await reg.applyProbes([busy])
        guard case .arrived(let first)? = await events.next() else { return XCTFail("expected arrived") }
        await reg.applyProbes([])
        guard case .removed(let gone)? = await events.next() else { return XCTFail("expected removed") }
        XCTAssertEqual(gone, first.id)
        await reg.applyProbes([busy])
        guard case .arrived(let again)? = await events.next() else { return XCTFail("expected arrived again") }
        XCTAssertEqual(again.id, first.id, "stable id survives the unplug")
        XCTAssertEqual(again.state, .inUse)
        // Fresh schedule: the first backoff is 2 s again (tick 3 may retry), not a stale doubled value.
        var gate = await reg.advanceTickAndProbeGate()   // tick 2
        XCTAssertFalse(gate(busy))
        gate = await reg.advanceTickAndProbeGate()       // tick 3
        XCTAssertTrue(gate(busy), "a stale or doubled schedule would still be skipping here")
    }

    func testDegradedProbeIsRefreshedThenCached() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000)
        var events = reg.events().makeAsyncIterator()

        await reg.applyProbes([probe(tuner: "unknown", gains: [])])
        guard case .arrived(let first)? = await events.next() else { return XCTFail("expected arrived") }
        XCTAssertEqual(first.features["tuner"], .text("unknown"))
        XCTAssertEqual(first.gainElements.first?.validDB, [])

        // A successful probe on a later pass rebuilds the descriptor and publishes `changed`.
        await reg.applyProbes([probe(tuner: "R820T", gains: [0, 0.9, 49.6])])
        guard case .changed(let refreshed)? = await events.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(refreshed.id, first.id)
        XCTAssertEqual(refreshed.features["tuner"], .text("R820T"))
        XCTAssertEqual(refreshed.gainElements.first?.validDB, [0, 0.9, 49.6])
        XCTAssertEqual(refreshed.tuningRanges, RTLSDRDevice.tunerInfo(RTLSDR_TUNER_R820T).ranges)
        let found = await reg.device(id: first.id)
        let device = try XCTUnwrap(found as? RTLSDRDevice)
        XCTAssertEqual(device.probe.tuner, "R820T")

        // Once probed, a degraded (skipped-open) probe keeps the cached data and is not a change.
        await reg.applyProbes([probe(tuner: "unknown", gains: [])])
        let after = await reg.devices
        XCTAssertEqual(after.first?.gainElements.first?.validDB, [0, 0.9, 49.6])
        XCTAssertEqual(device.probe.tuner, "R820T")
    }

    func testIdentityBaseStripsCollisionSuffix() {
        XCTAssertEqual(DefaultDeviceRegistry.identityBase(of: "s|m|p"), "s|m|p")
        XCTAssertEqual(DefaultDeviceRegistry.identityBase(of: "s|m|p#1"), "s|m|p")
    }
}
