// Leyline engine — internal protocol surface. Hand-designed and never generated.
// The wire contract (leyline.v1 protos, target LeylineProto) is a separate artifact; the daemon
// target maps between the two. EngineCore never imports LeylineProto.
//
// This file is the engine's contract. It was transcribed from the planning-phase signature sketch
// (docs/sdr-planning-todo.md §5) into compiling Swift; the concrete model types it references live in
// Model.swift, Identifiers.swift and Buffers.swift. Threading and ownership rules are in
// docs/engine-internals.md — read that before implementing anything here.
//
// Hot-path conventions (CLAUDE.md invariant 4):
//   - Sample buffers are engine-owned, preallocated, and reused. No allocation in process paths.
//   - `SampleBuffer` wraps raw memory + count + format; it is a borrow, never an owner, inside
//     processing calls. It never escapes the call it is passed to.
//   - Anything marked "hot path" is synchronous, allocation-free, lock-free, and non-async. It is
//     invoked from the capture's DSP thread (or the device I/O thread for `RadioDevice` delivery).

import Foundation

// MARK: - Timebase

/// Sample-indexed time within one timeline. The engine's only clock in signal paths.
/// `captureID` scopes the timeline; comparison is only meaningful within one timeline.
public struct SampleTime: Hashable, Comparable, Sendable {
    public var captureID: CaptureID
    public var sampleIndex: UInt64

    public init(captureID: CaptureID, sampleIndex: UInt64) {
        self.captureID = captureID
        self.sampleIndex = sampleIndex
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.sampleIndex < rhs.sampleIndex }
}

/// One per capture: maps sample 0 to host time. Wall clock is derived from this, never carried per-frame.
public struct CaptureAnchor: Hashable, Sendable {
    /// CLOCK_REALTIME nanoseconds at sample index 0.
    public var hostTimeNsAtSampleZero: Int64
    public var sampleRate: UInt64
    /// Measured drift; 0 if unknown.
    public var driftPPM: Double

    public init(hostTimeNsAtSampleZero: Int64, sampleRate: UInt64, driftPPM: Double = 0) {
        self.hostTimeNsAtSampleZero = hostTimeNsAtSampleZero
        self.sampleRate = sampleRate
        self.driftPPM = driftPPM
    }

    /// Derived wall clock for a sample index on this anchor's timeline.
    public func hostTimeNs(at sampleIndex: UInt64) -> Int64 {
        guard sampleRate > 0 else { return hostTimeNsAtSampleZero }
        let ns = (Double(sampleIndex) / Double(sampleRate)) * 1e9 * (1 + driftPPM * 1e-6)
        return hostTimeNsAtSampleZero + Int64(ns)
    }
}

// MARK: - Devices

/// One physical or virtual SDR. Implementations: RTLSDRDevice, FilePlaybackDevice, and later
/// HackRFDevice, AirspyDevice, SDRplayDevice, CompositeDevice (coherent rigs presented as one).
/// TX, when it arrives, is a separate `TransmitCapableDevice` protocol composed onto devices that
/// support it — never widen RadioDevice with TX methods (CLAUDE.md invariant 11).
public protocol RadioDevice: AnyObject, Sendable {
    var descriptor: DeviceDescriptor { get }
    /// Current setting of every gain element, in descriptor order.
    var gains: [GainState] { get }

    func open() async throws
    func close() async
    func tune(centerHz: UInt64) async throws
    func setSampleRate(_ hz: UInt64) async throws
    func setGain(element: String, value: GainValue) async throws

    /// Begin streaming on the given timeline. The device calls `deliver` from its own I/O context with
    /// engine-owned buffers in the device's native format; the callback must copy-or-consume before
    /// returning and must not block. `SampleTime.sampleIndex` counts samples since this call.
    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws
    func stopStreaming() async

