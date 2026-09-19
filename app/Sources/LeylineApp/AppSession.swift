// SPDX-License-Identifier: Apache-2.0

// What every view reaches for: the daemon's state copied out of the mirror on every change, the
// coalescer that writes through it, the two feeds, the bands and bookmarks files, and every
// action the window performs. Nothing here is authoritative (CLAUDE.md invariant 7): a view
// renders `state` and its own writes come back as events like everyone else's. One identity per
// process, so the window and its writes are one client to the daemon and `ley state` shows one
// row for the app.

import AppKit
import LeylineClient
import LeylineProto
import SwiftUI

@MainActor
@Observable
final class AppSession {
    // The mirror, copied.
    private(set) var state = MirrorState()
    private(set) var connection: MirrorConnection = .idle
    private(set) var socketPath = SocketPath.default()
    private(set) var writes: WriteCoalescer?
    private(set) var startupError: LeylineError?
    private var daemon: DaemonConnection?
    private var mirror: DaemonMirror?
    private var running: Task<Void, Never>?

    // The window's own selection: which capture it shows and which channel it hears. Ids only;
    // the objects are always read back from `state`.
    private(set) var captureID: String?
    private(set) var channelID: String?
    private(set) var selectedBandID: String?
    private var adopted = false
    /// The frequency this app last asked for, until the daemon confirms it or a second passes:
    /// what the field shows and what a step is taken from, so two quick presses do not both
    /// start from the frequency before the first (`../dev/app.md`: a view previews its own
    /// writes and reconciles on the event).
    private(set) var requestedHz: UInt64?
    private var requestedAt = Date.distantPast
    /// A centre write not yet confirmed by the capture's event; clicks in the meantime are
    /// computed against it rather than the mirror's old centre.
    private var centreInFlight: Int64?
    private var creatingChannel = false
    private var lastPan = Date.distantPast

    // Files both clients own.
    let bands: [Band] = Bands.plain
    private(set) var bookmarks = BookmarkStore(path: BookmarkStore.defaultPath())
    private var bookmarkWatch: DispatchSourceFileSystemObject?
    private var bookmarkWatchFD: Int32 = -1

    // Feeds.
    let spectrum = SpectrumFeed()
    let meters = MeterFeed()

    // View state that is the window's alone: presentation, never radio truth.
    var maxHold = true
    var zoom = 1
    /// Set by ⌘L: the transport field takes focus and edits in place.
    var frequencyEntryShown = false
    var deviceMenuShown = false
    /// One sentence about the last thing that happened, or nil.
    private(set) var notice: String?
    private(set) var lastError: LeylineError?
    private var busy = false
    private var rejectionsSeen = 0

    private static let lastBandKey = "lastBand"

    // MARK: Derived

    var capture: Leyline_V1_Capture? { captureID.flatMap { state.capture($0) } }
    var channel: Leyline_V1_Channel? { channelID.flatMap { state.channel($0) } }
    var device: Leyline_V1_DeviceDescriptor? { capture.flatMap { state.device($0.deviceID) } }
    var sink: Leyline_V1_Sink? {
        guard let channelID else { return nil }
        return state.sinks(of: channelID).first { if case .systemAudio? = $0.kind { true } else { false } }
    }
    var tunedHz: UInt64? { channel.flatMap { state.frequencyHz(of: $0) } }
    /// The frequency to show: the one asked for while it is in flight, else the daemon's.
    var displayHz: UInt64? { requestedHz ?? tunedHz }
    var isPlaying: Bool { sink != nil }
    var meter: Leyline_V1_Meter? { meters.meter }
    var isLive: Bool { if case .live = connection { true } else { false } }

