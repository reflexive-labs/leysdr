// SPDX-License-Identifier: GPL-3.0-or-later

// HackRFDevice: libhackrf-backed receive-only RadioDevice. HackRF is half duplex and Leyline's
// transmit side is a separate future protocol; this driver deliberately exposes RX only.

import CHackRF
import Foundation
import Logging

/// Result of enumerating one HackRF. Discovery opens an unclaimed device briefly to distinguish a
/// HackRF Pro from the USB-compatible HackRF One; a skipped probe keeps `probed == false` so the
/// registry can retain the descriptor it already has.
public struct HackRFProbe: Hashable, Sendable {
    public var serial: String
    public var model: String
    public var probed: Bool
    public var openError: Int32?

    public init(serial: String, model: String, probed: Bool = true, openError: Int32? = nil) {
        self.serial = serial
        self.model = model
        self.probed = probed
        self.openError = openError
    }
}

/// The libhackrf seam. Tests inject a memory-only implementation and drive the real C callback;
/// the product implementation below is the only code that talks to the system library directly.
protocol HackRFLibrary: AnyObject, Sendable {
    func initialize() -> Int32
    func enumerate(claimed: Set<String>, shouldOpen: @Sendable (HackRFProbe) -> Bool) throws -> [HackRFProbe]
    func open(serial: String, device: inout OpaquePointer?) -> Int32
    func close(_ device: OpaquePointer) -> Int32
    func setFrequency(_ device: OpaquePointer, _ hz: UInt64) -> Int32
    func setSampleRate(_ device: OpaquePointer, _ hz: Double) -> Int32
    func setLNAGain(_ device: OpaquePointer, _ db: UInt32) -> Int32
    func setVGAGain(_ device: OpaquePointer, _ db: UInt32) -> Int32
    func setAmpEnabled(_ device: OpaquePointer, _ enabled: UInt8) -> Int32
    func startRX(_ device: OpaquePointer, callback: hackrf_sample_block_cb_fn?, context: UnsafeMutableRawPointer?) -> Int32
    func stopRX(_ device: OpaquePointer) -> Int32
    func errorName(_ code: Int32) -> String
}

final class SystemHackRFLibrary: HackRFLibrary, @unchecked Sendable {
    static let shared = SystemHackRFLibrary()
    private init() {}

    func initialize() -> Int32 { hackrf_init() }

    func enumerate(claimed: Set<String>, shouldOpen: @Sendable (HackRFProbe) -> Bool) throws -> [HackRFProbe] {
        guard let list = hackrf_device_list() else {
            throw EngineError.deviceIO("hackrf_device_list returned null")
        }
        defer { hackrf_device_list_free(list) }
        let count = max(0, Int(list.pointee.devicecount))
        var probes: [HackRFProbe] = []
        probes.reserveCapacity(count)
        for i in 0..<count {
            let serial = list.pointee.serial_numbers?[i].map { String(cString: $0) } ?? ""
            var probe = HackRFProbe(serial: serial, model: "HackRF", probed: false)
            guard !claimed.contains(serial), shouldOpen(probe) else {
                probes.append(probe)
                continue
            }
            var device: OpaquePointer?
            let rc = hackrf_device_list_open(list, Int32(i), &device)
            guard rc == 0, let opened = device else {
                probe.openError = rc == 0 ? -1 : rc
                probes.append(probe)
                continue
            }
            var boardID: UInt8 = 0xff
            let boardRC = hackrf_board_id_read(opened, &boardID)
            if boardRC == 0 {
                probe.model = Self.model(boardID: boardID)
                probe.probed = true
            } else {
                probe.openError = boardRC
            }
            _ = hackrf_close(opened)
            probes.append(probe)
        }
        return probes
    }

    private static func model(boardID: UInt8) -> String {
        switch boardID {
        case 1: return "Jawbreaker"
        case 2, 4: return "HackRF One"
        case 3: return "rad1o"
        case 5: return "HackRF Pro"
        default: return "HackRF"
        }
    }

