// SPDX-License-Identifier: GPL-3.0-or-later

import CRTLSDR
import Foundation
import Synchronization
import XCTest
@testable import EngineCore

/// Shared helpers: writes small synthetic IQ pairs into a scratch directory.
enum DeviceFixtures {
    static func scratchDir() throws -> String {
        let dir = NSTemporaryDirectory() + "leyline-devices-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// cf32 file whose sample k has I = k, Q = -k (as Float), so ordering is checkable.
    @discardableResult
    static func writeRamp(dir: String, name: String, samples: Int, rate: UInt64 = 48_000, center: UInt64 = 100_000_000) throws -> String {
        let path = dir + "/" + name + ".cf32"
        var floats = [Float](repeating: 0, count: samples * 2)
        for k in 0..<samples {
            floats[2 * k] = Float(k)
            floats[2 * k + 1] = -Float(k)
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: URL(fileURLWithPath: path))
        try IQSidecar(format: "cf32", sampleRate: rate, centerHz: center, samples: UInt64(samples)).save(path: dir + "/" + name + ".json")
        return path
    }
}

final class DevicesIQFileTests: XCTestCase {
    func testSidecarCodableRoundTrip() throws {
        let json = """
        {"format":"cf32","sample_rate":2400000,"center_hz":146520000,"samples":2400000,"created_at_ns":0,
         "anchor":{"host_time_ns":0,"drift_ppm":0},"description":"NFM tone",
         "generator":{"tool":"leyfix","version":"0.1.0","seed":1,"signals":[{"kind":"nfm"}],"noise_dbfs":-60},
         "expect":[{"mode":"NFM","offset_hz":100000,"bandwidth_hz":12500,
                    "audio":{"tone_hz":1000,"min_snr_db":30},"meter":{"power_dbfs_min":-30,"squelch_open":true}}],
         "metadata":{"mode":"NFM","frequency_hz":"146620000"}}
        """
        let sc = try JSONDecoder().decode(IQSidecar.self, from: Data(json.utf8))
        XCTAssertEqual(sc.sampleRate, 2_400_000)
        XCTAssertEqual(sc.centerHz, 146_520_000)
        XCTAssertEqual(sc.samples, 2_400_000)
        XCTAssertEqual(sc.expect?.first?.mode, "NFM")
        XCTAssertEqual(sc.expect?.first?.offsetHz, 100_000)
        XCTAssertEqual(sc.expect?.first?.audio?.toneHz, 1000)
        XCTAssertEqual(sc.expect?.first?.meter?.squelchOpen, true)
        XCTAssertEqual(sc.metadata?["frequency_hz"], "146620000")
        XCTAssertEqual(sc.generator, .object(["tool": .string("leyfix"), "version": .string("0.1.0"), "seed": .number(1),
                                              "signals": .array([.object(["kind": .string("nfm")])]), "noise_dbfs": .number(-60)]))
        let back = try JSONDecoder().decode(IQSidecar.self, from: JSONEncoder().encode(sc))
        XCTAssertEqual(back, sc)
        // Save/load through the path helpers.
        let dir = try DeviceFixtures.scratchDir()
        try sc.save(path: dir + "/x.json")
        XCTAssertEqual(try IQSidecar.load(path: dir + "/x.cf32"), sc)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/x.json"))) as? [String: Any]
        XCTAssertEqual(obj?["sample_rate"] as? Int, 2_400_000)
        XCTAssertEqual((obj?["anchor"] as? [String: Any])?["host_time_ns"] as? Int, 0)
    }

    func testPathHelpers() {
        XCTAssertEqual(IQFilePaths.sidecarPath("/a/b.cf32"), "/a/b.json")
        XCTAssertEqual(IQFilePaths.sidecarPath("/a/b.cu8"), "/a/b.json")
        XCTAssertEqual(IQFilePaths.sidecarPath("/a/b.json"), "/a/b.json")
        XCTAssertEqual(IQFilePaths.samplesPath("/a/b.cu8"), "/a/b.cu8")
        XCTAssertEqual(IQFilePaths.samplesPath("/nonexistent/b.json"), "/nonexistent/b.cf32")
    }

