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
/// copies from by row count, and beside it each row's sample index and which rows were captured
/// while the radio clipped (plans/app.md, M2-8), in `ClippedRows`; the indices also place the
/// time gutter's kept bars (docs/design/app-design-handoff-m3.md, "In every screen"). Main-actor only: the renderer draws on the main thread.
@MainActor
final class WaterfallBuffer {
    nonisolated static let capacity = 2048
    private(set) var bins = 0
    private(set) var storage: [UInt8] = []
    /// Rows appended since the last reset; the ring index of the newest is `(count - 1) % capacity`.
    private(set) var count = 0
    /// The seq of the newest row, for the draw-side signpost.
    private(set) var newestSeq: UInt64 = 0
    /// Each slot's sample index, capture and clipping flag; its slots are the ring's.
    private(set) var clipped = ClippedRows(capacity: WaterfallBuffer.capacity)

    func reset(bins: Int) {
        self.bins = bins
        storage = [UInt8](repeating: 0, count: bins * Self.capacity)
        count = 0
        newestSeq = 0
        clipped.reset()
    }

    func append(_ row: [Float], seq: UInt64, time: Leyline_V1_SampleTime) {
        if row.count != bins { reset(bins: row.count) }
        clipped.append(sampleIndex: time.sampleIndex, captureID: time.captureID)
        let slot = count % Self.capacity
        let base = slot * bins
        for i in 0..<bins {
            let v = ((row[i] + DBU8.offset) * DBU8.scale).rounded()
            storage[base + i] = UInt8(v.clamped(to: 0...255))
        }
        count += 1
        newestSeq = seq
    }

    /// Flags the held rows one `CaptureLevel` reading covers, when it is over the clipping floor.
    func markClipped(_ level: Leyline_V1_CaptureLevel, at time: Leyline_V1_SampleTime) {
        clipped.mark(level, at: time)
    }

