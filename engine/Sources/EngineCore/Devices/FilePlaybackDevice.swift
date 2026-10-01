// SPDX-License-Identifier: GPL-3.0-or-later

// FilePlaybackDevice: a virtual RadioDevice that replays an IQ file (docs/reference/iq-files.md) through the
// same delivery path as hardware. Paced to real time by default; `realtime: false` runs flat out.

import Foundation
import Logging

/// Replays `<name>.cf32|.cu8` + sidecar as a `RadioDevice`. See docs/dev/engine-internals.md "Devices".
/// Unchecked Sendable: mutable state is read and written under `lock`; the reader and the sample index belong to the I/O thread.
package final class FilePlaybackDevice: VirtualDevice, @unchecked Sendable {
    /// Samples per delivered block (docs/dev/engine-internals.md "Block size").
    package static let blockSize = 16384
    /// `DeviceDescriptor.driver` value every file-playback device reports.
    package static let driverName = "file"

    package let path: String
    package let loop: Bool
    package let realtime: Bool
    package let sidecar: IQSidecar
    /// Total complex samples in the file.
    package let sampleCount: UInt64

    private static let logger = Logger(label: "leyline.file")
    /// Device lock; a condition so the pacing wait wakes the moment `stopStreaming` cancels.
    private let lock = NSCondition()
    private var _descriptor: DeviceDescriptor
    private var _onStateChange: (@Sendable (DeviceState) -> Void)?
    private var thread: Thread?
    private var streaming = false
    /// Set by stopStreaming; read by the I/O thread each block.
    private var cancelled = false
    private let joined = DispatchSemaphore(value: 0)
    private var runningIndex: UInt64 = 0

    /// Opens the file pair at `path` (samples or sidecar path). Throws DEVICE_IO / INVALID_ARGUMENT.
    package init(path: String, loop: Bool, realtime: Bool = true) throws {
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
            driver: FilePlaybackDevice.driverName,
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

    package var descriptor: DeviceDescriptor {
        lock.lock(); defer { lock.unlock() }
        return _descriptor
    }

    package var gains: [GainState] { [] }

    /// Called (from the I/O thread) whenever the device's state flips, e.g. `.disconnected` at EOF.
    /// The registry installs this to publish `changed`/`removed`.
    package func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) {
        lock.lock(); _onStateChange = hook; lock.unlock()
    }

    /// Assigns the registry-issued stable id (replaces the provisional one from init).
    package func assignID(_ id: DeviceID) {
        lock.lock(); _descriptor.id = id; lock.unlock()
    }

    /// Registry use: records an externally decided state (`.inUse` / `.available`) without firing
    /// the hook — the registry already knows. Safe from any thread.
    package func setState(_ state: DeviceState) {
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

    package func open() async throws {
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw EngineError.deviceIO("IQ file is not readable", target: path)
        }
    }

    package func close() async { await stopStreaming() }

    package func tune(centerHz: UInt64) async throws {
        guard descriptor.canTune(centerHz) else {
            throw EngineError.freqOutOfRange(centerHz, target: descriptor.id.string)
        }
    }

    package func setSampleRate(_ hz: UInt64) async throws {
        guard descriptor.sampleRates.contains(hz) else {
            throw EngineError.rateUnsupported(hz, target: descriptor.id.string)
        }
    }

    package func setGain(element: String, value: GainValue) async throws {
        throw EngineError.gainElementUnknown(element, target: descriptor.id.string)
    }

    // MARK: Streaming

    package func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        try beginStreaming()
        // The reader and scratch are created here, on the control plane, never on the I/O thread.
        let reader: IQFileReader
        do { reader = try IQFileReader(path: path, maxBlock: FilePlaybackDevice.blockSize) } catch {
            withLock { streaming = false }
            throw error
        }
        startLoop(reader: reader, captureID: captureID, deliver: deliver)
    }

    /// Streams from a reader the caller owns. Tests use it to drive the loop with a reader whose
    /// descriptor fails part way through the file.
    func startStreaming(captureID: CaptureID, reader: IQFileReader,
                        deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) throws {
        try beginStreaming()
        startLoop(reader: reader, captureID: captureID, deliver: deliver)
    }

    private func startLoop(reader: IQFileReader, captureID: CaptureID,
                           deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) {
        let storage = SampleStorage(capacity: FilePlaybackDevice.blockSize, format: .cf32)
        let t = Thread { [self] in
            self.runLoop(reader: reader, storage: storage, captureID: captureID, deliver: deliver)
        }
        t.name = "leyline.file.\(captureID.string)"
        t.qualityOfService = .userInteractive
        withLock { thread = t }
        t.start()
    }

    /// Cancels playback and returns once the I/O thread is gone. Both waits run on a dedicated
    /// thread: a cooperative-pool thread parked for the length of a block starves every other actor.
    package func stopStreaming() async {
        enum Next { case idle, join, awaitJoiner }
        let next: Next = withLock {
            guard streaming else { return Next.idle }
            guard !cancelled else { return Next.awaitJoiner }
            cancelled = true
            lock.broadcast() // cuts the pacing wait short, so the join is short too
            return Next.join
        }
        switch next {
        case .idle:
            return
        case .join:
            // The I/O thread signals `joined` exactly once when it exits.
            try? await BlockingWork.run { [joined] in joined.wait() }
            withLock { streaming = false; thread = nil; lock.broadcast() }
        case .awaitJoiner:
            // Another caller owns the single-signal semaphore; wait for it to finish the join. The
            // wait is bounded for the same reason `RTLSDRDevice`'s join is: a stuck I/O thread must
            // not wedge the capture actor and every client behind it.
            let joinedInTime = (try? await BlockingWork.run { [self] in
                let deadline = Date(timeIntervalSinceNow: 3)
                lock.lock(); defer { lock.unlock() }
                while streaming {
                    guard lock.wait(until: deadline) else { return false }
                }
                return true
            }) ?? false
            if !joinedInTime {
                FilePlaybackDevice.logger.error("IQ playback on \(path) did not finish stopping within 3s; returning with the stream still marked live")
            }
        }
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
            // Each stream starts the device's own index at 0; the capture timeline rebases onto it.
            runningIndex = 0
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
        var ended = false // the file is done with, by EOF or by a failed read
        while !isCancelled() {
            let n: Int
            do {
                n = try reader.read(into: storage.view())
            } catch {
                // The samples are unreachable (a pulled volume, a dropped mount). Nothing more will
                // arrive, so say so the way an unplug does rather than stalling the capture.
                FilePlaybackDevice.logger.error("IQ playback read failed on \(path): \(error)")
                ended = true
                break
            }
            if n == 0 {
                if loop, reader.sampleCount > 0, (try? reader.rewind()) != nil { continue }
                ended = true
                break
            }
            if realtime {
                // Block i may be delivered once wall time reaches start + (samples so far) / rate.
                let due = start + UInt64(Double(delivered) / rate * 1e9)
                let now = DispatchTime.now().uptimeNanoseconds
                if due > now, waitForPacing(seconds: Double(due - now) / 1e9) { break }
                if isCancelled() { break }
            }
            deliver(storage.view(count: n), SampleTime(captureID: captureID, sampleIndex: runningIndex))
            runningIndex &+= UInt64(n)
            delivered &+= UInt64(n)
        }
        if ended {
            // Ran off the end or lost the file: this device is gone, exactly like an unplug.
            // `streaming` stays set so the owner's stopStreaming still performs the
            // (already-complete) join.
            transition(to: .disconnected)
        }
    }

    /// Holds the I/O thread for `seconds` of pacing, returning true as soon as `stopStreaming`
    /// cancels — waiting on the condition rather than sleeping keeps the join short.
    private func waitForPacing(seconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !cancelled {
            if !lock.wait(until: deadline) { break }
        }
        return cancelled
    }
}

extension String {
    /// Zero-pads on the left to `width` characters.
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