    func testWriterReaderRoundTripCF32() throws {
        let dir = try DeviceFixtures.scratchDir()
        let w = try IQFileWriter(path: dir + "/rt.cf32", sidecar: IQSidecar(sampleRate: 1000, centerHz: 5000))
        let storage = SampleStorage(capacity: 100, format: .cf32)
        let f = storage.view().floats
        for i in 0..<200 { f[i] = Float(i) * 0.5 }
        try w.write(storage.view(count: 100))
        try w.write(storage.view(count: 37))
        try w.finish()
        XCTAssertEqual(w.samplesWritten, 137)
        let r = try IQFileReader(path: dir + "/rt.json", maxBlock: 64)
        XCTAssertEqual(r.sampleCount, 137)
        XCTAssertEqual(r.sidecar.samples, 137)
        XCTAssertEqual(r.sourceFormat, .cf32)
        let out = SampleStorage(capacity: 64, format: .cf32)
        XCTAssertEqual(try r.read(into: out.view()), 64)
        XCTAssertEqual(out.view().floats[1], 0.5)
        XCTAssertEqual(try r.read(into: out.view()), 64)
        XCTAssertEqual(try r.read(into: out.view()), 9)
        // Sample 128 is the second write's sample 28 -> float index 73 of the ramp.
        XCTAssertEqual(out.view().floats[17], 36.5)
        XCTAssertEqual(try r.read(into: out.view()), 0)
        try r.rewind()
        XCTAssertEqual(r.sampleIndex, 0)
        XCTAssertEqual(try r.read(into: out.view()), 64)
    }

    func testReaderConvertsCU8() throws {
        let dir = try DeviceFixtures.scratchDir()
        let bytes: [UInt8] = [0, 255, 127, 128, 255, 0]
        try Data(bytes).write(to: URL(fileURLWithPath: dir + "/raw.cu8"))
        try IQSidecar(format: "cu8", sampleRate: 2_400_000, centerHz: 1).save(path: dir + "/raw.json")
        let r = try IQFileReader(path: dir + "/raw.cu8", maxBlock: 8)
        XCTAssertEqual(r.sourceFormat, .cu8)
        XCTAssertEqual(r.sampleCount, 3)
        let out = SampleStorage(capacity: 8, format: .cf32)
        XCTAssertEqual(try r.read(into: out.view()), 3)
        let f = out.view().floats
        XCTAssertEqual(f[0], -1, accuracy: 1e-6)
        XCTAssertEqual(f[1], 1, accuracy: 1e-6)
        XCTAssertEqual(f[2], -0.5 / 127.5, accuracy: 1e-6)
        XCTAssertEqual(f[3], 0.5 / 127.5, accuracy: 1e-6)
    }
}

/// Collects delivered blocks off the device thread. Copies the first float of each block and the index.
final class DeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var indices: [UInt64] = []
    private(set) var counts: [Int] = []
    private(set) var firstI: [Float] = []
    private(set) var total = 0
    private(set) var firstAt: UInt64 = 0
    private(set) var lastAt: UInt64 = 0

    func record(_ b: SampleBuffer, _ t: SampleTime) {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        if total == 0 { firstAt = now }
        lastAt = now
        indices.append(t.sampleIndex)
        counts.append(b.count)
        firstI.append(b.floats[0])
        total += b.count
    }
}

