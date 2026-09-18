// SPDX-License-Identifier: GPL-3.0-or-later

// Daemon assembly and lifecycle (docs/dev/engine-internals.md "Daemon lifecycle").

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import LeylineProto
import Logging
import Synchronization

/// Everything a running daemon owns: device registry, session store, bulk registry and the gRPC
/// server on a UDS. `run()` serves until `shutdown()`; tests drive the same object in-process.
final class Daemon: @unchecked Sendable {
    struct Config {
        var socketPath: String
        var pidfile: String?
        var pollMs: Int = 1000
        /// false hides the machine's USB dongles from this daemon: it hosts only what is attached
        /// to it (file devices, rtl_tcp). For a daemon that must be hermetic, such as an eval's.
        var enumerateHardware: Bool = true
        /// Presence grace before non-persistent channels of absent clients are reaped.
        var presenceGraceNs: UInt64 = 5_000_000_000
        var registryPersistPath: String? = nil
        /// Remote dongles (rtl_tcp servers) to attach at startup. Failures are logged, never fatal.
        var rtltcp: [RTLTCPEndpoint] = []
        /// The remembered attach list; nil puts `devices.json` beside the socket.
        var devicesPath: String? = nil
        /// Where to look for decoder plugins, in order: the `--decoders` flags and
        /// `LEYLINE_DECODERS`, then the platform default (docs/design/decoders.md, "Decisions":
        /// "Manifest: a file, not a flag"). A test names one directory of its own.
        var decoderSearchPath: [String] = [defaultDecodersPath()]
        /// Where kept records live, and the retention applied to them.
        var storePath: String = defaultStorePath()
        var storeCapBytes: UInt64 = 2 << 30
        var storeAgeDays: UInt32 = 90
        /// Where recordings live, and the retention applied to them. The cap is a fixed number in
        /// one flag rather than a fraction of free space: predictable, and the same shape as the
        /// kept-records store (docs/design/recording.md, "Retention").
        var recordingsPath: String = defaultRecordingsPath()
        var recordingsCapBytes: UInt64 = 20 << 30
        var recordingsAgeDays: UInt32 = 0
    }

    /// A parsed `--rtltcp host:port`.
    struct RTLTCPEndpoint: Equatable {
        var host: String
        var port: UInt16
    }

    /// Parses `host:port` / `[v6::addr]:port` strings. Throws INVALID_ARGUMENT on a malformed entry.
    static func parseRTLTCPEndpoints(_ specs: [String]) throws -> [RTLTCPEndpoint] {
        try specs.map { spec in
            guard let colon = spec.lastIndex(of: ":"), colon != spec.startIndex,
                  let port = UInt16(spec[spec.index(after: colon)...]), port > 0 else {
                throw EngineError.invalidArgument("--rtltcp expects host:port, got \"\(spec)\"", target: spec)
            }
            var host = String(spec[..<colon])
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            guard !host.isEmpty else { throw EngineError.invalidArgument("--rtltcp expects host:port, got \"\(spec)\"", target: spec) }
            return RTLTCPEndpoint(host: host, port: port)
        }
    }

    let config: Config
    let registry: DefaultDeviceRegistry
    let store: SessionStore
    /// rtl_tcp endpoints the station keeps across restarts.
    let remembered: RememberedDevices
    let streams: StreamRegistry
    let jobs: JobStore
    private let server: GRPCServer<HTTP2ServerTransport.Posix>
    private let log = Logger(label: "leyline.daemon")
    private let teardown = TeardownGate()

