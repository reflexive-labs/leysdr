// SPDX-License-Identifier: GPL-3.0-or-later

import CHackRF
import Foundation
import XCTest
@testable import EngineCore

final class MockHackRFLibrary: HackRFLibrary, @unchecked Sendable {
    private let lock = NSLock()
    var probes: [HackRFProbe] = []
    var initializeRC: Int32 = 0
    var openRC: Int32 = 0
    var startRC: Int32 = 0
    private(set) var openedSerials: [String] = []
    private(set) var closes = 0
    private(set) var frequencies: [UInt64] = []
    private(set) var sampleRates: [UInt64] = []
    private(set) var lnaGains: [UInt32] = []
    private(set) var vgaGains: [UInt32] = []
    private(set) var amps: [UInt8] = []
    private(set) var starts = 0
    private(set) var stops = 0
    private var callback: hackrf_sample_block_cb_fn?
    private var context: UnsafeMutableRawPointer?

    func initialize() -> Int32 { initializeRC }

    func enumerate(claimed: Set<String>, shouldOpen: @Sendable (HackRFProbe) -> Bool) throws -> [HackRFProbe] {
        probes.map { probe in
            if claimed.contains(probe.serial) || !shouldOpen(probe) {
                return HackRFProbe(serial: probe.serial, model: "HackRF", probed: false)
            }
            return probe
        }
    }

    func open(serial: String, device: inout OpaquePointer?) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        openedSerials.append(serial)
        if openRC == 0 { device = OpaquePointer(bitPattern: 1) }
        return openRC
    }
    func close(_ device: OpaquePointer) -> Int32 {
        lock.lock(); closes += 1; lock.unlock()
        return 0
    }
    func setFrequency(_ device: OpaquePointer, _ hz: UInt64) -> Int32 {
        lock.lock(); frequencies.append(hz); lock.unlock()
        return 0
    }
    func setSampleRate(_ device: OpaquePointer, _ hz: Double) -> Int32 {
        lock.lock(); sampleRates.append(UInt64(hz)); lock.unlock()
        return 0
    }
    func setLNAGain(_ device: OpaquePointer, _ db: UInt32) -> Int32 {
        lock.lock(); lnaGains.append(db); lock.unlock()
        return 0
    }
    func setVGAGain(_ device: OpaquePointer, _ db: UInt32) -> Int32 {
        lock.lock(); vgaGains.append(db); lock.unlock()
        return 0
    }
    func setAmpEnabled(_ device: OpaquePointer, _ enabled: UInt8) -> Int32 {
        lock.lock(); amps.append(enabled); lock.unlock()
        return 0
    }
    func startRX(_ device: OpaquePointer, callback: hackrf_sample_block_cb_fn?, context: UnsafeMutableRawPointer?) -> Int32 {
        lock.lock()
        starts += 1
        self.callback = callback
        self.context = context
        lock.unlock()
        return startRC
    }
    func stopRX(_ device: OpaquePointer) -> Int32 {
        lock.lock(); stops += 1; callback = nil; context = nil; lock.unlock()
        return 0
    }
    func errorName(_ code: Int32) -> String { "mock \(code)" }

    func emit(_ bytes: [UInt8]) {
        lock.lock()
        let callback = callback
        let context = context
        lock.unlock()
        var copy = bytes
        copy.withUnsafeMutableBytes { raw in
            var transfer = hackrf_transfer()
            transfer.buffer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            transfer.buffer_length = Int32(raw.count)
            transfer.valid_length = Int32(raw.count)
            transfer.rx_ctx = context
            _ = callback?(&transfer)
        }
    }
}

private final class HackRFDeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var formats: [SampleFormat] = []
    private(set) var times: [SampleTime] = []
    private(set) var bytes: [[UInt8]] = []

    func append(_ buffer: SampleBuffer, _ time: SampleTime) {
        lock.lock()
        formats.append(buffer.format)
        times.append(time)
        bytes.append(Array(buffer.bytes))
        lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return times.count }
}

final class HackRFDeviceTests: XCTestCase {
    private let serial = "0000000000000000a06063c8234e925f"