    /// The waterfall's cold end: the squelch, as a level per bin, so raising the squelch darkens
    /// the noise and what is heard is what has colour, the way the desktop SDRs tie the waterfall
    /// minimum to the floor. The squelch is a channel power over the channel's width; per bin it
    /// is `squelch − 10·log10(bandwidth / bin width)`, the auto squelch's own scaling in reverse.
    /// With the squelch off, or before a floor is known, the feed's floor plus its headroom.
    var rampFloorDB: Float {
        let feed = spectrum
        guard let ch = channel, ch.squelchDb.isFinite, let cap = capture, cap.sampleRate > 0, ch.bandwidthHz > 0, !feed.floorDB.isNaN else {
            return feed.rampFloorDB
        }
        let binWidth = Double(cap.sampleRate) / Double(SpectrumFeed.bins)
        let perBin = Float(ch.squelchDb - 10 * log10(Double(ch.bandwidthHz) / binWidth))
        return max(perBin, feed.floorDB - 10)
    }

    /// The band the sidebar highlights: the chosen one, else the one the tuned frequency lies in.
    var band: Band? {
        if let id = selectedBandID, let b = bands.first(where: { $0.id == id }) { return b }
        return tunedHz.flatMap { Bands.band(containing: $0, in: bands) }
    }

    var stepHz: UInt32 { band?.stepHz ?? 12_500 }
    var fineStepHz: UInt32 { band?.fineStepHz ?? 1_000 }

    /// The frequencies the spectrum and waterfall show: the capture's span at zoom 1, a window
    /// of it centred on the tuned frequency when zoomed, clamped inside the capture.
    var visibleRange: ClosedRange<UInt64>? {
        guard let cap = capture, cap.sampleRate > 0 else { return nil }
        let span = cap.sampleRate
        let lo = cap.centerHz > span / 2 ? cap.centerHz - span / 2 : 0
        let hi = cap.centerHz + span / 2
        if zoom <= 1 { return lo...hi }
        let width = span / UInt64(zoom)
        let centre = (tunedHz ?? cap.centerHz).clamped(to: (lo + width / 2)...(hi - width / 2))
        return (centre - width / 2)...(centre + width / 2)
    }

    /// Where the window stands, in the guide's words, when there is nothing to draw.
    var emptyWords: (headline: String, detail: String)? {
        if let e = startupError { return ("Could not dial the daemon", e.message) }
        switch connection {
        case .idle, .connecting: return ("Connecting to leylined", socketPath)
        case .unavailable(let e, let retry):
            return e.daemonUnreachable
                ? ("The daemon is not running", "Start it with `ley daemon start`; retrying in \(retry).")
                : (e.message, "Retrying in \(retry).")
        case .live: break
        }
        if state.devices.allSatisfy({ $0.state == .disconnected }) {
            return ("No radio is plugged in", "Plug in an RTL-SDR, or attach a recording with `ley devices attach`.")
        }
        if capture == nil { return ("Pick a band to listen", "The sidebar's bands set the radio, the mode and the squelch at once.") }
        if capture?.state == .captureDetached { return ("The radio was unplugged", "Plug it back in and the capture rebinds on its own.") }
        return nil
    }

    // MARK: Lifecycle

    func start() async {
        guard running == nil else { return }
        log("session", "start: socket \(socketPath), log \(AppLog.shared.path)")
        loadBookmarks()
        watchBookmarks()
        selectedBandID = UserDefaults.standard.string(forKey: Self.lastBandKey)
        do {
            let daemon = try DaemonConnection(identity: .fresh(kind: "app", label: "Leyline"))
            self.daemon = daemon
            socketPath = daemon.socketPath
            let mirror = DaemonMirror(connection: daemon)
            mirror.onChange = { [weak self] m in self?.mirrorChanged(m) }
            self.mirror = mirror
            self.writes = WriteCoalescer(connection: daemon)
            running = Task { await mirror.run() }
            await running?.value
        } catch {
            startupError = LeylineError(error)
            log("session", "could not dial: \(LeylineError(error))")
        }
    }

