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
    /// The objects this app made, as their RPCs returned them, until the mirror carries them: a
    /// response arrives before the event does, and in that gap the window still has a channel.
    private var pendingCapture: Leyline_V1_Capture?
    private var pendingChannel: Leyline_V1_Channel?
    /// Whether the mirror has carried the object at all. An id is dropped only once the mirror
    /// had the object and lost it (a tombstone, or a resync without it), never for the gap
    /// between an RPC's response and its event, which once made ten channels from ten tunes.
    private var captureSeen = false
    private var channelSeen = false
    /// When the id was set, so a gap that never closes is not waited on forever: an object the
    /// daemon made and lost before its first event would otherwise leave the window pointing at
    /// an id no event will ever carry.
    private var captureSetAt = Date.distantPast
    private var channelSetAt = Date.distantPast
    /// The frequency this app last asked for, until the daemon confirms it or two seconds pass:
    /// what the field shows and what a step is taken from, so two quick presses do not both
    /// start from the frequency before the first (`../dev/app.md`: a view previews its own
    /// writes and reconciles on the event).
    private(set) var requestedHz: UInt64?
    /// The clock that clears `requestedHz`, because a write the daemon never confirms leaves the
    /// field showing a frequency nothing is tuned to until the next event, and a quiet daemon
    /// sends none.
    private var requestedExpiry: Task<Void, Never>?
    /// A centre write not yet confirmed by the capture's event; clicks in the meantime are
    /// computed against it rather than the mirror's old centre.
    private var centreInFlight: Int64?
    /// A centre move asked for while one was in flight. The last one wins, and `retune` performs
    /// it when the move it is waiting on confirms: two moves at once leave the coalescer holding
    /// only the last centre, and the first offset written against a centre that never applied.
    private var nextRetune: (centre: Int64, offset: Int64, capture: String, channel: String)?
    private var creatingChannel = false
    private var lastPan = Date.distantPast
    /// Where a rail drag is taking the centre, until the capture's event carries it: the rail
    /// draws its pill there so the region moves with the hand, not a tick behind it.
    private(set) var panCentre: Int64?

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
    /// The frequency under the pointer on either chart, so the hairline shows on both; nil when
    /// the pointer is over neither.
    var pointerHz: UInt64?
    /// Where a chart drag began, for the badge's `swept` figure.
    private(set) var sweepFromHz: UInt64?
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

    var capture: Leyline_V1_Capture? { captureID.flatMap { state.capture($0) } ?? pendingCapture }
    var channel: Leyline_V1_Channel? { channelID.flatMap { state.channel($0) } ?? pendingChannel }
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
        if let r = requestedHz, r == tunedHz { clearRequested() }
        // Objects the window pointed at may be gone: a tombstone, or the daemon restarted. One
        // that was never in the mirror goes the same way after 3 s, because the gap between an
        // RPC's response and its event closes in milliseconds and an object evicted inside it
        // has no event coming.
        if let id = captureID {
            if state.capture(id) != nil {
                captureSeen = true
                pendingCapture = nil
            } else if captureSeen {
                log("session", "capture \(id) is gone; a new one will be made")
                dropCapture()
            } else if Date().timeIntervalSince(captureSetAt) > 3 {
                log("session", "the mirror has no capture \(id) 3 s after the window took it; a new one will be made")
                dropCapture()
            }
        }
        if let id = channelID {
            if state.channel(id) != nil {
                channelSeen = true
                pendingChannel = nil
            } else if channelSeen {
                log("session", "channel \(id) is gone")
                dropChannel()
            } else if Date().timeIntervalSince(channelSetAt) > 3 {
                log("session", "the mirror has no channel \(id) 3 s after the window took it")
                dropChannel()
            }
        }
        if case .live = connection {
            if !adopted { adopt() }
        } else {
            adopted = false
            captureSeen = false
            channelSeen = false
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

    /// Forgets the capture, and the channel with it: a channel without its capture is nothing.
    /// The window then makes new ones, because `adopt` runs again.
    private func dropCapture() {
        captureID = nil
        captureSeen = false
        pendingCapture = nil
        adopted = false
        dropChannel()
    }

    private func dropChannel() {
        channelID = nil
        channelSeen = false
        pendingChannel = nil
    }

    /// The frequency the field shows until the daemon confirms it, with the clock that clears it
    /// armed afresh: a tune whose event never arrives stops showing after two seconds rather
    /// than until the mirror happens to change.
    private func request(_ hz: UInt64) {
        requestedHz = hz
        requestedExpiry?.cancel()
        requestedExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            if self.requestedHz == hz {
                self.requestedHz = nil
                self.requestedExpiry = nil
            }
        }
    }

    private func clearRequested() {
        requestedHz = nil
        requestedExpiry?.cancel()
        requestedExpiry = nil
    }

    /// On the first live snapshot: show a capture that already exists (another client's, or
    /// ours from before a reconnect), else make one on the last band used, else FM broadcast.
    private func adopt() {
        guard !busy, !creatingChannel else { return }
        adopted = true
        if captureID == nil, let cap = state.captures.first(where: { $0.state == .captureActive }) ?? state.captures.first {
            captureID = cap.captureID
            captureSetAt = Date()
            if channelID == nil, let ch = state.channels(in: cap.captureID).first {
                channelID = ch.channelID
                channelSetAt = Date()
            }
            log("session", "adopted capture \(cap.captureID) at \(cap.centerHz) Hz, \(cap.sampleRate) S/s, channel \(channelID ?? "none")")
            if channelID == nil, state.channels(in: cap.captureID).isEmpty { Task { await tuneCreating(hz: cap.centerHz) } }
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
    /// what does (docs/design/app-design-handoff.md, Region 1). With `hz`, the band arrives
    /// tuned there rather than at its centre, and the capture sits where that frequency is
    /// inside it: a drag past the rail's end cap lands on the neighbour's near edge.
    func select(band: Band, at hz: UInt64? = nil) async {
        guard !busy, daemon != nil else { return }
        busy = true
        defer { busy = false }
        selectedBandID = band.id
        UserDefaults.standard.set(band.id, forKey: Self.lastBandKey)
        lastError = nil
        log("session", "select band \(band.name)\(hz.map { " at \($0) Hz" } ?? "")")
        do {
            let dev = try pickDevice()
            let rate = Bands.sampleRate(for: band, offered: dev.sampleRates) ?? 2_400_000
            let target = hz ?? band.centerHz
            let centre = hz == nil ? band.centerHz : captureCentre(for: band, at: target, rate: rate)
            let cap = try await ensureCapture(on: dev, centerHz: centre, sampleRate: rate)
            let mode = band.mode(at: target)
            if hz != nil { request(target) }
            let ch = try await ensureChannel(in: cap, offsetHz: Int64(target) - Int64(centre), mode: mode, bandwidthHz: band.bandwidthHz)
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

    /// Where the capture sits so that `hz` is inside it with the channel's width to spare: the
    /// band's centre when the band fits the span, else the span slid along the band to hold
    /// `hz`, and either way pulled in until the channel has room, then kept in the radio's range.
    private func captureCentre(for band: Band, at hz: UInt64, rate: UInt64) -> UInt64 {
        let span = Int64(rate)
        let target = Int64(hz)
        let bw = Int64(band.bandwidthHz)
        var centre = Int64(band.centerHz)
        if band.widthHz > rate {
            centre = min(max(target, Int64(band.minHz) + span / 2), Int64(band.maxHz) - span / 2)
        }
        centre = min(max(centre, target - span / 2 + bw), target + span / 2 - bw)
        return UInt64(max(0, clampCentre(centre, span: span)))
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
        captureSeen = false
        captureSetAt = Date()
        pendingCapture = cap
        dropChannel()
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
        channelSeen = false
        channelSetAt = Date()
        pendingChannel = ch
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
    /// channel width. It waits for the feed to be subscribed to this channel's capture and for
    /// two of its rows, because a row of the span before is a floor from another band: the feed
    /// zeroes its count on each subscription, so a count that went backwards means the rows on
    /// hand are the new capture's and two of them is two of that span's. Three seconds is the
    /// budget, and if it runs out the squelch is left off, which is what `ley tune` leaves.
    private func measureSquelch(channel ch: Leyline_V1_Channel, sampleRate: UInt64, bandwidthHz: UInt32) async {
        guard let writes else { return }
        let start = spectrum.rows
        var fresh = false
        for _ in 0..<60 {
            let since = spectrum.rows >= start ? spectrum.rows - start : spectrum.rows
            if spectrum.subscribedCapture == ch.captureID, since >= 2 {
                fresh = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard fresh else {
            log("session", "no two rows of capture \(ch.captureID) within 3 s; squelch left off, so no station is muted by another band's floor")
            return
        }
        let (threshold, floor) = SpectrumFold.autoSquelch(spectrum.latest, sampleRate: sampleRate, bandwidthHz: bandwidthHz)
        guard threshold.isFinite else { return }
        await writes.squelchDb(threshold, channel: ch.channelID)
        log("session", "auto squelch \(threshold) dBFS from floor \(floor)")
    }

    // MARK: Tuning

    /// A drag across the spectrum or the waterfall: the end of a drag is still a drag, so there
    /// is no centre jump on release.
    func chartDrag(to hz: UInt64, ended: Bool) {
        if sweepFromHz == nil {
            sweepFromHz = hz
            log("tune", "drag from \(hz) Hz")
        }
        pointerHz = hz
        tune(to: hz, dragging: true)
        if ended {
            log("tune", "drag ended at \(hz) Hz")
            sweepFromHz = nil
        }
    }

    /// `146.520 MHz`, and during a drag how far it has swept.
    func pointerWords(_ hz: UInt64) -> String {
        let f = Frequency.fieldParts(hz)
        if let start = sweepFromHz, start != hz {
            let sweep = start > hz ? start - hz : hz - start
            return "\(f.major) MHz · \(Frequency.format(sweep)) swept"
        }
        return "\(f.major) MHz"
    }

    /// Every gesture ends here. Inside the capture it is one `offset_hz` write. Outside it the
    /// centre moves first and the offset follows once the capture's event confirms the move:
    /// the two in one tick land in the daemon's order, and an offset applied against the old
    /// centre is a frequency nobody asked for, which then moves again. A click, a step or a
    /// typed frequency puts the target an eighth of the span in from the edge it arrived
    /// through. A drag held past the edge pans the capture an eighth of the span at a time, no
    /// faster than every 300 ms, so the picture moves under the pointer at a pace a hand can
    /// follow rather than a span per event.
    func tune(to hz: UInt64, dragging: Bool = false) {
        place(hz, panning: dragging, quiet: dragging)
    }

    /// A drag along the rail moves the capture, not the station, and never out of the band:
    /// the region stops at the band's edges, and a band the region holds whole does not move
    /// at all. The offset follows the centre so the frequency stays put, until the station
    /// would leave the middle 80 % of the span, when it rides that edge instead (and never
    /// nearer the span's end than its own width).
    /// The centre and the offset go in one tick, centre first: the daemon bounds an offset by
    /// the sample rate alone, so either order applies and there is nothing to confirm between
    /// them, unlike a click's move (`retune`). While a click's move is in flight the drag is
    /// refused, because two writers of the same centre leave one offset against a centre that
    /// never applied.
    func pan(centreTo centre: Int64, ended: Bool) {
        guard let cap = capture, let ch = channel, let writes else { return }
        guard panCentre != nil || centreInFlight == nil else { return }
        let span = Int64(cap.sampleRate)
        var newCentre = clampCentre(centre, span: span)
        if let b = band {
            newCentre = b.widthHz > cap.sampleRate
                ? min(max(newCentre, Int64(b.minHz) + span / 2), Int64(b.maxHz) - span / 2)
                : Int64(cap.centerHz)
        }
        let bound = max(0, min(span * 4 / 10, span / 2 - Int64(ch.bandwidthHz)))
        let station = Int64(displayHz ?? cap.centerHz)
        let held = min(max(station, newCentre - bound), newCentre + bound)
        panCentre = newCentre
        centreInFlight = newCentre
        request(UInt64(max(0, held)))
        spectrum.resetFolds()
        let want = UInt64(max(0, newCentre))
        Task {
            await writes.centerHz(want, capture: cap.captureID)
            await writes.offsetHz(held - newCentre, channel: ch.channelID)
        }
        if ended {
            log("tune", "pan capture \(cap.centerHz) -> \(newCentre) Hz, station at \(held) Hz\(held != station ? ", pushed from \(station)" : "")")
            followBand(from: tunedHz, to: UInt64(max(0, held)), channel: ch)
            Task {
                await confirmed { self.capture?.centerHz == want }
                if panCentre == newCentre {
                    panCentre = nil
                    centreInFlight = nil
                }
            }
        }
    }

    private func place(_ hz: UInt64, panning dragging: Bool, quiet: Bool) {
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
                    request(UInt64(max(0, target)))
                    log("tune", "pan \(centre) -> \(newCentre) Hz under a drag at \(target) Hz")
                    Task { await retune(centre: newCentre, offset: target - newCentre, capture: cap.captureID, channel: ch.channelID) }
                    followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
                    return
                }
            } else {
                let newCentre = clampCentre(target < lo ? target + span * 3 / 8 : target - span * 3 / 8, span: span)
                request(UInt64(max(0, target)))
                // One move at a time: while one is in flight the new one waits in the slot and
                // `retune` performs it next, because two of them leave the coalescer holding
                // only the last centre and the first offset written against a centre that
                // never applied.
                if centreInFlight != nil {
                    if let waiting = nextRetune { log("tune", "centre \(waiting.centre) Hz superseded before it ran") }
                    log("tune", "centre \(newCentre) Hz for \(target) Hz waits on the move in flight")
                    nextRetune = (centre: newCentre, offset: target - newCentre, capture: cap.captureID, channel: ch.channelID)
                } else {
                    log("tune", "centre \(centre) -> \(newCentre) Hz for \(target) Hz")
                    Task { await retune(centre: newCentre, offset: target - newCentre, capture: cap.captureID, channel: ch.channelID) }
                }
                followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
                return
            }
        }
        let offset = target - centre
        request(UInt64(max(0, target)))
        Task { await writes.offsetHz(offset, channel: ch.channelID) }
        if !quiet { log("tune", "\(target) Hz (offset \(offset))\(hz != UInt64(max(0, target)) ? ", asked \(hz)" : "")") }
        followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
    }

    /// A centre inside the radio's tuning range, with half a span to spare on each side.
    private func clampCentre(_ centre: Int64, span: Int64) -> Int64 {
        guard let r = device?.tuningRanges.first(where: { Int64($0.minHz) - span / 2 <= centre && centre <= Int64($0.maxHz) + span / 2 })
            ?? device?.tuningRanges.first else { return max(0, centre) }
        return min(max(centre, Int64(r.minHz) + span / 2), Int64(r.maxHz) - span / 2)
    }

    /// The centre write, the wait for its event, then the offset — and then whatever move was
    /// asked for in the meantime, before `centreInFlight` is cleared, so a second request never
    /// starts a second one of these. A superseded move's offset is not written: the centre it
    /// belonged to is already on its way somewhere else.
    private func retune(centre: Int64, offset: Int64, capture: String, channel: String) async {
        guard let writes else { return }
        var move = (centre: centre, offset: offset, capture: capture, channel: channel)
        while true {
            centreInFlight = move.centre
            spectrum.resetFolds()
            let want = UInt64(max(0, move.centre))
            await writes.centerHz(want, capture: move.capture)
            await confirmed { self.capture?.centerHz == want }
            if self.capture?.centerHz != want { log("tune", "centre \(move.centre) not confirmed; capture is at \(self.capture?.centerHz ?? 0)") }
            if nextRetune == nil { await writes.offsetHz(move.offset, channel: move.channel) }
            guard let next = nextRetune else { break }
            nextRetune = nil
            log("tune", "centre \(move.centre) -> \(next.centre) Hz, the move that was waiting")
            move = next
        }
        centreInFlight = nil
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
        request(hz)
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

    /// Waits up to `seconds` for the mirror to show `condition`, checking every 50 ms. A second
    /// is the default because that is a control write's round trip with room to spare.
    private func confirmed(within seconds: Double = 1, _ condition: () -> Bool) async {
        for _ in 0..<Int(seconds * 20) {
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
        // `select(band:)` returns without doing anything while another band change is in flight,
        // so the switch must wait for that one rather than be dropped on the floor.
        await confirmed(within: 2) { !self.busy }
        guard !busy else {
            log("session", "device \(device.model) not chosen: a band change was still in flight after 2 s")
            return
        }
        let old = capture
        dropCapture()
        if let b = band { await select(band: b) } else if let b = bands.first(where: { $0.id == "fm" }) { await select(band: b) }
        if let old, old.createdBy.clientID == daemon.identity.id {
            var req = Leyline_V1_DestroyCaptureRequest()
            req.captureID = old.captureID
            _ = try? await daemon.control.destroyCapture(req)
        }
    }

    // MARK: Bookmarks

    /// Loads into the store the session already holds, so a read that fails leaves it unloaded
    /// and every write refuses until one succeeds: the sidebar goes on showing the last list it
    /// read, and nothing overwrites a file nobody could parse.
    private func loadBookmarks() {
        do {
            try bookmarks.load()
        } catch {
            lastError = LeylineError(code: "BOOKMARKS_UNREADABLE", message: "bookmarks.json could not be read: \(error)", target: bookmarks.path)
        }
    }

    /// What a refused bookmark write says. The unloaded case is the one worth spelling out: the
    /// file is still whatever it was, so the line names it and says nothing was written.
    private func bookmarkWriteError(_ error: any Error) -> LeylineError {
        if let reason = error as? BookmarkError, case .notLoaded(let path) = reason {
            return LeylineError(
                code: "BOOKMARKS_UNREADABLE",
                message: "\(path) could not be read, so nothing was written. Fix that file, or move it aside, and the list reloads.",
                target: path)
        }
        return LeylineError(code: "BOOKMARKS_UNWRITABLE", message: "bookmarks.json could not be written: \(error)", target: bookmarks.path)
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
            lastError = bookmarkWriteError(error)
        }
    }

    func remove(bookmark: Bookmark) {
        do {
            try bookmarks.remove(bookmark.id)
            try bookmarks.save()
        } catch {
            lastError = bookmarkWriteError(error)
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