final class DevicesFilePlaybackTests: XCTestCase {
    func testDescriptor() throws {
        let dir = try DeviceFixtures.scratchDir()
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "desc", samples: 4800, rate: 48_000, center: 7_000_000)
        let dev = try FilePlaybackDevice(path: path, loop: true, realtime: false)
        let d = dev.descriptor
        XCTAssertEqual(d.driver, "file")
        XCTAssertEqual(d.model, "desc.cf32")
        XCTAssertEqual(d.serial.count, 16)
        XCTAssertEqual(d.serial, try FilePlaybackDevice(path: path, loop: false, realtime: false).descriptor.serial, "serial is a stable path hash")
        XCTAssertEqual(d.tuningRanges, [FrequencyRange(minHz: 7_000_000, maxHz: 7_000_000)])
        XCTAssertEqual(d.sampleRates, [48_000])
        XCTAssertEqual(d.nativeFormat, .cf32)
        XCTAssertEqual(d.features["loop"], .flag(true))
        XCTAssertEqual(d.features["duration_s"], .number(0.1))
        XCTAssertEqual(d.features["path"], .text(path))
        XCTAssertEqual(d.state, .available)
    }

    func testControlErrors() async throws {
        let dir = try DeviceFixtures.scratchDir()
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "ctl", samples: 100, center: 7_000_000)
        let dev = try FilePlaybackDevice(path: path, loop: false, realtime: false)
        try await dev.open()
        try await dev.tune(centerHz: 7_000_000)
        try await dev.setSampleRate(48_000)
        await assertCode("FREQ_OUT_OF_RANGE") { try await dev.tune(centerHz: 7_000_001) }
        await assertCode("RATE_UNSUPPORTED") { try await dev.setSampleRate(1) }
        await assertCode("GAIN_ELEMENT_UNKNOWN") { try await dev.setGain(element: "TUNER", value: .auto) }
    }

    func testDeliversExactlyNSamplesInOrderThenDisconnects() async throws {
        let dir = try DeviceFixtures.scratchDir()
        let n = 16384 * 3 + 1234
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "once", samples: n)
        let dev = try FilePlaybackDevice(path: path, loop: false, realtime: false)
        let log = DeliveryLog()
        let states = StateLog()
        dev.setOnStateChange { states.record($0) }
        let cap = CaptureID()
        try await dev.startStreaming(captureID: cap) { log.record($0, $1) }
        try await waitUntil { states.states.contains(.disconnected) }
        await dev.stopStreaming()
        XCTAssertEqual(log.total, n)
        XCTAssertEqual(log.counts, [16384, 16384, 16384, 1234])
        XCTAssertEqual(log.indices, [0, 16384, 32768, 49152])
        XCTAssertEqual(log.firstI, [0, 16384, 32768, 49152])
        XCTAssertEqual(dev.descriptor.state, .disconnected)
        await assertCode("DEVICE_DETACHED") { try await dev.startStreaming(captureID: cap) { _, _ in } }
    }

    func testLoopsWithMonotonicIndices() async throws {
        let dir = try DeviceFixtures.scratchDir()
        let n = 16384 + 100
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "loop", samples: n)
        let dev = try FilePlaybackDevice(path: path, loop: true, realtime: false)
        let log = DeliveryLog()
        try await dev.startStreaming(captureID: CaptureID()) { log.record($0, $1) }
        try await waitUntil { log.total >= n * 3 }
        await dev.stopStreaming()
        XCTAssertGreaterThanOrEqual(log.total, n * 3)
        XCTAssertEqual(dev.descriptor.state, .available)
        for i in 1..<log.indices.count {
            XCTAssertEqual(log.indices[i], log.indices[i - 1] + UInt64(log.counts[i - 1]), "indices continue across the loop point")
        }
        XCTAssertEqual(log.firstI.prefix(4), [0, 16384, 0, 16384])
        // Every start restarts the device's own index at 0, the contract `CaptureDSPCore` rebases on.
        let log2 = DeliveryLog()
        try await dev.startStreaming(captureID: CaptureID()) { log2.record($0, $1) }
        try await waitUntil { log2.total > 0 }
        await dev.stopStreaming()
        XCTAssertEqual(log2.indices.first, 0)
    }

    func testRealtimePacingMatchesWallClock() async throws {
        let dir = try DeviceFixtures.scratchDir()
        let rate: UInt64 = 16384 * 5 * 5 // 0.2 s of file = 5 blocks of 16384
        let n = Int(rate) / 5
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "rt", samples: n, rate: rate)
        let dev = try FilePlaybackDevice(path: path, loop: false, realtime: true)
        let log = DeliveryLog()
        let states = StateLog()
        dev.setOnStateChange { states.record($0) }
        let start = DispatchTime.now().uptimeNanoseconds
        try await dev.startStreaming(captureID: CaptureID()) { log.record($0, $1) }
        try await waitUntil(timeoutS: 5) { states.states.contains(.disconnected) }
        await dev.stopStreaming()
        XCTAssertEqual(log.total, n)
        let elapsed = Double(log.lastAt - start) / 1e9
        // Last block is due at 0.16 s (4/5 of the file); allow scheduler slack on top, none below.
        XCTAssertGreaterThanOrEqual(elapsed, 0.155)
        XCTAssertLessThan(elapsed, 0.6)
    }

    func testReadErrorDisconnectsLikeAnUnplug() async throws {
        let dir = try DeviceFixtures.scratchDir()
        let rate: UInt64 = 16384 * 10 // one block per 0.1 s
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "ioerr", samples: Int(rate), rate: rate)
        // Looping, so reaching the end of the file cannot be what ends this run.
        let dev = try FilePlaybackDevice(path: path, loop: true, realtime: true)
        let reader = try IQFileReader(path: path, maxBlock: FilePlaybackDevice.blockSize)
        let log = DeliveryLog()
        let states = StateLog()
        dev.setOnStateChange { states.record($0) }
        try dev.startStreaming(captureID: CaptureID(), reader: reader) { log.record($0, $1) }
        try await waitUntil { log.total > 0 }
        reader.makeUnreadableForTesting()
        try await waitUntil { states.states.contains(.disconnected) }
        await dev.stopStreaming()
        XCTAssertEqual(dev.descriptor.state, .disconnected)
        XCTAssertGreaterThanOrEqual(log.total, FilePlaybackDevice.blockSize, "the blocks read before the failure still arrive")
    }

    func testStopDoesNotWaitOutTheBlockPacing() async throws {
        let dir = try DeviceFixtures.scratchDir()
        let rate: UInt64 = 16384 // one block per second
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "slow", samples: Int(rate) * 3, rate: rate)
        let dev = try FilePlaybackDevice(path: path, loop: false, realtime: true)
        let log = DeliveryLog()
        try await dev.startStreaming(captureID: CaptureID()) { log.record($0, $1) }
        try await waitUntil { log.total > 0 } // now inside the first second of pacing
        let start = DispatchTime.now().uptimeNanoseconds
        await dev.stopStreaming()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        XCTAssertLessThan(elapsed, 0.25, "cancel cuts the pacing wait short")
        XCTAssertEqual(dev.descriptor.state, .available)
    }

    func testConcurrentStopsBothReturn() async throws {
        let dir = try DeviceFixtures.scratchDir()
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "twostops", samples: 16384 * 3)
        let dev = try FilePlaybackDevice(path: path, loop: false, realtime: false)
        // The I/O thread parks inside `deliver`, so both stops are in flight before the join ends.
        let delivered = CallCount()
        let gate = DispatchSemaphore(value: 0)
        try await dev.startStreaming(captureID: CaptureID()) { _, _ in
            delivered.bump()
            gate.wait()
        }
        try await waitUntil { delivered.value == 1 }
        let returned = CallCount()
        Task.detached { await dev.stopStreaming(); returned.bump() }
        try await Task.sleep(nanoseconds: 50_000_000)
        Task.detached { await dev.stopStreaming(); returned.bump() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(returned.value, 0, "both callers wait for the I/O thread")
        gate.signal()
        try await waitUntil { returned.value == 2 }
        // Both saw a stopped device, so the next stream is accepted.
        try await dev.startStreaming(captureID: CaptureID()) { _, _ in }
        await dev.stopStreaming()
    }
}