    /// The held rows a recording's closed parts hold, as runs of row age: where the time
    /// gutter draws its kept bars (`ClippedRows.keptRuns`).
    func keptRuns(_ parts: [RecordingPart]) -> [Range<Int>] {
        clipped.keptRuns(parts)
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
    /// The ramp's cold end sits this far above the median, so noise, which spreads a few dB
    /// either side of it, stays in the near-black first stop and only signals get colour.
    /// Desktop SDRs do the same with a waterfall minimum set above the floor. The floor
    /// itself follows the gain: a gain change resets the folds, and the held floor is re-taken
    /// from the next row.
    static let noiseHeadroomDB: Float = 6
    /// Where the waterfall's ramp starts: the held floor plus the headroom.
    var rampFloorDB: Float { floorDB.isNaN ? .nan : floorDB + Self.noiseHeadroomDB }

    private(set) var latest: [Float] = []
    private(set) var hold = MaxHold()
    /// The noise floor the ramp and the spectrum's axis are keyed from. Held, not tracked
    /// (`HeldFloor`): taken from the smoothed median, it falls as soon as the median is more
    /// than `HeldFloor.slackDB` under it and rises only after the median has stayed that far over
    /// it for `HeldFloor.riseSeconds` on the rows' clock. An axis that follows every wobble of
    /// the median makes the max-hold trace throb, and every row on screen is coloured from this
    /// floor, so a floor that rose with a keyed handheld clipping the radio recoloured the rows
    /// already drawn. Reset on a retune and a gain change, which re-take it at once.
    var floorDB: Float { heldFloor.floorDB }
    private var heldFloor = HeldFloor()
    /// The median of the newest row, smoothed over about ten rows.
    private(set) var medianDB: Float = .nan
    private(set) var rows = 0
    private(set) var gaps = 0
    private(set) var descriptor: Leyline_V1_StreamDescriptor?
    private(set) var error: LeylineError?
    let waterfall = WaterfallBuffer()

    private var task: Task<Void, Never>?
    /// The capture the current rows belong to, so a caller that folds them (the app's auto
    /// squelch) can tell rows of this span from rows of the one before.
    private(set) var subscribedCapture: String?
    private var subscribedRate: UInt64 = 0
    /// Gain is part of the picture's calibration. Keep the mirror's stage values so a gain
    /// change made by this window or another client cannot leave an old max hold over a newly
    /// scaled live trace.
    private var subscribedGains: [GainSignature] = []

    private struct GainSignature: Equatable {
        var element: String
        var db: Double
        var auto: Bool
    }

    private static func gainSignature(_ capture: Leyline_V1_Capture) -> [GainSignature] {
        capture.gains.map { GainSignature(element: $0.element, db: $0.db, auto: $0.auto) }
            .sorted { $0.element < $1.element }
    }

    /// Follows `capture`, resubscribing when it or its sample rate changes. Nil stops the feed.
    func follow(_ capture: Leyline_V1_Capture?, connection: DaemonConnection?) {
        guard let capture, let connection else {
            stop()
            return
        }
        let gains = Self.gainSignature(capture)
        if capture.captureID == subscribedCapture, capture.sampleRate == subscribedRate, task != nil
        {
            if gains != subscribedGains {
                subscribedGains = gains
                resetFolds()
            }
            return
        }
        stop()
        resetFolds()
        subscribedCapture = capture.captureID
        subscribedRate = capture.sampleRate
        subscribedGains = gains
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
        subscribedGains = []
        rows = 0
        gaps = 0
    }

    /// The capture moved: the held values belong to the old span.
    func resetFolds() {
        hold.reset()
        heldFloor.reset()
        medianDB = .nan
    }

    /// Starts a fresh max-hold trace without moving the live trace or recolouring the waterfall.
    func clearMaxHold() {
        hold.reset()
    }

    private func ingest(_ row: FFTRow) {
        signposter.emitEvent("row", "seq=\(row.seq)")
        latest = row.levelsDB
        if hold.levelsDB.count != row.levelsDB.count { hold.reset() }
        hold.fold(row.levelsDB)
        let median = SpectrumFold.medianDB(row.levelsDB)
        medianDB = medianDB.isNaN ? median : medianDB + (median - medianDB) * 0.1
        let before = floorDB
        heldFloor.fold(
            medianDB: medianDB, atSample: row.time.sampleIndex, sampleRate: subscribedRate)
        if !before.isNaN, floorDB != before {
            log("feed", "floor \(before) -> \(floorDB) dBFS (median \(medianDB))")
        }
        waterfall.append(row.levelsDB, seq: row.seq, time: row.time)
        rows += 1
        if row.gap != nil { gaps += 1 }
        if rows % 900 == 0 { log("feed", "\(rows) rows, \(gaps) gaps, floor \(floorDB) dBFS") }
    }
}

/// One channel's telemetry: the meter ten times a second for the squelch track and the
/// inspector's readings, and the squelch edges and sub-audible reports folded into a
/// `TransmissionLog` for the inspector's log and its time on air (docs/design/
/// app-design-handoff-m2.md, Regions 3 and 4). One subscription per channel, reset with it. The
/// logs are kept per frequency and mode for the session (`TransmissionLogs`), and the one shown
/// is the tuned frequency's: the window retunes by writing the same channel's offset, so a
/// retune switches logs (`ChannelFrequencyWatch`), and coming back finds the rows heard there
/// before. Until the owner's second run (plans/app.md, APP-5, "Fixed 2026-09-25 (second run)")
/// a retune emptied the one log, and switching channel lost the transmissions. The capture
/// rate is `duration_samples`' unit and comes from the session's capture, which can change under
/// a live subscription, so it is taken on every `follow` and not only at subscribe time.
@MainActor
@Observable
final class ChannelTelemetryFeed {
    private(set) var meter: Leyline_V1_Meter?
    /// Every frequency's log this session; kept across a new channel and a lost connection.
    private(set) var logs = TransmissionLogs()
    /// The tuned frequency's log, or nil without a channel.
    var transmissions: TransmissionLog? { logs.log }
    /// The newest `SampleTime` any message carried, for `timeOnAir(at:)` and the log's relative
    /// times: the view asks with the newest time it has rather than a clock of its own.
    private(set) var newestTime: Leyline_V1_SampleTime?
    private(set) var error: LeylineError?
    /// Fires after every meter, on the main actor, with the message's time in seconds on the
    /// capture's clock (NaN while the rate is unknown); the session folds the inspector's
    /// steadied reading from it (`ChannelReading`).
    var onMeter: ((Leyline_V1_Meter, Double) -> Void)?
    private var captureRate: UInt64 = 0
    /// The last tone logged, by its words (`PL 100.0`, `DCS 023`; `none` for a report of no
    /// tone), so the heartbeat does not write a line a second and a changing measured frequency
    /// does not either: nil until the first sub-audible report, which is logged whether it names
    /// a tone or not, so a log with no tone in it shows whether the daemon reported anything.
    private var lastTone: String?
    /// Meters folded since the channel was followed, for the thirty-second log line.
    private var meters = 0
    private var task: Task<Void, Never>?
    private var channel: String?
    private var frequency = ChannelFrequencyWatch()

