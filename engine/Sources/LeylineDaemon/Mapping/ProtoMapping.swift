// Engine <-> leyline.v1 mapping. EngineCore never imports the protos; this is the one place the two
// vocabularies meet (docs/engine-internals.md "Daemon").

import EngineCore
import Foundation
import GRPCCore
import LeylineProto

/// Namespace for engine -> proto and proto -> engine conversions.
enum ProtoMapping {
    // MARK: Enums

    static func deviceState(_ s: DeviceState) -> Leyline_V1_DeviceState {
        switch s {
        case .available: return .available
        case .inUse: return .inUse
        case .disconnected: return .disconnected
        }
    }

    /// cu8 has no wire enum; RTL-SDR's offset-binary bytes are reported as CS8 (8-bit I/Q).
    static func sampleFormat(_ f: SampleFormat) -> Leyline_V1_SampleFormat {
        switch f {
        case .cu8, .cs8: return .cs8
        case .cs16: return .cs16
        case .cf32: return .cf32
        case .f32: return .unspecified
        }
    }

    static func demodMode(_ m: DemodMode) -> Leyline_V1_DemodMode {
        switch m {
        case .am: return .am
        case .nfm: return .nfm
        case .wfm: return .wfm
        case .usb: return .usb
        case .lsb: return .lsb
        case .cw: return .cw
        case .rawIQ: return .rawIq
        }
    }