/// Counts completions reported from detached tasks.
final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [DeviceState] = []
    var states: [DeviceState] { lock.lock(); defer { lock.unlock() }; return _states }
    func record(_ s: DeviceState) { lock.lock(); _states.append(s); lock.unlock() }
}

func waitUntil(timeoutS: Double = 5, _ cond: @escaping @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeoutS)
    while !cond() {
        if Date() > deadline { throw EngineError(code: "TEST_TIMEOUT", message: "condition not met") }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

func assertCode(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(code)", file: file, line: line)
    } catch let e as EngineError {
        XCTAssertEqual(e.code, code, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}

/// Holds an event iterator so the read can run in a child task; only one child ever touches it.
private final class EventCursor: @unchecked Sendable {
    var iterator: AsyncStream<DeviceEvent>.AsyncIterator
    init(_ it: AsyncStream<DeviceEvent>.AsyncIterator) { iterator = it }
    func next() async -> DeviceEvent? { await iterator.next() }
}

/// Reads the next event, racing the stream against a deadline, so a registry that stops publishing
/// fails the test at the waiting assertion instead of hanging the whole suite.
func next(_ it: inout AsyncStream<DeviceEvent>.AsyncIterator, timeoutS: Double = 5) async throws -> DeviceEvent {
    enum Outcome { case event(DeviceEvent), ended, timedOut }
    let cursor = EventCursor(it)
    defer { it = cursor.iterator }
    let outcome = await withTaskGroup(of: Outcome.self) { group in
        group.addTask { await cursor.next().map(Outcome.event) ?? .ended }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeoutS * 1e9))
            return .timedOut
        }
        let first = await group.next() ?? .timedOut
        group.cancelAll()
        return first
    }
    switch outcome {
    case .event(let e): return e
    case .ended: throw EngineError(code: "TEST_TIMEOUT", message: "stream ended")
    case .timedOut: throw EngineError(code: "TEST_TIMEOUT", message: "no event within \(timeoutS) s")
    }
}

