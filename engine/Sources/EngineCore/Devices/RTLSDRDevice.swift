// RTLSDRDevice: librtlsdr-backed RadioDevice. See docs/engine-internals.md "Devices" and
// docs/decisions/S3-usb-posture.md. The async read callback is a C function that must not touch
// Swift concurrency or take locks; it wraps the USB buffer and calls the stored deliver closure.

import CRTLSDR
import Foundation
import Logging

/// Result of enumerating one RTL-SDR dongle without claiming it for streaming.
public struct RTLSDRProbe: Hashable, Sendable {
    public var index: UInt32
    public var name: String
    public var manufacturer: String
    public var product: String
    public var serial: String
    /// Tuner name ("R820T", "E4000", ...); "unknown" when the device could not be opened.
    public var tuner: String
    /// Tuner gain table in dB (empty if unknown).
    public var gainsDB: [Double]
    public var tuningRanges: [FrequencyRange]

    public init(index: UInt32, name: String, manufacturer: String, product: String, serial: String,
                tuner: String, gainsDB: [Double], tuningRanges: [FrequencyRange]) {
        self.index = index
        self.name = name
        self.manufacturer = manufacturer
        self.product = product
        self.serial = serial
        self.tuner = tuner
        self.gainsDB = gainsDB
        self.tuningRanges = tuningRanges
    }
}

/// One RTL2832U dongle. Control methods run on the control plane; `deliver` runs on the USB thread.
public final class RTLSDRDevice: RadioDevice, @unchecked Sendable {
    /// Sample rates librtlsdr accepts without warnings (docs/engine-internals.md).
    public static let sampleRates: [UInt64] = [
        250_000, 1_024_000, 1_536_000, 1_800_000, 1_920_000, 2_048_000, 2_400_000, 2_560_000, 2_880_000, 3_200_000,
    ]

    /// Current librtlsdr enumeration index; shifts when a lower-index dongle is unplugged.
    public private(set) var index: UInt32
    /// The enumeration probe this device was built from (refreshed via `updateProbe` once a degraded
    /// probe — tuner "unknown", no gain table — is replaced by a successful one).
    public private(set) var probe: RTLSDRProbe

    private let lock = NSLock()
    private var _descriptor: DeviceDescriptor
    private static let logger = Logger(label: "leyline.rtlsdr")
    private var dev: OpaquePointer?
    private var thread: Thread?
    private var streaming = false
    /// Set by `stopStreaming` before cancelling so a non-zero read_async result is not treated as a failure.
    private var cancelRequested = false
    private let joined = DispatchSemaphore(value: 0)
    /// Signalled by the USB thread right before it enters `rtlsdr_read_async`, so `stopStreaming`
    /// never issues its first cancel against a thread that has not been scheduled yet.
    private let started = DispatchSemaphore(value: 0)
    private var _onStateChange: (@Sendable (DeviceState) -> Void)?
    private var centerHz: UInt64
    private var sampleRate: UInt64
    private var gain: GainValue = .auto
    private var features: [String: FeatureValue] = [:]

    // Written by startStreaming before the thread exists; read only by the C callback.
    private var deliver: (@Sendable (SampleBuffer, SampleTime) -> Void)?
    private var captureID = CaptureID()
    private var runningIndex: UInt64 = 0

    /// Builds a device for an enumerated dongle. `id` is the registry's stable id for this serial.
    public init(probe: RTLSDRProbe, id: DeviceID) {
        index = probe.index
        self.probe = probe
        centerHz = probe.tuningRanges.first?.minHz ?? 100_000_000
        sampleRate = 2_400_000
        features = [
            "tuner": .text(probe.tuner),
            "bias_tee": .flag(false),
            "direct_sampling": .integer(0),
            "ppm_correction": .integer(0),
            "rtl_agc": .flag(false),
        ]
        _descriptor = RTLSDRDevice.makeDescriptor(probe: probe, id: id, features: features)
    }

