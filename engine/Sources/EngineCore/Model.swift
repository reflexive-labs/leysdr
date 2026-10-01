// SPDX-License-Identifier: GPL-3.0-or-later

// Engine-side model types. The daemon maps these to leyline.v1 messages; EngineCore never imports the protos.

import Foundation

package enum DeviceState: Hashable, Sendable {
    case available
    case inUse
    case disconnected
}

package struct FrequencyRange: Hashable, Sendable {
    package var minHz: UInt64
    package var maxHz: UInt64

    package init(minHz: UInt64, maxHz: UInt64) {
        self.minHz = minHz
        self.maxHz = maxHz
    }

    package func contains(_ hz: UInt64) -> Bool { hz >= minHz && hz <= maxHz }
}

/// One gain stage, ordered as in the signal path. Continuous (`stepDB > 0`, `validDB` empty) or
/// discrete (`validDB` non-empty, `stepDB == 0`, writes snap to the nearest entry).
package struct GainElement: Hashable, Sendable {
    package var name: String
    package var minDB: Double
    package var maxDB: Double
    package var stepDB: Double
    package var supportsAuto: Bool
    package var validDB: [Double]

    package init(name: String, minDB: Double, maxDB: Double, stepDB: Double, supportsAuto: Bool, validDB: [Double] = []) {
        self.name = name
        self.minDB = minDB
        self.maxDB = maxDB
        self.stepDB = stepDB
        self.supportsAuto = supportsAuto
        self.validDB = validDB
    }

    /// Clamp/snap a requested value into this element's domain.
    package func snapped(_ db: Double) -> Double {
        if !validDB.isEmpty {
            return validDB.min(by: { abs($0 - db) < abs($1 - db) }) ?? db
        }
        let clamped = min(max(db, minDB), maxDB)
        guard stepDB > 0 else { return clamped }
        return minDB + (((clamped - minDB) / stepDB).rounded() * stepDB)
    }
}

package enum GainValue: Hashable, Sendable {
    case db(Double)
    case auto
}

package struct GainState: Hashable, Sendable {
    package var element: String
    package var value: GainValue

    package init(element: String, value: GainValue) {
        self.element = element
        self.value = value
    }
}

package enum GainMode: Hashable, Sendable {
    case manual
    case auto
}

/// Vendor features without schema changes. Well-known keys: "bias_tee", "direct_sampling",
/// "tx_capable", "full_duplex", "ppm_correction", "tuner", "serial_collision" (two dongles share a
/// serial; ids fall back to enumeration order) and "held_externally" (another program has the
/// dongle; state reads IN_USE until it is released).
package enum FeatureValue: Hashable, Sendable {
    case flag(Bool)
    case integer(Int64)
    case number(Double)
    case text(String)
}

