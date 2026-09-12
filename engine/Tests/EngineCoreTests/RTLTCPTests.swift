// SPDX-License-Identifier: GPL-3.0-or-later

// RTLTCPDevice tests against an in-process fake rtl_tcp server (POSIX sockets on 127.0.0.1).

import Foundation
import TestSupport
import XCTest
@testable import EngineCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Polls `cond` every 5 ms until true or `timeout` elapses.
func waitUntil(timeout: TimeInterval = 5, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        usleep(5000)
    }
    return cond()
}

func cmd(_ op: UInt8, _ arg: UInt32) -> [UInt8] {
    [op, UInt8(arg >> 24), UInt8((arg >> 16) & 0xff), UInt8((arg >> 8) & 0xff), UInt8(arg & 0xff)]
}

/// Collects delivered blocks from the I/O thread (copies out; the buffer is a borrow).
final class BlockCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _blocks: [(index: UInt64, count: Int, format: SampleFormat, bytes: [UInt8])] = []
    var blocks: [(index: UInt64, count: Int, format: SampleFormat, bytes: [UInt8])] { lock.lock(); defer { lock.unlock() }; return _blocks }
    var count: Int { blocks.count }
    func deliver(_ buf: SampleBuffer, _ t: SampleTime) {
        let bytes = Array(UnsafeRawBufferPointer(buf.bytes))
        lock.lock(); _blocks.append((t.sampleIndex, buf.count, buf.format, bytes)); lock.unlock()
    }
}

final class RTLTCPDeviceTests: XCTestCase {
    func testDescriptorShapeAndInitialCommands() async throws {
        let server = try FakeRTLTCPServer(tuner: 5, gainCount: 29)
        defer { server.stop() }
        let dev = RTLTCPDevice(host: "127.0.0.1", port: server.port)
        try await dev.open()
        defer { Task { await dev.close() } }
        let d = dev.descriptor
        XCTAssertEqual(d.driver, "rtltcp")
        XCTAssertEqual(d.model, "rtl_tcp 127.0.0.1:\(server.port) (R820T)")
        XCTAssertEqual(d.serial, "127.0.0.1:\(server.port)")
        XCTAssertEqual(d.usbLocation, "")
        XCTAssertEqual(d.state, .available)
        XCTAssertEqual(d.tuningRanges, [FrequencyRange(minHz: 24_000_000, maxHz: 1_766_000_000)])
        XCTAssertEqual(d.sampleRates, RTLSDRDevice.sampleRates)
        XCTAssertEqual(d.nativeFormat, .cu8)
        XCTAssertEqual(d.gainElements.count, 1)
        let g = try XCTUnwrap(d.gainElement(named: "TUNER"))
        XCTAssertEqual(g.validDB.count, 29)
        XCTAssertEqual(g.minDB, 0); XCTAssertEqual(g.maxDB, 49.6); XCTAssertEqual(g.stepDB, 0)
        XCTAssertTrue(g.supportsAuto)
        XCTAssertEqual(d.features["tuner"], .text("R820T"))
        XCTAssertEqual(d.features["remote"], .text("127.0.0.1:\(server.port)"))
        for k in ["bias_tee", "direct_sampling", "ppm_correction", "rtl_agc"] { XCTAssertNotNil(d.features[k], k) }
        XCTAssertEqual(dev.tunerName, "R820T")
        XCTAssertEqual(dev.tunerGainCount, 29)
        XCTAssertEqual(dev.gains, [GainState(element: "TUNER", value: .auto)])
        XCTAssertTrue(waitUntil { server.commands.count >= 2 })
        XCTAssertEqual(Array(server.commands.prefix(2)), [cmd(0x02, 2_400_000), cmd(0x01, 100_000_000)])
    }

    func testUnknownTunerDescriptorAndE4000Table() async throws {
        let server = try FakeRTLTCPServer(tuner: 0, gainCount: 7)
        defer { server.stop() }
        let dev = RTLTCPDevice(host: "127.0.0.1", port: server.port, sampleRate: 1_024_000)
        try await dev.open()
        let g = try XCTUnwrap(dev.descriptor.gainElement(named: "TUNER"))
        // librtlsdr answers { 0 } for a tuner it cannot name; the header count (7) only earns a warning.
        XCTAssertEqual(g.validDB, [0])
        XCTAssertEqual(g.minDB, 0); XCTAssertEqual(g.maxDB, 0)
        XCTAssertEqual(dev.descriptor.model, "rtl_tcp 127.0.0.1:\(server.port) (unknown)")
        XCTAssertTrue(waitUntil { server.commands.count >= 1 })
        XCTAssertEqual(server.commands.first, cmd(0x02, 1_024_000))
        await dev.close()
        let e4k = try FakeRTLTCPServer(tuner: 1, gainCount: 14)
        defer { e4k.stop() }
        let dev2 = RTLTCPDevice(host: "127.0.0.1", port: e4k.port)
        try await dev2.open()
        let d2 = dev2.descriptor
        XCTAssertEqual(d2.tuningRanges.count, 2)
        XCTAssertEqual(d2.gainElement(named: "TUNER")?.validDB.count, 14)
        XCTAssertEqual(d2.gainElement(named: "TUNER")?.minDB, -1.0)
        await dev2.close()
    }