final class DevicesRegistryTests: XCTestCase {
    func testAttachDetachEventsToTwoSubscribers() async throws {
        let dir = try DeviceFixtures.scratchDir()
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "reg", samples: 100)
        let reg = DefaultDeviceRegistry()
        var a = reg.events().makeAsyncIterator()
        var b = reg.events().makeAsyncIterator()

        let desc = try await reg.attachFileDevice(path: path, loop: false)
        XCTAssertEqual(desc.driver, "file")
        for it in [0, 1] {
            let e = it == 0 ? try await next(&a) : try await next(&b)
            guard case .arrived(let d) = e else { return XCTFail("expected arrived, got \(e)") }
            XCTAssertEqual(d, desc)
        }
        let listed = await reg.devices
        XCTAssertEqual(listed, [desc])
        // Same path attached twice is one device.
        let again = try await reg.attachFileDevice(path: path, loop: false)
        XCTAssertEqual(again.id, desc.id)

        // device(id:) hands back the same instance every time.
        let d1 = await reg.device(id: desc.id)
        let d2 = await reg.device(id: desc.id)
        XCTAssertNotNil(d1)
        XCTAssertTrue(d1 === d2)
        XCTAssertTrue(d1 is FilePlaybackDevice)
        XCTAssertEqual(d1?.descriptor.id, desc.id)

        // markInUse publishes changed with full state.
        try await reg.markInUse(id: desc.id, true)
        guard case .changed(let c) = try await next(&a) else { return XCTFail("expected changed") }
        XCTAssertEqual(c.state, .inUse)
        XCTAssertEqual(d1?.descriptor.state, .inUse)
        _ = try await next(&b)
        try await reg.markInUse(id: desc.id, false)
        _ = try await next(&a); _ = try await next(&b)