/// Self-describing device capabilities (control-plane doc, "Capability model").
package struct DeviceDescriptor: Hashable, Sendable {
    package var id: DeviceID
    /// "rtlsdr" | "file" | "hackrf" | "airspy" | "sdrplay" | "composite" | ...
    package var driver: String
    package var model: String
    package var serial: String
    /// Empty for virtual devices.
    package var usbLocation: String
    package var state: DeviceState
    package var tuningRanges: [FrequencyRange]
    package var sampleRates: [UInt64]
    package var nativeFormat: SampleFormat
    package var gainElements: [GainElement]
    package var providesTimestamps: Bool
    package var features: [String: FeatureValue]

    package init(id: DeviceID, driver: String, model: String, serial: String, usbLocation: String = "",
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

    package func canTune(_ hz: UInt64) -> Bool { tuningRanges.contains { $0.contains(hz) } }
    package func gainElement(named name: String) -> GainElement? { gainElements.first { $0.name == name } }
}

package enum DemodMode: String, Hashable, Sendable, CaseIterable {
    case am, nfm, wfm, usb, lsb, cw, rawIQ

    /// Sensible default channel bandwidth per mode (Hz).
    package var defaultBandwidthHz: UInt32 {
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
package struct EngineError: Error, Hashable, Sendable, CustomStringConvertible {
    package var code: String
    package var message: String
    package var target: String

    package init(code: String, message: String, target: String = "") {
        self.code = code
        self.message = message
        self.target = target
    }

    package var description: String { "\(code): \(message)\(target.isEmpty ? "" : " (\(target))")" }

    /// Every stable code a daemon puts in `ErrorDetail.code`, spelled once. The gRPC status each one
    /// maps to is the table in `docs/dev/engine-internals.md`; a client switch keys on these strings, so
    /// a new code is added here before it is thrown anywhere.
    package enum Code {
        package static let deviceNotFound = "DEVICE_NOT_FOUND"
        package static let deviceBusy = "DEVICE_BUSY"
        package static let deviceSweeping = "DEVICE_SWEEPING"
        package static let deviceDetached = "DEVICE_DETACHED"
        package static let deviceIO = "DEVICE_IO"
        package static let noDevice = "NO_DEVICE"
        package static let freqOutOfRange = "FREQ_OUT_OF_RANGE"
        package static let rateUnsupported = "RATE_UNSUPPORTED"
        package static let offsetOutOfCapture = "OFFSET_OUT_OF_CAPTURE"
        package static let blindSpot = "BLIND_SPOT"
        package static let gainElementUnknown = "GAIN_ELEMENT_UNKNOWN"
        package static let captureNotFound = "CAPTURE_NOT_FOUND"
        package static let channelNotFound = "CHANNEL_NOT_FOUND"
        package static let sinkNotFound = "SINK_NOT_FOUND"
        package static let streamNotFound = "STREAM_NOT_FOUND"
        package static let jobNotFound = "JOB_NOT_FOUND"
        package static let scanNotFound = "SCAN_NOT_FOUND"
        package static let modeUnsupported = "MODE_UNSUPPORTED"
        package static let unimplemented = "UNIMPLEMENTED"
        package static let platformUnsupported = "PLATFORM_UNSUPPORTED"
        /// Decoders (docs/design/decoders.md, "Decisions"): the registry has no manifest by that
        /// name, and the plugin's program could not be started.
        package static let decoderNotFound = "DECODER_NOT_FOUND"
        package static let decoderFailed = "DECODER_FAILED"
        package static let failedPrecondition = "FAILED_PRECONDITION"
        package static let invalidArgument = "INVALID_ARGUMENT"
        package static let internalError = "INTERNAL"
        /// Daemon-local: the process refuses to start, so no client ever sees it, and it is not in
        /// `all`.
        package static let socketInUse = "SOCKET_IN_USE"

        /// The registry itself: what every client can expect to see, and what the cross-language
        /// tests hold against the documented table.
        package static let all: [String] = [
            deviceNotFound, deviceBusy, deviceSweeping, deviceDetached, deviceIO, noDevice,
            freqOutOfRange, rateUnsupported, offsetOutOfCapture, blindSpot, gainElementUnknown,
            captureNotFound, channelNotFound, sinkNotFound, streamNotFound, jobNotFound, scanNotFound,
            modeUnsupported, unimplemented, platformUnsupported, failedPrecondition, invalidArgument,
            internalError, decoderNotFound, decoderFailed,
        ]
    }

    package static func deviceNotFound(_ id: String) -> EngineError { .init(code: Code.deviceNotFound, message: "no such device", target: id) }
    package static func deviceBusy(_ id: String) -> EngineError { .init(code: Code.deviceBusy, message: "device already has a capture", target: id) }
    package static func deviceStarting(_ id: String) -> EngineError { .init(code: Code.deviceBusy, message: "a capture is starting on it; try again", target: id) }
    package static func deviceHeldByOtherProgram(_ id: String) -> EngineError { .init(code: Code.deviceBusy, message: "another program has the device (rtl_tcp, SDR++, GQRX, hackrf tools?); quit it and retry", target: id) }
    package static func deviceSweeping(_ id: String) -> EngineError { .init(code: Code.deviceSweeping, message: "a scan is sweeping this radio; it is free again when the scan ends", target: id) }
    package static func deviceDetached(_ id: String) -> EngineError { .init(code: Code.deviceDetached, message: "device is disconnected", target: id) }
    package static func deviceIO(_ msg: String, target: String = "") -> EngineError { .init(code: Code.deviceIO, message: msg, target: target) }
    package static func freqOutOfRange(_ hz: UInt64, target: String) -> EngineError { .init(code: Code.freqOutOfRange, message: "\(hz) Hz is outside the device tuning range", target: target) }
    package static func rateUnsupported(_ hz: UInt64, target: String) -> EngineError { .init(code: Code.rateUnsupported, message: "\(hz) sps is not a supported sample rate", target: target) }
    package static func offsetOutOfCapture(_ hz: Int64, target: String) -> EngineError { .init(code: Code.offsetOutOfCapture, message: "offset \(hz) Hz falls outside the capture bandwidth", target: target) }
    package static func gainElementUnknown(_ name: String, target: String) -> EngineError { .init(code: Code.gainElementUnknown, message: "no gain element named \(name)", target: target) }
    package static func captureNotFound(_ id: String) -> EngineError { .init(code: Code.captureNotFound, message: "no such capture", target: id) }
    package static func channelNotFound(_ id: String) -> EngineError { .init(code: Code.channelNotFound, message: "no such channel", target: id) }
    package static func sinkNotFound(_ id: String) -> EngineError { .init(code: Code.sinkNotFound, message: "no such sink", target: id) }
    package static func streamNotFound(_ id: String) -> EngineError { .init(code: Code.streamNotFound, message: "no such stream", target: id) }
    package static func modeUnsupported(_ mode: String, target: String = "") -> EngineError { .init(code: Code.modeUnsupported, message: "demodulator \(mode) is not available", target: target) }
    package static func jobNotFound(_ id: String) -> EngineError { .init(code: Code.jobNotFound, message: "no such job", target: id) }
    package static func scanNotFound(_ id: String) -> EngineError { .init(code: Code.scanNotFound, message: "no such scan", target: id) }
    package static func unimplemented(_ what: String) -> EngineError { .init(code: Code.unimplemented, message: "\(what) is not implemented in v0", target: "") }
    package static func invalidArgument(_ msg: String, target: String = "") -> EngineError { .init(code: Code.invalidArgument, message: msg, target: target) }
    package static func platformUnsupported(_ what: String) -> EngineError { .init(code: Code.platformUnsupported, message: "\(what) requires macOS", target: "") }
    package static func decoderNotFound(_ name: String) -> EngineError { .init(code: Code.decoderNotFound, message: "no decoder named \(name) is installed", target: name) }
    package static func decoderFailed(_ msg: String, target: String = "") -> EngineError { .init(code: Code.decoderFailed, message: msg, target: target) }
    /// A precondition the caller can see and fix, where no more specific code fits.
    package static func failedPrecondition(_ msg: String, target: String = "") -> EngineError { .init(code: Code.failedPrecondition, message: msg, target: target) }
    /// A fault the caller did not cause and cannot act on; the prose is whatever went wrong.
    package static func internalError(_ msg: String, target: String = "") -> EngineError { .init(code: Code.internalError, message: msg, target: target) }
}