    private func mirrorChanged(_ m: DaemonMirror) {
        let wasLive = isLive
        state = m.state
        connection = m.connection
        if wasLive != isLive { log("session", isLive ? "live: leylined \(state.daemon.version), \(state.devices.count) devices, \(state.captures.count) captures" : "not live: \(connection)") }
        if let r = requestedHz, r == tunedHz || Date().timeIntervalSince(requestedAt) > 2 { requestedHz = nil }
        // Objects the window pointed at may be gone: a tombstone, or the daemon restarted.
        if let id = captureID, state.capture(id) == nil { captureID = nil }
        if let id = channelID, state.channel(id) == nil { channelID = nil }
        if case .live = connection {
            if !adopted { adopt() }
        } else {
            adopted = false
        }
        spectrum.follow(capture, connection: daemon)
        meters.follow(channelID, connection: daemon)
        // The mirror keeps this client's rejections; a new one is the last thing that went wrong.
        if state.rejections.count != rejectionsSeen {
            rejectionsSeen = state.rejections.count
            if let r = state.rejections.last {
                lastError = LeylineError(code: r.error.code, message: r.error.message, target: r.error.target)
                log("session", "write \(r.tag) rejected: \(r.error.code) \(r.error.message)")
            }
        }
    }

    /// On the first live snapshot: show a capture that already exists (another client's, or
    /// ours from before a reconnect), else make one on the last band used, else FM broadcast.
    private func adopt() {
        adopted = true
        if captureID == nil, let cap = state.captures.first(where: { $0.state == .captureActive }) ?? state.captures.first {
            captureID = cap.captureID
            if channelID == nil, let ch = state.channels(in: cap.captureID).first { channelID = ch.channelID }
            log("session", "adopted capture \(cap.captureID) at \(cap.centerHz) Hz, \(cap.sampleRate) S/s, channel \(channelID ?? "none")")
            if channelID == nil { Task { await tuneCreating(hz: cap.centerHz) } }
            return
        }
        guard captureID == nil, hasRadio else { return }
        let id = selectedBandID ?? "fm"
        if let b = bands.first(where: { $0.id == id }) ?? bands.first(where: { $0.id == "fm" }) {
            Task { await select(band: b) }
        }
    }

    private var hasRadio: Bool { state.devices.contains { $0.state != .disconnected } }

    // MARK: Bands

    /// The band's centre and rate on the radio, its mode and width on the channel, a sink so it
    /// is heard, and a squelch measured from the floor. Creates what does not exist and writes
    /// what does (docs/design/app-design-handoff.md, Region 1).
    func select(band: Band) async {
        guard !busy, let daemon else { return }
        busy = true
        defer { busy = false }
        selectedBandID = band.id
        UserDefaults.standard.set(band.id, forKey: Self.lastBandKey)
        lastError = nil
        log("session", "select band \(band.name)")
        do {
            let dev = try pickDevice()
            let rate = Bands.sampleRate(for: band, offered: dev.sampleRates) ?? 2_400_000
            let centre = band.centerHz
            let cap = try await ensureCapture(on: dev, centerHz: centre, sampleRate: rate)
            let mode = band.mode(at: centre)
            let ch = try await ensureChannel(in: cap, offsetHz: 0, mode: mode, bandwidthHz: band.bandwidthHz)
            try await ensureSink(on: ch)
            spectrum.resetFolds()
            if band.widthHz > rate {
                notice = "\(band.name) is \(Frequency.format(band.widthHz)) wide and this radio captures at most \(Frequency.format(rate)); showing that much, centred on \(Frequency.format(centre))"
            } else {
                notice = "\(band.name): \(mode.word) at \(Frequency.width(band.bandwidthHz))"
            }
            await measureSquelch(channel: ch, sampleRate: rate, bandwidthHz: band.bandwidthHz)
        } catch {
            lastError = LeylineError(error)
        }
    }