    /// `offsetHz`, `centerHz` and `mode` are the mirror's for the channel and its capture, read
    /// on every call so a retune of the same channel switches to the new frequency's log.
    func follow(
        _ channelID: String?, offsetHz: Int64?, centerHz: UInt64?, mode: Leyline_V1_DemodMode?,
        captureRate: UInt64, connection: DaemonConnection?
    ) {
        self.captureRate = captureRate
        guard let channelID, let connection else {
            stop()
            return
        }
        if channelID == channel, task != nil {
            if let offsetHz { _ = frequency.observe(offsetHz: offsetHz, centerHz: centerHz) }
            showLog(of: channelID, mode: mode)
            return
        }
        stop()
        channel = channelID
        lastTone = nil
        frequency = ChannelFrequencyWatch()
        if let offsetHz { _ = frequency.observe(offsetHz: offsetHz, centerHz: centerHz) }
        showLog(of: channelID, mode: mode)
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

    /// Switches to the log of the channel's frequency, as `ChannelFrequencyWatch` last read it,
    /// and its mode, making it if this pair is new. Until both are known the log shown does not
    /// change.
    private func showLog(of channelID: String, mode: Leyline_V1_DemodMode?) {
        guard let hz = frequency.tunedHz, let mode else { return }
        let key = TransmissionLogs.Key(frequencyHz: hz, mode: mode)
        let retune = logs.current != nil && logs.current != key
        guard logs.tune(key, channelID: channelID) else { return }
        if retune {
            lastTone = nil
            log(
                "telemetry",
                "retuned to \(hz) Hz \(mode.word); its log has \(logs.log?.closed.count ?? 0) transmissions, \(logs.count) logs kept"
            )
        }
    }

    private func fold(_ msg: Leyline_V1_TelemetryMsg) {
        newestTime = msg.time
        switch msg.body {
        case .meter(let m)?:
            meter = m
            meters += 1
            onMeter?(
                m,
                captureRate > 0 ? Double(msg.time.sampleIndex) / Double(captureRate) : .nan)
            // The meter's numbers every thirty seconds, so an inspector label that does not
            // change can be checked against what the daemon sent (a tuning error of exactly 0
            // means a daemon built before the field existed).
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
            // One line per change of tone, not per heartbeat: the CTCSS tone or DCS code the
            // daemon reported, or that it found none, so a missing tone in the log can be
            // explained from here.
            let heard = SubAudibleTone(sa)
            let now = heard?.words ?? "none"
            if now != lastTone {
                lastTone = now
                let line: String
                switch heard {
                case .ctcss?:
                    line = String(
                        format: "%@ Hz (measured %.1f, dev %.0f Hz, tone/band %.0f dB)", now,
                        sa.toneHz, sa.deviationHz, sa.toneSnrDb)
                case .dcs?:
                    line = String(
                        format: "%@ (dev %.0f Hz, confidence %.2f)", now, sa.deviationHz,
                        sa.confidence)
                case nil:
                    line = "no tone (\(sa.kind))"
                }
                log("telemetry", line)
            }
        default:
            break
        }
        logs.fold(msg, captureRate: captureRate)
        if case .squelch(let sq)? = msg.body, !sq.open, sq.durationSamples > 0 {
            // After the fold, so the line can say which tone the log attached to the
            // transmission; one too short for the log (`TransmissionLog.shortestSeconds`) has
            // no entry and no tone clause.
            let entry = transmissions?.closed.first.flatMap { $0.end == msg.time ? $0 : nil }
            let tone = entry.map { t in
                t.tone.map { " · " + $0.words } ?? " · no tone"
            }
            log(
                "telemetry",
                "transmission ended after \(sq.durationSamples) samples\(tone ?? "")")
        }
    }

    /// A record job on the tuned frequency started or ended at `time`: the tuned log's open
    /// transmission is cut there (`TransmissionLogs.mark`). Returns whether it cut.
    @discardableResult
    func mark(_ marker: Transmission.Marker, at time: Leyline_V1_SampleTime) -> Bool {
        logs.mark(marker, at: time, captureRate: captureRate)
    }

    func stop() {
        task?.cancel()
        task = nil
        channel = nil
        meter = nil
        logs.leave()
        newestTime = nil
    }
}

/// The capture's raw level four times a second (`CaptureLevel`): samples at the converter's
/// rails and the peak, the clipping source the failure state reads (`FailureState`,
/// plans/app.md M2-5). One subscription per capture, reset with it.
@MainActor
@Observable
final class CaptureLevelFeed {
    private(set) var level: Leyline_V1_CaptureLevel?
    /// The newest reading's time, the end of its interval: the failure state's hold is timed on
    /// it (`FailureHold`).
    private(set) var time: Leyline_V1_SampleTime?
    private(set) var error: LeylineError?
    /// Fires after every reading, on the main actor; the session derives the failure state from it.
    var onLevel: (() -> Void)?
    private var task: Task<Void, Never>?
    /// The capture the readings belong to, so the session marks only that capture's rows.
    private(set) var capture: String?

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
                        self?.time = msg.time
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
        time = nil
    }
}

/// The tuned channel's audio ladder: the spectrum of its demod tap folded into octave bands and
/// their ballistics (`BandLevels`, `LevelBar`), for the inspector's audio region
/// (docs/design/app-design-handoff-m2.md, "Region 3b: audio"). One subscription per channel at
/// 1024 bins and 20 rows a second, `ley levels`' request, latest-wins because a meter wants the
/// newest row and nothing older; reset with the channel, and stopped while the inspector is
/// hidden, since nothing draws it, and for a raw-IQ channel, which has no audio and which the
/// daemon refuses. The pair at the right, rms and peak, is the meter's `audio_dbfs` and
/// `audio_peak_dbfs`, never a row's, as in `ley levels`, so two clients print the same numbers.
/// While the meter says the squelch is closed the bars are reset and draw unlit: the demod tap
/// carries the discriminator's noise between transmissions, and a lit bar would show it as audio.
@MainActor
@Observable
final class AudioLevelsFeed {
    nonisolated static let bins: UInt32 = 1024
    static let rowsPerSecond: Double = 20
    /// Rows waiting to be read. A meter draws the newest; two covers one late main-actor turn.
    static let buffer = 2