    /// Samples the driver has already asked the hardware for and not yet delivered.
    ///
    /// This is the settle window after a retune, and it is much larger than anything to do with
    /// the tuner: a PLL relocks in under a millisecond, while librtlsdr keeps 32 USB buffers of
    /// 16384 complex samples queued, which is 218 ms at 2.4 MSPS of already-captured air arriving
    /// after the new centre is set. `tune` does not flush them, and the spectrum ladder stamps
    /// every row with the centre in force when the row was computed -- so a sweep that does not
    /// discard this much after a hop attributes energy to a frequency the radio was not on.
    ///
    /// Zero for a device with no queue ahead of it. A bound, not a measurement: it is derived from
    /// the driver's own buffer geometry.
    var inFlightSamples: UInt64 { get }
}

public extension RadioDevice {
    /// Devices with no driver queue -- file playback, synthetic sources -- deliver what they are
    /// asked for when they are asked for it.
    var inFlightSamples: UInt64 { 0 }
}

/// Discovers devices, tracks hot-plug, maps serials to stable DeviceIDs across replug.
/// Also hosts virtual devices (file playback, rtl_tcp), which appear and disappear like hot-plugged hardware.
public protocol DeviceRegistry: AnyObject, Sendable {
    var devices: [DeviceDescriptor] { get async }
    func device(id: DeviceID) async -> (any RadioDevice)?
    /// Every subscriber gets every event from the moment of subscription.
    func events() -> AsyncStream<DeviceEvent>

    func attachFileDevice(path: String, loop: Bool) async throws -> DeviceDescriptor
    /// Hosts an already-constructed virtual device (network source, synthetic source). The registry
    /// assigns the stable id, installs its state-change hook and publishes `arrived`. Attaching a
    /// device whose identity is already hosted returns the existing descriptor.
    func attachVirtualDevice(_ device: any RadioDevice) async throws -> DeviceDescriptor
    /// Detaches any virtual device (file or `attachVirtualDevice`): closes it and publishes `removed`.
    func detachFileDevice(id: DeviceID) async throws
}

public enum DeviceEvent: Sendable {
    case arrived(DeviceDescriptor)
    case removed(DeviceID)
    case changed(DeviceDescriptor)
}

// MARK: - Capture engine

/// Owns one open device stream: the fan-out point for channels, the FFT ladder, and capture-level taps.
/// One device per capture (invariant 10). State transitions: created -> active -> (detached <-> active) -> stopped.
public protocol CaptureEngine: AnyObject, Sendable {
    var id: CaptureID { get }
    var deviceID: DeviceID { get }
    var snapshot: CaptureSnapshot { get async }
    var spectrum: any SpectrumLadder { get }

    /// Opens the device, starts streaming and the DSP thread. Establishes the anchor.
    func start() async throws
    /// Stops streaming, tears down channels and taps, closes the device.
    func stop() async

    func retune(centerHz: UInt64) async throws
    func setSampleRate(_ hz: UInt64) async throws
    func setGain(element: String, value: GainValue) async throws

    func addChannel(_ config: ChannelConfig) async throws -> any ChannelEngine
    func removeChannel(_ id: ChannelID) async
    func channel(id: ChannelID) async -> (any ChannelEngine)?
    var channels: [any ChannelEngine] { get async }

    /// Capture-level consumers of the full-rate cf32 stream (IQ recording, IQ bulk streams).
    func addTap(_ tap: any CaptureTap) async
    func removeTap(id: StreamID) async

    /// Enters .detached on device loss; channels pause without teardown.
    func deviceLost() async
    /// Rebinds automatically on matching-serial replug; resumes channels.
    func deviceRebound(_ device: any RadioDevice) async throws
}

public struct CaptureSnapshot: Hashable, Sendable {
    public var centerHz: UInt64
    public var sampleRate: UInt64
    public var detached: Bool
    public var anchor: CaptureAnchor
    public var gains: [GainState]

