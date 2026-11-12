// SPDX-License-Identifier: GPL-3.0-or-later

import CRTLSDR
import Foundation
import XCTest
@testable import EngineCore

/// A dongle that stops answering (2026-11-09) is left alone until it re-enumerates: opens that get
/// past the claim and fail (-1, -7 timeouts), USB descriptors that read empty and a stream that
/// dies under its capture each count, and the third in a row makes it NOT_ANSWERING, after which
/// the poll never opens it. A dongle another program holds (-3, -6) is not this: it stays IN_USE
/// on the backoff re-check. Drives `applyProbes` and the gate directly, as `RegistryProbeTests`
/// does, because the stub librtlsdr enumerates no hardware.
final class NotAnsweringTests: XCTestCase {
    static let detail =
        "RTL2838UHIDIR is not answering: unplug it and plug it back in, ideally into a port on the back of the Mac"

    private func probe(tuner: String = "R820T", openError: Int32? = nil, index: UInt32 = 0) -> RTLSDRProbe {
        RTLSDRProbe(index: index, name: "Generic RTL2832U OEM", manufacturer: "Realtek", product: "RTL2838UHIDIR",
                    serial: "00000001", tuner: tuner, gainsDB: tuner == "unknown" ? [] : [0, 0.9, 49.6],
                    tuningRanges: RTLSDRDevice.tunerInfo(tuner == "unknown" ? RTLSDR_TUNER_UNKNOWN : RTLSDR_TUNER_R820T).ranges,
                    openError: openError)
    }

    /// What enumeration reports once the dongle's string descriptors stop answering: the name
    /// librtlsdr knows from the USB ids, and no product or serial.
    private func unreadable(index: UInt32 = 0) -> RTLSDRProbe {
        RTLSDRProbe(index: index, name: "Generic RTL2832U OEM", manufacturer: "", product: "", serial: "",
                    tuner: "unknown", gainsDB: [], tuningRanges: RTLSDRDevice.tunerInfo(RTLSDR_TUNER_UNKNOWN).ranges)
    }

    /// Advances the poll `n` ticks and returns the last gate.
    private func ticks(_ reg: DefaultDeviceRegistry, _ n: Int) async -> @Sendable (RTLSDRProbe) -> Bool {
        var gate = await reg.advanceTickAndProbeGate()
        for _ in 1..<n { gate = await reg.advanceTickAndProbeGate() }
        return gate
    }

