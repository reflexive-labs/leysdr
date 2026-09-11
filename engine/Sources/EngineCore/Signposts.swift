// os_signpost helpers for the sample path. Category "SamplePath" (docs/engine-internals.md,
// "Hot-path rules"). No-ops where the `os` module is unavailable. Nothing here allocates: names are
// `StaticString`, the `OSLog` handle is created once and intervals use the free-function
// `os_signpost` API with value-type `OSSignpostID`s (no `OSSignpostIntervalState` objects).

#if canImport(os)
import os
#endif

/// Signpost intervals and events around the hot path. Usage:
///
///     let s = Signpost.begin(.blockIngest)
///     ... work ...
///     Signpost.end(.blockIngest, s)
///
/// The interval names are the ones the S1/S2 spike measurements key on; keep them stable.
public enum Signpost {
    /// Interval/event names used on the sample path.
    public enum Name: CaseIterable {
        /// One device block converted and pushed into the block ring.
        case blockIngest
        /// One channel's NCO → FIR → demod → sinks pass for one block.
        case channelProcess
        /// One spectrum ladder tick (all requested sizes).
        case ladderPass
        /// A ring overrun event (producer dropped a block / samples).
        case ringOverrun
        /// One demodulator `process` call.
        case demodulate
        /// One FFT of a given size.
        case fft
        /// One `AudioSink.write`: the handoff from the DSP thread to an output device or a client.
        case audioWrite
        /// One frame pushed into a bulk stream's `FrameRing`.
        case frameRingWrite
        /// One spectrum row folded into a persistence histogram.
        case persistenceAdd
        /// One sweep row handed to the scan collector.
        case sweepRow

        @inline(__always) var staticName: StaticString {
            switch self {
            case .blockIngest: return "blockIngest"
            case .channelProcess: return "channelProcess"
            case .ladderPass: return "ladderPass"
            case .ringOverrun: return "ringOverrun"
            case .demodulate: return "demodulate"
            case .fft: return "fft"
            case .audioWrite: return "audioWrite"
            case .frameRingWrite: return "frameRingWrite"
            case .persistenceAdd: return "persistenceAdd"
            case .sweepRow: return "sweepRow"
            }
        }
    }

    /// Opaque token returned by `begin`, consumed by `end`. Holds a value-type `OSSignpostID`: the
    /// `OSSignposter.beginInterval` API is deliberately avoided because its `OSSignpostIntervalState`
    /// is a class instance, i.e. a heap allocation per interval while recording.
    public struct Token {
        #if canImport(os)
        @usableFromInline let id: OSSignpostID
        @usableFromInline let active: Bool
        #endif
    }

    #if canImport(os)
    @usableFromInline static let log = OSLog(subsystem: "com.leyline.engine", category: "SamplePath")
    #endif

    /// Whether signposts are being recorded. On non-Darwin this is always false.
    public static var isEnabled: Bool {
        #if canImport(os)
        return log.signpostsEnabled
        #else
        return false
        #endif
    }

    /// Begin an interval. Returns a token that must be passed to `end` with the same name.
    @inline(__always)
    public static func begin(_ name: Name) -> Token {
        #if canImport(os)
        guard log.signpostsEnabled else { return Token(id: .null, active: false) }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name.staticName, signpostID: id)
        return Token(id: id, active: true)
        #else
        return Token()
        #endif
    }

    /// End an interval started with `begin`.
    @inline(__always)
    public static func end(_ name: Name, _ token: Token) {
        #if canImport(os)
        guard token.active else { return }
        os_signpost(.end, log: log, name: name.staticName, signpostID: token.id)
        #endif
    }

    /// Emit a point event (e.g. a ring overrun).
    @inline(__always)
    public static func event(_ name: Name) {
        #if canImport(os)
        guard log.signpostsEnabled else { return }
        os_signpost(.event, log: log, name: name.staticName)
        #endif
    }
}