    public init(centerHz: UInt64, sampleRate: UInt64, detached: Bool, anchor: CaptureAnchor, gains: [GainState]) {
        self.centerHz = centerHz
        self.sampleRate = sampleRate
        self.detached = detached
        self.anchor = anchor
        self.gains = gains
    }
}

/// Receives the capture's full-rate stream as interleaved cf32. Hot path.
public protocol CaptureTap: AnyObject, Sendable {
    var id: StreamID { get }
    /// `iq` is interleaved cf32 (format == .cf32). Copy-or-consume; never block.
    func write(iq: SampleBuffer, at time: SampleTime)
    func closeTap() async
}

public struct ChannelConfig: Hashable, Sendable {
    /// Offset from capture center; absolute frequency = center + offset.
    public var offsetHz: Int64
    public var bandwidthHz: UInt32
    public var mode: DemodMode
    /// dBFS threshold; NaN = squelch off.
    public var squelchDB: Double
    public var agc: GainMode
    /// Survives owner disconnect; jobs set this.
    public var persistent: Bool
    /// Set by jobs: rebind target when OUT_OF_CAPTURE.
    public var requiredHz: UInt64?
    /// Watch for a sub-audible tone (CTCSS/PL). NFM only; ignored for every other mode. It never
    /// gates audio: tone squelch is a separate, later decision, because a false negative there is
    /// silence the user cannot diagnose.
    public var subAudibleDetect: Bool

    public init(offsetHz: Int64, bandwidthHz: UInt32, mode: DemodMode, squelchDB: Double = .nan,
                agc: GainMode = .auto, persistent: Bool = false, requiredHz: UInt64? = nil,
                subAudibleDetect: Bool = false) {
        self.offsetHz = offsetHz
        self.bandwidthHz = bandwidthHz
        self.mode = mode
        self.squelchDB = squelchDB
        self.agc = agc
        self.persistent = persistent
        self.requiredHz = requiredHz
        self.subAudibleDetect = subAudibleDetect
    }

    // NaN-aware equality so squelch-off compares equal to squelch-off.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.offsetHz == rhs.offsetHz && lhs.bandwidthHz == rhs.bandwidthHz && lhs.mode == rhs.mode
            && (lhs.squelchDB == rhs.squelchDB || (lhs.squelchDB.isNaN && rhs.squelchDB.isNaN))
            && lhs.agc == rhs.agc && lhs.persistent == rhs.persistent && lhs.requiredHz == rhs.requiredHz
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(offsetHz); hasher.combine(bandwidthHz); hasher.combine(mode)
        hasher.combine(squelchDB.isNaN ? 0 : squelchDB.bitPattern)
        hasher.combine(agc); hasher.combine(persistent); hasher.combine(requiredHz)
    }
}

// MARK: - Channels & DSP

/// One demod chain inside a capture: translate -> filter -> demodulate -> distribute to sinks.
public protocol ChannelEngine: AnyObject, Sendable {
    var id: ChannelID { get }
    var captureID: CaptureID { get }
    var config: ChannelConfig { get async }
    var state: ChannelState { get async }
    /// Output audio rate in Hz, fixed by the capture rate and the decimation chain.
    var audioRate: UInt32 { get }

    func update(_ config: ChannelConfig) async throws
    func attach(_ sink: any AudioSink) async throws
    func detach(_ id: SinkID) async
    var sinks: [any AudioSink] { get async }

    /// OUT_OF_CAPTURE handling: pause without teardown when the capture retunes away; resume when it returns.
    func captureMoved(newCenterHz: UInt64) async

