// Daemon assembly and lifecycle (docs/engine-internals.md "Daemon lifecycle").

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import LeylineProto
import Logging

/// The version reported in `DaemonInfo` and by `--version`.
let leylinedVersion = "0.1.0-dev"

/// Everything a running daemon owns: device registry, session store, bulk registry and the gRPC
/// server on a UDS. `run()` serves until `shutdown()`; tests drive the same object in-process.
final class Daemon: @unchecked Sendable {
    struct Config {
        var socketPath: String
        var pidfile: String?
        var pollMs: Int = 1000
        /// Presence grace before non-persistent channels of absent clients are reaped.
        var presenceGraceNs: UInt64 = 5_000_000_000
        var registryPersistPath: String? = nil
    }

    let config: Config
    let registry: DefaultDeviceRegistry
    let store: SessionStore
    let streams: StreamRegistry
    private let server: GRPCServer<HTTP2ServerTransport.Posix>
    private let log = Logger(label: "leyline.daemon")

    init(config: Config) {
        self.config = config
        registry = DefaultDeviceRegistry(persistPath: config.registryPersistPath, pollIntervalMs: config.pollMs)
        let info = DaemonInfo(version: leylinedVersion, pid: Int64(getpid()), startedAtNs: realtimeNs(), socketPath: config.socketPath)
        store = SessionStore(registry: registry, info: info, presenceGraceNs: config.presenceGraceNs)
        streams = StreamRegistry(store: store)
        server = GRPCServer(
            transport: .http2NIOPosix(address: .unixDomainSocket(path: config.socketPath), transportSecurity: .plaintext),
            services: [
                ControlService(store: store),
                TelemetryService(store: store),
                BulkService(store: store, registry: streams),
                JobsService(),
                ResourcesService(),
            ],
            interceptors: [ClientContextInterceptor()]
        )
    }

    /// Removes a stale socket file (nothing listening) or throws if a live daemon owns it.
    static func prepareSocket(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            return
        }
        if socketIsLive(path: path) {
            throw EngineError(code: "SOCKET_IN_USE", message: "another leylined is listening on \(path)", target: path)
        }
        try FileManager.default.removeItem(atPath: path)
    }

    /// True when a connect() to the UDS succeeds.
    static func socketIsLive(path: String) -> Bool {
        // Glibc imports SOCK_STREAM as the `__socket_type` enum; Darwin as a plain Int32.
        #if os(Linux)
        let sockType = Int32(SOCK_STREAM.rawValue)
        #else
        let sockType = SOCK_STREAM
        #endif
        let fd = socket(AF_UNIX, sockType, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutablePointer(to: &addr.sun_path) { ptr -> Bool in
            let cap = MemoryLayout.size(ofValue: ptr.pointee)
            guard path.utf8.count < cap else { return false }
            ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                _ = path.withCString { strcpy(dst, $0) }
            }
            return true
        }
        guard ok else { return false }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
    }

    /// Prepares the socket, writes the pidfile, starts device polling and the store mirror, then
    /// serves until `shutdown()`. Cleans up the socket and pidfile on the way out.
    func run() async throws {
        try Self.prepareSocket(path: config.socketPath)
        if let pid = config.pidfile {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: pid).deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(getpid())\n".write(toFile: pid, atomically: true, encoding: .utf8)
        }
        await registry.start()
        await store.startDeviceMirror()
        await streams.install()
        log.info("leylined \(leylinedVersion) listening on \(config.socketPath)")
        defer {
            try? FileManager.default.removeItem(atPath: config.socketPath)
            if let pid = config.pidfile { try? FileManager.default.removeItem(atPath: pid) }
        }
        try await server.serve()
    }

    /// Waits until the listener is accepting connections (for in-process tests).
    func waitUntilListening(timeoutNs: UInt64 = 5_000_000_000) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNs
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if (try? await server.listeningAddress) != nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// Graceful stop: streams closed, captures stopped and devices closed, then the server drains.
    func shutdown() async {
        log.info("shutting down")
        await streams.closeAll()
        await store.shutdown()
        await registry.stop()
        server.beginGracefulShutdown()
    }
}
