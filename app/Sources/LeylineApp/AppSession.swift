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
    var isPlaying: Bool { sink != nil }
    var meter: Leyline_V1_Meter? { meters.meter }
    var isLive: Bool { if case .live = connection { true } else { false } }

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
        }
    }

    private func mirrorChanged(_ m: DaemonMirror) {
        state = m.state
        connection = m.connection
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
        captureID = cap.captureID
        channelID = nil
        return cap
    }

    private func ensureChannel(in cap: Leyline_V1_Capture, offsetHz: Int64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32) async throws -> Leyline_V1_Channel {
        guard let daemon, let writes else { throw LeylineError.notDialled }
        if var ch = channel, ch.captureID == cap.captureID {
            if ch.mode != mode { await writes.mode(mode, channel: ch.channelID) }
            if ch.bandwidthHz != bandwidthHz { await writes.bandwidthHz(bandwidthHz, channel: ch.channelID) }
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
        notice = "Squelch \(Int(threshold)) dBFS, 10 dB above the band's noise floor (\(Int(floor.rounded())) dBFS)"
    }

    // MARK: Tuning

    /// Every gesture ends here: an `offset_hz` write, or a centre move first when the frequency
    /// is outside the capture (the one thing that should feel slower).
    func tune(to hz: UInt64) {
        guard let cap = capture, let writes else { return }
        guard let ch = channel else {
            Task { await tuneCreating(hz: hz) }
            return
        }
        let half = Int64(cap.sampleRate / 2)
        let lo = Int64(cap.centerHz) - half + Int64(ch.bandwidthHz)
        let hi = Int64(cap.centerHz) + half - Int64(ch.bandwidthHz)
        if Int64(hz) < lo || Int64(hz) > hi {
            Task { await writes.centerHz(hz, capture: cap.captureID) }
            Task { await writes.offsetHz(0, channel: ch.channelID) }
            spectrum.resetFolds()
            selectedBandID = nil
            return
        }
        let offset = Int64(hz) - Int64(cap.centerHz)
        Task { await writes.offsetHz(offset, channel: ch.channelID) }
        if let b = band, !b.contains(hz) { selectedBandID = nil }
    }

    private func tuneCreating(hz: UInt64) async {
        guard let cap = capture else { return }
        let mode = Bands.defaultMode(at: hz, in: bands)
        let bw = Bands.band(containing: hz, in: bands).map { $0.mode(at: hz) == mode ? $0.bandwidthHz : mode.defaultBandwidthHz } ?? mode.defaultBandwidthHz
        do {
            let ch = try await ensureChannel(in: cap, offsetHz: Int64(hz) - Int64(cap.centerHz), mode: mode, bandwidthHz: bw)
            try await ensureSink(on: ch)
            await measureSquelch(channel: ch, sampleRate: cap.sampleRate, bandwidthHz: bw)
        } catch {
            lastError = LeylineError(error)
        }
    }

    func step(_ direction: Int, fine: Bool = false) {
        guard let hz = tunedHz else { return }
        let step = UInt64(fine ? fineStepHz : stepHz)
        let snapped = fine ? hz : (hz / step) * step
        let next = direction > 0 ? snapped + step : (snapped >= step ? snapped - step : 0)
        tune(to: next)
    }

    func setMode(_ mode: Leyline_V1_DemodMode) {
        guard let ch = channel, let writes else { return }
        Task {
            await writes.mode(mode, channel: ch.channelID)
            if !mode.offeredBandwidthsHz.contains(ch.bandwidthHz), let bw = mode.offeredBandwidthsHz.first {
                await writes.bandwidthHz(bw, channel: ch.channelID)
            }
        }
    }

    func setBandwidth(_ hz: UInt32) {
        guard let ch = channel, let writes else { return }
        Task { await writes.bandwidthHz(hz, channel: ch.channelID) }
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
            } else {
                try await ensureSink(on: ch)
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
        let name = Bands.band(containing: hz, in: bands).map { "\($0.name) \(Frequency.format(hz))" } ?? Frequency.format(hz)
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
        if let ch = channel, let writes {
            if bookmark.mode != .unspecified, ch.mode != bookmark.mode {
                Task { await writes.mode(bookmark.mode, channel: ch.channelID) }
            }
            let bw = bookmark.bandwidthHz == 0 ? bookmark.mode.defaultBandwidthHz : bookmark.bandwidthHz
            if bw > 0, ch.bandwidthHz != bw { Task { await writes.bandwidthHz(bw, channel: ch.channelID) } }
        }
        tune(to: bookmark.hz)
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
