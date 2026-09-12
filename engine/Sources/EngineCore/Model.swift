// SPDX-License-Identifier: GPL-3.0-or-later

// Engine-side model types. The daemon maps these to leyline.v1 messages; EngineCore never imports the protos.

import Foundation

public enum DeviceState: Hashable, Sendable {
    case available
    case inUse
    case disconnected
}

public struct FrequencyRange: Hashable, Sendable {
    public var minHz: UInt64
    public var maxHz: UInt64

    public init(minHz: UInt64, maxHz: UInt64) {
        self.minHz = minHz
        self.maxHz = maxHz
    }

    public func contains(_ hz: UInt64) -> Bool { hz >= minHz && hz <= maxHz }
}

/// One gain stage, ordered as in the signal path. Continuous (`stepDB > 0`, `validDB` empty) or
/// discrete (`validDB` non-empty, `stepDB == 0`, writes snap to the nearest entry).
public struct GainElement: Hashable, Sendable {
    public var name: String
    public var minDB: Double
    public var maxDB: Double
    public var stepDB: Double
    public var supportsAuto: Bool
    public var validDB: [Double]

    public init(name: String, minDB: Double, maxDB: Double, stepDB: Double, supportsAuto: Bool, validDB: [Double] = []) {
        self.name = name
        self.minDB = minDB
        self.maxDB = maxDB
        self.stepDB = stepDB
        self.supportsAuto = supportsAuto
        self.validDB = validDB
    }

    /// Clamp/snap a requested value into this element's domain.
    public func snapped(_ db: Double) -> Double {
        if !validDB.isEmpty {
            return validDB.min(by: { abs($0 - db) < abs($1 - db) }) ?? db
        }
        let clamped = min(max(db, minDB), maxDB)
        guard stepDB > 0 else { return clamped }
        return minDB + (((clamped - minDB) / stepDB).rounded() * stepDB)
    }
}

public enum GainValue: Hashable, Sendable {
    case db(Double)
    case auto
}

public struct GainState: Hashable, Sendable {
    public var element: String
    public var value: GainValue

    public init(element: String, value: GainValue) {
        self.element = element
        self.value = value
    }
}

public enum GainMode: Hashable, Sendable {
    case manual
    case auto
}

/// Vendor features without schema changes. Well-known keys: "bias_tee", "direct_sampling",
/// "tx_capable", "full_duplex", "ppm_correction", "tuner", "serial_collision" (two dongles share a
/// serial; ids fall back to enumeration order) and "held_externally" (another program has the
/// dongle; state reads IN_USE until it is released).
public enum FeatureValue: Hashable, Sendable {
    case flag(Bool)
    case integer(Int64)
    case number(Double)
    case text(String)
}

/// Self-describing device capabilities (control-plane doc, "Capability model").
public struct DeviceDescriptor: Hashable, Sendable {
    public var id: DeviceID
    /// "rtlsdr" | "file" | "hackrf" | "airspy" | "sdrplay" | "composite" | ...
    public var driver: String
    public var model: String
    public var serial: String
    /// Empty for virtual devices.
    public var usbLocation: String
    public var state: DeviceState
    public var tuningRanges: [FrequencyRange]
    public var sampleRates: [UInt64]
    public var nativeFormat: SampleFormat
    public var gainElements: [GainElement]
    public var providesTimestamps: Bool
    public var features: [String: FeatureValue]

    public init(id: DeviceID, driver: String, model: String, serial: String, usbLocation: String = "",
                state: DeviceState = .available, tuningRanges: [FrequencyRange], sampleRates: [UInt64],
                nativeFormat: SampleFormat, gainElements: [GainElement] = [], providesTimestamps: Bool = false,
                features: [String: FeatureValue] = [:]) {
        self.id = id
        self.driver = driver
        self.model = model
        self.serial = serial
        self.usbLocation = usbLocation
        self.state = state
        self.tuningRanges = tuningRanges
        self.sampleRates = sampleRates
        self.nativeFormat = nativeFormat
        self.gainElements = gainElements
        self.providesTimestamps = providesTimestamps
        self.features = features
    }

