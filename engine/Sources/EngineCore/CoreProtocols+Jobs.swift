// SPDX-License-Identifier: GPL-3.0-or-later

// Part of the engine contract (CoreProtocols.swift): hand-written, never generated.
// Jobs, the detector a scan runs, and the store their outputs go to.

import Foundation

// MARK: - Detector

/// v0: energy detection over the FFT ladder. Noise-floor estimation, threshold crossing,
/// carrier/bandwidth/SNR estimation, persistence tracking across sweep passes.
package protocol Detector: AnyObject, Sendable {
    func observe(fftRow: UnsafeBufferPointer<Float>, at time: SampleTime, centerHz: UInt64, spanHz: UInt64)
    func detections() -> AsyncStream<Detection>
    func snapshotDetections() async -> [Detection]
}

package struct Detection: Hashable, Sendable {
    package var centerHz: UInt64
    package var bandwidthHz: UInt32
    package var snrDB: Double
    package var firstSeen: SampleTime
    package var lastSeen: SampleTime
    /// Empty or cheap-heuristic only, with stated confidence (invariant 12).
    package var modulationGuess: String?
    package var guessConfidence: Double
}

// MARK: - Jobs

/// Daemon-owned persistent intents. Respawned from the store on daemon start.
/// A table of watches, not a workflow engine.
///
/// This is the Milestone D.15 contract (docs/plans/build-order.md) for the watch job; there is no
/// implementation yet, and the scan job (`ScanRunner`) does not go through it.
package protocol JobRunner: AnyObject, Sendable {
    var id: JobID { get }
    func start(context: JobContext) async throws
    func cancel() async
    func status() async -> JobStatus
}

package struct JobContext: Sendable {
    // Part of the Milestone D.15 contract; empty until a JobRunner conformance exists to fill it
    // in with the store, the capture allocator (don't-disturb policy lives here), and a telemetry
    // outlet.
    package init() {}
}

package enum JobStatus: Sendable {
    case running
    case degraded(String)
    case completed
    case cancelled
    case failed(String)
}

/// Allocates captures/channels for jobs under the don't-disturb policy:
/// prefer idle devices; never retune a capture with recent interactive activity (invariant 9).
///
/// Jobs never specify a capture. A watch needs one channel inside any capture that covers it. A
/// sweep needs a whole radio to itself for several seconds, which a channel cannot provide: a
/// channel's offset is bounded by the sample rate, and a sweep covers megahertz. So the allocator
/// gives a sweep a *lease*, the only way a job can retune a radio.
package protocol CaptureAllocator: Sendable {
    func allocate(_ request: AllocationRequest, for job: JobID) async -> AllocationResult
}

/// A gain a job asks for on the radio it is allocated: one element (the device's first when the
/// name is empty) set to a level or to auto.
package struct GainRequest: Sendable, Hashable {
    package let element: String
    package let value: GainValue
    package init(element: String, value: GainValue) {
        self.element = element
        self.value = value
    }
}

package enum AllocationRequest: Sendable {
    /// One demod chain at a frequency, inside any capture that covers it. A decode job (and, from
    /// D.15, a watch job) asks for this: it needs one demodulated channel from any radio.
    /// `deviceID` nil means the allocator picks; `takeOver` retunes a capture somebody is using.
    case channel(frequencyHz: UInt64, bandwidthHz: UInt32, mode: DemodMode, deviceID: DeviceID?, takeOver: Bool)
    /// The whole capture band around a frequency, as cf32, for an IQ decoder that needs the signal
    /// before it is demodulated (docs/design/decoders.md, "Multiplexing"; DecoderSignal SIGNAL_IQ).
    /// Unlike `.channel`, the decoder receives the entire span, so "covers the frequency" is the
    /// capture-span test and the created capture is centred on the frequency. `sampleRateHz` 0 means
    /// the device's default; `deviceID` nil lets the allocator pick; `takeOver` retunes a capture
    /// somebody is using.
    case captureIQ(frequencyHz: UInt64, sampleRateHz: UInt64, deviceID: DeviceID?, takeOver: Bool)
    /// A whole radio, retunable, for the duration of the lease. `takeOver` skips the don't-disturb
    /// checks (a capture with channels, a live audio sink, a recent interactive write) but never
    /// the exclusivity one: two sweeps do not share a radio.
    /// `deviceID` nil means the allocator picks; setting one selects the radio on a two-radio rig.
    /// `gains` is where the sweep pins the tuner, one stage at a time in order: a level, or `auto`
    /// for where the driver's AGC settles. Empty pins whatever the radio is on, which is what the
    /// last client left.
    case exclusiveCapture(rangeHz: ClosedRange<UInt64>, deviceID: DeviceID?, takeOver: Bool, gains: [GainRequest] = [])
}