    /// The band bars, nine octaves, then rms and peak. Read through `bars`, which registers the
    /// view on `folded`: the storage is mutated in place once per row rather than published bar
    /// by bar, so a row costs one observation and no array copy.
    @ObservationIgnored private var storage = [LevelBar](
        repeating: LevelBar(), count: BandLevels.octaveCentresHz.count + 2)
    private(set) var folded = 0
    var bars: [LevelBar] {
        _ = folded
        return storage
    }
    /// The meter's audio level and peak in dBFS, NaN before the first meter.
    private(set) var rmsDB: Double = .nan
    private(set) var peakDB: Double = .nan
    /// The meter's squelch, nil until a meter has arrived: bars fold until the meter says closed.
    private(set) var squelchOpen: Bool?
    private(set) var descriptor: Leyline_V1_StreamDescriptor?
    private(set) var error: LeylineError?
    /// Fires on the main actor after the stream ended without an error and the subscription was
    /// cleared, so the session follows the channel again. The daemon closes a channel's tap when
    /// it rebuilds the channel's chain, as a sample-rate change does, and without a new
    /// subscription the ladder stayed dark on the new chain.
    var onEnded: (() -> Void)?
    /// A stream that ends sooner than this after subscribing waits this long before the retry,
    /// so a chain that closes every subscription at once is not asked again in a tight loop.
    static let retryAfter: Duration = .seconds(1)

    @ObservationIgnored private var levels = BandLevels()
    @ObservationIgnored private var binHz: Double = 0
    @ObservationIgnored private var captureRate: UInt64 = 0
    @ObservationIgnored private var rows = 0
    private var task: Task<Void, Never>?
    private var channel: String?
    private var mode: Leyline_V1_DemodMode?
    /// The capture rate the current subscription was made at.
    private var subscribedRate: UInt64 = 0