    /// Telemetry (meters at a fixed cadence, squelch transitions edge-triggered). Every subscriber gets
    /// every message from the moment of subscription; drop-oldest under backpressure (see `telemetryDropped`).
    func telemetry() -> AsyncStream<ChannelTelemetry>
    /// `telemetry()` plus this subscriber's own drop counter: the fan-out buffer behind the stream is
    /// drop-oldest too, and every record it discards because *this* subscriber fell behind is counted
    /// in `ChannelTelemetrySubscription.dropped` (diff it between records, like `telemetryDropped`).
    func telemetrySubscription() -> ChannelTelemetrySubscription
    /// Cumulative count of telemetry records the engine evicted (drop-oldest) before any subscriber
    /// could see them. Subscribers diff it between records to surface a sequence gap.
    var telemetryDropped: Int { get }
}

public enum ChannelState: Hashable, Sendable {
    case active
    case outOfCapture
}

public enum ChannelTelemetry: Sendable {
    /// `audioDBFS`/`audioPeakDBFS` are what the listener hears over the meter interval, measured on
    /// the demodulated block; NaN when there is no audio to measure (a raw-IQ channel, or before the
    /// first block). NaN means "not measured" and is not the same as 0 dBFS, which is very loud.
    case meter(time: SampleTime, powerDBFS: Double, snrDB: Double, squelchOpen: Bool,
               audioDBFS: Double, audioPeakDBFS: Double)
    /// A squelch edge. `openSamples` and the two peaks summarise the transmission that just ended
    /// and are meaningful on a close edge only (`open == false`); an open edge carries 0 and NaN,
    /// because a transmission still in progress has neither a duration nor a final peak.
    case squelch(time: SampleTime, open: Bool, openSamples: UInt64, peakSNRDB: Double, peakPowerDBFS: Double)
    /// A sub-audible tone, or the absence of one. Emitted only while the channel asked for it.
    case subAudible(time: SampleTime, result: SubAudibleResult)
}

/// A demodulator that can hand out its raw discriminator output, decimated to roughly 1 kHz, for
/// sub-audible tone detection.
///
/// The tap is set once when the channel is built and never changes for the life of the DSP core, so
/// the hot path reads a reference nobody is writing. Everything the tap does is decimation into a
/// ring; every decision about what the samples mean happens in a slow task draining it.
public protocol SubAudibleSource: AnyObject {
    /// Deviation in Hz that maps to ±1.0 in the discriminator output (5 kHz NFM, 75 kHz WFM).
    var fullScaleDeviationHz: Double { get }
    /// Where to write decimated discriminator output. nil (the default) costs the hot path a single
    /// nil check per block.
    var subAudibleTap: FloatRing? { get set }
    /// The rate `subAudibleTap` is written at. Zero until `configure`.
    var subAudibleRate: Double { get }
}

/// A demodulator stage. Implementations per DemodMode, all vDSP-backed on macOS.
/// `process` is the hot path: synchronous, allocation-free, called from the capture's DSP thread.
public protocol Demodulator: AnyObject {
    var mode: DemodMode { get }
    /// `inputRate` is the channel (post-decimation) rate; output audio rate equals `inputRate` unless
    /// `outputRate` says otherwise (WFM decimates internally).
    func configure(inputRate: UInt32, bandwidthHz: UInt32) throws
    var outputRate: UInt32 { get }
    /// Maximum input samples per call the demodulator's scratch is sized for.
    var maxBlock: Int { get }
    /// `input` is interleaved cf32 at `inputRate`; `output` is real f32 mono (format == .f32) with
    /// capacity `output.count` frames on entry. Returns frames produced (output.count is not mutated).
    func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer) -> Int
    func reset()
}

/// The shared FFT ladder: fixed power-of-two sizes, one pass per size per tick, fanned to all
/// subscribers. Subscribers get the nearest size the ladder computes and at most the rate they ask for.
public protocol SpectrumLadder: AnyObject, Sendable {
    /// Requested `bins`/`rowsPerSecond` may be downgraded, never upgraded; the returned subscription is authoritative.
    func subscribe(bins: Int, rowsPerSecond: Double, accumulation: SpectrumAccumulation,
                   policy: DeliveryPolicy, sink: any SpectrumSink) async -> SpectrumSubscription
    func cancel(_ subscription: SpectrumSubscription) async
}

