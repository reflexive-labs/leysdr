// Leyline engine — internal protocol surface. Signatures only; no implementations.
// These are hand-designed and never generated. The wire contract (leyline.v1 protos) is
// a separate artifact; the daemon maps between the two.
//
// Hot-path conventions:
//   - Sample buffers are engine-owned, preallocated, and reused. No allocation in process paths.
//   - `SampleBuffer` wraps raw memory + count + format; it is a borrow, never an owner,
//     inside processing calls.

import Foundation

// MARK: - Timebase

/// Sample-indexed time within one capture. The engine's only clock in signal paths.
struct SampleTime: Hashable, Comparable {
    var captureID: CaptureID
    var sampleIndex: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool
}

// MARK: - Identifiers (prefixed ULIDs)

struct DeviceID: Hashable, Codable { init(); init?(string: String) }
struct CaptureID: Hashable, Codable { init(); init?(string: String) }
struct ChannelID: Hashable, Codable { init(); init?(string: String) }
struct SinkID: Hashable, Codable { init(); init?(string: String) }
struct JobID: Hashable, Codable { init(); init?(string: String) }
struct StreamID: Hashable, Codable { init(); init?(string: String) }

// MARK: - Buffers

/// A borrowed view of interleaved complex samples. Never escapes the call it is passed to.
struct SampleBuffer {
    var base: UnsafeMutableRawPointer
    var count: Int              // complex samples
    var format: SampleFormat
}

enum SampleFormat { case cs8, cs16, cf32 }

// MARK: - Devices

/// One physical or virtual SDR. Implementations: RTLSDRDevice, HackRFDevice, AirspyDevice,
/// SDRplayDevice, FilePlaybackDevice, and later CompositeDevice (coherent rigs presented as one).
/// TX, when it arrives, is a separate `TransmitCapableDevice` protocol composed onto devices
/// that support it — never widen RadioDevice with TX methods.
protocol RadioDevice: AnyObject, Sendable {
    var descriptor: DeviceDescriptor { get }
    func open() async throws
    func close() async
    func tune(centerHz: UInt64) async throws
    func setSampleRate(_ hz: UInt64) async throws
    func setGain(element: String, value: GainValue) async throws
    /// Begin streaming. The device calls `deliver` from its own I/O context with engine-owned
    /// buffers; the callback must copy-or-consume before returning.
    func startStreaming(deliver: @escaping (SampleBuffer, SampleTime) -> Void) async throws
    func stopStreaming() async
}

enum GainValue { case db(Double); case auto }

/// Discovers devices, tracks hot-plug, maps serials to stable DeviceIDs across replug.
protocol DeviceRegistry: AnyObject, Sendable {
    var devices: [DeviceDescriptor] { get async }
    func device(id: DeviceID) async -> (any RadioDevice)?
    func events() -> AsyncStream<DeviceEvent>
}

enum DeviceEvent { case arrived(DeviceDescriptor); case removed(DeviceID); case changed(DeviceDescriptor) }

// MARK: - Capture engine

/// Owns one open device stream: the fan-out point for channels, FFT ladder, and capture-level taps.
protocol CaptureEngine: AnyObject, Sendable {
    var id: CaptureID { get }
    var state: CaptureSnapshot { get async }
    func retune(centerHz: UInt64) async throws
    func setSampleRate(_ hz: UInt64) async throws
    func addChannel(_ config: ChannelConfig) async throws -> any ChannelEngine
    func removeChannel(_ id: ChannelID) async
    /// Enters .detached on device loss; rebinds automatically on matching-serial replug.
    func deviceLost() async
    func deviceRebound(_ device: any RadioDevice) async throws
}

struct CaptureSnapshot { var centerHz: UInt64; var sampleRate: UInt64; var detached: Bool; var anchor: CaptureAnchor }
struct CaptureAnchor { var hostTimeAtSampleZero: UInt64; var sampleRate: UInt64; var driftPPM: Double }
struct ChannelConfig {
    var offsetHz: Int64; var bandwidthHz: UInt32; var mode: DemodMode
    var persistent: Bool; var requiredHz: UInt64?
}

// MARK: - Channels & DSP