    func open(serial: String, device: inout OpaquePointer?) -> Int32 {
        serial.withCString { hackrf_open_by_serial($0, &device) }
    }
    func close(_ device: OpaquePointer) -> Int32 { hackrf_close(device) }
    func setFrequency(_ device: OpaquePointer, _ hz: UInt64) -> Int32 { hackrf_set_freq(device, hz) }
    func setSampleRate(_ device: OpaquePointer, _ hz: Double) -> Int32 { hackrf_set_sample_rate(device, hz) }
    func setLNAGain(_ device: OpaquePointer, _ db: UInt32) -> Int32 { hackrf_set_lna_gain(device, db) }
    func setVGAGain(_ device: OpaquePointer, _ db: UInt32) -> Int32 { hackrf_set_vga_gain(device, db) }
    func setAmpEnabled(_ device: OpaquePointer, _ enabled: UInt8) -> Int32 { hackrf_set_amp_enable(device, enabled) }
    func startRX(_ device: OpaquePointer, callback: hackrf_sample_block_cb_fn?, context: UnsafeMutableRawPointer?) -> Int32 {
        hackrf_start_rx(device, callback, context)
    }
    func stopRX(_ device: OpaquePointer) -> Int32 { hackrf_stop_rx(device) }
    func errorName(_ code: Int32) -> String {
        hackrf_error_name(hackrf_error(rawValue: code)).map { String(cString: $0) } ?? "unknown error"
    }
}

/// A HackRF in libhackrf's backwards-compatible 8-bit receive mode. `deliver` runs on libhackrf's
/// transfer thread and receives the library-owned buffer as native signed 8-bit interleaved IQ.
public final class HackRFDevice: RadioDevice, @unchecked Sendable {
    public static let driverName = "hackrf"
    /// A missing native library disables only this backend; the daemon and other drivers remain usable.
    public static var backendAvailable: Bool { leyline_hackrf_available() != 0 }
    public static var backendLoadError: String? {
        leyline_hackrf_load_error().map { String(cString: $0) }
    }

    public static let sampleRates: [UInt64] = [
        2_000_000, 2_400_000, 4_000_000, 8_000_000, 10_000_000, 12_500_000, 16_000_000, 20_000_000,
    ]
    /// libhackrf 2026.01 uses four 262144-byte transfers, two bytes per complex sample.
    public static let queuedSamples: UInt64 = 4 * 262_144 / 2

    private static let logger = Logger(label: "leyline.hackrf")
    private let lock = NSLock()
    private let library: any HackRFLibrary
    public private(set) var probe: HackRFProbe
    private var _descriptor: DeviceDescriptor
    private var device: OpaquePointer?
    private var streaming = false
    private var centerHz: UInt64
    private var sampleRate: UInt64 = 2_400_000
    // Match hackrf_transfer's conservative RX defaults. Zero on both variable stages is a valid
    // expert setting, but it makes an otherwise healthy first tune look like a dead stream.
    private var gainValues: [String: GainValue] = ["LNA": .db(8), "VGA": .db(20), "AMP": .db(0)]
    private var _onStateChange: (@Sendable (DeviceState) -> Void)?

    // Written before hackrf_start_rx and cleared only after hackrf_stop_rx has joined its transfer
    // thread. The C callback reads these without locking or allocating.
    private var deliver: (@Sendable (SampleBuffer, SampleTime) -> Void)?
    private var captureID = CaptureID()
    private var runningIndex: UInt64 = 0

    public init(probe: HackRFProbe, id: DeviceID) {
        self.probe = probe
        library = SystemHackRFLibrary.shared
        _descriptor = Self.makeDescriptor(probe: probe, id: id)
        centerHz = _descriptor.tuningRanges.first?.minHz ?? 1_000_000
    }

    init(probe: HackRFProbe, id: DeviceID, library: any HackRFLibrary) {
        self.probe = probe
        self.library = library
        _descriptor = Self.makeDescriptor(probe: probe, id: id)
        centerHz = _descriptor.tuningRanges.first?.minHz ?? 1_000_000
    }

    public static func makeDescriptor(probe: HackRFProbe, id: DeviceID) -> DeviceDescriptor {
        let isPro = probe.model == "HackRF Pro"
        let minHz: UInt64 = isPro ? 100_000 : 1_000_000
        return DeviceDescriptor(
            id: id,
            driver: driverName,
            model: probe.model,
            serial: probe.serial,
            usbLocation: "Great Scott Gadgets/\(probe.model)/\(probe.serial)",
            tuningRanges: [FrequencyRange(minHz: minHz, maxHz: 6_000_000_000)],
            sampleRates: sampleRates,
            nativeFormat: .cs8,
            gainElements: [
                GainElement(name: "LNA", minDB: 0, maxDB: 40, stepDB: 8, supportsAuto: false),
                GainElement(name: "VGA", minDB: 0, maxDB: 62, stepDB: 2, supportsAuto: false),
                GainElement(name: "AMP", minDB: 0, maxDB: 11, stepDB: 0, supportsAuto: false, validDB: [0, 11]),
            ],
            providesTimestamps: false,
            features: [
                "bias_tee": .flag(false),
                "tx_capable": .flag(true),
                "full_duplex": .flag(false),
                "sample_mode": .text("legacy_cs8"),
            ]
        )
    }