        try await reg.detachVirtualDevice(id: desc.id)
        guard case .removed(let rid) = try await next(&a) else { return XCTFail("expected removed") }
        XCTAssertEqual(rid, desc.id)
        guard case .removed = try await next(&b) else { return XCTFail("expected removed") }
        let empty = await reg.devices
        XCTAssertTrue(empty.isEmpty)
        let gone = await reg.device(id: desc.id)
        XCTAssertNil(gone)
        await assertCode("DEVICE_NOT_FOUND") { try await reg.detachVirtualDevice(id: desc.id) }
    }

    func testEOFPublishesDisconnected() async throws {
        let dir = try DeviceFixtures.scratchDir()
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "eof", samples: 100)
        let reg = DefaultDeviceRegistry()
        var it = reg.events().makeAsyncIterator()
        let desc = try await reg.attachFileDevice(path: path, loop: false, realtime: false)
        _ = try await next(&it)
        let dev = await reg.device(id: desc.id)!
        try await dev.startStreaming(captureID: CaptureID()) { _, _ in }
        guard case .changed(let c) = try await next(&it) else { return XCTFail("expected changed") }
        XCTAssertEqual(c.state, .disconnected)
        XCTAssertEqual(c.id, desc.id)
        await dev.stopStreaming()
        let still = await reg.device(id: desc.id)
        XCTAssertTrue(still === dev)
        await assertCode("DEVICE_DETACHED") { try await reg.markInUse(id: desc.id, true) }
    }

    func testIDPersistsAcrossInstances() async throws {
        let dir = try DeviceFixtures.scratchDir()
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "persist", samples: 100)
        let mapPath = dir + "/ids/devices.json"
        let first = try await DefaultDeviceRegistry(persistPath: mapPath).attachFileDevice(path: path, loop: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mapPath))
        let second = try await DefaultDeviceRegistry(persistPath: mapPath).attachFileDevice(path: path, loop: true)
        XCTAssertEqual(first.id, second.id)
        let other = try await DefaultDeviceRegistry().attachFileDevice(path: path, loop: false)
        XCTAssertNotEqual(first.id, other.id, "without persistence a fresh registry mints a fresh id")
    }

    func testSubscriberRemovedOnTermination() async throws {
        let reg = DefaultDeviceRegistry()
        do {
            var it = reg.events().makeAsyncIterator()
            let t = Task { await it.next() }
            t.cancel()
            _ = await t.value
        }
        let dir = try DeviceFixtures.scratchDir()
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "term", samples: 10)
        _ = try await reg.attachFileDevice(path: path, loop: false) // must not crash publishing to a dead stream
    }

    /// Attaching a second instance of an already-hosted identity keeps the first and closes the
    /// newcomer: the caller opened it, so nothing else is left holding its link.
    func testDuplicateVirtualDeviceIsClosed() async throws {
        let reg = DefaultDeviceRegistry()
        let first = ClosableVirtualDevice(serial: "vd-1")
        let second = ClosableVirtualDevice(serial: "vd-1")
        let a = try await reg.attachVirtualDevice(first).descriptor
        let b = try await reg.attachVirtualDevice(second).descriptor
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(second.closes, 1, "the discarded instance is closed")
        XCTAssertEqual(first.closes, 0, "the hosted instance keeps running")
        let hosted = await reg.device(id: a.id)
        XCTAssertTrue(hosted === first)
        // Re-attaching the hosted instance itself is still a no-op.
        _ = try await reg.attachVirtualDevice(first).descriptor
        XCTAssertEqual(first.closes, 0)
    }

    /// `stop()` is the registry's shutdown: every `events()` subscription finishes, so a consumer
    /// may wait for the end of its stream instead of relying on its own task being cancelled.
    func testStopFinishesEventSubscriptions() async throws {
        let reg = DefaultDeviceRegistry()
        var it = reg.events().makeAsyncIterator()
        let dir = try DeviceFixtures.scratchDir()
        let path = try DeviceFixtures.writeRamp(dir: dir, name: "fin", samples: 10)
        _ = try await reg.attachFileDevice(path: path, loop: false)
        guard case .arrived = try await next(&it) else { return XCTFail("expected arrived") }
        await reg.stop()
        let end = await it.next()
        XCTAssertNil(end, "stop() finishes the subscription")
    }
}

/// A hosted virtual device that counts `close()` calls.
final class ClosableVirtualDevice: VirtualDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DeviceDescriptor
    var descriptor: DeviceDescriptor { lock.lock(); defer { lock.unlock() }; return stored }
    private let closeCount = Atomic<Int>(0)
    var closes: Int { closeCount.load(ordering: .relaxed) }

    init(serial: String) {
        stored = DeviceDescriptor(id: DeviceID(), driver: "test-virtual", model: "closable", serial: serial,
                                  tuningRanges: [FrequencyRange(minHz: 0, maxHz: 1_000_000_000)],
                                  sampleRates: [2_400_000], nativeFormat: .cf32)
    }

    func assignID(_ id: DeviceID) { lock.lock(); stored.id = id; lock.unlock() }
    func setState(_ state: DeviceState) { lock.lock(); stored.state = state; lock.unlock() }
    func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) {}

    var gains: [GainState] { [] }
    func open() async throws {}
    func close() async { closeCount.add(1, ordering: .relaxed) }
    func tune(centerHz: UInt64) async throws {}
    func setSampleRate(_ hz: UInt64) async throws {}
    func setGain(element: String, value: GainValue) async throws { throw EngineError.gainElementUnknown(element, target: "") }
    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {}
    func stopStreaming() async {}
}

final class DevicesRTLSDRTests: XCTestCase {
    /// These two tests describe the no-hardware case (CI runners, the Linux stub); a dongle plugged
    /// into the developer's machine would be opened for real, so they skip when one is present.
    private func skipIfDongleAttached() throws {
        try XCTSkipIf(rtlsdr_get_device_count() > 0, "an RTL-SDR is attached; hardware-free assertions do not apply")
    }

