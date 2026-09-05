// RTLTCPDevice: a virtual RadioDevice that speaks the osmocom rtl_tcp protocol to a dongle served on
// another machine. BSD sockets only (no Network framework) so it builds and tests on Linux. See
// docs/engine-internals.md "Devices".
//
// Wire protocol: on connect the server sends 12 bytes — magic "RTL0", u32be tuner type, u32be tuner
// gain count — then streams raw cu8 I/Q forever. Commands are 5 bytes (u8 opcode + u32be argument),
// never acknowledged. The server serves one client and drops it if it does not read fast enough, so
// the reader thread does nothing but recv into a preallocated block and hand it to `deliver`.

import Foundation
import Logging
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class RTLTCPDevice: VirtualDevice, @unchecked Sendable {
    /// Samples per delivered block (docs/engine-internals.md "Block size"); 32768 bytes of cu8.
    public static let blockSize = 16384
    /// Same list as `RTLSDRDevice` — the remote end is librtlsdr.
    public static let sampleRates = RTLSDRDevice.sampleRates
    /// Connect and per-read timeout. A server that stops sending for this long is `.disconnected`.
    public static let timeoutSeconds: Int32 = 5

    /// rtl_tcp opcodes (rtl_tcp.c `command` switch).
    enum Op: UInt8 {
        case setFrequency = 0x01, setSampleRate = 0x02, setGainMode = 0x03, setGain = 0x04
        case setFreqCorrection = 0x05, setAGCMode = 0x08, setDirectSampling = 0x09
        case setGainByIndex = 0x0d, setBiasTee = 0x0e
    }

    public let host: String
    public let port: UInt16

    private static let logger = Logger(label: "leyline.rtltcp")
    /// Device lock; a condition so `stopStreaming` can wait for the reader to leave `deliver`.
    private let lock = NSCondition()
    private var _descriptor: DeviceDescriptor
    private var _onStateChange: (@Sendable (DeviceState) -> Void)?
    private var fd: Int32 = -1
    private var thread: Thread?
    private let joined = DispatchSemaphore(value: 0)
    /// Set by close(): the reader's exit is deliberate, not a link loss.
    private var closing = false
    private var streaming = false
    /// True while the reader thread is inside `deliver` (set/cleared under `lock`).
    private var inDeliver = false
    /// Bumped by every startStreaming so the reader restarts its sample index at 0.
    private var generation: UInt64 = 0
    private var deliver: (@Sendable (SampleBuffer, SampleTime) -> Void)?
    private var captureID = CaptureID()
    private var centerHz: UInt64
    private var sampleRate: UInt64
    private var gain: GainValue = .auto
    private var features: [String: FeatureValue]
    /// The one block buffer the reader thread fills; allocated once here, never on the I/O thread.
    private let storage = SampleStorage(capacity: RTLTCPDevice.blockSize, format: .cu8)
    /// From the server header (valid after open()).
    public private(set) var tunerName = "unknown"
    public private(set) var tunerGainCount: UInt32 = 0

    public init(host: String, port: UInt16, sampleRate: UInt64 = 2_400_000) {
        self.host = host
        self.port = port
        self.sampleRate = sampleRate
        let info = RTLSDRDevice.tunerInfo(code: 0)
        centerHz = 100_000_000
        features = [
            "tuner": .text(info.name),
            "remote": .text("\(host):\(port)"),
            "bias_tee": .flag(false),
            "direct_sampling": .integer(0),
            "ppm_correction": .integer(0),
            "rtl_agc": .flag(false),
        ]
        _descriptor = RTLTCPDevice.makeDescriptor(id: DeviceID(), host: host, port: port, tuner: info.name,
                                                  ranges: info.ranges, gainCount: 0, features: features)
    }

    deinit { if fd >= 0 { RTLTCPDevice.closeFD(fd) } }

    /// Descriptor for a header (tuner code + gain count). Gain element `TUNER` carries librtlsdr's
    /// fixed table for the reported tuner (the header only says how many entries the server has, so
    /// a count that disagrees with the table is logged — the remote driver is not stock librtlsdr).
    static func makeDescriptor(id: DeviceID, host: String, port: UInt16, tuner: String, ranges: [FrequencyRange],
                               gainCount: UInt32, features: [String: FeatureValue]) -> DeviceDescriptor {
        let table = RTLSDRDevice.knownGainTableDB(tuner: tuner)
        if gainCount != 0, Int(gainCount) != table.count {
            logger.warning("rtl_tcp \(host):\(port) reports \(gainCount) gains for \(tuner); librtlsdr's table has \(table.count)")
        }
        let element = GainElement(
            name: "TUNER",
            minDB: table.min() ?? 0,
            maxDB: table.max() ?? 0,
            stepDB: 0,
            supportsAuto: true,
            validDB: table
        )
        return DeviceDescriptor(
            id: id,
            driver: "rtltcp",
            model: "rtl_tcp \(host):\(port) (\(tuner))",
            serial: "\(host):\(port)",
            usbLocation: "",
            state: .available,
            tuningRanges: ranges,
            sampleRates: sampleRates,
            nativeFormat: .cu8,
            gainElements: [element],
            providesTimestamps: false,
            features: features
        )
    }

    public var descriptor: DeviceDescriptor {
        lock.lock(); defer { lock.unlock() }
        return _descriptor
    }

    public var gains: [GainState] {
        lock.lock(); defer { lock.unlock() }
        return [GainState(element: "TUNER", value: gain)]
    }

    // MARK: Registry hooks (VirtualDevice)

    public func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) {
        lock.lock(); _onStateChange = hook; lock.unlock()
    }

    public func assignID(_ id: DeviceID) {
        lock.lock(); _descriptor.id = id; lock.unlock()
    }

    /// Registry use: records `.inUse` / `.available` without firing the hook.
    public func setState(_ state: DeviceState) {
        lock.lock(); _descriptor.state = state; lock.unlock()
    }

    /// Device-originated transition (link lost → `.disconnected`): updates state, stops delivery
    /// and fires the hook outside the lock.
    private func transition(to state: DeviceState) {
        lock.lock()
        let changed = _descriptor.state != state
        _descriptor.state = state
        if state == .disconnected { deliver = nil; streaming = false }
        let hook = _onStateChange
        lock.unlock()
        if changed { hook?(state) }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: Sockets

    private static func closeFD(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }

    private static func shutdownFD(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
        #else
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        #endif
    }

    private static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }

    /// Resolves `host:port` and connects with a bounded wait. Returns a blocking socket whose reads
    /// time out after `timeoutSeconds`. Throws DEVICE_IO.
    static func connect(host: String, port: UInt16, timeoutSeconds: Int32) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let target = "\(host):\(port)"
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw EngineError.deviceIO("cannot resolve \(host): \(String(cString: gai_strerror(rc)))", target: target)
        }
        defer { freeaddrinfo(first) }
        var lastError = "no addresses"
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            guard fd >= 0 else { lastError = String(cString: strerror(errno)); continue }
            #if !os(Linux)
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            setNonBlocking(fd, true)
            #if canImport(Glibc)
            var connected = Glibc.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0
            #else
            var connected = Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0
            #endif
            if !connected, errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, timeoutSeconds * 1000) > 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 { connected = true }
                    else { lastError = String(cString: strerror(err)) }
                } else {
                    lastError = "connect timed out after \(timeoutSeconds) s"
                }
            } else if !connected {
                lastError = String(cString: strerror(errno))
            }
            guard connected else { closeFD(fd); continue }
            setNonBlocking(fd, false)
            var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            return fd
        }
        throw EngineError.deviceIO("connect to \(target) failed: \(lastError)", target: target)
    }

    /// Reads exactly `count` bytes (blocking, subject to SO_RCVTIMEO). Returns false on EOF/timeout.
    private static func readFully(_ fd: Int32, into base: UnsafeMutableRawPointer, count: Int) -> Bool {
        var filled = 0
        while filled < count {
            let n = recv(fd, base + filled, count - filled, 0)
            if n > 0 { filled += n; continue }
            if n < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    /// Sends one 5-byte command. Caller holds the lock (writes are serialized; the reader never
    /// writes, so this never contends with the I/O thread). Throws DEVICE_IO on a dead socket.
    private func sendCommand(_ op: Op, _ arg: UInt32) throws {
        guard fd >= 0 else { throw EngineError.deviceIO("rtl_tcp device is not open", target: _descriptor.id.string) }
        var frame: (UInt8, UInt8, UInt8, UInt8, UInt8) = (
            op.rawValue, UInt8(arg >> 24), UInt8((arg >> 16) & 0xff), UInt8((arg >> 8) & 0xff), UInt8(arg & 0xff)
        )
        let ok: Bool = withUnsafeBytes(of: &frame) { raw in
            var sent = 0
            while sent < 5 {
                #if os(Linux)
                let n = send(fd, raw.baseAddress! + sent, 5 - sent, Int32(MSG_NOSIGNAL))
                #else
                let n = send(fd, raw.baseAddress! + sent, 5 - sent, 0)
                #endif
                if n > 0 { sent += n; continue }
                if n < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        guard ok else { throw EngineError.deviceIO("rtl_tcp write failed: \(String(cString: strerror(errno)))", target: _descriptor.id.string) }
    }

    // MARK: RadioDevice

    /// Connects, parses the header, builds the descriptor, pushes the initial sample rate and
    /// frequency, then starts the reader thread. Idempotent while connected.
    public func open() async throws {
        guard withLock({ fd < 0 }) else { return }
        // Connect and read the header with the lock released: both block for up to `timeoutSeconds`
        // and `descriptor`/`gains` must stay responsive meanwhile.
        let target = "\(host):\(port)"
        let sock = try RTLTCPDevice.connect(host: host, port: port, timeoutSeconds: RTLTCPDevice.timeoutSeconds)
        var header = [UInt8](repeating: 0, count: 12)
        let got = header.withUnsafeMutableBytes { RTLTCPDevice.readFully(sock, into: $0.baseAddress!, count: 12) }
        guard got else {
            RTLTCPDevice.closeFD(sock)
            throw EngineError.deviceIO("rtl_tcp header not received", target: target)
        }
        guard header[0] == 0x52, header[1] == 0x54, header[2] == 0x4c, header[3] == 0x30 else {
            RTLTCPDevice.closeFD(sock)
            throw EngineError.deviceIO("not an rtl_tcp server (bad magic)", target: target)
        }
        func be32(_ i: Int) -> UInt32 {
            UInt32(header[i]) << 24 | UInt32(header[i + 1]) << 16 | UInt32(header[i + 2]) << 8 | UInt32(header[i + 3])
        }
        try withLock {
            // A concurrent open() won the race: keep its connection, drop ours.
            guard fd < 0 else { RTLTCPDevice.closeFD(sock); return }
            let info = RTLSDRDevice.tunerInfo(code: be32(4))
            tunerName = info.name
            tunerGainCount = be32(8)
            features["tuner"] = .text(info.name)
            if !info.ranges.contains(where: { $0.contains(centerHz) }) { centerHz = info.ranges.first?.minHz ?? centerHz }
            _descriptor = RTLTCPDevice.makeDescriptor(id: _descriptor.id, host: host, port: port, tuner: info.name,
                                                      ranges: info.ranges, gainCount: tunerGainCount, features: features)
            _descriptor.state = .available
            fd = sock
            closing = false
            do {
                try sendCommand(.setSampleRate, UInt32(clamping: sampleRate))
                try sendCommand(.setFrequency, UInt32(clamping: centerHz))
            } catch {
                RTLTCPDevice.closeFD(sock); fd = -1
                throw error
            }
            let t = Thread { [self] in self.readLoop(sock) }
            t.name = "leyline.rtltcp.\(host):\(port)"
            t.qualityOfService = .userInteractive
            thread = t
            t.start()
            RTLTCPDevice.logger.info("connected to rtl_tcp \(target): tuner \(info.name), \(tunerGainCount) gains")
        }
    }

    /// Shuts the socket down, joins the reader and releases the descriptor. Safe to call twice.
    public func close() async {
        let (sock, t): (Int32, Thread?) = withLock {
            closing = true
            streaming = false
            deliver = nil
            if fd >= 0 { RTLTCPDevice.shutdownFD(fd) }
            return (fd, thread)
        }
        if t != nil { joined.wait() }
        withLock {
            thread = nil
            if sock >= 0 { RTLTCPDevice.closeFD(sock) }
            fd = -1
        }
    }

    public func tune(centerHz hz: UInt64) async throws {
        try withLock {
            guard _descriptor.canTune(hz) else { throw EngineError.freqOutOfRange(hz, target: _descriptor.id.string) }
            try sendCommand(.setFrequency, UInt32(clamping: hz))
            centerHz = hz
        }
    }

    /// Sent live; rtl_tcp applies it to the running dongle, so no restart is needed. The block
    /// count per second changes, the sample index does not reset.
    public func setSampleRate(_ hz: UInt64) async throws {
        try withLock {
            guard RTLTCPDevice.sampleRates.contains(hz) else { throw EngineError.rateUnsupported(hz, target: _descriptor.id.string) }
            try sendCommand(.setSampleRate, UInt32(clamping: hz))
            sampleRate = hz
        }
    }

    public func setGain(element: String, value: GainValue) async throws {
        try withLock {
            guard element == "TUNER", let el = _descriptor.gainElement(named: element) else {
                throw EngineError.gainElementUnknown(element, target: _descriptor.id.string)
            }
            switch value {
            case .auto:
                try sendCommand(.setGainMode, 0)
                gain = .auto
            case .db(let requested):
                let db = el.snapped(requested)
                try sendCommand(.setGainMode, 1)
                try sendCommand(.setGain, UInt32(bitPattern: Int32((db * 10).rounded())))
                gain = .db(db)
            }
        }
    }

    /// Applies one of the descriptor's settable features (`bias_tee`, `direct_sampling`,
    /// `ppm_correction`, `rtl_agc`). `tuner` and `remote` are read-only. Unknown → INVALID_ARGUMENT.
    public func setFeature(_ name: String, _ value: FeatureValue) async throws {
        try withLock {
            switch (name, value) {
            case ("bias_tee", .flag(let on)):
                try sendCommand(.setBiasTee, on ? 1 : 0)
            case ("direct_sampling", .integer(let mode)):
                guard (0...2).contains(mode) else { throw EngineError.invalidArgument("direct_sampling must be 0, 1 or 2", target: name) }
                try sendCommand(.setDirectSampling, UInt32(mode))
            case ("ppm_correction", .integer(let ppm)):
                try sendCommand(.setFreqCorrection, UInt32(bitPattern: Int32(clamping: ppm)))
            case ("rtl_agc", .flag(let on)):
                try sendCommand(.setAGCMode, on ? 1 : 0)
            case ("tuner", _), ("remote", _):
                throw EngineError.invalidArgument("feature \(name) is read-only", target: name)
            default:
                throw EngineError.invalidArgument("unknown or mistyped feature", target: name)
            }
            features[name] = value
            _descriptor.features = features
        }
    }

    // MARK: Streaming

    /// The socket is already flowing; this only arms delivery. Sample index restarts at 0.
    public func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        try withLock {
            if streaming { throw EngineError.deviceBusy(_descriptor.id.string) }
            if _descriptor.state == .disconnected { throw EngineError.deviceDetached(_descriptor.id.string) }
            guard fd >= 0, thread != nil else { throw EngineError.deviceIO("rtl_tcp device is not open", target: _descriptor.id.string) }
            self.captureID = captureID
            self.deliver = deliver
            generation &+= 1
            streaming = true
        }
    }

    /// Disarms delivery; the connection stays up (the reader keeps draining so the server does not
    /// drop us). Returns once the reader can no longer be inside `deliver`.
    public func stopStreaming() async {
        disarmAndWaitForReader()
    }

    /// Synchronous body of stopStreaming. The reader snapshots (streaming, deliver) and raises
    /// `inDeliver` in one critical section, so once we hold the lock it either never enters
    /// `deliver` again or is inside it right now: wait that call out before returning.
    private func disarmAndWaitForReader() {
        lock.lock(); defer { lock.unlock() }
        streaming = false
        deliver = nil
        while inDeliver { lock.wait() }
    }

    /// I/O thread body. No allocation, no Swift concurrency: recv straight into `storage`, snapshot
    /// the delivery state under the lock once per block, call `deliver` with the lock released.
    private func readLoop(_ sock: Int32) {
        defer { joined.signal() }
        let bytesPerBlock = RTLTCPDevice.blockSize * SampleFormat.cu8.bytesPerSample
        let base = storage.base
        var filled = 0
        var index: UInt64 = 0
        var gen: UInt64 = 0
        var lostLink = false
        var readErrno: Int32 = 0
        while true {
            let n = recv(sock, base + filled, bytesPerBlock - filled, 0)
            if n < 0, errno == EINTR { continue }
            if n <= 0 {
                // 0: peer closed (or our own shutdown); <0: timeout (EAGAIN) or a socket error.
                readErrno = n < 0 ? errno : 0
                lock.lock(); let deliberate = closing; lock.unlock()
                lostLink = !deliberate
                break
            }
            filled += n
            guard filled == bytesPerBlock else { continue }
            filled = 0
            lock.lock()
            let cb = streaming ? deliver : nil
            let cap = captureID
            let g = generation
            inDeliver = cb != nil
            lock.unlock()
            guard let cb else { continue }
            if g != gen { gen = g; index = 0 }
            cb(storage.view(), SampleTime(captureID: cap, sampleIndex: index))
            index &+= UInt64(RTLTCPDevice.blockSize)
            lock.lock(); inDeliver = false; lock.broadcast(); lock.unlock()
        }
        if lostLink {
            RTLTCPDevice.logger.warning("rtl_tcp \(host):\(port) link lost (\(readErrno == 0 ? "peer closed" : String(cString: strerror(readErrno))))")
            transition(to: .disconnected)
        }
    }
}
