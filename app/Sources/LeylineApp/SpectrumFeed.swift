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
    nonisolated static let bins: UInt32 = 2048
    static let rowsPerSecond: Double = 30
    /// The ramp's reach above its cold end before a peak is known: six stops over 60 dB. Once
    /// rows arrive the hot end is `peakDB` (`AppSession.rampRangeDB`).
    static let fallbackRangeDB: Float = 60
    /// The least the ramp reaches, so an empty band is not its noise blown up to cream.
    static let minRangeDB: Float = 20
    /// How fast the held peak lets go: 1 dB a second, so a burst does not leave the picture
    /// cold for the rest of the session and a carrier that stays keeps the top stop.
    static let peakDecayDBPerRow: Float = 1 / Float(rowsPerSecond)
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
    /// The loudest level on the band, held and let go at `peakDecayDBPerRow`: the ramp's hot
    /// end, so the strongest thing on the band reaches the last stop rather than a full scale
    /// nothing reaches (a −12 dBFS carrier 200 kHz wide is −34 dBFS a bin). Reset on a retune.
    private(set) var peakDB: Float = .nan
    /// The noise floor the ramp and the spectrum's axis are keyed from. Held, not chased: it is
    /// taken from the smoothed median and re-taken only when that drifts more than `floorSlackDB`
    /// from it, because an axis that follows every wobble of the median makes the max-hold trace
    /// throb. Reset on a retune.
    private(set) var floorDB: Float = .nan
    /// The median of the newest row, smoothed over about ten rows.
    private(set) var medianDB: Float = .nan
    static let floorSlackDB: Float = 4
    private(set) var rows = 0
    /// Rows folded into the held floor and peak since they were last reset: a retune resets the
    /// folds without ending the subscription, and a rule about "the last 3 s" counts from there.
    private(set) var heldRows = 0
    /// Fires after every row is folded, on the main actor; the session names the failure state
    /// from the folds here rather than polling them.
    var onRow: (() -> Void)?
    private(set) var gaps = 0
    private(set) var descriptor: Leyline_V1_StreamDescriptor?
    private(set) var error: LeylineError?
    let waterfall = WaterfallBuffer()

    private var task: Task<Void, Never>?
    /// The capture the rows on hand belong to, so a caller that folds them (the app's auto
    /// squelch) can tell rows of this span from rows of the one before.
    private(set) var subscribedCapture: String?
    private var subscribedRate: UInt64 = 0

    /// Follows `capture`, resubscribing when it or its sample rate changes. Nil stops the feed.
    func follow(_ capture: Leyline_V1_Capture?, connection: DaemonConnection?) {
        guard let capture, let connection else {
            stop()
            return
        }
        if capture.captureID == subscribedCapture, capture.sampleRate == subscribedRate, task != nil
        {
            return
        }
        stop()
        subscribedCapture = capture.captureID
        subscribedRate = capture.sampleRate
        let id = capture.captureID
        task = Task { [weak self] in
            do {
                let (desc, rows) = try await connection.fft(
                    capture: id, bins: Self.bins, rowsPerSecond: Self.rowsPerSecond)
                guard let self else { return }
                self.descriptor = desc
                log(
                    "feed",
                    "fft \(desc.streamID): \(desc.fft.bins) bins, \(desc.fft.rowsPerSecond) rows/s, \(desc.fft.binFormat), centre \(desc.centerHz) span \(desc.spanHz)"
                )
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

    /// Ends the subscription and forgets what it counted: `rows` counts one subscription's rows,
    /// not the feed's lifetime, so waiting for two rows is waiting for two rows of this span.
    func stop() {
        task?.cancel()
        task = nil
        subscribedCapture = nil
        subscribedRate = 0
        rows = 0
        gaps = 0
        heldRows = 0
    }

    /// The capture moved: what was held is about another span.
    func resetFolds() {
        hold.reset()
        floorDB = .nan
        medianDB = .nan
        peakDB = .nan
        heldRows = 0
    }

    private func ingest(_ row: FFTRow) {
        signposter.emitEvent("row", "seq=\(row.seq)")
        latest = row.levelsDB
        if hold.levelsDB.count != row.levelsDB.count { hold.reset() }
        hold.fold(row.levelsDB)
        let median = SpectrumFold.medianDB(row.levelsDB)
        medianDB = medianDB.isNaN ? median : medianDB + (median - medianDB) * 0.1
        if floorDB.isNaN || abs(medianDB - floorDB) > Self.floorSlackDB {
            floorDB = medianDB.rounded()
        }
        if let rowMax = row.levelsDB.max(), rowMax.isFinite {
            peakDB = peakDB.isNaN ? rowMax : max(rowMax, peakDB - Self.peakDecayDBPerRow)
        }
        waterfall.append(row.levelsDB, seq: row.seq)
        rows += 1
        heldRows += 1
        if row.gap != nil { gaps += 1 }
        if rows % 900 == 0 { log("feed", "\(rows) rows, \(gaps) gaps, floor \(floorDB) dBFS") }
        onRow?()
    }
}

/// One channel's telemetry: the meter ten times a second for the squelch track and the
/// inspector's readings, and the squelch edges and sub-audible reports folded into a
/// `TransmissionLog` for the inspector's log and its time on air (docs/design/
/// app-design-handoff-m2.md, Regions 3 and 4). One subscription per channel, reset with it: the
/// log is the channel's, and a transmission on the last channel is not one on this. The capture
/// rate is `duration_samples`' unit and comes from the session's capture, which can change under
/// a live subscription, so it is taken on every `follow` and not only at subscribe time.
@MainActor
@Observable
final class ChannelTelemetryFeed {
    private(set) var meter: Leyline_V1_Meter?
    private(set) var transmissions: TransmissionLog?
    /// The newest `SampleTime` any message carried, for `timeOnAir(at:)` and the log's relative
    /// times: the view asks with the newest time it has rather than a clock of its own.
    private(set) var newestTime: Leyline_V1_SampleTime?
    private(set) var error: LeylineError?
    private var captureRate: UInt64 = 0
    /// The last tone logged, so the heartbeat does not write a line a second.
    private var lastToneHz: Double = 0
    /// Meters folded since the channel was followed, for the thirty-second log line.
    private var meters = 0
    private var task: Task<Void, Never>?
    private var channel: String?

    func follow(_ channelID: String?, captureRate: UInt64, connection: DaemonConnection?) {
        self.captureRate = captureRate
        guard let channelID, let connection else {
            stop()
            return
        }
        if channelID == channel, task != nil { return }
        stop()
        channel = channelID
        transmissions = TransmissionLog(channelID: channelID)
        var sub = Leyline_V1_TelemetrySubscription()
        sub.channelID = channelID
        sub.types = [.meter, .squelchTransition, .subAudible]
        let stream = connection.telemetry(sub)
        task = Task { [weak self] in
            do {
                for try await msg in stream {
                    if Task.isCancelled { return }
                    self?.fold(msg)
                }
            } catch {
                if !Task.isCancelled { self?.error = LeylineError(error) }
            }
        }
    }

    private func fold(_ msg: Leyline_V1_TelemetryMsg) {
        newestTime = msg.time
        switch msg.body {
        case .meter(let m)?:
            meter = m
            meters += 1
            // The meter's numbers every thirty seconds, so a word in the inspector that does not
            // move can be read against what the daemon sent (a tuning error of exactly 0 is a
            // daemon built before the field existed).
            if meters % 300 == 1 {
                log(
                    "meter",
                    String(
                        format:
                            "power %.1f dBFS, snr %.1f dB, audio %.1f dBFS, freq error %.0f Hz, deviation %.0f Hz, squelch %@",
                        m.powerDbfs, m.snrDb, m.audioDbfs, m.freqErrorHz, m.deviationHz,
                        m.squelchOpen ? "open" : "closed"))
            }
        case .subAudible(let sa)?:
            // One line per change of tone, not per heartbeat: what the daemon named, or that it
            // looked and found nothing, so a missing PL in the log can be explained from here.
            let now = sa.kind == .subAudibleCtcss ? sa.standardToneHz : 0
            if now != lastToneHz {
                lastToneHz = now
                log(
                    "telemetry",
                    now > 0
                        ? String(
                            format: "PL %.1f Hz (measured %.1f, dev %.0f Hz, tone/band %.0f dB)",
                            sa.standardToneHz, sa.toneHz, sa.deviationHz, sa.toneSnrDb)
                        : "no PL (\(sa.kind))")
            }
        case .squelch(let sq)?:
            if !sq.open, sq.durationSamples > 0 {
                log("telemetry", "transmission ended after \(sq.durationSamples) samples")
            }
        default:
            break
        }
        transmissions?.fold(msg, captureRate: captureRate)
    }

    func stop() {
        task?.cancel()
        task = nil
        channel = nil
        meter = nil
        transmissions = nil
        newestTime = nil
    }
}

/// The capture's raw level four times a second (`CaptureLevel`): samples at the converter's
/// rails and the peak, the clipping authority the failure state reads (`FailureState`,
/// plans/app.md M2-5). One subscription per capture, reset with it.
@MainActor
@Observable
final class CaptureLevelFeed {
    private(set) var level: Leyline_V1_CaptureLevel?
    private(set) var error: LeylineError?
    /// Fires after every reading, on the main actor; the session names the failure state from it.
    var onLevel: (() -> Void)?
    private var task: Task<Void, Never>?
    private var capture: String?

    func follow(_ captureID: String?, connection: DaemonConnection?) {
        guard let captureID, let connection else {
            stop()
            return
        }
        if captureID == capture, task != nil { return }
        stop()
        capture = captureID
        var sub = Leyline_V1_TelemetrySubscription()
        sub.captureID = captureID
        sub.types = [.captureLevel]
        let stream = connection.telemetry(sub)
        task = Task { [weak self] in
            do {
                for try await msg in stream {
                    if Task.isCancelled { return }
                    if case .captureLevel(let l)? = msg.body {
                        self?.level = l
                        self?.onLevel?()
                    }
                }
            } catch {
                if !Task.isCancelled { self?.error = LeylineError(error) }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        capture = nil
        level = nil
    }
}