/// One demod chain inside a capture: translate -> filter -> demodulate -> distribute to sinks.
protocol ChannelEngine: AnyObject, Sendable {
    var id: ChannelID { get }
    func update(_ config: ChannelConfig) async throws
    func attach(_ sink: any AudioSink) async throws -> SinkID
    func detach(_ id: SinkID) async
    /// OUT_OF_CAPTURE handling: pause without teardown when the capture retunes away.
    func captureMoved(newCenterHz: UInt64) async
}

/// A demodulator stage. Implementations per DemodMode, all vDSP-backed.
/// `process` is the hot path: synchronous, allocation-free, called from the capture's DSP context.
protocol Demodulator: AnyObject {
    var mode: DemodMode { get }
    func configure(inputRate: UInt64, bandwidthHz: UInt32) throws
    func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer) -> Int // frames produced
    func reset()
}

enum DemodMode { case am, nfm, wfm, usb, lsb, cw, rawIQ }

/// The shared FFT ladder: fixed power-of-two sizes, one pass per size per tick,
/// fanned to all subscribers. Subscribers get the nearest size the ladder computes.
protocol SpectrumLadder: AnyObject, Sendable {
    func subscribe(bins: Int, rowsPerSecond: Double, policy: DeliveryPolicy) async -> SpectrumSubscription
    func cancel(_ subscription: SpectrumSubscription) async
}

struct SpectrumSubscription { var id: StreamID; var actualBins: Int; var actualRate: Double }
enum DeliveryPolicy { case latestWins, gapMarked }

// MARK: - Sinks

/// Where demodulated audio (or channel IQ) goes. Implementations: CoreAudioSink,
/// StreamSink (bulk plane), FileRecorderSink. Lossless delivery exists only in FileRecorderSink.
protocol AudioSink: AnyObject, Sendable {
    var id: SinkID { get }
    /// Hot path: synchronous, allocation-free.
    func write(_ audio: SampleBuffer, at time: SampleTime)
    func flush() async
    func closeSink() async
}

// MARK: - Detector

/// v0: energy detection over the FFT ladder. Noise-floor estimation, threshold crossing,
/// carrier/bandwidth/SNR estimation, persistence tracking across sweep passes.
protocol Detector: AnyObject, Sendable {
    func observe(fftRow: SampleBuffer, bins: Int, at time: SampleTime, centerHz: UInt64, spanHz: UInt64)
    func detections() -> AsyncStream<Detection>
    func snapshotDetections() async -> [Detection]
}

struct Detection {
    var centerHz: UInt64; var bandwidthHz: UInt32; var snrDB: Double
    var firstSeen: SampleTime; var lastSeen: SampleTime
    var modulationGuess: String?; var guessConfidence: Double
}

// MARK: - Jobs

/// Daemon-owned persistent intents. Respawned from the store on daemon start.
/// A table of watches, not a workflow engine.
protocol JobRunner: AnyObject, Sendable {
    var id: JobID { get }
    func start(context: JobContext) async throws
    func cancel() async
    func status() async -> JobStatus
}

struct JobContext { /* store, capture allocator (don't-disturb policy lives here), telemetry out */ }
enum JobStatus { case running, degraded(String), completed, cancelled, failed(String) }

/// Allocates captures/channels for jobs under the don't-disturb policy:
/// prefer idle devices; never retune a capture with recent interactive activity.
protocol CaptureAllocator: Sendable {
    func allocate(frequencyHz: UInt64, bandwidthHz: UInt32) async throws -> AllocationResult
}
enum AllocationResult { case channel(ChannelID); case declined(reason: String) }

// MARK: - Store

/// Resources: a plain directory Finder can see, plus a metadata index.
protocol ResourceStore: AnyObject, Sendable {
    func create(kind: ResourceKind, metadata: [String: String]) async throws -> ResourceHandle
    func find(kind: ResourceKind?, matching: [String: String]) async -> [ResourceRecord]
    func localPath(uri: String) async -> URL?
}

enum ResourceKind { case recording, scan, snapshot, transcript }
struct ResourceHandle { var uri: String; var writeURL: URL }
struct ResourceRecord { var uri: String; var kind: ResourceKind; var createdAt: Date; var sizeBytes: UInt64; var metadata: [String: String] }