    /// Descriptor for a probe (shared with the registry so unopened devices advertise the same shape).
    public static func makeDescriptor(probe: RTLSDRProbe, id: DeviceID, features: [String: FeatureValue]) -> DeviceDescriptor {
        let gains = probe.gainsDB
        let element = GainElement(
            name: "TUNER",
            minDB: gains.min() ?? 0,
            maxDB: gains.max() ?? 0,
            stepDB: 0,
            supportsAuto: true,
            validDB: gains
        )
        return DeviceDescriptor(
            id: id,
            driver: "rtlsdr",
            model: probe.product.isEmpty ? probe.name : probe.product,
            serial: probe.serial,
            usbLocation: "\(probe.manufacturer)/\(probe.product)/\(probe.serial)",
            state: .available,
            tuningRanges: probe.tuningRanges,
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

    /// Updates the published state (registry use: `.inUse`, `.disconnected`) without firing the
    /// state-change hook — the registry already knows.
    public func setState(_ state: DeviceState) {
        lock.lock(); _descriptor.state = state; lock.unlock()
    }

    /// Called (from the USB thread) when the device flips state on its own, e.g. `.disconnected`
    /// when `rtlsdr_read_async` dies. The registry installs this to publish `changed`.
    public func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) {
        lock.lock(); _onStateChange = hook; lock.unlock()
    }

    /// Device-originated transition: updates state and fires the hook outside the lock.
    private func transition(to state: DeviceState) {
        lock.lock()
        let changed = _descriptor.state != state
        _descriptor.state = state
        let hook = _onStateChange
        lock.unlock()
        if changed { hook?(state) }
    }

    /// Registry use: re-points a not-yet-open device at its new enumeration index.
    public func setIndex(_ i: UInt32) {
        lock.lock(); index = i; lock.unlock()
    }

    /// Registry use: replaces a degraded discovery probe (device was busy when first seen) with a
    /// successful one and rebuilds the descriptor — tuner, gain table, tuning ranges — keeping state.
    public func updateProbe(_ p: RTLSDRProbe) {
        withLock {
            probe = p
            index = p.index
            features["tuner"] = .text(p.tuner)
            let state = _descriptor.state
            _descriptor = RTLSDRDevice.makeDescriptor(probe: p, id: _descriptor.id, features: features)
            _descriptor.state = state
            if !_descriptor.canTune(centerHz) { centerHz = p.tuningRanges.first?.minHz ?? centerHz }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    /// Maps a librtlsdr return code to DEVICE_IO. Only called with `lock` held (reads `_descriptor`).
    private func check(_ rc: Int32, _ call: String) throws {
        if rc < 0 { throw EngineError.deviceIO("\(call) failed: \(rc)", target: _descriptor.id.string) }
    }

    // MARK: Enumeration

    /// Tuner name and tuning ranges for a librtlsdr tuner enum (docs/engine-internals.md table).
    static func tunerInfo(_ t: rtlsdr_tuner) -> (name: String, ranges: [FrequencyRange]) {
        switch t {
        case RTLSDR_TUNER_E4000:
            return ("E4000", [FrequencyRange(minHz: 52_000_000, maxHz: 1_100_000_000),
                              FrequencyRange(minHz: 1_250_000_000, maxHz: 2_200_000_000)])
        case RTLSDR_TUNER_FC0012:
            return ("FC0012", [FrequencyRange(minHz: 22_000_000, maxHz: 948_000_000)])
        case RTLSDR_TUNER_FC0013:
            return ("FC0013", [FrequencyRange(minHz: 22_000_000, maxHz: 1_100_000_000)])
        case RTLSDR_TUNER_FC2580:
            return ("FC2580", [FrequencyRange(minHz: 146_000_000, maxHz: 924_000_000)])
        case RTLSDR_TUNER_R820T:
            return ("R820T", [FrequencyRange(minHz: 24_000_000, maxHz: 1_766_000_000)])
        case RTLSDR_TUNER_R828D:
            return ("R828D", [FrequencyRange(minHz: 24_000_000, maxHz: 1_766_000_000)])
        default:
            return ("unknown", [FrequencyRange(minHz: 24_000_000, maxHz: 1_766_000_000)])
        }
    }

    /// Enumerates attached dongles. USB strings need no open; tuner type and gain table need a brief
    /// open (a full USB reset + tuner init, 100–300 ms on real hardware), which is skipped for indexes
    /// in `claimed` (already open for streaming) and for any probe `shouldOpen` rejects (the registry
    /// passes `false` for dongles it has already probed successfully, so the open happens once per
    /// device rather than once per poll and never races a capture's own `rtlsdr_open`). Skipped
    /// devices are reported with `tuner == "unknown"` and the caller reuses its cached probe. Never
    /// throws: an unreadable device is likewise reported with `tuner == "unknown"`.
    public static func enumerate(claimed: Set<UInt32> = [], shouldOpen: (RTLSDRProbe) -> Bool = { _ in true }) -> [RTLSDRProbe] {
        let count = rtlsdr_get_device_count()
        var out: [RTLSDRProbe] = []
        out.reserveCapacity(Int(count))
        for i in 0..<count {
            let name = rtlsdr_get_device_name(i).map { String(cString: $0) } ?? ""
            var manufact = [CChar](repeating: 0, count: 256)
            var product = [CChar](repeating: 0, count: 256)
            var serial = [CChar](repeating: 0, count: 256)
            let rc = rtlsdr_get_device_usb_strings(i, &manufact, &product, &serial)
            var probe = RTLSDRProbe(
                index: i, name: name,
                manufacturer: rc == 0 ? String(cString: manufact) : "",
                product: rc == 0 ? String(cString: product) : "",
                serial: rc == 0 ? String(cString: serial) : "",
                tuner: "unknown", gainsDB: [], tuningRanges: tunerInfo(RTLSDR_TUNER_UNKNOWN).ranges
            )
            if !claimed.contains(i), shouldOpen(probe) {
                var dev: OpaquePointer?
                if rtlsdr_open(&dev, i) == 0, let d = dev {
                    let info = tunerInfo(rtlsdr_get_tuner_type(d))
                    probe.tuner = info.name
                    probe.tuningRanges = info.ranges
                    let n = rtlsdr_get_tuner_gains(d, nil)
                    if n > 0 {
                        var table = [Int32](repeating: 0, count: Int(n))
                        let got = rtlsdr_get_tuner_gains(d, &table)
                        if got > 0 { probe.gainsDB = table.prefix(Int(got)).map { Double($0) / 10.0 } }
                    }
                    rtlsdr_close(d)
                }
            }
            out.append(probe)
        }
        return out
    }

    // MARK: Control

    public func open() async throws {
        try withLock {
            guard dev == nil else { return }
            var d: OpaquePointer?
            var rc = rtlsdr_open(&d, index)
            if rc != 0 {
                // A transient claim (registry probe of a never-probed dongle, or another process
                // releasing it) usually clears within tens of ms; retry once before failing.
                Thread.sleep(forTimeInterval: 0.05)
                d = nil
                rc = rtlsdr_open(&d, index)
            }
            guard rc == 0, let opened = d else {
                throw EngineError.deviceIO("rtlsdr_open failed: \(rc)", target: _descriptor.id.string)
            }
            dev = opened
            // Apply the cached configuration so reopen after replug is transparent.
            rtlsdr_set_sample_rate(opened, UInt32(sampleRate))
            rtlsdr_set_center_freq(opened, UInt32(truncatingIfNeeded: centerHz))
            rtlsdr_set_tuner_gain_mode(opened, 0)
        }
    }

    public func close() async {
        await stopStreaming()
        withLock {
            if let d = dev { rtlsdr_close(d) }
            dev = nil
        }
    }

    private func requireDev() throws -> OpaquePointer {
        guard let d = dev else { throw EngineError.deviceDetached(_descriptor.id.string) }
        return d
    }

    public func tune(centerHz hz: UInt64) async throws {
        try withLock {
            guard _descriptor.canTune(hz) else { throw EngineError.freqOutOfRange(hz, target: _descriptor.id.string) }
            let d = try requireDev()
            try check(rtlsdr_set_center_freq(d, UInt32(truncatingIfNeeded: hz)), "rtlsdr_set_center_freq")
            let actual = rtlsdr_get_center_freq(d)
            guard actual != 0 else { throw EngineError.deviceIO("rtlsdr_get_center_freq returned 0", target: _descriptor.id.string) }
            centerHz = UInt64(actual)
        }
    }

    public func setSampleRate(_ hz: UInt64) async throws {
        guard RTLSDRDevice.sampleRates.contains(hz) else {
            throw EngineError.rateUnsupported(hz, target: descriptor.id.string)
        }
        // Rate changes need a stream restart: the index continues monotonically (docs "Timebase").
        let resume: (CaptureID, @Sendable (SampleBuffer, SampleTime) -> Void)? = withLock {
            guard streaming, let cb = deliver else { return nil }
            return (captureID, cb)
        }
        if resume != nil { await stopStreaming() }
        try withLock {
            let d = try requireDev()
            try check(rtlsdr_set_sample_rate(d, UInt32(hz)), "rtlsdr_set_sample_rate")
            sampleRate = hz
        }
        if let (cap, cb) = resume { try await startStreaming(captureID: cap, deliver: cb) }
    }

    public func setGain(element: String, value: GainValue) async throws {
        try withLock {
            guard element == "TUNER", let el = _descriptor.gainElement(named: element) else {
                throw EngineError.gainElementUnknown(element, target: _descriptor.id.string)
            }
            let d = try requireDev()
            switch value {
            case .auto:
                try check(rtlsdr_set_tuner_gain_mode(d, 0), "rtlsdr_set_tuner_gain_mode")
                gain = .auto
            case .db(let requested):
                let db = el.snapped(requested)
                try check(rtlsdr_set_tuner_gain_mode(d, 1), "rtlsdr_set_tuner_gain_mode")
                try check(rtlsdr_set_tuner_gain(d, Int32((db * 10).rounded())), "rtlsdr_set_tuner_gain")
                gain = .db(db)
            }
        }
    }

    /// Applies one of the descriptor's settable features (`bias_tee`, `direct_sampling`,
    /// `ppm_correction`, `rtl_agc`). `tuner` is read-only. Unknown names → INVALID_ARGUMENT.
    public func setFeature(_ name: String, _ value: FeatureValue) async throws {
        try withLock {
            let d = try requireDev()
            switch (name, value) {
            case ("bias_tee", .flag(let on)):
                try check(rtlsdr_set_bias_tee(d, on ? 1 : 0), "rtlsdr_set_bias_tee")
            case ("direct_sampling", .integer(let mode)):
                guard (0...2).contains(mode) else { throw EngineError.invalidArgument("direct_sampling must be 0, 1 or 2", target: name) }
                try check(rtlsdr_set_direct_sampling(d, Int32(mode)), "rtlsdr_set_direct_sampling")
            case ("ppm_correction", .integer(let ppm)):
                // librtlsdr returns -2 when the value is unchanged; that is not an error.
                let rc = rtlsdr_set_freq_correction(d, Int32(clamping: ppm))
                if rc < 0 && rc != -2 { try check(rc, "rtlsdr_set_freq_correction") }
            case ("rtl_agc", .flag(let on)):
                try check(rtlsdr_set_agc_mode(d, on ? 1 : 0), "rtlsdr_set_agc_mode")
            case ("tuner", _):
                throw EngineError.invalidArgument("feature tuner is read-only", target: name)
            default:
                throw EngineError.invalidArgument("unknown or mistyped feature", target: name)
            }
            features[name] = value
            _descriptor.features = features
        }
    }

    // MARK: Streaming

    public func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        let d: OpaquePointer = try withLock {
            if streaming || thread != nil { throw EngineError.deviceBusy(_descriptor.id.string) }
            let d = try requireDev()
            try check(rtlsdr_reset_buffer(d), "rtlsdr_reset_buffer")
            // Stored before the thread exists; the callback reads them without locks.
            self.deliver = deliver
            self.captureID = captureID
            streaming = true
            cancelRequested = false
            streamError = nil
            return d
        }
        let t = Thread { [self] in
            self.started.signal()
            // Blocks until rtlsdr_cancel_async; each USB transfer invokes the callback once.
            let rc = rtlsdr_read_async(d, RTLSDRDevice.readCallback, Unmanaged.passUnretained(self).toOpaque(), 32, 32768)
            self.readAsyncReturned(rc)
            self.joined.signal()
        }
        t.name = "leyline.rtlsdr.\(captureID.string)"
        t.qualityOfService = .userInteractive
        withLock { thread = t }
        t.start()
    }

    /// USB-thread exit: the only legitimate way out of `rtlsdr_read_async` is a cancel we asked for,
    /// so any other return means the stream died regardless of `rc`. In particular a pulled dongle
    /// is handled inside librtlsdr's own libusb callback (`dev_lost = 1` + `rtlsdr_cancel_async`),
    /// which unwinds read_async through its normal cancel path and returns 0 (or an incidental
    /// libusb code). The device stops claiming to stream so `stopStreaming`/`setSampleRate` see the
    /// truth and `streamError` surfaces it. `thread` stays recorded: the thread still signals
    /// `joined`, and `stopStreaming` (called by the capture on `.disconnected`) consumes that signal
    /// and clears it, keeping the semaphores balanced for the next start.
    func readAsyncReturned(_ rc: Int32) {
        let died: Bool = withLock {
            guard !cancelRequested else { return false }
            streaming = false
            deliver = nil
            streamError = EngineError.deviceIO("rtlsdr_read_async returned unexpectedly (rc \(rc)): device lost", target: _descriptor.id.string)
            RTLSDRDevice.logger.error("rtlsdr_read_async on \(_descriptor.id.string) returned \(rc) without a requested cancel; stream stopped")
            return true
        }
        // Report the loss like a physical unplug so the capture goes `.detached` and clients see it.
        if died { transition(to: .disconnected) }
    }

    /// The error that ended the last stream unexpectedly, if any (cleared by `startStreaming`).
    public var streamError: EngineError? {
        get { withLock { _streamError } }
        set { _streamError = newValue }   // only called with `lock` held
    }
    private var _streamError: EngineError?

    public func stopStreaming() async {
        let (d, wasStreaming): (OpaquePointer?, Bool) = withLock {
            guard thread != nil, let d = dev else { return (nil, false) }
            cancelRequested = true
            return (d, streaming)
        }
        guard let d else { return }
        if wasStreaming {
            // Wait for the USB thread to be scheduled: rtlsdr_cancel_async is a no-op (returns -2)
            // until rtlsdr_read_async has set RTLSDR_RUNNING on that thread.
            _ = started.wait(timeout: .now() + .seconds(1))
            // Keep cancelling until it takes (bounded, ~1 s) unless the thread exits first.
            var attempts = 0
            while rtlsdr_cancel_async(d) != 0 && attempts < 200 {
                attempts += 1
                if joined.wait(timeout: .now() + .milliseconds(5)) == .success {
                    withLock { streaming = false; thread = nil; deliver = nil }
                    return
                }
            }
        }
        // Never block forever on the join: a stuck libusb thread would otherwise wedge the capture
        // actor and every client behind it. On timeout the thread stays recorded (later starts fail
        // DEVICE_BUSY rather than double-streaming) and the failure is logged.
        if joined.wait(timeout: .now() + .seconds(3)) == .timedOut {
            RTLSDRDevice.logger.error("rtlsdr_read_async on \(descriptor.id.string) did not return after cancel; leaving USB thread detached")
            // Leave `deliver` in place: the USB thread may still read it without the lock; it is cleared
            // when the thread is finally joined by the next stopStreaming.
            withLock { streaming = false }
            return
        }
        withLock { streaming = false; thread = nil; deliver = nil }
    }

    /// librtlsdr async callback. Runs on the USB thread: no allocation, no locks, no concurrency.
    private static let readCallback: rtlsdr_read_async_cb_t = { buf, len, ctx in
        guard let buf, let ctx else { return }
        let device = Unmanaged<RTLSDRDevice>.fromOpaque(ctx).takeUnretainedValue()
        device.onBuffer(buf, Int(len))
    }

    @inline(__always)
    private func onBuffer(_ buf: UnsafeMutablePointer<UInt8>, _ len: Int) {
        guard let cb = deliver else { return }
        let count = len / 2
        let buffer = SampleBuffer(base: UnsafeMutableRawPointer(buf), count: count, format: .cu8)
        cb(buffer, SampleTime(captureID: captureID, sampleIndex: runningIndex))
        runningIndex &+= UInt64(count)
    }
}