    /// Follows `channel` while `shown`. The capture rate is the rows' clock (a row's
    /// `SampleTime` is on the capture's timeline) and is taken on every call, as
    /// `ChannelTelemetryFeed` takes it. A changed rate resubscribes, as `SpectrumFeed` does:
    /// the daemon rebuilds the channel's chain at the new rate, which is a new stream. A mode
    /// change resubscribes too: the tap's audio rate, and so the row's axis, belongs to the mode.
    func follow(
        _ channel: Leyline_V1_Channel?, captureRate: UInt64, shown: Bool,
        connection: DaemonConnection?
    ) {
        self.captureRate = captureRate
        guard shown, let channel, channel.mode != .rawIq, let connection else {
            stop()
            return
        }
        if channel.channelID == self.channel, channel.mode == mode,
            captureRate == subscribedRate, task != nil
        {
            return
        }
        stop()
        self.channel = channel.channelID
        mode = channel.mode
        subscribedRate = captureRate
        let id = channel.channelID
        task = Task { [weak self] in
            let started = ContinuousClock.now
            do {
                let (desc, rows) = try await connection.fft(
                    channel: id, tap: .tapDemod, bins: Self.bins,
                    rowsPerSecond: Self.rowsPerSecond, buffer: Self.buffer)
                guard let self else { return }
                self.descriptor = desc
                self.binHz = desc.fft.bins > 0 ? Double(desc.spanHz) / Double(desc.fft.bins) : 0
                log(
                    "feed",
                    "audio fft \(desc.streamID) on \(id): \(desc.fft.bins) bins, \(desc.fft.rowsPerSecond) rows/s, \(desc.fft.tap), span \(desc.spanHz) Hz"
                )
                for try await row in rows {
                    if Task.isCancelled { return }
                    self.ingest(row)
                }
                log("feed", "audio fft stream ended after \(self.rows) rows")
                if Task.isCancelled { return }
                // The daemon closed the stream: follow the channel again, a second later if
                // this subscription lasted less than that.
                let quick = started.duration(to: .now) < Self.retryAfter
                log(
                    "feed",
                    "audio fft on \(id): following again\(quick ? " in 1 s" : "")")
                if quick {
                    try? await Task.sleep(for: Self.retryAfter)
                    if Task.isCancelled { return }
                }
                self.task = nil
                self.channel = nil
                self.mode = nil
                self.subscribedRate = 0
                self.onEnded?()
            } catch {
                if !Task.isCancelled {
                    self?.error = LeylineError(error)
                    log("feed", "audio fft stream failed: \(LeylineError(error))")
                }
            }
        }
    }

    /// The session hands over every meter of the tuned channel (`ChannelTelemetryFeed.onMeter`).
    /// A closed squelch resets the bars at once, so the ladder goes dark with the speaker.
    func meterChanged(_ m: Leyline_V1_Meter) {
        // Only a changed number is published; NaN never equals itself, so it is compared apart.
        if !(rmsDB == m.audioDbfs || rmsDB.isNaN && m.audioDbfs.isNaN) { rmsDB = m.audioDbfs }
        if !(peakDB == m.audioPeakDbfs || peakDB.isNaN && m.audioPeakDbfs.isNaN) {
            peakDB = m.audioPeakDbfs
        }
        if squelchOpen != m.squelchOpen { squelchOpen = m.squelchOpen }
        if !m.squelchOpen { resetBars() }
    }

    func stop() {
        task?.cancel()
        task = nil
        channel = nil
        mode = nil
        subscribedRate = 0
        descriptor = nil
        error = nil
        rows = 0
        binHz = 0
        rmsDB = .nan
        peakDB = .nan
        squelchOpen = nil
        resetBars()
    }

    /// Every bar back to the floor. Publishes only when a bar was off it, so a closed squelch's
    /// ten meters a second do not redraw a dark ladder ten times a second.
    private func resetBars() {
        guard storage.contains(where: { $0 != LevelBar() }) else { return }
        for i in storage.indices { storage[i].reset() }
        levels.reset()
        folded += 1
    }

    /// One row into the bars, on the capture's clock: NaN seconds while the rate is unknown,
    /// which the bars count as no time, so they hold rather than guess.
    private func ingest(_ row: FFTRow) {
        rows += 1
        if rows % 600 == 0 { log("feed", "audio fft: \(rows) rows") }
        if squelchOpen == false { return }
        let seconds =
            captureRate > 0 ? Double(row.time.sampleIndex) / Double(captureRate) : .nan
        levels.measure(row.levelsDB, binHz: binHz)
        let n = levels.levelsDB.count
        for i in 0..<n { storage[i].update(levels.levelsDB[i], atSeconds: seconds) }
        storage[n].update(rmsDB, atSeconds: seconds)
        storage[n + 1].update(peakDB, atSeconds: seconds)
        folded += 1
    }
}