    func testEnumerateWithoutHardware() async throws {
        try skipIfDongleAttached()
        // The stub librtlsdr reports zero devices; enumeration and a poll must be no-ops.
        XCTAssertEqual(RTLSDRDevice.enumerate(), [])
        let reg = DefaultDeviceRegistry(pollIntervalMs: 20)
        await reg.start()
        await reg.poll()
        try await Task.sleep(nanoseconds: 60_000_000)
        await reg.stop()
        let devices = await reg.devices
        XCTAssertTrue(devices.isEmpty)
    }

    /// A pulled dongle makes librtlsdr cancel read_async itself, so it returns 0 without our asking.
    /// That must still be treated as device loss: `.disconnected`, hook fired, `streamError` set.
    func testReadAsyncReturningZeroWithoutCancelIsDeviceLoss() {
        let probe = RTLSDRProbe(index: 0, name: "Generic RTL2832U", manufacturer: "Realtek", product: "RTL2838UHIDIR",
                                serial: "00000002", tuner: "R820T", gainsDB: [0, 49.6],
                                tuningRanges: RTLSDRDevice.tunerInfo(RTLSDR_TUNER_R820T).ranges)
        let device = RTLSDRDevice(probe: probe, id: DeviceID())
        let fired = expectation(description: "state hook")
        device.setOnStateChange { state in
            XCTAssertEqual(state, .disconnected)
            fired.fulfill()
        }
        XCTAssertNil(device.streamError)
        device.readAsyncReturned(0)
        wait(for: [fired], timeout: 1)
        XCTAssertEqual(device.descriptor.state, .disconnected)
        XCTAssertEqual(device.streamError?.code, "DEVICE_IO")
        // Non-zero results are device loss too.
        let other = RTLSDRDevice(probe: probe, id: DeviceID())
        other.readAsyncReturned(-4)
        XCTAssertEqual(other.descriptor.state, .disconnected)
        XCTAssertNotNil(other.streamError)
    }

    /// `open()` runs through `BlockingWork`; with the stub librtlsdr (zero devices) the
    /// rtlsdr_open failure must still surface as DEVICE_IO with the device id as target.
    func testOpenWithoutHardwareThrowsDeviceIO() async throws {
        try skipIfDongleAttached()
        let probe = RTLSDRProbe(index: 0, name: "Generic RTL2832U", manufacturer: "Realtek", product: "RTL2838UHIDIR",
                                serial: "00000003", tuner: "R820T", gainsDB: [0, 49.6],
                                tuningRanges: RTLSDRDevice.tunerInfo(RTLSDR_TUNER_R820T).ranges)
        let id = DeviceID()
        let device = RTLSDRDevice(probe: probe, id: id)
        do {
            try await device.open()
            XCTFail("open() must fail without hardware")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "DEVICE_IO")
            XCTAssertEqual(e.target, id.string)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        await device.close()
    }

    func testTunerTable() {
        XCTAssertEqual(RTLSDRDevice.tunerInfo(RTLSDR_TUNER_R820T).ranges, [FrequencyRange(minHz: 24_000_000, maxHz: 1_766_000_000)])
        XCTAssertEqual(RTLSDRDevice.tunerInfo(RTLSDR_TUNER_E4000).ranges.count, 2)
        XCTAssertEqual(RTLSDRDevice.tunerInfo(RTLSDR_TUNER_FC0012).name, "FC0012")
        let probe = RTLSDRProbe(index: 0, name: "Generic RTL2832U", manufacturer: "Realtek", product: "RTL2838UHIDIR",
                                serial: "00000001", tuner: "R820T", gainsDB: [0, 0.9, 49.6],
                                tuningRanges: RTLSDRDevice.tunerInfo(RTLSDR_TUNER_R820T).ranges)
        let d = RTLSDRDevice(probe: probe, id: DeviceID()).descriptor
        XCTAssertEqual(d.driver, "rtlsdr")
        XCTAssertEqual(d.model, "RTL2838UHIDIR")
        XCTAssertEqual(d.nativeFormat, .cu8)
        XCTAssertEqual(d.gainElements.first?.name, "TUNER")
        XCTAssertEqual(d.gainElements.first?.validDB, [0, 0.9, 49.6])
        XCTAssertEqual(d.gainElements.first?.supportsAuto, true)
        XCTAssertEqual(d.features["tuner"], .text("R820T"))
        XCTAssertEqual(d.sampleRates.count, 10)
    }
}