    init(config: Config) {
        self.config = config
        registry = DefaultDeviceRegistry(persistPath: config.registryPersistPath, pollIntervalMs: config.pollMs,
                                         enumerateHardware: config.enumerateHardware)
        let info = DaemonInfo(version: leylinedVersion, pid: Int64(getpid()), startedAtNs: realtimeNs(), socketPath: config.socketPath)
        remembered = RememberedDevices(path: config.devicesPath ?? RememberedDevices.pathBeside(socket: config.socketPath))
        store = SessionStore(registry: registry, info: info, presenceGraceNs: config.presenceGraceNs, remembered: remembered)
        streams = StreamRegistry(store: store)
        let allocator = SessionCaptureAllocator(store: store)
        let decoders = DecoderRegistry(searchPath: config.decoderSearchPath)
        let recordStore = RecordStore(directory: config.storePath, capBytes: config.storeCapBytes, ageDays: config.storeAgeDays)
        let recordings = RecordingStore(directory: config.recordingsPath, capBytes: config.recordingsCapBytes,
                                        ageDays: config.recordingsAgeDays)
        jobs = JobStore(store: store, allocator: allocator, decoders: decoders, records: recordStore,
                        recordings: recordings)
        // Transport policy for a local, user-trusted socket. The default keepalive policy counts any
        // client PING arriving sooner than five minutes after the previous one as a strike while a
        // stream is open and sends GOAWAY on the third strike — but grpc-go pings for bandwidth
        // estimation whenever data flows, so a busy bulk stream got its connection dropped after
        // about a second. Pings are harmless here; allow them at any rate.
        var transport = HTTP2ServerTransport.Posix.Config.defaults
        transport.connection.keepalive.clientBehavior = .init(minPingIntervalWithoutCalls: .zero, allowWithoutCalls: true)
        server = GRPCServer(
            transport: .http2NIOPosix(address: .unixDomainSocket(path: config.socketPath), transportSecurity: .plaintext, config: transport),
            services: [
                ControlService(store: store, recordings: recordings),
                TelemetryService(store: store, jobs: jobs),
                BulkService(store: store, registry: streams),
                JobsService(jobs: jobs, store: store),
                DecodersService(jobs: jobs, store: store),
                ResourcesService(jobs: jobs, store: store),
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
            throw EngineError(code: EngineError.Code.socketInUse, message: "another leylined is listening on \(path)", target: path)
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
        // Retention at start, as the design doc says: a store over its cap or its age is trimmed
        // before anything new is written to it.
        await jobs.records.retain()
        // A recording the last daemon was still writing is closed rather than resumed: the part's
        // WAV header is repaired from the file's length and the manifest says `restart`. A
        // recording is a bounded artefact (docs/design/recording.md, "Retune, detach and restart").
        await jobs.repairRecordings()
        await attachRemoteDongles()
        await store.startDeviceMirror()
        await streams.install()
        // Kept decode jobs the last daemon was running come back once a radio is here (DEC-11).
        await jobs.resumeKept()
        let table = jobs
        await store.setJobsProvider { await table.snapshot() }
        await store.setClientGoneHook { await table.clientGone($0) }
        log.info("leylined \(leylinedVersion) listening on \(config.socketPath)")
        var served: (any Error)?
        do { try await server.serve() } catch { served = error }
        // The listener stops at the top of `shutdown()`, long before the captures and devices go,
        // so the socket and pidfile wait for teardown to finish: while those paths exist a second
        // daemon takes itself for the live one and races this one for the radios.
        await teardown.wait()
        try? FileManager.default.removeItem(atPath: config.socketPath)
        if let pid = config.pidfile { try? FileManager.default.removeItem(atPath: pid) }
        if let served { throw served }
    }

    /// Opens and attaches every rtl_tcp source the daemon starts with: the `--rtltcp` flags first,
    /// then the endpoints remembered from earlier attaches, deduplicated on `host:port` so an
    /// endpoint named both ways is opened once and belongs to the flag, which is what makes it the
    /// operator's rather than a client's. A server that cannot be reached is hosted anyway, as a
    /// `DISCONNECTED` device the registry's reconnect poll keeps calling: one dead remote never
    /// keeps the daemon from serving local dongles, and a Pi that is merely off joins the moment it
    /// answers.
    func attachRemoteDongles() async {
        var seen: Set<String> = []
        let flagged = config.rtltcp.map { (endpoint: $0, origin: VirtualDeviceOrigin.operatorFlag) }
        let saved = await remembered.list().map {
            (endpoint: RTLTCPEndpoint(host: $0.host, port: $0.port), origin: VirtualDeviceOrigin.client)
        }
        for (ep, origin) in (flagged + saved).filter({ seen.insert("\($0.endpoint.host):\($0.endpoint.port)").inserted }) {
            let device = RTLTCPDevice(host: ep.host, port: ep.port)
            var reached = true
            do {
                try await device.open()
            } catch {
                reached = false
                // The reconnect poll only retries devices the registry holds, so hosting this one
                // disconnected is what gives it a way back.
                device.setState(.disconnected)
                log.warning("rtl_tcp \(ep.host):\(ep.port) is not answering (\(error)); hosting it and waiting")
            }
            do {
                let attachment = try await registry.attachVirtualDevice(device, origin: origin)
                let id = attachment.descriptor.id.string
                if attachment.alreadyHosted {
                    log.info("rtl_tcp \(ep.host):\(ep.port) already attached as \(id)")
                } else if reached {
                    log.info("attached rtl_tcp \(ep.host):\(ep.port) as \(id) (\(device.tunerName))")
                } else {
                    log.info("attached rtl_tcp \(ep.host):\(ep.port) as \(id), disconnected")
                }
            } catch {
                log.error("rtl_tcp \(ep.host):\(ep.port): \(error)")
                await device.close()
            }
        }
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

    /// Graceful stop: the listener stops accepting first, then streams close, captures stop and
    /// devices close.
    func shutdown() async {
        log.info("shutting down")
        teardown.arm()
        defer { teardown.open() }
        // First of all: teardown takes seconds (a running sweep can hold a capture for ~3 s), and an
        // RPC accepted during that window would build state after the store that owns it is gone.
        server.beginGracefulShutdown()
        // Before the store: a running sweep holds a lease on a capture and must give it back
        // while there is still a store to give it back to.
        await jobs.cancelAll()
        await streams.closeAll()
        await store.shutdown()
        await registry.stop()
    }
}

/// A one-shot gate with a single waiter, used to hold the daemon's socket and pidfile until
/// teardown has finished. `arm()` closes it, `open()` releases the waiter, and a wait on a gate
/// that was never armed returns at once. Waiting ends on cancellation, like any stream read.
final class TeardownGate: Sendable {
    private let armed = Mutex(false)
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func arm() {
        armed.withLock { $0 = true }
    }

    func open() {
        continuation.finish()
    }

    func wait() async {
        guard armed.withLock({ $0 }) else { return }
        for await _ in stream {}
    }
}