    func testProDescriptorAdvertisesLegacyRXCapabilities() {
        let descriptor = HackRFDevice(probe: HackRFProbe(serial: serial, model: "HackRF Pro"),
                                      id: DeviceID()).descriptor
        XCTAssertEqual(descriptor.driver, "hackrf")
        XCTAssertEqual(descriptor.model, "HackRF Pro")
        XCTAssertEqual(descriptor.tuningRanges, [FrequencyRange(minHz: 100_000, maxHz: 6_000_000_000)])
        XCTAssertEqual(descriptor.nativeFormat, .cs8)
        XCTAssertEqual(descriptor.sampleRates, HackRFDevice.sampleRates)
        XCTAssertEqual(descriptor.gainElements.map(\.name), ["LNA", "VGA", "AMP"])
        XCTAssertEqual(descriptor.gainElement(named: "LNA")?.stepDB, 8)
        XCTAssertEqual(descriptor.gainElement(named: "VGA")?.stepDB, 2)
        XCTAssertEqual(descriptor.gainElement(named: "AMP")?.validDB, [0, 11])
        XCTAssertEqual(descriptor.features["tx_capable"], .flag(true))
        XCTAssertEqual(descriptor.features["full_duplex"], .flag(false))
        XCTAssertEqual(descriptor.features["sample_mode"], .text("legacy_cs8"))
        XCTAssertEqual(HackRFDevice.queuedSamples, 524_288)
        XCTAssertEqual(HackRFDevice(probe: HackRFProbe(serial: serial, model: "HackRF Pro"),
                                    id: DeviceID()).gains.map(\.value), [.db(8), .db(20), .db(0)])
    }

    func testMockedOpenControlStreamAndClose() async throws {
        let library = MockHackRFLibrary()
        let device = HackRFDevice(probe: HackRFProbe(serial: serial, model: "HackRF Pro"),
                                  id: DeviceID(), library: library)
        try await device.open()
        XCTAssertEqual(library.openedSerials, [serial])
        XCTAssertEqual(library.sampleRates, [2_400_000])
        XCTAssertEqual(library.frequencies, [100_000])
        XCTAssertEqual(library.lnaGains, [8])
        XCTAssertEqual(library.vgaGains, [20])
        XCTAssertEqual(library.amps, [0])

        try await device.tune(centerHz: 101_100_000)
        try await device.setSampleRate(10_000_000)
        try await device.setGain(element: "LNA", value: .db(17))
        try await device.setGain(element: "VGA", value: .db(9))
        try await device.setGain(element: "AMP", value: .db(8))
        XCTAssertEqual(library.frequencies.last, 101_100_000)
        XCTAssertEqual(library.sampleRates.last, 10_000_000)
        XCTAssertEqual(library.lnaGains.last, 16)
        XCTAssertEqual(library.vgaGains.last, 10)
        XCTAssertEqual(library.amps.last, 1)
        XCTAssertEqual(device.gains.map(\.value), [.db(16), .db(10), .db(11)])

        let captureID = CaptureID()
        let delivered = HackRFDeliveryLog()
        try await device.startStreaming(captureID: captureID) { delivered.append($0, $1) }
        library.emit([0x80, 0x7f, 0xff, 0x01])
        library.emit([0x10, 0x20])
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered.formats, [.cs8, .cs8])
        XCTAssertEqual(delivered.bytes, [[0x80, 0x7f, 0xff, 0x01], [0x10, 0x20]])
        XCTAssertEqual(delivered.times.map(\.captureID), [captureID, captureID])
        XCTAssertEqual(delivered.times.map(\.sampleIndex), [0, 2])