    func testCommandBytes() async throws {
        let server = try FakeRTLTCPServer()
        defer { server.stop() }
        let dev = RTLTCPDevice(host: "127.0.0.1", port: server.port)
        try await dev.open()
        XCTAssertTrue(waitUntil { server.commands.count >= 2 })
        let base = server.commands.count
        try await dev.tune(centerHz: 146_520_000)
        try await dev.setSampleRate(1_024_000)
        try await dev.setGain(element: "TUNER", value: .db(30)) // snaps to 29.7
        XCTAssertEqual(dev.gains, [GainState(element: "TUNER", value: .db(29.7))])
        try await dev.setGain(element: "TUNER", value: .auto)
        XCTAssertEqual(dev.gains, [GainState(element: "TUNER", value: .auto)])
        try await dev.setFeature("bias_tee", .flag(true))
        try await dev.setFeature("ppm_correction", .integer(-5))
        try await dev.setFeature("direct_sampling", .integer(2))
        try await dev.setFeature("rtl_agc", .flag(true))
        let expected: [[UInt8]] = [
            cmd(0x01, 146_520_000), cmd(0x02, 1_024_000), cmd(0x03, 1), cmd(0x04, 297), cmd(0x03, 0),
            cmd(0x0e, 1), cmd(0x05, UInt32(bitPattern: -5)), cmd(0x09, 2), cmd(0x08, 1),
        ]
        XCTAssertTrue(waitUntil { server.commands.count >= base + expected.count })
        XCTAssertEqual(Array(server.commands.dropFirst(base)), expected)
        XCTAssertEqual(dev.descriptor.features["bias_tee"], .flag(true))
        XCTAssertEqual(dev.descriptor.features["ppm_correction"], .integer(-5))
        // Validation happens before anything is sent.
        await assertCode("FREQ_OUT_OF_RANGE") { try await dev.tune(centerHz: 10_000_000) }
        await assertCode("RATE_UNSUPPORTED") { try await dev.setSampleRate(2_000_000) }
        await assertCode("GAIN_ELEMENT_UNKNOWN") { try await dev.setGain(element: "LNA", value: .auto) }
        await assertCode("INVALID_ARGUMENT") { try await dev.setFeature("direct_sampling", .integer(3)) }
        await assertCode("INVALID_ARGUMENT") { try await dev.setFeature("tuner", .text("x")) }
        await assertCode("INVALID_ARGUMENT") { try await dev.setFeature("nope", .flag(true)) }
        usleep(50_000)
        XCTAssertEqual(server.commands.count, base + expected.count)
        await dev.close()
    }