    func testThreeFailedOpensLeaveTheDongleAloneUntilItReEnumerates() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000, enumerateHardware: false)
        var events = reg.events().makeAsyncIterator()

        // Tick 1: first sight, the open times out. Listed, available, on the backoff.
        _ = await reg.advanceTickAndProbeGate()
        await reg.applyProbes([probe(tuner: "unknown", openError: -7)])
        guard case .arrived(let first) = try await next(&events) else { return XCTFail("expected arrived") }
        XCTAssertEqual(first.state, .available)
        XCTAssertNil(first.features["held_externally"], "a timeout is not another program")
        var gate = await reg.advanceTickAndProbeGate()   // tick 2
        XCTAssertFalse(gate(probe(tuner: "unknown")), "inside the 2 s backoff")
        gate = await reg.advanceTickAndProbeGate()       // tick 3
        XCTAssertTrue(gate(probe(tuner: "unknown")))

        // Second failure (-1), then the 4 s backoff, then the third: NOT_ANSWERING, said once.
        await reg.applyProbes([probe(tuner: "unknown", openError: -1)])
        gate = await ticks(reg, 3)                       // ticks 4..6
        XCTAssertFalse(gate(probe(tuner: "unknown")))
        gate = await reg.advanceTickAndProbeGate()       // tick 7
        XCTAssertTrue(gate(probe(tuner: "unknown")))
        await reg.applyProbes([probe(tuner: "unknown", openError: -7)])
        guard case .changed(let gone) = try await next(&events) else { return XCTFail("expected changed") }
        XCTAssertEqual(gone.id, first.id)
        XCTAssertEqual(gone.state, .notAnswering)
        XCTAssertEqual(gone.stateDetail, Self.detail)

        // Left alone: no tick opens it, a pass changes nothing, and letting it go keeps the state.
        gate = await ticks(reg, 120)
        XCTAssertFalse(gate(probe(tuner: "unknown")), "a radio that is not answering is never opened")
        await reg.applyProbes([probe(tuner: "unknown", openError: -7)])
        await reg.applyProbes([probe()])
        try await reg.markInUse(id: first.id, false)
        let still = await reg.devices
        XCTAssertEqual(still.first?.state, .notAnswering)

        // Unplugged and plugged back in: a pass without it removes it, the next is a new arrival
        // under the same id with a clean count, and the poll may open it again.
        await reg.applyProbes([])
        guard case .removed(let removed) = try await next(&events) else { return XCTFail("expected removed") }
        XCTAssertEqual(removed, first.id)
        _ = await reg.advanceTickAndProbeGate()
        await reg.applyProbes([probe()])
        guard case .arrived(let back) = try await next(&events) else { return XCTFail("expected arrived") }
        XCTAssertEqual(back.id, first.id)
        XCTAssertEqual(back.state, .available)
        XCTAssertEqual(back.stateDetail, "")
    }

    /// Another program's claim keeps today's rule however often it fails: IN_USE, held, re-checked.
    func testABusyDongleStaysInUseAndIsRechecked() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000, enumerateHardware: false)
        _ = await reg.advanceTickAndProbeGate()
        for rc: Int32 in [-3, -3, -6, -3, -3, -3] {
            await reg.applyProbes([probe(tuner: "unknown", openError: rc)])
        }
        let devices = await reg.devices
        XCTAssertEqual(devices.first?.state, .inUse)
        XCTAssertEqual(devices.first?.features["held_externally"], .flag(true))
        XCTAssertEqual(devices.first?.stateDetail, "")
        let gate = await ticks(reg, 61)
        XCTAssertTrue(gate(probe(tuner: "unknown")), "the backoff re-check carries on")
    }

    /// Descriptors that read empty count against the known dongle at that index, which stays listed
    /// rather than leaving and coming back as a nameless radio, and is never opened while they do.
    /// While one of our captures streams from it, the stream judges it, not the descriptors.
    func testUnreadableDescriptorsCountAgainstTheKnownDongle() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000, enumerateHardware: false)
        var events = reg.events().makeAsyncIterator()
        _ = await reg.advanceTickAndProbeGate()
        await reg.applyProbes([probe()])
        guard case .arrived(let first) = try await next(&events) else { return XCTFail("expected arrived") }
        let gate = await reg.advanceTickAndProbeGate()
        XCTAssertFalse(gate(unreadable()), "a dongle whose descriptors read empty is never opened")

        try await reg.markInUse(id: first.id, true)
        guard case .changed = try await next(&events) else { return XCTFail("expected changed") }
        for _ in 0..<5 { await reg.applyProbes([unreadable()]) }
        var devices = await reg.devices
        XCTAssertEqual(devices.map(\.id), [first.id], "still listed, under its own id")
        XCTAssertEqual(devices.first?.state, .inUse, "ours: the capture's stall check decides")

        try await reg.markInUse(id: first.id, false)
        guard case .changed = try await next(&events) else { return XCTFail("expected changed") }
        await reg.applyProbes([unreadable()])
        await reg.applyProbes([unreadable()])
        devices = await reg.devices
        XCTAssertEqual(devices.first?.state, .available, "two is not yet three")
        await reg.applyProbes([unreadable()])
        guard case .changed(let gone) = try await next(&events) else { return XCTFail("expected changed, no removal") }
        XCTAssertEqual(gone.id, first.id)
        XCTAssertEqual(gone.state, .notAnswering)
        XCTAssertEqual(gone.stateDetail, Self.detail)
    }

    /// A dongle first seen with unreadable descriptors is listed under what it gave, never opened,
    /// and NOT_ANSWERING after three passes.
    func testANewDongleWithUnreadableDescriptorsIsNeverOpened() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000, enumerateHardware: false)
        var events = reg.events().makeAsyncIterator()
        for _ in 0..<3 {
            let gate = await reg.advanceTickAndProbeGate()
            XCTAssertFalse(gate(unreadable()))
            await reg.applyProbes([unreadable()])
        }
        guard case .arrived(let first) = try await next(&events) else { return XCTFail("expected arrived") }
        XCTAssertEqual(first.model, "Generic RTL2832U OEM")
        guard case .changed(let gone) = try await next(&events) else { return XCTFail("expected changed") }
        XCTAssertEqual(gone.state, .notAnswering)
        XCTAssertEqual(gone.stateDetail,
                       "Generic RTL2832U OEM is not answering: unplug it and plug it back in, ideally into a port on the back of the Mac")
    }

    /// A stream that dies while the dongle stays listed counts, and the dongle is offered back to
    /// its capture on a new device object after the backoff; two rebinds that fail after it make
    /// three, and the dongle is left alone.
    func testAStreamThatDiesIsRevivedAndThenGivenUpOn() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000, enumerateHardware: false)
        var events = reg.events().makeAsyncIterator()
        _ = await reg.advanceTickAndProbeGate()
        await reg.applyProbes([probe()])
        guard case .arrived(let first) = try await next(&events) else { return XCTFail("expected arrived") }
        try await reg.markInUse(id: first.id, true)
        guard case .changed = try await next(&events) else { return XCTFail("expected changed") }
        let original = await reg.device(id: first.id)

        // rtlsdr_read_async returned on its own (libusb -5): the capture is told, the count is one.
        await reg.deviceStateChanged(id: first.id, state: .disconnected)
        guard case .changed(let lost) = try await next(&events) else { return XCTFail("expected changed") }
        XCTAssertEqual(lost.state, .disconnected)
        var gate = await reg.advanceTickAndProbeGate()
        XCTAssertFalse(gate(probe(tuner: "unknown")), "the rebind is the open, not a probe")
        await reg.applyProbes([probe(tuner: "unknown")])

        // After the 2 s backoff: a new device object, announced as arrived.
        gate = await reg.advanceTickAndProbeGate()
        await reg.applyProbes([probe(tuner: "unknown")])
        guard case .arrived(let revived) = try await next(&events) else { return XCTFail("expected arrived") }
        XCTAssertEqual(revived.id, first.id)
        XCTAssertEqual(revived.state, .available)
        let fresh = await reg.device(id: first.id)
        XCTAssertFalse(fresh === original, "a dead handle is never handed back")

        // The rebind fails (two), is tried again after the 4 s backoff and fails (three).
        await reg.noteFailure(id: first.id, reason: "the rebind failed", revive: true)
        gate = await ticks(reg, 4)
        await reg.applyProbes([probe(tuner: "unknown")])
        guard case .arrived = try await next(&events) else { return XCTFail("expected a second revive") }
        let gaveUp = await reg.noteFailure(id: first.id, reason: "the rebind failed", revive: true)
        XCTAssertTrue(gaveUp)
        guard case .changed(let gone) = try await next(&events) else { return XCTFail("expected changed") }
        XCTAssertEqual(gone.state, .notAnswering)
        gate = await ticks(reg, 120)
        XCTAssertFalse(gate(probe(tuner: "unknown")))
        _ = gate
    }

    /// An open that works ends the run: two failures, an open, two more is not three.
    func testASuccessfulOpenResetsTheCount() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000, enumerateHardware: false)
        _ = await reg.advanceTickAndProbeGate()
        await reg.applyProbes([probe()])
        let listed = await reg.devices
        let id = try XCTUnwrap(listed.first?.id)
        await reg.noteFailure(id: id, reason: "test")
        await reg.noteFailure(id: id, reason: "test")
        try await reg.markInUse(id: id, true)
        try await reg.markInUse(id: id, false)
        await reg.noteFailure(id: id, reason: "test")
        let gaveUp = await reg.noteFailure(id: id, reason: "test")
        XCTAssertFalse(gaveUp)
        let devices = await reg.devices
        XCTAssertEqual(devices.first?.state, .available)
    }
}