package enum AllocationResult: Sendable {
    case channel(any ChannelLease)
    case capture(any CaptureLease)
    case captureIQ(any CaptureIQLease)
    /// `code` is a stable machine string; `reason` names what is using the radio, in prose.
    case declined(code: String, reason: String)
}

/// A job's hold on one channel, and on whatever the allocator had to build under it. Releasing
/// destroys the channel, and the capture too when the lease created it -- a job that borrowed
/// somebody's radio leaves it as it found it (docs/design/decoders.md, "Decisions": "A decode job
/// is a job").
package protocol ChannelLease: AnyObject, Sendable {
    var channelID: ChannelID { get }
    var captureID: CaptureID { get }
    var engine: any ChannelEngine { get }
    func release() async
}

/// A job's hold on one capture read as raw IQ, for an IQ decoder (docs/design/decoders.md,
/// "Multiplexing"; DecoderSignal SIGNAL_IQ). Unlike `ChannelLease` there is no channel: the decoder
/// taps the whole capture band. Releasing destroys the capture only when the lease created it, so a
/// job that borrowed a capture leaves it as it found it.
package protocol CaptureIQLease: AnyObject, Sendable {
    var captureID: CaptureID { get }
    var sampleRateHz: UInt64 { get }
    var centerHz: UInt64 { get async }
    var capture: any CaptureEngine { get }
    func release() async
}

/// A job's exclusive hold on one capture. Retuning through the lease bypasses the write coalescer,
/// because that path keeps last-value-per-parameter on a 20 ms tick and would silently drop
/// sweep steps.
package protocol CaptureLease: AnyObject, Sendable {
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
    /// Why the gain the job asked for could not be set, or nil when it was (or none was asked
    /// for). A sweep at some other gain than the requested one is a different measurement, so
    /// the job reads this before it runs.
    var pinFailure: EngineError? { get async }

    func retune(centerHz: UInt64) async throws
    /// Restores what was borrowed: the original centre and gain, or the capture is destroyed if
    /// the lease created it. Idempotent, and must run on cancellation as well as on success.
    func release() async
}

// MARK: - Store

/// Resources: a plain directory Finder can see, plus a metadata index.
///
/// This is the Milestone D.15 contract (docs/plans/build-order.md); no implementation exists yet, and it
/// declares the shape jobs will persist their outputs through.
package protocol ResourceStore: AnyObject, Sendable {
    func create(kind: ResourceKind, metadata: [String: String]) async throws -> ResourceHandle
    func find(kind: ResourceKind?, matching: [String: String]) async -> [ResourceRecord]
    func localPath(uri: String) async -> URL?
}

package enum ResourceKind: String, Hashable, Sendable {
    case recording, scan, snapshot, transcript
}

package struct ResourceHandle: Sendable {
    package var uri: String
    package var writeURL: URL
}

package struct ResourceRecord: Sendable {
    package var uri: String
    package var kind: ResourceKind
    package var createdAt: Date
    package var sizeBytes: UInt64
    package var metadata: [String: String]
}