    private func pickDevice() throws -> Leyline_V1_DeviceDescriptor {
        if let d = device, d.state != .disconnected { return d }
        if let d = state.devices.first(where: { $0.state == .available }) ?? state.devices.first(where: { $0.state == .inUse }) { return d }
        throw LeylineError(code: "DEVICE_NOT_FOUND", message: "No radio is plugged in")
    }

    private func ensureCapture(on dev: Leyline_V1_DeviceDescriptor, centerHz: UInt64, sampleRate: UInt64) async throws -> Leyline_V1_Capture {
        guard let daemon, let writes else { throw LeylineError.notDialled }
        if var cap = capture, cap.deviceID == dev.deviceID {
            if cap.sampleRate != sampleRate { _ = await writes.set(.captureSampleRate(sampleRate), target: cap.captureID) }
            if cap.centerHz != centerHz { await writes.centerHz(centerHz, capture: cap.captureID) }
            cap.centerHz = centerHz
            cap.sampleRate = sampleRate
            return cap
        }
        var req = Leyline_V1_CreateCaptureRequest()
        req.deviceID = dev.deviceID
        req.centerHz = centerHz
        req.sampleRate = sampleRate
        let cap: Leyline_V1_Capture
        do { cap = try await daemon.control.createCapture(req) } catch { throw LeylineError(error) }
        log("session", "created capture \(cap.captureID) on \(dev.model) at \(centerHz) Hz, \(sampleRate) S/s")
        captureID = cap.captureID
        channelID = nil
        return cap
    }

    private func ensureChannel(in cap: Leyline_V1_Capture, offsetHz: Int64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32) async throws -> Leyline_V1_Channel {
        guard let daemon, let writes else { throw LeylineError.notDialled }
        if var ch = channel, ch.captureID == cap.captureID {
            await apply(mode: mode, bandwidthHz: bandwidthHz, to: ch)
            if ch.offsetHz != offsetHz { await writes.offsetHz(offsetHz, channel: ch.channelID) }
            ch.mode = mode
            ch.bandwidthHz = bandwidthHz
            ch.offsetHz = offsetHz
            return ch
        }
        var req = Leyline_V1_CreateChannelRequest()
        req.captureID = cap.captureID
        req.offsetHz = offsetHz
        req.mode = mode
        req.bandwidthHz = bandwidthHz
        let ch: Leyline_V1_Channel
        do { ch = try await daemon.control.createChannel(req) } catch { throw LeylineError(error) }
        log("session", "created channel \(ch.channelID): \(mode.word) \(bandwidthHz) Hz at offset \(offsetHz)")
        channelID = ch.channelID
        return ch
    }

    private func ensureSink(on ch: Leyline_V1_Channel) async throws {
        guard let daemon else { throw LeylineError.notDialled }
        if let s = sink, s.channelID == ch.channelID { return }
        var req = Leyline_V1_AttachSinkRequest()
        req.channelID = ch.channelID
        req.sink.systemAudio = Leyline_V1_SystemAudioSink()
        do { _ = try await daemon.control.attachSink(req) } catch { throw LeylineError(error) }
    }

