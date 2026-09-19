// SPDX-License-Identifier: Apache-2.0

// The FFT stream as the window sees it: the latest row for the spectrum, the max-hold fold, the
// noise floor the ramp is keyed from, and a ring of rows the waterfall's texture is filled from.
// One subscription per capture at 2048 bins and 30 rows a second (docs/design/
// app-design-handoff.md, Region 4); the frequency axis is the mirror's capture, never the
// descriptor's, because the descriptor is a snapshot at subscribe time and rows keep flowing
// across a retune. Signposts from a row's arrival to its draw are S1's client half.

import Foundation
import LeylineClient
import LeylineProto
import os

let signposter = OSSignposter(subsystem: "com.leyline.app", category: "waterfall")

/// Rows as the waterfall's texture wants them: DB_U8 bytes, newest last, in a ring the renderer
/// copies from by row count. Main-actor only: the renderer draws on the main thread.
@MainActor
final class WaterfallBuffer {
    static let capacity = 2048
    private(set) var bins = 0
    private(set) var storage: [UInt8] = []
    /// Rows appended since the last reset; the ring index of the newest is `(count - 1) % capacity`.
    private(set) var count = 0
    /// The seq of the newest row, for the draw-side signpost.
    private(set) var newestSeq: UInt64 = 0

    func reset(bins: Int) {
        self.bins = bins
        storage = [UInt8](repeating: 0, count: bins * Self.capacity)
        count = 0
        newestSeq = 0
    }

    func append(_ row: [Float], seq: UInt64) {
        if row.count != bins { reset(bins: row.count) }
        let slot = count % Self.capacity
        let base = slot * bins
        for i in 0..<bins {
            let v = ((row[i] + DBU8.offset) * DBU8.scale).rounded()
            storage[base + i] = UInt8(v.clamped(to: 0...255))
        }
        count += 1
        newestSeq = seq
    }

    /// The row at ring slot `slot`, as a pointer for a texture upload.
    func withRow<T>(slot: Int, _ body: (UnsafeRawPointer) -> T) -> T {
        storage.withUnsafeBytes { body($0.baseAddress! + slot * bins) }
    }
}

@MainActor
@Observable
final class SpectrumFeed {
    static let bins: UInt32 = 2048
    static let rowsPerSecond: Double = 30
    /// How far above the floor the ramp reaches: six stops over 60 dB. The terminal's is 40 with
    /// four shades (`go/internal/cli/waterfall_view.go`); the eye can use more here.
    static let rangeDB: Float = 60
    /// The ramp's cold end sits this far above the median, so noise, which spreads a few dB
    /// either side of it, stays in the near-black first stop and a signal is what has colour.
    /// The desktop SDRs do the same with a waterfall minimum set above the floor. The floor
    /// itself follows the gain: a gain change moves the median, and the held floor is re-taken
    /// once it drifts `floorSlackDB`.
    static let noiseHeadroomDB: Float = 6
    /// Where the waterfall's ramp starts: the held floor plus the headroom.
    var rampFloorDB: Float { floorDB.isNaN ? .nan : floorDB + Self.noiseHeadroomDB }

    private(set) var latest: [Float] = []
    private(set) var hold = MaxHold()
    /// The noise floor the ramp and the spectrum's axis are keyed from. Held, not chased: it is
    /// taken from the smoothed median and re-taken only when that drifts more than `floorSlackDB`
    /// from it, because an axis that follows every wobble of the median makes the max-hold trace
    /// throb. Reset on a retune.
    private(set) var floorDB: Float = .nan
    /// The median of the newest row, smoothed over about ten rows.
    private(set) var medianDB: Float = .nan
    static let floorSlackDB: Float = 4
    private(set) var rows = 0
    private(set) var gaps = 0
    private(set) var descriptor: Leyline_V1_StreamDescriptor?
    private(set) var error: LeylineError?
    let waterfall = WaterfallBuffer()

    private var task: Task<Void, Never>?
    private var subscribedCapture: String?
    private var subscribedRate: UInt64 = 0

    /// Follows `capture`, resubscribing when it or its sample rate changes. Nil stops the feed.
    func follow(_ capture: Leyline_V1_Capture?, connection: DaemonConnection?) {
        guard let capture, let connection else {
            stop()
            return
        }
        if capture.captureID == subscribedCapture, capture.sampleRate == subscribedRate, task != nil { return }
        stop()
        subscribedCapture = capture.captureID
        subscribedRate = capture.sampleRate
        let id = capture.captureID
        task = Task { [weak self] in
            do {
                let (desc, rows) = try await connection.fft(capture: id, bins: Self.bins, rowsPerSecond: Self.rowsPerSecond)
                guard let self else { return }
                self.descriptor = desc
                log("feed", "fft \(desc.streamID): \(desc.fft.bins) bins, \(desc.fft.rowsPerSecond) rows/s, \(desc.fft.binFormat), centre \(desc.centerHz) span \(desc.spanHz)")
                for try await row in rows {
                    if Task.isCancelled { return }
                    self.ingest(row)
                }
                log("feed", "fft stream ended after \(self.rows) rows")
            } catch {
                if !Task.isCancelled {
                    self?.error = LeylineError(error)
                    log("feed", "fft stream failed: \(LeylineError(error))")
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        subscribedCapture = nil
        subscribedRate = 0
    }

    /// The capture moved: what was held is about another span.
    func resetFolds() {
        hold.reset()
        floorDB = .nan
        medianDB = .nan
    }

    private func ingest(_ row: FFTRow) {
        signposter.emitEvent("row", "seq=\(row.seq)")
        latest = row.levelsDB
        if hold.levelsDB.count != row.levelsDB.count { hold.reset() }
        hold.fold(row.levelsDB)
        let median = SpectrumFold.medianDB(row.levelsDB)
        medianDB = medianDB.isNaN ? median : medianDB + (median - medianDB) * 0.1
        if floorDB.isNaN || abs(medianDB - floorDB) > Self.floorSlackDB { floorDB = medianDB.rounded() }
        waterfall.append(row.levelsDB, seq: row.seq)
        rows += 1
        if row.gap != nil { gaps += 1 }
        if rows % 900 == 0 { log("feed", "\(rows) rows, \(gaps) gaps, floor \(floorDB) dBFS") }
    }
}

/// The channel meter, ten times a second, for the signal readout and the squelch track.
@MainActor
@Observable
final class MeterFeed {
    private(set) var meter: Leyline_V1_Meter?
    private(set) var error: LeylineError?
    private var task: Task<Void, Never>?
    private var channel: String?

    func follow(_ channelID: String?, connection: DaemonConnection?) {
        guard let channelID, let connection else {
            stop()
            return
        }
        if channelID == channel, task != nil { return }
        stop()
        channel = channelID
        var sub = Leyline_V1_TelemetrySubscription()
        sub.channelID = channelID
        sub.types = [.meter]
        let stream = connection.telemetry(sub)
        task = Task { [weak self] in
            do {
                for try await msg in stream {
                    if Task.isCancelled { return }
                    if case .meter(let m)? = msg.body { self?.meter = m }
                }
            } catch {
                if !Task.isCancelled { self?.error = LeylineError(error) }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        channel = nil
        meter = nil
    }
}
