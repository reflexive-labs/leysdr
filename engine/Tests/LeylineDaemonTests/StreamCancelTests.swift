import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// FU-3: a streaming RPC the client cancels ends its daemon-side handler even when no traffic is
/// flowing (RPC cancellation is not task cancellation in grpc-swift). Observable two ways: the client's
/// presence drops (its ephemeral channel is reaped after the 300 ms grace) and shutdown stays prompt.
final class StreamCancelTests: XCTestCase {
    private let other: Metadata = ["leyline-client-id": .string("cli_CANCEL"), "leyline-client-kind": .string("app")]

    /// A playback capture plus one ephemeral channel owned by `other`; returns (capture, channel).
    private func setUp(_ c: DaemonClients, fixture: String) async throws -> (Leyline_V1_Capture, Leyline_V1_Channel) {
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
        cch.offsetHz = 0
        cch.bandwidthHz = 12_500
        cch.mode = .nfm
        let channel = try await c.control.createChannel(cch, metadata: other)
        return (capture, channel)
    }

    /// Polls GetState until `channel` is gone (the presence reaper ran) or `timeoutMs` elapses.
    private func waitReaped(_ c: DaemonClients, _ channel: String, timeoutMs: Int = 2000) async throws -> Bool {
        for _ in 0..<(timeoutMs / 50) {
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            if !state.channels.contains(where: { $0.channelID == channel }) { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// `withDaemon` with a watchdog on the teardown: shutdown + serve exit must finish within 2 s.
    private func withPromptShutdown(_ body: @escaping @Sendable (DaemonClients) async throws -> Void) async throws {
        let dir = NSTemporaryDirectory() + "leyline-cancel-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socket = dir + "/d.sock"
        let daemon = Daemon(config: .init(socketPath: socket, pidfile: dir + "/leylined.pid", pollMs: 100_000, presenceGraceNs: 300_000_000))
        let serverTask = Task { try await daemon.run() }
        let listening = await daemon.waitUntilListening()
        XCTAssertTrue(listening, "daemon did not start listening")
        var bodyError: (any Error)?
        do {
            try await withGRPCClient(transport: try .http2NIOPosix(target: .unixDomainSocket(path: socket), transportSecurity: .plaintext)) { client in
                let clients = DaemonClients(control: .init(wrapping: client), telemetry: .init(wrapping: client),
                                            bulk: .init(wrapping: client), jobs: .init(wrapping: client), resources: .init(wrapping: client), daemon: daemon, socketPath: socket)
                do { try await body(clients) } catch { bodyError = error }
            }
        } catch {
            if bodyError == nil { bodyError = error }
        }
        let started = DispatchTime.now()
        let stopped = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await daemon.shutdown(); _ = try? await serverTask.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(stopped, "daemon.shutdown() did not complete within 2 s (handler still alive after client cancel)")
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds, 2_000_000_000)
        if let e = bodyError { throw e }
    }

    func testWatchEventsEndsOnClientCancel() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("fixture missing: \(fixture)") }
        try await withPromptShutdown { c in
            let (_, channel) = try await self.setUp(c, fixture: fixture)
            // Opened after the setup traffic: nothing will be emitted while it is open.
            let watch = Task {
                var scope = Leyline_V1_EventScope()
                scope.daemon = true
                try await c.control.watchEvents(scope, metadata: self.other) { r in for try await _ in r.messages {} }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            var state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.channels.contains { $0.channelID == channel.channelID }, "channel held while the watch is open")
            watch.cancel()
            _ = try? await watch.value
            let reaped = try await self.waitReaped(c, channel.channelID)
            XCTAssertTrue(reaped, "cancelled WatchEvents must release the client's presence")
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.channels.count, 0)
        }
    }

    func testBulkStreamEndsOnClientCancelWithoutFrames() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("fixture missing: \(fixture)") }
        try await withPromptShutdown { c in
            let (capture, channel) = try await self.setUp(c, fixture: fixture)
            var req = Leyline_V1_SubscribeRequest()
            req.captureID = capture.captureID
            req.kind = .fft
            req.fft.bins = 512
            req.fft.rowsPerSecond = 0.1  // first row is 10 s out: no frame inside the test window
            let desc = try await c.bulk.subscribe(req, metadata: self.other)
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            let reader = Task {
                try await c.bulk.stream(ref, metadata: self.other) { r in for try await _ in r.messages {} }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            var state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.channels.contains { $0.channelID == channel.channelID }, "channel held while the stream is open")
            reader.cancel()
            _ = try? await reader.value
            let reaped = try await self.waitReaped(c, channel.channelID)
            XCTAssertTrue(reaped, "cancelled Bulk.Stream must release the client's presence")
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.channels.count, 0)
        }
    }
}