/// How a spectrum row is built from the samples it covers.
public enum SpectrumAccumulation: Sendable, Hashable {
    /// One periodogram per row, from whichever block crossed the row boundary. At 2.4 MSPS a
    /// 1024-point FFT covers 0.17% of a 250 ms row, so a burst shorter than a row shows up only
    /// sometimes. Right for a live band chart, wrong for anything reading duty cycle.
    case snapshot
    /// Power mean over the looks taken in the row: a stable floor that dilutes short bursts.
    case mean
    /// Elementwise maximum over the looks: catches bursts, and reads the noise floor a few dB high
    /// because the maximum of N draws is biased upward.
    case max
}

public struct SpectrumSubscription: Hashable, Sendable {
    public var id: StreamID
    public var actualBins: Int
    public var actualRate: Double
    public var accumulation: SpectrumAccumulation
    /// Looks the ladder takes per row. Always 1 under `.snapshot`.
    public var looksPerRow: Int

    public init(id: StreamID, actualBins: Int, actualRate: Double,
                accumulation: SpectrumAccumulation = .snapshot, looksPerRow: Int = 1) {
        self.id = id
        self.actualBins = actualBins
        self.actualRate = actualRate
        self.accumulation = accumulation
        self.looksPerRow = looksPerRow
    }
}

/// Receives FFT rows. Hot path (DSP thread): copy-or-consume, never block.
public protocol SpectrumSink: AnyObject, Sendable {
    /// `row` is `bins` dBFS values, DC-centered (fft-shifted), lowest frequency first.
    ///
    /// `looks` is how many periodograms were averaged into this row: 1 under `.snapshot`, and
    /// under `.mean` however many blocks actually arrived during the row interval, which is not
    /// the subscription's `looksPerRow` (that is a cap). Anything doing statistics on a row needs
    /// it -- an averaged bin is Gamma-distributed with that shape, so a detector that assumes 16
    /// looks and gets 2 sets its threshold about 4 dB too low and calls noise a carrier.
    func write(row: UnsafeBufferPointer<Float>, at time: SampleTime, centerHz: UInt64, spanHz: UInt64, looks: Int)
}

public enum DeliveryPolicy: Hashable, Sendable {
    case latestWins
    case gapMarked
}

// MARK: - Sinks

/// Where demodulated audio goes. Implementations: CoreAudioSink, StreamAudioSink (bulk plane),
/// FileRecorderSink, NullSink. Lossless delivery exists only in FileRecorderSink.
public protocol AudioSink: AnyObject, Sendable {
    var id: SinkID { get }
    /// Hot path: synchronous, allocation-free. `audio` is real f32 mono (format == .f32).
    func write(_ audio: SampleBuffer, at time: SampleTime)
    func flush() async
    func closeSink() async
}

// MARK: - Detector

/// v0: energy detection over the FFT ladder. Noise-floor estimation, threshold crossing,
/// carrier/bandwidth/SNR estimation, persistence tracking across sweep passes. (Milestone D.)
public protocol Detector: AnyObject, Sendable {
    func observe(fftRow: UnsafeBufferPointer<Float>, at time: SampleTime, centerHz: UInt64, spanHz: UInt64)
    func detections() -> AsyncStream<Detection>
    func snapshotDetections() async -> [Detection]
}

public struct Detection: Hashable, Sendable {
    public var centerHz: UInt64
    public var bandwidthHz: UInt32
    public var snrDB: Double
    public var firstSeen: SampleTime
    public var lastSeen: SampleTime
    /// Empty or cheap-heuristic only, with stated confidence (invariant 12).
    public var modulationGuess: String?
    public var guessConfidence: Double
}

// MARK: - Jobs (Milestone D)

/// Daemon-owned persistent intents. Respawned from the store on daemon start.
/// A table of watches, not a workflow engine.
public protocol JobRunner: AnyObject, Sendable {
    var id: JobID { get }
    func start(context: JobContext) async throws
    func cancel() async
    func status() async -> JobStatus
}

