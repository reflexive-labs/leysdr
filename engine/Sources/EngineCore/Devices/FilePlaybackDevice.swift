// FilePlaybackDevice: a virtual RadioDevice that replays an IQ file (docs/fixtures.md) through the
// same delivery path as hardware. Paced to real time by default; `realtime: false` runs flat out.

import Foundation

/// Replays `<name>.cf32|.cu8` + sidecar as a `RadioDevice`. See docs/engine-internals.md "Devices".
public final class FilePlaybackDevice: RadioDevice, @unchecked Sendable {
    /// Samples per delivered block (docs/engine-internals.md "Block size").
    public static let blockSize = 16384

    public let path: String
    public let loop: Bool
    public let realtime: Bool
    public let sidecar: IQSidecar
    /// Total complex samples in the file.
    public let sampleCount: UInt64

    private let lock = NSLock()
    private var _descriptor: DeviceDescriptor
    private var _onStateChange: (@Sendable (DeviceState) -> Void)?
    private var thread: Thread?
    private var streaming = false
    /// Set by stopStreaming; read by the I/O thread each block.
    private var cancelled = false
    private let joined = DispatchSemaphore(value: 0)
    private var runningIndex: UInt64 = 0

    /// Opens the file pair at `path` (samples or sidecar path). Throws DEVICE_IO / INVALID_ARGUMENT.
    public init(path: String, loop: Bool, realtime: Bool = true) throws {
        let abs = URL(fileURLWithPath: path).standardizedFileURL.path
        let reader = try IQFileReader(path: abs, maxBlock: 1)
        self.path = abs
        self.loop = loop
        self.realtime = realtime
        sidecar = reader.sidecar
        sampleCount = reader.sampleCount
        let rate = reader.sampleRate
        let center = reader.centerHz
        let duration = rate > 0 ? Double(sampleCount) / Double(rate) : 0
        _descriptor = DeviceDescriptor(
            id: DeviceID(),
            driver: "file",
            model: URL(fileURLWithPath: reader.samplesPath).lastPathComponent,
            serial: FilePlaybackDevice.stableHash(abs),
            usbLocation: "",
            state: .available,
            tuningRanges: [FrequencyRange(minHz: center, maxHz: center)],
            sampleRates: [rate],
            nativeFormat: .cf32,
            gainElements: [],
            providesTimestamps: false,
            features: [
                "loop": .flag(loop),
                "duration_s": .number(duration),
                "path": .text(abs),
            ]
        )
    }

    /// Stable 64-bit FNV-1a hash of the absolute path, rendered as 16 hex digits.
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16).leftPadded(to: 16)
    }

    public var descriptor: DeviceDescriptor {
        lock.lock(); defer { lock.unlock() }
        return _descriptor
    }

    public var gains: [GainState] { [] }

    /// Called (from the I/O thread) whenever the device's state flips, e.g. `.disconnected` at EOF.
    /// The registry installs this to publish `changed`/`removed`.
    public func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) {
        lock.lock(); _onStateChange = hook; lock.unlock()
    }

    /// Assigns the registry-issued stable id (replaces the provisional one from init).
    public func assignID(_ id: DeviceID) {
        lock.lock(); _descriptor.id = id; lock.unlock()
    }

    /// Registry use: records an externally decided state (`.inUse` / `.available`) without firing
    /// the hook — the registry already knows. Safe from any thread.
    public func setState(_ state: DeviceState) {
        lock.lock(); _descriptor.state = state; lock.unlock()
    }

    /// Device-originated transition (EOF → `.disconnected`): updates state and fires the hook.
    private func transition(to state: DeviceState) {
        lock.lock()
        let changed = _descriptor.state != state
        _descriptor.state = state
        let hook = _onStateChange
        lock.unlock()
        if changed { hook?(state) }
    }

    public func open() async throws {
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw EngineError.deviceIO("IQ file is not readable", target: path)
        }
    }

    public func close() async { await stopStreaming() }

    public func tune(centerHz: UInt64) async throws {
        guard descriptor.canTune(centerHz) else {
            throw EngineError.freqOutOfRange(centerHz, target: descriptor.id.string)
        }
    }

    public func setSampleRate(_ hz: UInt64) async throws {
        guard descriptor.sampleRates.contains(hz) else {
            throw EngineError.rateUnsupported(hz, target: descriptor.id.string)
        }
    }

    public func setGain(element: String, value: GainValue) async throws {
        throw EngineError.gainElementUnknown(element, target: descriptor.id.string)
    }

    // MARK: Streaming

    public func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        try beginStreaming()
        // The reader and scratch are created here, on the control plane, never on the I/O thread.
        let reader: IQFileReader
        do { reader = try IQFileReader(path: path, maxBlock: FilePlaybackDevice.blockSize) } catch {
            withLock { streaming = false }
            throw error
        }
        let storage = SampleStorage(capacity: FilePlaybackDevice.blockSize, format: .cf32)
        let t = Thread { [self] in
            self.runLoop(reader: reader, storage: storage, captureID: captureID, deliver: deliver)
        }
        t.name = "leyline.file.\(captureID.string)"
        t.qualityOfService = .userInteractive
        withLock { thread = t }
        t.start()
    }

    public func stopStreaming() async {
        let wasStreaming: Bool = withLock {
            guard streaming else { return false }
            cancelled = true
            return true
        }
        guard wasStreaming else { return }
        // Join: the I/O thread signals `joined` exactly once when it exits.
        joined.wait()
        withLock { streaming = false; thread = nil }
    }

    /// Synchronous critical section; never called with the lock already held.
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func beginStreaming() throws {
        try withLock {
            if streaming { throw EngineError.deviceBusy(_descriptor.id.string) }
            if _descriptor.state == .disconnected { throw EngineError.deviceDetached(_descriptor.id.string) }
            streaming = true
            cancelled = false
        }
    }

    private func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// I/O thread body. Pacing is against the absolute start time so sleep jitter never accumulates.
    private func runLoop(reader: IQFileReader, storage: SampleStorage, captureID: CaptureID,
                         deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) {
        defer { joined.signal() }
        let rate = Double(max(reader.sampleRate, 1))
        let start = DispatchTime.now().uptimeNanoseconds
        var delivered: UInt64 = 0 // samples delivered since this start, for pacing
        var hitEOF = false
        while !isCancelled() {
            let n: Int
            do { n = try reader.read(into: storage.view()) } catch { break }
            if n == 0 {
                if loop, reader.sampleCount > 0, (try? reader.rewind()) != nil { continue }
                hitEOF = true
                break
            }
            if realtime {
                // Block i may be delivered once wall time reaches start + (samples so far) / rate.
                let due = start + UInt64(Double(delivered) / rate * 1e9)
                let now = DispatchTime.now().uptimeNanoseconds
                if due > now {
                    var ts = timespec(tv_sec: Int((due - now) / 1_000_000_000), tv_nsec: Int((due - now) % 1_000_000_000))
                    var rem = timespec()
                    while nanosleep(&ts, &rem) != 0 && errno == EINTR { ts = rem }
                }
                if isCancelled() { break }
            }
            deliver(storage.view(count: n), SampleTime(captureID: captureID, sampleIndex: runningIndex))
            runningIndex &+= UInt64(n)
            delivered &+= UInt64(n)
        }
        if hitEOF {
            // Ran off the end: this device is gone, exactly like an unplug. `streaming` stays set so
            // the owner's stopStreaming still performs the (already-complete) join.
            transition(to: .disconnected)
        }
    }
}

extension String {
    /// Zero-pads on the left to `width` characters.
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