    /// Returns nil for UNSPECIFIED / unknown values (callers reject with MODE_UNSUPPORTED).
    static func demodMode(_ m: Leyline_V1_DemodMode) -> DemodMode? {
        switch m {
        case .am: return .am
        case .nfm: return .nfm
        case .wfm: return .wfm
        case .usb: return .usb
        case .lsb: return .lsb
        case .cw: return .cw
        case .rawIq: return .rawIQ
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    static func gainMode(_ g: GainMode) -> Leyline_V1_GainMode {
        switch g {
        case .manual: return .manual
        case .auto: return .auto
        }
    }

    static func channelState(_ s: ChannelState) -> Leyline_V1_ChannelState {
        switch s {
        case .active: return .channelActive
        case .outOfCapture: return .outOfCapture
        }
    }

    // MARK: Devices

    static func gainElement(_ g: GainElement) -> Leyline_V1_GainElement {
        var out = Leyline_V1_GainElement()
        out.name = g.name
        out.minDb = g.minDB
        out.maxDb = g.maxDB
        out.stepDb = g.stepDB
        out.supportsAuto = g.supportsAuto
        out.validDb = g.validDB
        return out
    }

    static func featureValue(_ v: FeatureValue) -> Leyline_V1_FeatureValue {
        var out = Leyline_V1_FeatureValue()
        switch v {
        case .flag(let b): out.value = .flag(b)
        case .integer(let i): out.value = .integer(i)
        case .number(let d): out.value = .number(d)
        case .text(let s): out.value = .text(s)
        }
        return out
    }

    static func descriptor(_ d: DeviceDescriptor) -> Leyline_V1_DeviceDescriptor {
        var out = Leyline_V1_DeviceDescriptor()
        out.deviceID = d.id.string
        out.driver = d.driver
        out.model = d.model
        out.serial = d.serial
        out.usbLocation = d.usbLocation
        out.state = deviceState(d.state)
        out.tuningRanges = d.tuningRanges.map { r in
            var fr = Leyline_V1_FrequencyRange()
            fr.minHz = r.minHz
            fr.maxHz = r.maxHz
            return fr
        }
        out.sampleRates = d.sampleRates
        out.nativeFormat = sampleFormat(d.nativeFormat)
        out.gainElements = d.gainElements.map(gainElement)
        out.providesTimestamps = d.providesTimestamps
        for (k, v) in d.features { out.features[k] = featureValue(v) }
        return out
    }

    // MARK: Timebase

    static func sampleTime(_ t: SampleTime) -> Leyline_V1_SampleTime {
        var out = Leyline_V1_SampleTime()
        out.captureID = t.captureID.string
        out.sampleIndex = t.sampleIndex
        return out
    }

    static func anchor(_ a: CaptureAnchor, captureID: CaptureID) -> Leyline_V1_CaptureAnchor {
        var out = Leyline_V1_CaptureAnchor()
        out.captureID = captureID.string
        out.hostTimeNs = a.hostTimeNsAtSampleZero
        out.sampleRate = a.sampleRate
        out.driftPpm = a.driftPPM
        return out
    }

    // MARK: Session objects

    static func gainState(_ g: GainState) -> Leyline_V1_GainState {
        var out = Leyline_V1_GainState()
        out.element = g.element
        switch g.value {
        case .db(let db): out.db = db
        case .auto: out.auto = true
        }
        return out
    }

    /// Daemon-side bookkeeping the proto Capture carries beside the engine snapshot.
    struct CaptureMeta {
        var createdBy: Leyline_V1_ClientInfo
        var lastInteractiveWriteNs: Int64
        var liveAudioSinks: UInt32
    }

    static func capture(id: CaptureID, deviceID: DeviceID, snapshot: CaptureSnapshot, meta: CaptureMeta) -> Leyline_V1_Capture {
        var out = Leyline_V1_Capture()
        out.captureID = id.string
        out.deviceID = deviceID.string
        out.centerHz = snapshot.centerHz
        out.sampleRate = snapshot.sampleRate
        out.state = snapshot.detached ? .captureDetached : .captureActive
        out.anchor = anchor(snapshot.anchor, captureID: id)
        out.activity.lastInteractiveWriteNs = meta.lastInteractiveWriteNs
        out.activity.liveAudioSinks = meta.liveAudioSinks
        out.createdBy = meta.createdBy
        out.gains = snapshot.gains.map(gainState)
        return out
    }

    static func channel(id: ChannelID, captureID: CaptureID, config: ChannelConfig, state: ChannelState?, owner: Leyline_V1_ClientInfo) -> Leyline_V1_Channel {
        var out = Leyline_V1_Channel()
        out.channelID = id.string
        out.captureID = captureID.string
        out.offsetHz = config.offsetHz
        out.bandwidthHz = config.bandwidthHz
        out.mode = demodMode(config.mode)
        out.squelchDb = config.squelchDB
        out.agc = gainMode(config.agc)
        out.state = state.map(channelState) ?? .unspecified
        out.persistent = config.persistent
        out.requiredHz = config.requiredHz ?? 0
        out.owner = owner
        return out
    }

    // MARK: Errors

    static func errorDetail(_ e: EngineError) -> Leyline_V1_ErrorDetail {
        var out = Leyline_V1_ErrorDetail()
        out.code = e.code
        out.message = e.message
        out.target = e.target
        return out
    }

    /// gRPC status code for a stable engine code.
    static func statusCode(for code: String) -> RPCError.Code {
        switch code {
        case "DEVICE_NOT_FOUND", "CAPTURE_NOT_FOUND", "CHANNEL_NOT_FOUND", "SINK_NOT_FOUND", "STREAM_NOT_FOUND":
            return .notFound
        case "DEVICE_BUSY": return .resourceExhausted
        case "DEVICE_DETACHED": return .failedPrecondition
        case "DEVICE_IO": return .unavailable
        case "FREQ_OUT_OF_RANGE", "RATE_UNSUPPORTED", "OFFSET_OUT_OF_CAPTURE", "GAIN_ELEMENT_UNKNOWN",
             "MODE_UNSUPPORTED", "INVALID_ARGUMENT":
            return .invalidArgument
        case "UNIMPLEMENTED", "PLATFORM_UNSUPPORTED": return .unimplemented
        default: return .internalError
        }
    }

    /// Wire form of an engine error: status message "CODE: message" and the serialised
    /// `ErrorDetail` in the trailing metadata key `leyline-error-bin`.
    static func rpcError(_ e: EngineError) -> RPCError {
        var md = Metadata()
        if let bytes = try? errorDetail(e).serializedBytes() as [UInt8] {
            md.addBinary(bytes, forKey: "leyline-error-bin")
        }
        return RPCError(code: statusCode(for: e.code), message: "\(e.code): \(e.message)", metadata: md)
    }

    /// Maps any thrown error to the wire form: EngineErrors keep their code, RPCErrors pass through,
    /// everything else becomes INTERNAL.
    static func rpcError(_ error: any Error) -> RPCError {
        if let e = error as? EngineError { return rpcError(e) }
        if let r = error as? RPCError { return r }
        return rpcError(EngineError(code: "INTERNAL", message: String(describing: error)))
    }
}

/// Converts engine errors thrown by `body` into `RPCError` with the leyline trailer.
func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch { throw ProtoMapping.rpcError(error) }
}