    public static func enumerate(claimed: Set<String> = [],
                                 shouldOpen: @Sendable (HackRFProbe) -> Bool = { _ in true }) throws -> [HackRFProbe] {
        try enumerate(claimed: claimed, shouldOpen: shouldOpen, library: SystemHackRFLibrary.shared)
    }

    static func enumerate(claimed: Set<String>, shouldOpen: @Sendable (HackRFProbe) -> Bool,
                          library: any HackRFLibrary) throws -> [HackRFProbe] {
        if library is SystemHackRFLibrary, !backendAvailable { return [] }
        let rc = library.initialize()
        guard rc == 0 else {
            throw EngineError.deviceIO("hackrf_init failed: \(library.errorName(rc)) (\(rc))")
        }
        return try library.enumerate(claimed: claimed, shouldOpen: shouldOpen)
    }

    public var descriptor: DeviceDescriptor { withLock { _descriptor } }
    public var gains: [GainState] {
        withLock {
            _descriptor.gainElements.map { GainState(element: $0.name, value: gainValues[$0.name] ?? .db(0)) }
        }
    }
    public var inFlightSamples: UInt64 { Self.queuedSamples }

    public func setState(_ state: DeviceState) { withLock { _descriptor.state = state } }
    public func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) { withLock { _onStateChange = hook } }

    public func updateProbe(_ newProbe: HackRFProbe) {
        withLock {
            let state = _descriptor.state
            probe = newProbe
            _descriptor = Self.makeDescriptor(probe: newProbe, id: _descriptor.id)
            _descriptor.state = state
            if !_descriptor.canTune(centerHz) { centerHz = _descriptor.tuningRanges[0].minHz }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func requireDevice() throws -> OpaquePointer {
        guard let device else { throw EngineError.deviceDetached(_descriptor.id.string) }
        return device
    }

    private func check(_ rc: Int32, _ call: String) throws {
        guard rc != 0 else { return }
        throw EngineError.deviceIO("\(call) failed: \(library.errorName(rc)) (\(rc))", target: _descriptor.id.string)
    }

    public func open() async throws {
        try await BlockingWork.run { [self] in
            try withLock {
                guard device == nil else { return }
                let initRC = library.initialize()
                if initRC != 0 { try check(initRC, "hackrf_init") }
                var opened: OpaquePointer?
                let rc = library.open(serial: probe.serial, device: &opened)
                guard rc == 0, let opened else {
                    if rc == -1_000 { throw EngineError.deviceHeldByOtherProgram(_descriptor.id.string) }
                    throw EngineError.deviceIO("hackrf_open_by_serial failed: \(library.errorName(rc)) (\(rc))",
                                               target: _descriptor.id.string)
                }
                do {
                    try check(library.setSampleRate(opened, Double(sampleRate)), "hackrf_set_sample_rate")
                    try check(library.setFrequency(opened, centerHz), "hackrf_set_freq")
                    try applyGains(to: opened)
                } catch {
                    _ = library.close(opened)
                    throw error
                }
                device = opened
            }
        }
    }

    public func close() async {
        await stopStreaming()
        try? await BlockingWork.run { [self] in
            withLock {
                if let device {
                    let rc = library.close(device)
                    if rc != 0 {
                        Self.logger.error("hackrf_close on \(_descriptor.id.string) failed: \(library.errorName(rc)) (\(rc))")
                    }
                }
                device = nil
                deliver = nil
            }
        }
    }

    public func tune(centerHz hz: UInt64) async throws {
        try withLock {
            guard _descriptor.canTune(hz) else { throw EngineError.freqOutOfRange(hz, target: _descriptor.id.string) }
            let device = try requireDevice()
            try check(library.setFrequency(device, hz), "hackrf_set_freq")
            centerHz = hz
        }
    }

    public func setSampleRate(_ hz: UInt64) async throws {
        guard Self.sampleRates.contains(hz) else { throw EngineError.rateUnsupported(hz, target: descriptor.id.string) }
        try withLock {
            if streaming { throw EngineError.deviceBusy(_descriptor.id.string) }
            let device = try requireDevice()
            try check(library.setSampleRate(device, Double(hz)), "hackrf_set_sample_rate")
            sampleRate = hz
        }
    }

    public func setGain(element: String, value: GainValue) async throws {
        try withLock {
            guard let descriptor = _descriptor.gainElement(named: element) else {
                throw EngineError.gainElementUnknown(element, target: _descriptor.id.string)
            }
            guard case .db(let requested) = value else {
                throw EngineError.invalidArgument("HackRF gain elements do not support auto", target: element)
            }
            guard requested.isFinite else { throw EngineError.invalidArgument("gain db must be finite", target: element) }
            let snapped = descriptor.snapped(requested)
            let device = try requireDevice()
            switch element {
            case "LNA": try check(library.setLNAGain(device, UInt32(snapped)), "hackrf_set_lna_gain")
            case "VGA": try check(library.setVGAGain(device, UInt32(snapped)), "hackrf_set_vga_gain")
            case "AMP": try check(library.setAmpEnabled(device, snapped == 0 ? 0 : 1), "hackrf_set_amp_enable")
            default: throw EngineError.gainElementUnknown(element, target: _descriptor.id.string)
            }
            gainValues[element] = .db(snapped)
        }
    }

    private func applyGains(to device: OpaquePointer) throws {
        let lna = gainValues["LNA"].flatMap(Self.db) ?? 0
        let vga = gainValues["VGA"].flatMap(Self.db) ?? 0
        let amp = gainValues["AMP"].flatMap(Self.db) ?? 0
        try check(library.setLNAGain(device, UInt32(lna)), "hackrf_set_lna_gain")
        try check(library.setVGAGain(device, UInt32(vga)), "hackrf_set_vga_gain")
        try check(library.setAmpEnabled(device, amp == 0 ? 0 : 1), "hackrf_set_amp_enable")
    }

    private static func db(_ value: GainValue) -> Double? {
        if case .db(let db) = value { return db }
        return nil
    }

    public func startStreaming(captureID: CaptureID,
                               deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        try await BlockingWork.run { [self] in
            try withLock {
                if streaming { throw EngineError.deviceBusy(_descriptor.id.string) }
                let device = try requireDevice()
                self.deliver = deliver
                self.captureID = captureID
                runningIndex = 0
                streaming = true
                let rc = library.startRX(device, callback: Self.rxCallback,
                                         context: Unmanaged.passUnretained(self).toOpaque())
                if rc != 0 {
                    streaming = false
                    self.deliver = nil
                    try check(rc, "hackrf_start_rx")
                }
            }
        }
    }

    public func stopStreaming() async {
        let opened: OpaquePointer? = withLock {
            guard streaming else { return nil }
            // Prevent new delivery immediately. libhackrf joins the callback thread before
            // hackrf_stop_rx returns, after which its borrowed buffers are no longer reachable.
            deliver = nil
            return device
        }
        guard let opened else { return }
        let openedAddress = UInt(bitPattern: opened)
        try? await BlockingWork.run { [self] in
            guard let opened = OpaquePointer(bitPattern: openedAddress) else { return }
            let rc = library.stopRX(opened)
            if rc != 0 {
                Self.logger.error("hackrf_stop_rx on \(descriptor.id.string) failed: \(library.errorName(rc)) (\(rc))")
            }
            withLock { streaming = false }
        }
    }

    private static let rxCallback: hackrf_sample_block_cb_fn = { transfer in
        guard let transfer, let context = transfer.pointee.rx_ctx, let buffer = transfer.pointee.buffer else { return 0 }
        let device = Unmanaged<HackRFDevice>.fromOpaque(context).takeUnretainedValue()
        device.onBuffer(buffer, Int(transfer.pointee.valid_length))
        return 0
    }

    @inline(__always)
    private func onBuffer(_ bytes: UnsafeMutablePointer<UInt8>, _ length: Int) {
        guard let deliver, length > 1 else { return }
        let count = length / 2
        let buffer = SampleBuffer(base: UnsafeMutableRawPointer(bytes), count: count, format: .cs8)
        deliver(buffer, SampleTime(captureID: captureID, sampleIndex: runningIndex))
        runningIndex &+= UInt64(count)
    }
}