    func assertCode(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("expected \(code)", file: file, line: line) } catch let e as EngineError {
            XCTAssertEqual(e.code, code, file: file, line: line)
        } catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }

    func testStreamingDeliversBlocksAndStopKeepsConnection() async throws {
        let server = try FakeRTLTCPServer()
        defer { server.stop() }
        let dev = RTLTCPDevice(host: "127.0.0.1", port: server.port)
        try await dev.open()
        let cap = CaptureID()
        let sink = BlockCollector()
        try await dev.startStreaming(captureID: cap) { buf, t in sink.deliver(buf, t) }
        XCTAssertTrue(waitUntil(timeout: 10) { sink.count >= 3 })
        await dev.stopStreaming()
        let blocks = sink.blocks
        XCTAssertGreaterThanOrEqual(blocks.count, 3)
        for (i, b) in blocks.enumerated() {
            XCTAssertEqual(b.index, UInt64(i) * 16384)
            XCTAssertEqual(b.count, 16384)
            XCTAssertEqual(b.format, .cu8)
            XCTAssertEqual(b.bytes.count, 32768)
            // Stream byte k is UInt8(k); 32768 is a multiple of 256, so every block is the same ramp.
            XCTAssertTrue(b.bytes.enumerated().allSatisfy { $0.element == UInt8(truncatingIfNeeded: $0.offset) }, "block \(i) ramp")
        }
        // Stopped: no more delivery, socket still alive (commands still reach the server).
        let after = sink.count
        usleep(100_000)
        XCTAssertEqual(sink.count, after)
        XCTAssertEqual(dev.descriptor.state, .available)
        let base = server.commands.count
        try await dev.tune(centerHz: 99_500_000)
        XCTAssertTrue(waitUntil { server.commands.count == base + 1 })
        XCTAssertFalse(server.clientGone)
        // Restart: index restarts at 0 on the new timeline.
        let cap2 = CaptureID()
        let sink2 = BlockCollector()
        try await dev.startStreaming(captureID: cap2) { buf, t in
            XCTAssertEqual(t.captureID, cap2)
            sink2.deliver(buf, t)
        }
        await assertCode("DEVICE_BUSY") { try await dev.startStreaming(captureID: cap2) { _, _ in } }
        XCTAssertTrue(waitUntil { sink2.count >= 2 })
        await dev.stopStreaming()
        XCTAssertEqual(sink2.blocks.first?.index, 0)
        XCTAssertEqual(sink2.blocks.dropFirst().first?.index, 16384)
        await dev.close()
        XCTAssertTrue(waitUntil { server.clientGone })
    }

    /// stopStreaming must not return while the reader is still inside `deliver` (the capture frees
    /// its ring right after).
    func testStopStreamingWaitsForInFlightDeliver() async throws {
        let server = try FakeRTLTCPServer()
        defer { server.stop() }
        let dev = RTLTCPDevice(host: "127.0.0.1", port: server.port)
        try await dev.open()
        let entered = DispatchSemaphore(value: 0)
        let finished = ManagedAtomicFlag()
        try await dev.startStreaming(captureID: CaptureID()) { _, _ in
            if finished.enteredOnce() { return }
            entered.signal()
            usleep(300_000)
            finished.markDone()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        await dev.stopStreaming()
        XCTAssertTrue(finished.done, "stopStreaming returned while deliver was still running")
        await dev.close()
    }

    func testCloseJoinsReaderAndIsIdempotent() async throws {
        let server = try FakeRTLTCPServer()
        defer { server.stop() }
        let dev = RTLTCPDevice(host: "127.0.0.1", port: server.port)
        try await dev.open()
        let sink = BlockCollector()
        try await dev.startStreaming(captureID: CaptureID()) { buf, t in sink.deliver(buf, t) }
        XCTAssertTrue(waitUntil { sink.count >= 1 })
        let t0 = Date()
        await dev.close()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "close must join promptly, not wait for a read timeout")
        let n = sink.count
        usleep(50_000)
        XCTAssertEqual(sink.count, n)
        XCTAssertTrue(waitUntil { server.clientGone })
        await dev.close() // no-op
        await assertCode("DEVICE_IO") { try await dev.startStreaming(captureID: CaptureID()) { _, _ in } }
        await assertCode("DEVICE_IO") { try await dev.tune(centerHz: 100_000_000) }
    }

    func testServerDropBecomesDisconnected() async throws {
        let server = try FakeRTLTCPServer()
        defer { server.stop() }
        let dev = RTLTCPDevice(host: "127.0.0.1", port: server.port)
        try await dev.open()
        let observed = StateLog()
        dev.setOnStateChange { s in observed.record(s) }
        let sink = BlockCollector()
        try await dev.startStreaming(captureID: CaptureID()) { buf, t in sink.deliver(buf, t) }
        XCTAssertTrue(waitUntil { sink.count >= 1 })
        server.closeClient()
        XCTAssertTrue(waitUntil { observed.states == [.disconnected] })
        XCTAssertEqual(dev.descriptor.state, .disconnected)
        let n = sink.count
        usleep(50_000)
        XCTAssertEqual(sink.count, n)
        await dev.stopStreaming()
        await assertCode("DEVICE_DETACHED") { try await dev.startStreaming(captureID: CaptureID()) { _, _ in } }
        await dev.close()
    }

    func testLinkLossReleasesSocketAndReopenReconnects() async throws {
        var server = try FakeRTLTCPServer()
        let port = server.port
        let dev = RTLTCPDevice(host: "127.0.0.1", port: port)
        try await dev.open()
        let observed = StateLog()
        dev.setOnStateChange { s in observed.record(s) }
        let first = BlockCollector()
        try await dev.startStreaming(captureID: CaptureID()) { buf, t in first.deliver(buf, t) }
        XCTAssertTrue(waitUntil { first.count >= 1 })
        // Server dies: the reader releases the socket and reports the loss.
        server.stop()
        XCTAssertTrue(waitUntil { observed.states == [.disconnected] })
        XCTAssertTrue(waitUntil { !dev.isConnected }, "fd is cleared by the exiting reader")
        XCTAssertEqual(dev.descriptor.state, .disconnected)
        await dev.stopStreaming()
        // Server back on the same port: open() reconnects and streaming resumes from index 0.
        server = try FakeRTLTCPServer(port: port)
        defer { server.stop() }
        try await dev.open()
        XCTAssertTrue(dev.isConnected)
        XCTAssertEqual(dev.descriptor.state, .available)
        XCTAssertEqual(dev.descriptor.model, "rtl_tcp 127.0.0.1:\(port) (R820T)")
        XCTAssertTrue(waitUntil { server.commands.count >= 2 }, "sample rate + frequency re-pushed on reconnect")
        let second = BlockCollector()
        try await dev.startStreaming(captureID: CaptureID()) { buf, t in second.deliver(buf, t) }
        XCTAssertTrue(waitUntil { second.count >= 2 })
        XCTAssertEqual(second.blocks.first?.index, 0)
        await dev.close()
        XCTAssertFalse(dev.isConnected)
        XCTAssertEqual(observed.states, [.disconnected], "open()/close() do not fire the hook")
    }

    func testRegistryReconnectsDisconnectedRemoteOnPoll() async throws {
        var server = try FakeRTLTCPServer()
        let port = server.port
        let registry = DefaultDeviceRegistry()
        let events = registry.events()
        var iter = events.makeAsyncIterator()
        let dev = RTLTCPDevice(host: "127.0.0.1", port: port)
        try await dev.open()
        let d = try await registry.attachVirtualDevice(dev).descriptor
        guard case .arrived? = await iter.next() else { return XCTFail("expected arrived") }
        server.stop()
        guard case .changed(let gone)? = await iter.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(gone.state, .disconnected)
        // Server still down: the poll's attempt fails and the entry stays disconnected.
        await registry.poll()
        for _ in 0..<1600 where await !registry.reconnectingIDs.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let pending = await registry.reconnectingIDs
        XCTAssertTrue(pending.isEmpty, "failed attempt settles")
        // A real dongle on the developer's machine is enumerated by the poll too; look only at ours.
        var devices = await registry.devices.filter { $0.driver != "rtlsdr" }
        XCTAssertEqual(devices.map(\.state), [.disconnected])
        // Server back: the next poll reconnects, marks available and re-announces the same id.
        server = try FakeRTLTCPServer(port: port)
        defer { server.stop() }
        await registry.poll()
        // The same poll also announces any real dongle on the developer's machine; wait for ours.
        var reannounced: DeviceDescriptor?
        for _ in 0..<8 {
            guard let ev = await iter.next() else { break }
            if case .arrived(let desc) = ev, desc.id == d.id { reannounced = desc; break }
        }
        let back = try XCTUnwrap(reannounced, "expected arrived for the rtl_tcp device")
        XCTAssertEqual(back.state, .available)
        devices = await registry.devices.filter { $0.driver != "rtlsdr" }
        XCTAssertEqual(devices.map(\.state), [.available])
        XCTAssertTrue(dev.isConnected)
        XCTAssertEqual(dev.descriptor.state, .available)
        let hosted = await registry.device(id: d.id)
        XCTAssertTrue(hosted === dev)
        try await registry.detachVirtualDevice(id: d.id)
        await dev.close()
    }

    /// The link can die between `open()` returning and the actor-side `reconnectFinished` hop; the
    /// registry must not announce a device that is already gone again.
    func testReconnectFinishedPublishesNothingWhenDeviceDiedBeforeHop() async throws {
        let server = try FakeRTLTCPServer()
        let registry = DefaultDeviceRegistry()
        let events = registry.events()
        var iter = events.makeAsyncIterator()
        let dev = RTLTCPDevice(host: "127.0.0.1", port: server.port)
        try await dev.open()
        let d = try await registry.attachVirtualDevice(dev).descriptor
        guard case .arrived? = await iter.next() else { return XCTFail("expected arrived") }
        // Server drops the link: the device flips to .disconnected and the registry records it.
        server.stop()
        guard case .changed(let gone)? = await iter.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(gone.state, .disconnected)
        XCTAssertEqual(dev.descriptor.state, .disconnected)
        // Simulate the race: a reconnect attempt "succeeded" but the device is disconnected again by
        // the time the actor sees the result.
        await registry.reconnectFinished(id: d.id, device: dev, ok: true)
        let pending = await registry.reconnectingIDs
        XCTAssertTrue(pending.isEmpty)
        var devices = await registry.devices.filter { $0.driver != "rtlsdr" }
        XCTAssertEqual(devices.map(\.state), [.disconnected], "entry stays disconnected for the next poll")
        // Nothing was published: the next event on the stream is our own detach, not an `arrived`.
        try await registry.detachVirtualDevice(id: d.id)
        guard case .removed(let removed)? = await iter.next() else { return XCTFail("expected removed, got arrived") }
        XCTAssertEqual(removed, d.id)
        devices = await registry.devices.filter { $0.driver != "rtlsdr" }
        XCTAssertTrue(devices.isEmpty)
        await dev.close()
    }

    func testConnectRefusedIsDeviceIO() async throws {
        let port = try FakeRTLTCPServer.closedPort()
        let dev = RTLTCPDevice(host: "127.0.0.1", port: port)
        await assertCode("DEVICE_IO") { try await dev.open() }
        XCTAssertEqual(dev.descriptor.driver, "rtltcp")
        await dev.close()
    }

    func testRegistryAttachDetachRoundTrip() async throws {
        let server = try FakeRTLTCPServer()
        defer { server.stop() }
        let registry = DefaultDeviceRegistry()
        let events = registry.events()
        var iter = events.makeAsyncIterator()
        let dev = RTLTCPDevice(host: "127.0.0.1", port: server.port)
        try await dev.open()
        let d = try await registry.attachVirtualDevice(dev).descriptor
        XCTAssertEqual(d.driver, "rtltcp")
        XCTAssertEqual(d.id, dev.descriptor.id, "registry id is assigned to the device")
        guard case .arrived(let a)? = await iter.next() else { return XCTFail("expected arrived") }
        XCTAssertEqual(a.id, d.id)
        let again = try await registry.attachVirtualDevice(dev).descriptor
        XCTAssertEqual(again.id, d.id)
        let devices = await registry.devices
        XCTAssertEqual(devices.map(\.id), [d.id])
        let hosted = await registry.device(id: d.id)
        XCTAssertTrue(hosted === dev)
        try await registry.markInUse(id: d.id, true)
        guard case .changed(let c)? = await iter.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(c.state, .inUse)
        XCTAssertEqual(dev.descriptor.state, .inUse)
        try await registry.markInUse(id: d.id, false)
        _ = await iter.next()
        // Link loss reaches the registry through the hook.
        server.closeClient()
        guard case .changed(let gone)? = await iter.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(gone.state, .disconnected)
        try await registry.detachVirtualDevice(id: d.id)
        guard case .removed(let rid)? = await iter.next() else { return XCTFail("expected removed") }
        XCTAssertEqual(rid, d.id)
        let empty = await registry.devices
        XCTAssertTrue(empty.isEmpty)
        await assertCode("DEVICE_NOT_FOUND") { try await registry.detachVirtualDevice(id: d.id) }
    }

    /// An endpoint hosted before anybody reached it has no tuner to name, so its model reads
    /// `(unknown)`; the same endpoint once the socket opens names the real tuner. Both are the one
    /// radio at the one address, and the registry has to say so or the operator ends up with two.
    func testRegistryHostsOneDevicePerEndpointAcrossFirstOpen() async throws {
        let server = try FakeRTLTCPServer()
        defer { server.stop() }
        let registry = DefaultDeviceRegistry()
        let unreached = RTLTCPDevice(host: "127.0.0.1", port: server.port)
        let waiting = try await registry.attachVirtualDevice(unreached, origin: .operatorFlag).descriptor
        XCTAssertTrue(waiting.model.hasSuffix("(unknown)"), waiting.model)
        let opened = RTLTCPDevice(host: "127.0.0.1", port: server.port)
        try await opened.open()
        let second = try await registry.attachVirtualDevice(opened)
        XCTAssertTrue(second.alreadyHosted)
        XCTAssertEqual(second.descriptor.id, waiting.id)
        let devices = await registry.devices
        XCTAssertEqual(devices.count, 1, "one endpoint is one radio")
        await unreached.close()
    }
}

/// Tiny lock-guarded flags for the in-flight deliver test.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var _done = false
    /// Returns true on every call after the first, so only the first block runs the slow path.
    func enteredOnce() -> Bool { lock.lock(); defer { lock.unlock() }; let was = entered; entered = true; return was }
    func markDone() { lock.lock(); _done = true; lock.unlock() }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
}