    /// `ley tune`'s auto squelch from the next fresh row: 10 dB above the floor scaled to the
    /// channel width. Waits for two rows so the first is not the old span's.
    private func measureSquelch(channel ch: Leyline_V1_Channel, sampleRate: UInt64, bandwidthHz: UInt32) async {
        guard let writes else { return }
        let target = spectrum.rows + 2
        for _ in 0..<60 where spectrum.rows < target {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard spectrum.rows >= target else { return }
        let (threshold, floor) = SpectrumFold.autoSquelch(spectrum.latest, sampleRate: sampleRate, bandwidthHz: bandwidthHz)
        guard threshold.isFinite else { return }
        await writes.squelchDb(threshold, channel: ch.channelID)
        log("session", "auto squelch \(threshold) dBFS from floor \(floor)")
    }

    // MARK: Tuning

    /// Every gesture ends here. Inside the capture it is one `offset_hz` write. Outside it the
    /// centre moves first and the offset follows once the capture's event confirms the move:
    /// the two in one tick land in the daemon's order, and an offset applied against the old
    /// centre is a frequency nobody asked for, which then moves again. A click, a step or a
    /// typed frequency puts the target an eighth of the span in from the edge it arrived
    /// through. A drag held past the edge pans the capture an eighth of the span at a time, no
    /// faster than every 300 ms, so the picture moves under the pointer at a pace a hand can
    /// follow rather than a span per event.
    func tune(to hz: UInt64, dragging: Bool = false) {
        guard let cap = capture, let writes else { return }
        guard let ch = channel else {
            if !dragging, !creatingChannel { Task { await tuneCreating(hz: hz) } }
            return
        }
        let span = Int64(cap.sampleRate)
        let margin = Int64(ch.bandwidthHz)
        let centre = centreInFlight ?? Int64(cap.centerHz)
        let lo = centre - span / 2 + margin
        let hi = centre + span / 2 - margin
        var target = Int64(hz)
        if target < lo || target > hi {
            if dragging {
                target = min(max(target, lo), hi)
                if Date().timeIntervalSince(lastPan) > 0.3, centreInFlight == nil {
                    lastPan = Date()
                    let newCentre = clampCentre(target < lo ? centre - span / 8 : centre + span / 8, span: span)
                    requestedHz = UInt64(max(0, target))
                    requestedAt = Date()
                    log("tune", "pan \(centre) -> \(newCentre) Hz under a drag at \(target) Hz")
                    Task { await retune(centre: newCentre, offset: target - newCentre, capture: cap.captureID, channel: ch.channelID) }
                    followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
                    return
                }
            } else {
                let newCentre = clampCentre(target < lo ? target + span * 3 / 8 : target - span * 3 / 8, span: span)
                requestedHz = UInt64(max(0, target))
                requestedAt = Date()
                log("tune", "centre \(centre) -> \(newCentre) Hz for \(target) Hz")
                Task { await retune(centre: newCentre, offset: target - newCentre, capture: cap.captureID, channel: ch.channelID) }
                followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
                return
            }
        }
        let offset = target - centre
        requestedHz = UInt64(max(0, target))
        requestedAt = Date()
        Task { await writes.offsetHz(offset, channel: ch.channelID) }
        if !dragging { log("tune", "\(target) Hz (offset \(offset))\(hz != UInt64(max(0, target)) ? ", asked \(hz)" : "")") }
        followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
    }

    /// A centre inside the radio's tuning range, with half a span to spare on each side.
    private func clampCentre(_ centre: Int64, span: Int64) -> Int64 {
        guard let r = device?.tuningRanges.first(where: { Int64($0.minHz) - span / 2 <= centre && centre <= Int64($0.maxHz) + span / 2 })
            ?? device?.tuningRanges.first else { return max(0, centre) }
        return min(max(centre, Int64(r.minHz) + span / 2), Int64(r.maxHz) - span / 2)
    }

    /// The centre write, the wait for its event, then the offset.
    private func retune(centre: Int64, offset: Int64, capture: String, channel: String) async {
        guard let writes else { return }
        centreInFlight = centre
        spectrum.resetFolds()
        await writes.centerHz(UInt64(max(0, centre)), capture: capture)
        await confirmed { self.capture?.centerHz == UInt64(max(0, centre)) }
        if self.capture?.centerHz != UInt64(max(0, centre)) { log("tune", "centre \(centre) not confirmed; capture is at \(self.capture?.centerHz ?? 0)") }
        centreInFlight = nil
        await writes.offsetHz(offset, channel: channel)
    }

    /// No channel yet (a capture adopted from another client, or the first click): the centre
    /// moves if it must, then a channel on the band's defaults, a sink, a measured squelch. One
    /// at a time, because a drag with no channel once asked for thirteen.
    private func tuneCreating(hz: UInt64) async {
        guard let cap = capture, let writes, !creatingChannel else { return }
        creatingChannel = true
        defer { creatingChannel = false }
        let mode = Bands.defaultMode(at: hz, in: bands)
        let bw = Bands.band(containing: hz, in: bands).map { $0.mode(at: hz) == mode ? $0.bandwidthHz : mode.defaultBandwidthHz } ?? mode.defaultBandwidthHz
        let span = Int64(cap.sampleRate)
        var centre = Int64(cap.centerHz)
        let target = Int64(hz)
        if target < centre - span / 2 + Int64(bw) || target > centre + span / 2 - Int64(bw) {
            centre = clampCentre(target < centre ? target + span * 3 / 8 : target - span * 3 / 8, span: span)
            log("tune", "centre \(cap.centerHz) -> \(centre) Hz for \(target) Hz, before the first channel")
            centreInFlight = centre
            await writes.centerHz(UInt64(max(0, centre)), capture: cap.captureID)
            await confirmed { self.capture?.centerHz == UInt64(max(0, centre)) }
            centreInFlight = nil
        }
        requestedHz = hz
        requestedAt = Date()
        do {
            let ch = try await ensureChannel(in: cap, offsetHz: target - centre, mode: mode, bandwidthHz: bw)
            try await ensureSink(on: ch)
            await measureSquelch(channel: ch, sampleRate: cap.sampleRate, bandwidthHz: bw)
        } catch {
            lastError = LeylineError(error)
            log("tune", "could not make a channel at \(hz) Hz: \(LeylineError(error))")
        }
    }

    /// Crossing into another band takes that band's mode and width, because nobody chooses a
    /// demodulator to hear a station; inside one band the channel keeps whatever was chosen.
    private func followBand(from oldHz: UInt64?, to hz: UInt64, channel ch: Leyline_V1_Channel) {
        let was = oldHz.flatMap { Bands.band(containing: $0, in: bands) }
        let now = Bands.band(containing: hz, in: bands)
        if let b = band, !b.contains(hz) { selectedBandID = nil }
        guard let now, now.id != was?.id else { return }
        let mode = now.mode(at: hz)
        guard ch.mode != mode || ch.bandwidthHz != now.bandwidthHz else { return }
        log("tune", "band \(was?.name ?? "none") -> \(now.name): \(mode.word) \(now.bandwidthHz) Hz")
        notice = "\(now.name): \(mode.word) at \(Frequency.width(now.bandwidthHz))"
        Task { await apply(mode: mode, bandwidthHz: now.bandwidthHz, to: ch) }
    }

    /// Mode and width as one change, in the order the daemon accepts them: a narrow mode cannot
    /// take a wide channel, so narrowing writes the width first and waits for the event before
    /// the mode, and widening writes the mode first. Two writes in one tick land in the daemon's
    /// order, not ours, which is how a WFM width met an NFM mode and was refused. If the pair is
    /// not confirmed within a second it is tried once more the other way round, and logged.
    func apply(mode: Leyline_V1_DemodMode, bandwidthHz: UInt32, to ch: Leyline_V1_Channel) async {
        guard let writes else { return }
        let id = ch.channelID
        await widenCapture(for: bandwidthHz)
        if ch.mode == mode {
            if ch.bandwidthHz != bandwidthHz { await writes.bandwidthHz(bandwidthHz, channel: id) }
            return
        }
        let widthFirst = bandwidthHz < ch.bandwidthHz
        for attempt in 0..<2 {
            let first = (attempt == 0) == widthFirst
            if first {
                await writes.bandwidthHz(bandwidthHz, channel: id)
                await confirmed { self.channel?.bandwidthHz == bandwidthHz }
                await writes.mode(mode, channel: id)
            } else {
                await writes.mode(mode, channel: id)
                await confirmed { self.channel?.mode == mode }
                await writes.bandwidthHz(bandwidthHz, channel: id)
            }
            await confirmed { self.channel?.mode == mode && self.channel?.bandwidthHz == bandwidthHz }
            if channel?.mode == mode, channel?.bandwidthHz == bandwidthHz {
                log("tune", "channel \(id) is \(mode.word) \(bandwidthHz) Hz\(attempt == 1 ? " on the second order" : "")")
                return
            }
            log("tune", "channel \(id) did not confirm \(mode.word) \(bandwidthHz) Hz (\(first ? "width first" : "mode first")); is \(channel?.mode.word ?? "?") \(channel?.bandwidthHz ?? 0)")
        }
    }

    /// A channel needs room: the capture is widened to the smallest rate the radio offers that
    /// holds the width with a quarter to spare, and the move is confirmed before the channel is
    /// touched. WFM at 200 kHz on a 250 kS/s capture was refused for want of this.
    private func widenCapture(for bandwidthHz: UInt32) async {
        guard let cap = capture, let dev = device, let writes else { return }
        let need = UInt64(bandwidthHz) * 5 / 4
        guard cap.sampleRate < need else { return }
        guard let rate = dev.sampleRates.filter({ $0 >= need }).min() ?? dev.sampleRates.max(), rate > cap.sampleRate else { return }
        log("tune", "capture \(cap.sampleRate) -> \(rate) S/s to hold \(bandwidthHz) Hz")
        _ = await writes.set(.captureSampleRate(rate), target: cap.captureID)
        spectrum.resetFolds()
        await confirmed { self.capture?.sampleRate == rate }
    }

    /// Waits up to a second for the mirror to show `condition`, checking every 50 ms.
    private func confirmed(_ condition: () -> Bool) async {
        for _ in 0..<20 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func step(_ direction: Int, fine: Bool = false) {
        guard let hz = displayHz else { return }
        let step = UInt64(fine ? fineStepHz : stepHz)
        let snapped = fine ? hz : (hz / step) * step
        let next = direction > 0 ? snapped + step : (snapped >= step ? snapped - step : 0)
        tune(to: next)
    }

    func setMode(_ mode: Leyline_V1_DemodMode) {
        guard let ch = channel else { return }
        let bw = mode.offeredBandwidthsHz.contains(ch.bandwidthHz) ? ch.bandwidthHz : mode.defaultBandwidthHz
        log("tune", "mode \(mode.word) chosen, width \(bw) Hz")
        Task { await apply(mode: mode, bandwidthHz: bw, to: ch) }
    }

    func setBandwidth(_ hz: UInt32) {
        guard let ch = channel, let writes else { return }
        log("tune", "width \(hz) Hz chosen")
        Task {
            await widenCapture(for: hz)
            await writes.bandwidthHz(hz, channel: ch.channelID)
        }
    }

    func setSquelch(_ db: Double) {
        guard let ch = channel, let writes else { return }
        Task { await writes.squelchDb(db, channel: ch.channelID) }
    }

    func setVolume(_ v: Double) {
        guard let s = sink, let writes else { return }
        Task { await writes.volume(v.clamped(to: 0...1), sink: s.sinkID) }
    }

    /// Pause detaches the sink and play attaches one; the channel and its squelch stay.
    func togglePlay() async {
        guard let daemon, let ch = channel else { return }
        do {
            if let s = sink {
                var req = Leyline_V1_DetachSinkRequest()
                req.sinkID = s.sinkID
                _ = try await daemon.control.detachSink(req)
                log("session", "paused: sink \(s.sinkID) detached")
            } else {
                try await ensureSink(on: ch)
                log("session", "playing: sink attached")
            }
        } catch {
            lastError = LeylineError(error)
        }
    }

    // MARK: Device and gain

    func setGain(db: Double) {
        guard let cap = capture, let writes else { return }
        var w = Leyline_V1_GainWrite()
        w.db = db
        Task { await writes.gain(w, capture: cap.captureID) }
    }

    func setGainAuto() {
        guard let cap = capture, let writes else { return }
        var w = Leyline_V1_GainWrite()
        w.auto = true
        Task { await writes.gain(w, capture: cap.captureID) }
    }

    func setSampleRate(_ rate: UInt64) {
        guard let cap = capture, let writes else { return }
        Task { _ = await writes.set(.captureSampleRate(rate), target: cap.captureID) }
        spectrum.resetFolds()
    }

    /// Another radio: a new capture there on the current band, the old one left to its owner
    /// (destroyed only if this app made it).
    func choose(device: Leyline_V1_DeviceDescriptor) async {
        guard let daemon, device.deviceID != capture?.deviceID else { return }
        let old = capture
        captureID = nil
        channelID = nil
        if let b = band { await select(band: b) } else if let b = bands.first(where: { $0.id == "fm" }) { await select(band: b) }
        if let old, old.createdBy.clientID == daemon.identity.id {
            var req = Leyline_V1_DestroyCaptureRequest()
            req.captureID = old.captureID
            _ = try? await daemon.control.destroyCapture(req)
        }
    }

    // MARK: Bookmarks

    private func loadBookmarks() {
        var store = BookmarkStore(path: BookmarkStore.defaultPath())
        do {
            try store.load()
            bookmarks = store
        } catch {
            lastError = LeylineError(code: "BOOKMARKS_UNREADABLE", message: "bookmarks.json could not be read: \(error)", target: store.path)
        }
    }

    /// Reloads when `ley bookmarks` or anyone else writes the file.
    private func watchBookmarks() {
        let dir = (bookmarks.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        bookmarkWatchFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.loadBookmarks() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        bookmarkWatch = source
    }

    func bookmarkCurrent() {
        guard let ch = channel, let hz = tunedHz else { return }
        let name = Frequency.format(hz)
        do {
            try bookmarks.add(name: name, hz: hz, mode: ch.mode, bandwidthHz: ch.bandwidthHz)
            try bookmarks.save()
            notice = "Bookmarked \(name)"
        } catch {
            lastError = LeylineError(code: "BOOKMARKS_UNWRITABLE", message: "bookmarks.json could not be written: \(error)", target: bookmarks.path)
        }
    }

    func remove(bookmark: Bookmark) {
        do {
            try bookmarks.remove(bookmark.id)
            try bookmarks.save()
        } catch {
            lastError = LeylineError(code: "BOOKMARKS_UNWRITABLE", message: "bookmarks.json could not be written: \(error)", target: bookmarks.path)
        }
    }

    func tune(bookmark: Bookmark) {
        selectedBandID = nil
        log("tune", "bookmark \(bookmark.name) at \(bookmark.hz) Hz")
        tune(to: bookmark.hz)
        if let ch = channel, bookmark.mode != .unspecified {
            let bw = bookmark.bandwidthHz == 0 ? bookmark.mode.defaultBandwidthHz : bookmark.bandwidthHz
            Task { await apply(mode: bookmark.mode, bandwidthHz: bw, to: ch) }
        }
    }

    func snapToNearestBookmark() {
        guard let hz = tunedHz, let b = bookmarks.nearest(to: hz) else { return }
        tune(bookmark: b)
    }

    /// The loudest peak in the span by `ley spectrum`'s rule; a flat band tunes nothing.
    func centreOnStrongest() {
        guard let cap = capture, let peak = SpectrumFold.strongest(spectrum.latest, centerHz: cap.centerHz, spanHz: cap.sampleRate) else {
            notice = "Nothing in the span is 15 dB above the floor"
            return
        }
        log("tune", "strongest peak \(peak.centerHz) Hz at \(peak.db) dBFS")
        tune(to: peak.centerHz)
    }

    func zoomIn() { zoom = min(zoom * 2, 8) }
    func zoomOut() { zoom = max(zoom / 2, 1) }

    func clearNotice() { notice = nil }
    func clearError() { lastError = nil }
}

extension LeylineError {
    static let notDialled = LeylineError(code: "UNAVAILABLE", message: "The daemon is not dialled")
}
