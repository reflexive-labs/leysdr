// SPDX-License-Identifier: GPL-3.0-or-later

// Telemetry over the daemon: every record lost between the DSP thread and the wire shows as a
// gap in seq.

@testable import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
@testable import LeylineServer
import LeylineProto
import XCTest

extension DaemonTests {
    /// A drain that falls behind the telemetry ring loses the oldest readings; the subscriber sees every
    /// eviction as a `seq` gap instead of a silently contiguous stream.
    func testTelemetrySeqGapsAfterQueueOverflow() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("fixture missing: \(fixture)") }
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixture
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            let anyEngine = await c.daemon.store.channelEngine(ChannelID(string: channel.channelID)!)
            let engine = try XCTUnwrap(anyEngine as? DefaultChannelEngine)
            let queue = engine.telemetryQueue
            let capID = CaptureID(string: capture.captureID)!
            func squelchRecord(_ index: UInt64) -> ChannelTelemetryRecord {
                ChannelTelemetryRecord(kind: .squelch, time: SampleTime(captureID: capID, sampleIndex: index), powerDBFS: 0, snrDB: 0, squelchOpen: true)
            }

            // Squelch is off, so every squelch transition this subscription receives is one the test pushed
            // (tagged by sample index). Meters stay subscribed so the live channel keeps the RPC flowing.
            // The DSP thread's own 10 Hz meter pushes overlap the microsecond burst only by coincidence.
            var sub = Leyline_V1_TelemetrySubscription()
            sub.channelID = channel.channelID
            let burst = UInt64(queue.capacity * 8)
            let lastIndex = burst + 1
            let collector = TelemetryCollector()
            // Leave only once a meter follows the last pushed record, so the server has no backlog in
            // flight when the client goes away (an in-flight write can otherwise outlive the RPC).
            let rpc = Task {
                try await c.telemetry.subscribe(sub, metadata: testMetadata) { response in
                    var sawLast = false
                    for try await m in response.messages {
                        await collector.append(m)
                        if case .squelch? = m.body, m.time.sampleIndex == lastIndex { sawLast = true }
                        else if sawLast, case .meter? = m.body { break }
                    }
                }
            }
            func pushed(_ all: [Leyline_V1_TelemetryMsg]) -> [Leyline_V1_TelemetryMsg] {
                all.filter { if case .squelch? = $0.body { return true } else { return false } }
            }
            // Probe until the server-side drain is attached (index 1 may arrive more than once).
            let deadline = Date().addingTimeInterval(10)
            while await pushed(collector.messages).isEmpty, Date() < deadline {
                queue.push(squelchRecord(1))
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let probed = await pushed(collector.messages).count
            XCTAssertGreaterThan(probed, 0, "subscription never delivered the probe")
            // Push the burst faster than the drain task can pop: the ring overflows and evicts oldest-first.
            for i in 2...lastIndex { queue.push(squelchRecord(i)) }
            while await pushed(collector.messages).last?.time.sampleIndex != lastIndex, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let watchdog = Task { try await Task.sleep(nanoseconds: 5_000_000_000); rpc.cancel() }
            _ = try? await rpc.value
            watchdog.cancel()

            let all = await collector.messages
            let msgs = pushed(all).filter { $0.time.sampleIndex >= 2 }
            XCTAssertEqual(msgs.last?.time.sampleIndex, lastIndex, "the newest record always survives an overflow")
            XCTAssertLessThan(UInt64(msgs.count), burst, "the burst must overflow the ring (\(queue.capacity) slots)")
            XCTAssertGreaterThan(engine.telemetryDropped, 0)
            let seqs = all.map(\.seq)
            XCTAssertEqual(seqs, seqs.sorted(), "seq must be monotonic")
            XCTAssertEqual(Set(seqs).count, seqs.count, "seq must be unique")
            let jumps = zip(seqs, seqs.dropFirst()).map { $1 - $0 }
            XCTAssertGreaterThan(jumps.max() ?? 0, 1, "evictions must show up as a seq gap")
            // Every pushed record was either delivered (+1) or evicted (+1): seq runs ahead of the delivered count.
            if let last = msgs.last, let position = all.firstIndex(where: { $0.seq == last.seq }) {
                XCTAssertGreaterThan(last.seq, UInt64(position + 1), "seq advances past the delivered count by the evictions")
            }
        }
    }

    /// The same accounting when the *reader* stalls instead of the ring: the service's `write` is held,
    /// the merged buffer (and the fan-out buffer behind it) overflow and discard their oldest items, and
    /// every record lost downstream of the ring still widens `seq`: it advances by exactly the number of
    /// records pushed, whether they were delivered or lost in any of the three buffers.
    func testTelemetrySeqGapsAfterReaderStall() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("fixture missing: \(fixture)") }
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixture
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            let anyEngine = await c.daemon.store.channelEngine(ChannelID(string: channel.channelID)!)
            let engine = try XCTUnwrap(anyEngine as? DefaultChannelEngine)
            let queue = engine.telemetryQueue
            let capID = CaptureID(string: capture.captureID)!
            func squelchRecord(_ index: UInt64) -> ChannelTelemetryRecord {
                ChannelTelemetryRecord(kind: .squelch, time: SampleTime(captureID: capID, sampleIndex: index), powerDBFS: 0, snrDB: 0, squelchOpen: true)
            }

            // Squelch transitions only: every message this subscription delivers is one the test pushed,
            // and the DSP thread's 10 Hz meters are filtered out by the drain (they can only reach `seq`
            // by being lost upstream of it, which a stalled writer alone never causes).
            var sub = Leyline_V1_TelemetrySubscription()
            sub.channelID = channel.channelID
            sub.types = [.squelchTransition]
            let collector = TelemetryCollector()
            let gate = TestGate()
            let writer = RPCWriter(wrapping: StallingTelemetryWriter(collector: collector, gate: gate))
            let service = TelemetryService(store: c.daemon.store, jobs: c.daemon.jobs)
            let descriptor = MethodDescriptor(fullyQualifiedService: "leyline.v1.Telemetry", method: "Subscribe")
            let cancellation = LockedValue<ServerContext.RPCCancellationHandle?>(nil)
            // Drive the service directly with a writer we can hold, so the stall is deterministic.
            let rpc = Task {
                try await withServerContextRPCCancellationHandle { handle in
                    cancellation.value = handle
                    let context = ServerContext(descriptor: descriptor, remotePeer: "test", localPeer: "test", cancellation: handle)
                    try await ClientContext.$current.withValue(ClientContext(id: "stall-test", kind: "test", label: "stall")) {
                        try await service.subscribe(request: sub, response: writer, context: context)
                    }
                }
            }
            // Probe until the server-side drain is attached (index 1 may arrive more than once).
            let deadline = Date().addingTimeInterval(10)
            while await collector.messages.isEmpty, Date() < deadline {
                queue.push(squelchRecord(1))
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let probeDelivered = await !collector.messages.isEmpty
            XCTAssertTrue(probeDelivered, "subscription never delivered the probe")
            // Let any in-flight probe land before the writer stalls: every index-1 record then counts as delivered.
            try await Task.sleep(nanoseconds: 100_000_000)
            let probes = await collector.messages.count
            let windowStart = Date()
            await gate.close()
            let evictedBefore = engine.telemetryDropped
            // Burst in rounds the ring can absorb, so most records survive the ring and pile into the
            // fan-out and merged buffers, which (with `write` held) discard all but their newest.
            let rounds = 8
            let burst = rounds * queue.capacity
            let lastIndex = UInt64(burst) + 1
            var next: UInt64 = 2
            for _ in 0..<rounds {
                for _ in 0..<queue.capacity { queue.push(squelchRecord(next)); next += 1 }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(next, lastIndex + 1)
            // Let the drains settle into the full merged buffer; nothing gets through the held writer.
            try await Task.sleep(nanoseconds: 200_000_000)
            let heldCount = await collector.messages.count
            XCTAssertEqual(heldCount, probes, "nothing is delivered while the writer is held")
            await gate.open()
            while await collector.messages.last?.time.sampleIndex != lastIndex, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let windowSeconds = Date().timeIntervalSince(windowStart)
            cancellation.value?.cancel()
            let watchdog = Task { try await Task.sleep(nanoseconds: 5_000_000_000); rpc.cancel() }
            _ = try? await rpc.value
            watchdog.cancel()

            let all = await collector.messages
            XCTAssertTrue(all.allSatisfy { if case .squelch? = $0.body { return true } else { return false } }, "meters are filtered out")
            let delivered = all.filter { $0.time.sampleIndex >= 2 }
            XCTAssertEqual(delivered.last?.time.sampleIndex, lastIndex, "the newest record survives every drop-oldest buffer")
            XCTAssertLessThan(delivered.count, burst, "the stall must lose records")
            let evicted = engine.telemetryDropped - evictedBefore
            let lostDownstream = burst - evicted - delivered.count
            XCTAssertGreaterThan(lostDownstream, 0, "the stall must lose records in the fan-out/merged buffers, not only the ring")
            let seqs = all.map(\.seq)
            XCTAssertEqual(seqs, seqs.sorted(), "seq must be monotonic")
            XCTAssertEqual(Set(seqs).count, seqs.count, "seq must be unique")
            // Every record pushed after the first delivered message was delivered (+1) or lost (+1 via a gap),
            // wherever it was lost. Meters pushed inside the window are filtered, so they add to `seq` only
            // if the ring or the fan-out evicted one — at 10 Hz that bounds the slack.
            let first = try XCTUnwrap(all.first)
            let last = try XCTUnwrap(delivered.last)
            let extraProbes = UInt64(all.filter { $0.time.sampleIndex == 1 }.count - 1)
            let expected = extraProbes + UInt64(burst)
            let advance = last.seq - first.seq
            let meterSlack = UInt64(windowSeconds * 10) + 2
            XCTAssertGreaterThanOrEqual(advance, expected, "seq must account for every lost record (\(lostDownstream) lost past the ring)")
            XCTAssertLessThanOrEqual(advance, expected + meterSlack, "seq must not count more than was pushed")
        }
    }
}

/// Accumulates telemetry messages from a streaming RPC for polling from the test body.
actor TelemetryCollector {
    private(set) var messages: [Leyline_V1_TelemetryMsg] = []
    func append(_ m: Leyline_V1_TelemetryMsg) { messages.append(m) }
}

/// A latch for tests: `wait()` suspends callers while the gate is closed; `open()` releases them all.
actor TestGate {
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func close() { closed = true }

    func open() {
        closed = false
        let resumed = waiters
        waiters = []
        for w in resumed { w.resume() }
    }

    func wait() async {
        guard closed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A telemetry response writer that records every message and, while `gate` is closed, holds the
/// service inside `write` — what a client that stopped reading looks like from the server side.
struct StallingTelemetryWriter: RPCWriterProtocol {
    typealias Element = Leyline_V1_TelemetryMsg
    let collector: TelemetryCollector
    let gate: TestGate

    func write(_ element: Element) async throws {
        await gate.wait()
        await collector.append(element)
    }

    func write(contentsOf elements: some Sequence<Element>) async throws {
        for e in elements { try await write(e) }
    }
}
