// In-process daemon on a temp UDS, driven by the generated Swift client.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// Identity the tests send on every RPC.
let testClientID = "cli_" + ULID().string
let testMetadata: Metadata = [
    "leyline-client-id": .string(testClientID),
    "leyline-client-kind": .string("cli"),
    "leyline-client-label": .string("xctest"),
]

/// Path to a generated fixture (`leyfix generate` if absent).
func fixturePath(_ name: String) -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return root.appendingPathComponent("fixtures/\(name)").path
}

struct DaemonClients {
    let control: Leyline_V1_Control.Client<HTTP2ClientTransport.Posix>
    let telemetry: Leyline_V1_Telemetry.Client<HTTP2ClientTransport.Posix>
    let bulk: Leyline_V1_Bulk.Client<HTTP2ClientTransport.Posix>
    let jobs: Leyline_V1_Jobs.Client<HTTP2ClientTransport.Posix>
    let resources: Leyline_V1_Resources.Client<HTTP2ClientTransport.Posix>
    let daemon: Daemon
    let socketPath: String
}

/// Boots a daemon on a temp socket, runs `body` with connected clients, then shuts down.
/// `shutdownDeadlineNs` puts a watchdog on the teardown: tests about handlers ending on cancellation
/// need shutdown to be prompt, and a hung handler shows up here rather than as a stalled suite.
func withDaemon(presenceGraceNs: UInt64 = 5_000_000_000, shutdownDeadlineNs: UInt64? = nil,
                _ body: @escaping @Sendable (DaemonClients) async throws -> Void) async throws {
    let dir = NSTemporaryDirectory() + "leyline-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let socket = dir + "/d.sock"
    let daemon = Daemon(config: .init(socketPath: socket, pidfile: dir + "/leylined.pid", pollMs: 100_000, presenceGraceNs: presenceGraceNs))
    let serverTask = Task { try await daemon.run() }
    let listening = await daemon.waitUntilListening()
    XCTAssertTrue(listening, "daemon did not start listening")
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/leylined.pid"))
    var bodyError: (any Error)?
    do {
        try await withGRPCClient(
            transport: try .http2NIOPosix(target: .unixDomainSocket(path: socket), transportSecurity: .plaintext)
        ) { client in
            let clients = DaemonClients(
                control: .init(wrapping: client), telemetry: .init(wrapping: client),
                bulk: .init(wrapping: client), jobs: .init(wrapping: client), resources: .init(wrapping: client), daemon: daemon, socketPath: socket
            )
            do { try await body(clients) } catch { bodyError = error }
        }
    } catch {
        if bodyError == nil { bodyError = error }
    }
    let teardownStart = DispatchTime.now().uptimeNanoseconds
    if let deadline = shutdownDeadlineNs {
        let stopped = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await daemon.shutdown(); _ = try? await serverTask.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: deadline); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(stopped, "daemon.shutdown() did not finish within \(Double(deadline) / 1e9) s (a handler is still alive)")
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - teardownStart, deadline)
    } else {
        await daemon.shutdown()
        _ = try? await serverTask.value
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: socket), "socket not unlinked on shutdown")
    if let e = bodyError { throw e }
}

/// Collects WatchEvents into an array; `stop()` cancels the RPC.
actor EventCollector {
    private(set) var events: [Leyline_V1_Event] = []
    private var task: Task<Void, Never>?

    func append(_ e: Leyline_V1_Event) { events.append(e) }
    func setTask(_ t: Task<Void, Never>) { task = t }

    func stop() { task?.cancel() }

    /// Starts watching and returns once the daemon holds the subscription, so anything a test changes
    /// afterwards is guaranteed to reach this collector. Response headers only say the client reached
    /// the service, which is a weaker promise than the store having the subscriber.
    static func start(_ control: Leyline_V1_Control.Client<HTTP2ClientTransport.Posix>, daemon: Daemon) async -> EventCollector {
        let before = await daemon.store.subscriberCount
        let c = EventCollector()
        let t = Task {
            var scope = Leyline_V1_EventScope()
            scope.daemon = true
            try? await control.watchEvents(scope, metadata: testMetadata) { response in
                for try await ev in response.messages { await c.append(ev) }
            }
        }
        await c.setTask(t)
        for _ in 0..<1000 {
            if await daemon.store.subscriberCount > before { return c }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("watch subscription never registered with the store")
        return c
    }

    /// Polls until an event matching `pred` arrives (timeout in ms).
    func waitFor(timeoutMs: Int = 3000, _ pred: (Leyline_V1_Event) -> Bool) async -> Leyline_V1_Event? {
        for _ in 0..<(timeoutMs / 20) {
            if let e = events.first(where: pred) { return e }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return events.first(where: pred)
    }
}

/// The stable engine code from a failed RPC (status message "CODE: ..." plus the trailer).
func errorCode(_ error: any Error) -> (code: String, trailer: Leyline_V1_ErrorDetail?) {
    guard let rpc = error as? RPCError else { return ("", nil) }
    let code = rpc.message.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    var detail: Leyline_V1_ErrorDetail?
    for bytes in rpc.metadata[binaryValues: "leyline-error-bin"] {
        detail = try? Leyline_V1_ErrorDetail(serializedBytes: bytes)
    }
    return (code, detail)
}

/// The devices a test created. A developer's Mac may have a real dongle plugged in while the suite
/// runs; every registry poll enumerates it, so assertions about "the" device list must ignore it.
func testDevices(_ devices: [Leyline_V1_DeviceDescriptor]) -> [Leyline_V1_DeviceDescriptor] {
    devices.filter { $0.driver != "rtlsdr" }
}

func testDevices(_ devices: [DeviceDescriptor]) -> [DeviceDescriptor] {
    devices.filter { $0.driver != "rtlsdr" }
}