        await device.stopStreaming()
        XCTAssertEqual(library.starts, 1)
        XCTAssertEqual(library.stops, 1)
        await device.close()
        XCTAssertEqual(library.closes, 1)
    }

    func testValidationAndLibraryFailures() async throws {
        let library = MockHackRFLibrary()
        let id = DeviceID()
        let device = HackRFDevice(probe: HackRFProbe(serial: serial, model: "HackRF One"),
                                  id: id, library: library)
        try await device.open()
        await assertCode("FREQ_OUT_OF_RANGE") { try await device.tune(centerHz: 100_000) }
        await assertCode("RATE_UNSUPPORTED") { try await device.setSampleRate(3_000_000) }
        await assertCode("INVALID_ARGUMENT") { try await device.setGain(element: "LNA", value: .auto) }
        await assertCode("INVALID_ARGUMENT") { try await device.setGain(element: "LNA", value: .db(.nan)) }
        await assertCode("GAIN_ELEMENT_UNKNOWN") { try await device.setGain(element: "TUNER", value: .db(1)) }
        await device.close()

        let busyLibrary = MockHackRFLibrary()
        busyLibrary.openRC = -1_000
        let busy = HackRFDevice(probe: HackRFProbe(serial: serial, model: "HackRF Pro"),
                                id: id, library: busyLibrary)
        await assertCode("DEVICE_BUSY") { try await busy.open() }

        let startLibrary = MockHackRFLibrary()
        startLibrary.startRC = -5
        let startFailure = HackRFDevice(probe: HackRFProbe(serial: serial, model: "HackRF Pro"),
                                        id: id, library: startLibrary)
        try await startFailure.open()
        await assertCode("DEVICE_IO") {
            try await startFailure.startStreaming(captureID: CaptureID()) { _, _ in }
        }
        await startFailure.close()
    }

    func testMockedEnumerationHonorsClaimAndProbeGate() throws {
        let library = MockHackRFLibrary()
        library.probes = [
            HackRFProbe(serial: "pro", model: "HackRF Pro"),
            HackRFProbe(serial: "one", model: "HackRF One"),
        ]
        let probes = try HackRFDevice.enumerate(claimed: ["one"], shouldOpen: { $0.serial != "blocked" },
                                                library: library)
        XCTAssertEqual(probes[0].model, "HackRF Pro")
        XCTAssertTrue(probes[0].probed)
        XCTAssertEqual(probes[1], HackRFProbe(serial: "one", model: "HackRF", probed: false))
    }

    func testRegistryHackRFHotPlugKeepsStableID() async throws {
        let registry = DefaultDeviceRegistry(enumerateHardware: false)
        var events = registry.events().makeAsyncIterator()
        let probe = HackRFProbe(serial: serial, model: "HackRF Pro")
        await registry.applyHackRFProbes([probe])
        guard case .arrived(let first) = try await next(&events) else { return XCTFail("expected arrived") }
        XCTAssertEqual(first.driver, "hackrf")
        let detachable = await registry.isDetachableVirtualDevice(id: first.id)
        let hosted = await registry.device(id: first.id)
        XCTAssertFalse(detachable)
        XCTAssertTrue(hosted is HackRFDevice)

        await registry.applyHackRFProbes([])
        guard case .removed(let removed) = try await next(&events) else { return XCTFail("expected removed") }
        XCTAssertEqual(removed, first.id)
        await registry.applyHackRFProbes([probe])
        guard case .arrived(let second) = try await next(&events) else { return XCTFail("expected arrived") }
        XCTAssertEqual(second.id, first.id)
    }

    func testRegistryBacksOffBusyHackRFThenRefreshesBoard() async throws {
        let registry = DefaultDeviceRegistry(pollIntervalMs: 1_000, enumerateHardware: false)
        var events = registry.events().makeAsyncIterator()
        let busy = HackRFProbe(serial: serial, model: "HackRF", probed: false, openError: -1_000)

        _ = await registry.advanceTickAndProbeGate()
        await registry.applyHackRFProbes([busy])
        guard case .arrived(let held) = try await next(&events) else { return XCTFail("expected arrived") }
        XCTAssertEqual(held.state, .inUse)
        XCTAssertEqual(held.features["held_externally"], .flag(true))

        _ = await registry.advanceTickAndProbeGate()
        var gate = await registry.hackrfProbeGate()
        XCTAssertFalse(gate(busy), "the first 2 s backoff is still active on tick 2")
        _ = await registry.advanceTickAndProbeGate()
        gate = await registry.hackrfProbeGate()
        XCTAssertTrue(gate(busy), "the device may be probed again on tick 3")

        await registry.applyHackRFProbes([HackRFProbe(serial: serial, model: "HackRF Pro")])
        guard case .changed(let available) = try await next(&events) else { return XCTFail("expected changed") }
        XCTAssertEqual(available.id, held.id)
        XCTAssertEqual(available.state, .available)
        XCTAssertEqual(available.model, "HackRF Pro")
        XCTAssertNil(available.features["held_externally"])
        XCTAssertEqual(available.tuningRanges.first?.minHz, 100_000)
    }
}