public struct JobContext: Sendable {
    // store, capture allocator (don't-disturb policy lives here), telemetry out — filled in with Milestone D.
    public init() {}
}

public enum JobStatus: Sendable {
    case running
    case degraded(String)
    case completed
    case cancelled
    case failed(String)
}

/// Allocates captures/channels for jobs under the don't-disturb policy:
/// prefer idle devices; never retune a capture with recent interactive activity (invariant 9).
///
/// Jobs never name a capture. A watch wants one channel inside whatever capture it can get; a
/// sweep wants a whole radio to itself for several seconds, which no channel can express -- a
/// channel's offset is bounded by the sample rate, and a sweep walks megahertz. So the allocator
/// answers a sweep with a *lease*, which is the only handle a job ever has on tuning.
public protocol CaptureAllocator: Sendable {
    func allocate(_ request: AllocationRequest, for job: JobID) async -> AllocationResult
}

public enum AllocationRequest: Sendable {
    /// One demod chain at a frequency, inside any capture that covers it.
    case channel(frequencyHz: UInt64, bandwidthHz: UInt32)
    /// A whole radio, retunable, for the duration of the lease. `takeOver` skips the politeness
    /// checks (a capture with channels, a live audio sink, a recent interactive write) but never
    /// the exclusivity one: two sweeps do not share a radio.
    case exclusiveCapture(rangeHz: ClosedRange<UInt64>, takeOver: Bool)
}

public enum AllocationResult: Sendable {
    case channel(ChannelID)
    case capture(any CaptureLease)
    /// `code` is a stable machine string; `reason` names what is using the radio, in prose.
    case declined(code: String, reason: String)
}

/// A job's exclusive hold on one capture. Retuning through the lease bypasses the write coalescer
/// deliberately: that path keeps last-value-per-parameter on a 20 ms tick and would silently eat
/// sweep steps.
public protocol CaptureLease: AnyObject, Sendable {
    var captureID: CaptureID { get }
    var sampleRateHz: UInt64 { get }
    var centerHz: UInt64 { get async }
    /// Samples the driver has queued ahead of the retune -- the settle window (see
    /// `RadioDevice.inFlightSamples`), plus whatever is already in the capture's own ring.
    var settleSamples: UInt64 { get async }
    /// Where the capture's timeline has reached. A sweep needs this and not merely the newest row
    /// it has seen: rows arrive at the row rate, so the last one can be a whole row interval
    /// behind the radio, and a settle window measured from it starts too early.
    var sampleIndex: UInt64 { get async }
    /// The ladder this capture computes, for a detector to subscribe to.
    var spectrum: any SpectrumLadder { get }
    /// The gain the lease pinned for its duration.
    var pinnedGains: [GainState] { get async }

    func retune(centerHz: UInt64) async throws
    /// Restores what was borrowed: the original centre and gain, or the capture is destroyed if
    /// the lease created it. Idempotent, and must run on cancellation as well as on success.
    func release() async
}

// MARK: - Store (Milestone C/D)

/// Resources: a plain directory Finder can see, plus a metadata index.
public protocol ResourceStore: AnyObject, Sendable {
    func create(kind: ResourceKind, metadata: [String: String]) async throws -> ResourceHandle
    func find(kind: ResourceKind?, matching: [String: String]) async -> [ResourceRecord]
    func localPath(uri: String) async -> URL?
}

public enum ResourceKind: String, Hashable, Sendable {
    case recording, scan, snapshot, transcript
}

public struct ResourceHandle: Sendable {
    public var uri: String
    public var writeURL: URL
}

public struct ResourceRecord: Sendable {
    public var uri: String
    public var kind: ResourceKind
    public var createdAt: Date
    public var sizeBytes: UInt64
    public var metadata: [String: String]
}