    public func canTune(_ hz: UInt64) -> Bool { tuningRanges.contains { $0.contains(hz) } }
    public func gainElement(named name: String) -> GainElement? { gainElements.first { $0.name == name } }
}

public enum DemodMode: String, Hashable, Sendable, CaseIterable {
    case am, nfm, wfm, usb, lsb, cw, rawIQ

    /// Sensible default channel bandwidth per mode (Hz).
    public var defaultBandwidthHz: UInt32 {
        switch self {
        case .am: return 10_000
        case .nfm: return 12_500
        case .wfm: return 200_000
        case .usb, .lsb: return 2_800
        case .cw: return 500
        case .rawIQ: return 12_500
        }
    }
}

/// A rejection with a stable machine code from `Code` in `code` and prose for a person in `message`;
/// `target` names the object it is about. This is what `ErrorDetail` carries to every client.
public struct EngineError: Error, Hashable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var target: String

    public init(code: String, message: String, target: String = "") {
        self.code = code
        self.message = message
        self.target = target
    }

    public var description: String { "\(code): \(message)\(target.isEmpty ? "" : " (\(target))")" }

    /// Every stable code a daemon puts in `ErrorDetail.code`, spelled once. The gRPC status each one
    /// maps to is the table in `docs/dev/engine-internals.md`; a client switch keys on these strings, so
    /// a new code is added here before it is thrown anywhere.
    public enum Code {
        public static let deviceNotFound = "DEVICE_NOT_FOUND"
        public static let deviceBusy = "DEVICE_BUSY"
        public static let deviceSweeping = "DEVICE_SWEEPING"
        public static let deviceDetached = "DEVICE_DETACHED"
        public static let deviceIO = "DEVICE_IO"
        public static let noDevice = "NO_DEVICE"
        public static let freqOutOfRange = "FREQ_OUT_OF_RANGE"
        public static let rateUnsupported = "RATE_UNSUPPORTED"
        public static let offsetOutOfCapture = "OFFSET_OUT_OF_CAPTURE"
        public static let blindSpot = "BLIND_SPOT"
        public static let gainElementUnknown = "GAIN_ELEMENT_UNKNOWN"
        public static let captureNotFound = "CAPTURE_NOT_FOUND"
        public static let channelNotFound = "CHANNEL_NOT_FOUND"
        public static let sinkNotFound = "SINK_NOT_FOUND"
        public static let streamNotFound = "STREAM_NOT_FOUND"
        public static let jobNotFound = "JOB_NOT_FOUND"
        public static let scanNotFound = "SCAN_NOT_FOUND"
        public static let modeUnsupported = "MODE_UNSUPPORTED"
        public static let unimplemented = "UNIMPLEMENTED"
        public static let platformUnsupported = "PLATFORM_UNSUPPORTED"
        /// Decoders (docs/design/decoders.md, "Decisions"): the registry has no manifest by that
        /// name, and the plugin's program could not be started.
        public static let decoderNotFound = "DECODER_NOT_FOUND"
        public static let decoderFailed = "DECODER_FAILED"
        public static let failedPrecondition = "FAILED_PRECONDITION"
        public static let invalidArgument = "INVALID_ARGUMENT"
        public static let internalError = "INTERNAL"
        /// Daemon-local: the process refuses to start, so no client ever sees it, and it is not in
        /// `all`.
        public static let socketInUse = "SOCKET_IN_USE"

        /// The registry itself: what every client can expect to see, and what the cross-language
        /// tests hold against the documented table.
        public static let all: [String] = [
            deviceNotFound, deviceBusy, deviceSweeping, deviceDetached, deviceIO, noDevice,
            freqOutOfRange, rateUnsupported, offsetOutOfCapture, blindSpot, gainElementUnknown,
            captureNotFound, channelNotFound, sinkNotFound, streamNotFound, jobNotFound, scanNotFound,
            modeUnsupported, unimplemented, platformUnsupported, failedPrecondition, invalidArgument,
            internalError, decoderNotFound, decoderFailed,
        ]
    }

    public static func deviceNotFound(_ id: String) -> EngineError { .init(code: Code.deviceNotFound, message: "no such device", target: id) }
    public static func deviceBusy(_ id: String) -> EngineError { .init(code: Code.deviceBusy, message: "device already has a capture", target: id) }
    public static func deviceStarting(_ id: String) -> EngineError { .init(code: Code.deviceBusy, message: "a capture is starting on it; try again", target: id) }
    public static func deviceHeldByOtherProgram(_ id: String) -> EngineError { .init(code: Code.deviceBusy, message: "another program has the device (rtl_tcp, SDR++, GQRX?); quit it and retry", target: id) }
    public static func deviceSweeping(_ id: String) -> EngineError { .init(code: Code.deviceSweeping, message: "a scan is sweeping this radio; it is free again when the scan ends", target: id) }
    public static func deviceDetached(_ id: String) -> EngineError { .init(code: Code.deviceDetached, message: "device is disconnected", target: id) }
    public static func deviceIO(_ msg: String, target: String = "") -> EngineError { .init(code: Code.deviceIO, message: msg, target: target) }
    public static func freqOutOfRange(_ hz: UInt64, target: String) -> EngineError { .init(code: Code.freqOutOfRange, message: "\(hz) Hz is outside the device tuning range", target: target) }
    public static func rateUnsupported(_ hz: UInt64, target: String) -> EngineError { .init(code: Code.rateUnsupported, message: "\(hz) sps is not a supported sample rate", target: target) }
    public static func offsetOutOfCapture(_ hz: Int64, target: String) -> EngineError { .init(code: Code.offsetOutOfCapture, message: "offset \(hz) Hz falls outside the capture bandwidth", target: target) }
    public static func gainElementUnknown(_ name: String, target: String) -> EngineError { .init(code: Code.gainElementUnknown, message: "no gain element named \(name)", target: target) }
    public static func captureNotFound(_ id: String) -> EngineError { .init(code: Code.captureNotFound, message: "no such capture", target: id) }
    public static func channelNotFound(_ id: String) -> EngineError { .init(code: Code.channelNotFound, message: "no such channel", target: id) }
    public static func sinkNotFound(_ id: String) -> EngineError { .init(code: Code.sinkNotFound, message: "no such sink", target: id) }
    public static func streamNotFound(_ id: String) -> EngineError { .init(code: Code.streamNotFound, message: "no such stream", target: id) }
    public static func modeUnsupported(_ mode: String, target: String = "") -> EngineError { .init(code: Code.modeUnsupported, message: "demodulator \(mode) is not available", target: target) }
    public static func jobNotFound(_ id: String) -> EngineError { .init(code: Code.jobNotFound, message: "no such job", target: id) }
    public static func scanNotFound(_ id: String) -> EngineError { .init(code: Code.scanNotFound, message: "no such scan", target: id) }
    public static func unimplemented(_ what: String) -> EngineError { .init(code: Code.unimplemented, message: "\(what) is not implemented in v0", target: "") }
    public static func invalidArgument(_ msg: String, target: String = "") -> EngineError { .init(code: Code.invalidArgument, message: msg, target: target) }
    public static func platformUnsupported(_ what: String) -> EngineError { .init(code: Code.platformUnsupported, message: "\(what) requires macOS", target: "") }
    public static func decoderNotFound(_ name: String) -> EngineError { .init(code: Code.decoderNotFound, message: "no decoder named \(name) is installed", target: name) }
    public static func decoderFailed(_ msg: String, target: String = "") -> EngineError { .init(code: Code.decoderFailed, message: msg, target: target) }
    /// A precondition the caller can see and fix, where no more specific code fits.
    public static func failedPrecondition(_ msg: String, target: String = "") -> EngineError { .init(code: Code.failedPrecondition, message: msg, target: target) }
    /// A fault the caller did not cause and cannot act on; the prose is whatever went wrong.
    public static func internalError(_ msg: String, target: String = "") -> EngineError { .init(code: Code.internalError, message: msg, target: target) }
}