/// Malformed-input hardening for the file pair.
final class DevicesMalformedInputTests: XCTestCase {
    private func writeSidecarJSON(dir: String, name: String, sampleRate: String) throws {
        let json = #"{"format":"cf32","sample_rate":"# + sampleRate + #","center_hz":100000000}"#
        try json.write(toFile: dir + "/" + name + ".json", atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 8 * 16).write(to: URL(fileURLWithPath: dir + "/" + name + ".cf32"))
    }

    func testSidecarSampleRateOutOfRangeIsInvalidArgument() throws {
        let dir = try DeviceFixtures.scratchDir()
        try writeSidecarJSON(dir: dir, name: "zero", sampleRate: "0")
        try writeSidecarJSON(dir: dir, name: "huge", sampleRate: "1000000000000000")
        try writeSidecarJSON(dir: dir, name: "low", sampleRate: "999")
        try writeSidecarJSON(dir: dir, name: "top", sampleRate: "100000000")
        for name in ["zero", "huge", "low"] {
            XCTAssertThrowsError(try IQSidecar.load(path: dir + "/\(name).json"), name) {
                XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT", name)
            }
            XCTAssertThrowsError(try FilePlaybackDevice(path: dir + "/\(name).cf32", loop: false, realtime: false), name) {
                XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT", name)
            }
        }
        XCTAssertNoThrow(try IQSidecar.load(path: dir + "/top.json"))
        XCTAssertThrowsError(try IQSidecar(sampleRate: 0, centerHz: 1).validate()) {
            XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
        }
    }

    func testOversizedSidecarIsInvalidArgument() throws {
        let dir = try DeviceFixtures.scratchDir()
        let padding = String(repeating: " ", count: Int(IQSidecar.maxSidecarBytes) + 1)
        try (#"{"format":"cf32","sample_rate":48000,"center_hz":1}"# + padding)
            .write(toFile: dir + "/big.json", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try IQSidecar.load(path: dir + "/big.json")) {
            XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
        }
    }

    func testFIFOSamplesFileIsRejectedWithoutBlocking() throws {
        let dir = try DeviceFixtures.scratchDir()
        try IQSidecar(format: "cf32", sampleRate: 48_000, centerHz: 1).save(path: dir + "/fifo.json")
        guard mkfifo(dir + "/fifo.cf32", 0o600) == 0 else { throw XCTSkip("mkfifo unavailable: \(errno)") }
        let started = Date()
        XCTAssertThrowsError(try IQFileReader(path: dir + "/fifo.cf32")) {
            XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
        }
        XCTAssertThrowsError(try FilePlaybackDevice(path: dir + "/fifo.json", loop: false, realtime: false)) {
            XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a FIFO must be rejected, not opened (which blocks)")
    }

    func testFIFOSidecarIsRejectedWithoutBlocking() throws {
        let dir = try DeviceFixtures.scratchDir()
        try Data(repeating: 0, count: 64).write(to: URL(fileURLWithPath: dir + "/sc.cf32"))
        guard mkfifo(dir + "/sc.json", 0o600) == 0 else { throw XCTSkip("mkfifo unavailable: \(errno)") }
        let started = Date()
        XCTAssertThrowsError(try IQSidecar.load(path: dir + "/sc.cf32")) {
            XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testDirectoryIsInvalidArgument() throws {
        let dir = try DeviceFixtures.scratchDir()
        try FileManager.default.createDirectory(atPath: dir + "/d.cf32", withIntermediateDirectories: true)
        XCTAssertThrowsError(try FilePlaybackDevice(path: dir, loop: false, realtime: false)) {
            XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
        }
        XCTAssertThrowsError(try FilePlaybackDevice(path: dir + "/d.cf32", loop: false, realtime: false)) {
            XCTAssertEqual(($0 as? EngineError)?.code, "INVALID_ARGUMENT")
        }
    }

    func testMissingFileStaysDeviceIO() {
        XCTAssertThrowsError(try FilePlaybackDevice(path: "/nonexistent/leyline/x.cf32", loop: false, realtime: false)) {
            XCTAssertEqual(($0 as? EngineError)?.code, "DEVICE_IO")
        }
    }
}
