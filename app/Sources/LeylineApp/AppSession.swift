// SPDX-License-Identifier: Apache-2.0

// Shared state for every view: the daemon's state copied out of the mirror on every change, the
// coalescer that writes through it, the two feeds, the bands and bookmarks files, and every
// action the window performs. Nothing here is authoritative (AGENTS.md invariant 7): a view
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

    // The window's own selection: which capture it shows and which channel it plays. Ids only;
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
    /// draws its pill there so the region tracks the drag instead of lagging one event behind.
    private(set) var panCentre: Int64?

    // Files both clients own. `bands` is the part table, which every lookup below keeps reading
    // (`band(containing:)`, `defaultMode`, `tune(bookmark:)`, the last-band adoption): none of
    // them ever answers a group (the plan's KTD4). `sidebarRows` is the fold the sidebar and
    // the filter draw, a group in place of its parts (docs/design/channels.md, "Bands are the
    // spine of the sidebar").
    let bands: [Band] = Bands.plain
    let sidebarRows: [Band] = Bands.sidebar()
    private(set) var bookmarks = BookmarkStore(path: BookmarkStore.defaultPath())
    private var bookmarkWatch: DispatchSourceFileSystemObject?
    private var bookmarkWatchFD: Int32 = -1

    // Feeds.
    let spectrum = SpectrumFeed()
    let telemetry = ChannelTelemetryFeed()
    let captureLevel = CaptureLevelFeed()
    let audioLevels = AudioLevelsFeed()

    // View state local to the window: presentation only, never radio state.
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
    /// When the chip was clicked, until the menu appears: the open is timed into the log.
    @ObservationIgnored var deviceMenuAskedAt: Date?
    /// Whether the inspector is on the window's right (M2 handoff, "The panel"). Remembered in
    /// the defaults under `inspectorShownKey`, the way the last band is; shown until someone
    /// closes it, because the default window is sized with it.
    var inspectorShown =
        UserDefaults.standard.object(forKey: AppSession.inspectorShownKey) as? Bool
        ?? true
    {
        didSet {
            UserDefaults.standard.set(inspectorShown, forKey: Self.inspectorShownKey)
            // The audio ladder subscribes only while the panel draws it.
            followAudioLevels()
        }
    }
    /// Which of the window's two places shows, the toolbar's `Radio | Library` (docs/design/
    /// app-design-handoff-m3.md, "Decided 2026-09-25: the Library"). The live radio keeps
    /// running in the Library: its channel, sink and subscriptions are the session's, not the
    /// Radio body's. Remembered in the defaults under `placeKey`, the way `inspectorShown` is.
    /// Arriving in the Library selects its first channel when none is selected, so the centre
    /// is never blank.
    var place =
        UserDefaults.standard.string(forKey: AppSession.placeKey)
        .flatMap(WindowPlace.init(rawValue:)) ?? .radio
    {
        didSet {
            UserDefaults.standard.set(place.rawValue, forKey: Self.placeKey)
            guard place != oldValue else { return }
            log("session", "place: \(place.rawValue)")
            if place == .library { selectFirstChannel() }
            followPage()
            // The audio ladder is drawn only by the Radio's inspector.
            followAudioLevels()
        }
    }
    /// The Library's selected channel row (`RecordingChannel.id`), or nil. While one is selected
    /// and the Library shows, the centre column is that channel's page (`RecordingsPage`), and
    /// the manifests of its recordings are read. Another row, or none, clears the selected part:
    /// the inspector then shows a part only while one plays.
    var selectedRecordingChannel: String? {
        didSet {
            guard selectedRecordingChannel != oldValue else { return }
            selectedPartURI = nil
            followPage()
        }
    }
    /// The Library sidebar's search field.
    var recordingsQuery = ""
    /// The Radio sidebar's filter field, and whether it holds focus (`Go to…`, ⌘G, gives it;
    /// Escape takes it). While the query is non-empty the sidebar is the flat list of matches.
    var filterQuery = ""
    var filterFocused = false
    /// The sidebar row opened by its chevron without tuning, or nil; the tuned row is always
    /// open (`isExpanded`), and a tune into any other row closes this one
    /// (docs/design/channels.md, "Bands are the spine of the sidebar").
    private(set) var expandedBandID: String?
    /// Whether the one line standing for the bands this radio cannot tune has been opened to
    /// its rows; the next tune folds it again.
    var outOfRangeExpanded = false
    /// The sidebar row whose `Channels…` popover is open, or nil. Opening it empties the query
    /// and puts the highlight on the tuned channel when the plan has it, else the first row.
    var pickerBand: Band? {
        didSet {
            guard pickerBand?.id != oldValue?.id else { return }
            pickerQuery = ""
            pickerHighlight = 0
            guard let band = pickerBand, let hz = tunedHz,
                let found = Plans.channel(at: hz), let i = band.plan().firstIndex(of: found.channel)
            else { return }
            pickerHighlight = i
        }
    }
    /// The picker's filter field: a case-insensitive prefix of a channel's name or alias, the
    /// rule the sidebar's filter uses (the plan's KTD6). Typing puts the highlight back on the
    /// first row.
    var pickerQuery = "" {
        didSet { if pickerQuery != oldValue { pickerHighlight = 0 } }
    }
    /// The picker row Return picks: an index into `pickerRows`.
    private(set) var pickerHighlight = 0
    /// One sentence about the last thing that happened, or nil.
    /// Every message the window shows is also logged (`AppLog.swift`): the notice and the error
    /// when set, the empty-state and out-of-capture messages when they change, and the failure
    /// state in `nameFailure`, so any message in a screenshot can be found in the log.
    private(set) var notice: String? {
        didSet { if let n = notice, n != oldValue { log("shown", "notice: \(n)") } }
    }
    private(set) var lastError: LeylineError? {
        didSet {
            if let e = lastError, e != oldValue {
                log("shown", "error: \(e.code) \(e.message.isEmpty ? "" : e.message)")
            }
        }
    }
    /// The empty-state and out-of-capture messages last logged, so a change logs one line.
    private var shownEmptyWords: String?
    private var shownOutOfCapture: String?
    /// The problem the radio's level shows, or nil (`FailureState`): folded through
    /// `failureHold` on every `CaptureLevel` reading and on every mirror change (the gains pick
    /// the words), and logged when it is raised and when it clears. While it holds the device
    /// chip's dot is `caution` with the sentence as its tooltip and the gain slider's knob is
    /// `recording`; there is no close control, because it goes when the level clears
    /// (plans/app.md, M2-6 and M2-8).
    private(set) var failure: FailureState?
    /// The hold on the capture's clock that keeps a burst of clipping from showing.
    @ObservationIgnored private var failureHold = FailureHold()
    /// The channel the mirror has reported out of capture for `outOfCaptureHoldSeconds`, or nil:
    /// only then are `outOfCaptureWords` shown.
    private var outOfCaptureHeld: String?
    /// The wait that sets `outOfCaptureHeld`, for the channel it is waiting on; cancelled when
    /// the channel comes back inside.
    @ObservationIgnored private var outOfCaptureWait: (channel: String, task: Task<Void, Never>)?
    private var busy = false
    private var rejectionsSeen = 0

    // Recording (plans/app.md, APP-5; docs/design/app-design-handoff-m3.md, 8a and 8b). The
    // jobs and the playbacks are the mirror's; what is here is the store's listing, the
    // manifests of the recordings the window shows as read from disk, and the switch's click
    // until its job's event arrives.
    /// The recordings the daemon holds, newest first, from `ListResources(RECORDING)`: re-read on
    /// every change to a record job and once on adoption. The Library's sidebar and the
    /// store footer render it.
    private(set) var recordings: [RecordingSummary] = []
    @ObservationIgnored private var recordingsLoad: Task<Void, Never>?
    /// The record jobs as last seen, so a change to one is noticed.
    @ObservationIgnored private var recordJobsSeen: [Leyline_V1_Job] = []
    /// The switch's click, until the job's event agrees or `RecordSwitchClick.holdSeconds`
    /// pass: the switch would otherwise flick back for the round trip. Not a state of its own;
    /// the switch shows the job as soon as the mirror carries it. By frequency and mode, because
    /// the channel page's switch and the log's are one state in two places when they name the
    /// same channel, and two states when they do not. Written only by `holdRecordSwitch` and
    /// `letGoRecordSwitch`, which log it.
    private var recordSwitchPending: RecordSwitchClick?
    @ObservationIgnored private var recordSwitchExpiry: Task<Void, Never>?
    /// The log's switch as last written to the log (`logRecordSwitch`), so a change is logged
    /// once: the owner's third run saw the switch go grey and left nothing in the log to say why.
    @ObservationIgnored private var recordSwitchLogged: String?
    /// The tuned log's frequency and mode and the record job running there, as the last mirror
    /// change left them, so `markRecordToggles` cuts the log when the job starts or ends.
    @ObservationIgnored private var recordMarkSeen: (key: TransmissionLogs.Key, jobID: String?)?
    /// The record jobs either switch started, until each ends: `StartJob` answers before the
    /// radio is allocated, so a decline arrives as the job's FAILED event and is shown from
    /// there (`Recordings.failureNotice`).
    @ObservationIgnored private var switchStartedJobs: Set<String> = []
    /// Manifests by job id, read through `ResolveLocalPath`: every recording of the channel page's
    /// channel (docs/design/app-design-handoff-m3.md, 8c) and every recording on the tuned
    /// frequency and mode, whose parts the log's kept rows and the time gutter's bars come from
    /// (`tunedManifests`). Each is kept while the listing holds the recording, read once, and read
    /// again on each event of its job, which is how a running card grows and a new row is kept as
    /// parts land.
    private(set) var manifests: [String: RecordingManifest] = [:]
    @ObservationIgnored private var manifestLoads: [String: Task<Void, Never>] = [:]
    /// Job ids whose manifest a job event made stale.
    @ObservationIgnored private var staleManifests: Set<String> = []
    /// Job ids whose read failed, not tried again until their job changes or the listing is read
    /// again: a mirror change arrives four times a second while a part plays.
    @ObservationIgnored private var failedManifests: Set<String> = []
    /// The part the Library's inspector and player show: the last row clicked, and
    /// the part Play all or Play day moved on to. Cleared when its recording is deleted.
    var selectedPartURI: String?
    /// The EARLIER days (older than `Recordings.collapseAfterDays`) opened in place by a click,
    /// by `DayRows.id`. Presentation only.
    var openedDays: Set<String> = []
    /// Play all's or Play day's parts still to play (`PlayQueue`); the next starts on the
    /// tombstone of the one playing.
    private(set) var playQueue = PlayQueue()
    /// Each Library row's level graph (`LevelGraph.columns`), by part URI, once read: the part's
    /// WAV through `ResolveLocalPath`, one pass, off the main actor (docs/design/
    /// app-design-handoff-m3.md, "10a · The Library, revised"). An empty array is a part whose
    /// file could not be read here (a remote daemon, a file gone), not tried again.
    private(set) var levelGraphs: [String: [Float]] = [:]
    @ObservationIgnored private var levelGraphLoads: Set<String> = []
    /// The playback this window started, by the id `StartPlayback` returned, and the part it
    /// plays, until its tombstone. One at a time. Its position is the mirror's: the daemon
    /// publishes a playing playback four times a second.
    private var playbackID: String?
    private(set) var playingURI: String?
    /// The start of the log row whose ▶ started the playing part, so only that row shows ■ and
    /// the progress line: several rows can lie inside one part, and until 2026-09-25 each of them
    /// showed the part playing (plans/app.md, APP-5, "Fixed 2026-09-25 (second run)"). nil when
    /// the part was started anywhere else, and cleared when the playback ends.
    private(set) var playingRowStart: Leyline_V1_SampleTime?
    @ObservationIgnored private var playbackSeen = false
    @ObservationIgnored private var playbackStartedAt = Date.distantPast
    /// Whether the live channel's sink was attached when the clip started, so it is attached
    /// again when the clip ends and the clip is heard alone meanwhile.
    @ObservationIgnored private var reattachAfterPlayback = false
    /// Set by Stop listening: the window adopts nothing until a band or a frequency is picked,
    /// or the next snapshot would put a capture back.
    private var listeningStopped = false

    private static let lastBandKey = "lastBand"
    /// The capture rate the window opens a radio at: the plan's default, 2.4 MSPS, until the
    /// device menu's picker sets another, which is remembered. The radio's setting, not the
    /// band's: a band change never moves it (the owner, 2026-09-21), the way the width does.
    static let defaultSampleRate: UInt64 = 2_400_000
    private static let sampleRateKey = "sampleRate"
    /// A one-stage radio keeps the app's established fixed first-use gain. Multi-stage radios keep
    /// their driver's stage-specific defaults until the person moves a control; applying one
    /// generic number to every stage can leave a working radio insensitive or overloaded.
    static let defaultGainDB: Double = 28
    private static let legacyGainKey = "gain"

    /// Remembered writes for this physical/virtual radio and each of its stages. The old global
    /// preference migrates only for one-stage radios; feeding an RTL tuner value into a HackRF LNA
    /// was the coupling this per-stage store is meant to remove.
    private func preferredGains(for dev: Leyline_V1_DeviceDescriptor) -> [Leyline_V1_GainWrite] {
        dev.gainElements.compactMap { el in
            let defaults = UserDefaults.standard
            let key = GainPreferences.storageKey(deviceID: dev.deviceID, element: el.name)
            let stored =
                defaults.string(forKey: key)
                ?? (dev.gainElements.count == 1 ? defaults.string(forKey: Self.legacyGainKey) : nil)
            return GainPreferences.write(
                element: el, storedValue: stored,
                defaultDB: dev.gainElements.count == 1 ? Self.defaultGainDB : nil)
        }
    }

    /// The remembered rate, snapped to what this radio offers (the nearest, so a radio without
    /// the exact number gets its closest rather than a refusal).
    private func preferredSampleRate(for dev: Leyline_V1_DeviceDescriptor) -> UInt64 {
        let stored = UInt64(UserDefaults.standard.integer(forKey: Self.sampleRateKey))
        let want = stored > 0 ? stored : Self.defaultSampleRate
        guard !dev.sampleRates.isEmpty else { return want }
        return dev.sampleRates.min {
            abs(Int64($0) - Int64(want)) < abs(Int64($1) - Int64(want))
        } ?? want
    }
    private static let inspectorShownKey = "inspectorShown"
    private static let placeKey = "place"

    // MARK: Derived

    var capture: Leyline_V1_Capture? { captureID.flatMap { state.capture($0) } ?? pendingCapture }
    var channel: Leyline_V1_Channel? { channelID.flatMap { state.channel($0) } ?? pendingChannel }
    var device: Leyline_V1_DeviceDescriptor? { capture.flatMap { state.device($0.deviceID) } }
    var sink: Leyline_V1_Sink? {
        guard let channelID else { return nil }
        return state.sinks(of: channelID).first {
            if case .systemAudio? = $0.kind { true } else { false }
        }
    }
    var tunedHz: UInt64? { channel.flatMap { state.frequencyHz(of: $0) } }
    /// The frequency to show: the one asked for while it is in flight, else the daemon's.
    /// While a sweep borrows the radio there is no channel, and the field keeps showing the
    /// frequency the window paused on rather than going blank (R18).
    var displayHz: UInt64? { requestedHz ?? tunedHz ?? (sweeping ? sweep?.paused?.hz : nil) }
    /// The transport bar's speaker: muted is no sink on the channel (the daemon has no mute), and
    /// the channel, its squelch and the meter carry on.
    var isMuted: Bool { sink == nil }
    var meter: Leyline_V1_Meter? { telemetry.meter }
    /// The inspector's reading, steadied (`ChannelReading`): folded from every meter in
    /// `foldReading`. Presentation only; the raw meter is `meter`.
    private var reading = ChannelReading()
    /// The steadied reading for the tuned channel, or nil before its first meter: a reading
    /// left from the last channel is not shown for this one.
    var channelReading: ChannelReading? {
        guard let id = channel?.channelID, reading.channelID == id else { return nil }
        return reading
    }
    /// The tuned channel's recent transmissions and the open one, or nil without a channel.
    var transmissions: TransmissionLog? { telemetry.transmissions }
    /// How long the open transmission has run, at the newest telemetry time; nil when idle.
    var timeOnAirSeconds: Double? {
        guard let now = telemetry.newestTime else { return nil }
        return transmissions?.timeOnAir(at: now)
    }
    /// The bookmark on the tuned frequency, the first by name when there are several: the name
    /// the inspector leads with, and what its pencil renames.
    var tunedBookmark: Bookmark? {
        guard let hz = tunedHz else { return nil }
        return bookmarks.list.first { $0.hz == hz }
    }
    var isLive: Bool { if case .live = connection { true } else { false } }

    /// The waterfall's cold end: the squelch, as a level per bin, so raising the squelch darkens
    /// the noise and only signals above the squelch are coloured, the way desktop SDRs tie the
    /// waterfall minimum to the floor. The squelch is a channel power over the channel's width;
    /// per bin it is `squelch − 10·log10(bandwidth / bin width)`, the auto squelch's own scaling
    /// in reverse.
    /// With the squelch off, or before a floor is known, the feed's floor plus its headroom.
    var rampFloorDB: Float {
        squelchPerBinDB ?? spectrum.rampFloorDB
    }

    /// How far below the cold end the waterfall fades to the background, when the cold end is
    /// the squelch: anything below the squelch goes dark rather than sitting at the ramp's first
    /// stop. Zero with the squelch off, where the cold end is a headroom over the noise and the
    /// noise stays a faint teal.
    static let squelchFadeDB: Float = 6
    var rampFadeDB: Float { squelchPerBinDB == nil ? 0 : Self.squelchFadeDB }

    /// How far the ramp reaches above its cold end: six stops over 40 dB, fixed, so a row keeps
    /// its colour while it scrolls and only a squelch change recolours the waterfall. A hot end
    /// that followed the loudest level on the band recoloured every row on screen whenever
    /// something anywhere in the capture, on screen or not, keyed up or went quiet.
    static let rampRangeDB: Float = 40

    /// The band's floor at the channel's width, the auto squelch's scaling of the feed's held
    /// floor. Nil until the floor is known.
    var channelFloorDB: Double? {
        guard let cap = capture, let ch = channel else { return nil }
        let floor = SpectrumFold.channelFloorDB(
            binFloorDB: Double(spectrum.floorDB), bins: Int(SpectrumFeed.bins),
            sampleRate: cap.sampleRate, bandwidthHz: ch.bandwidthHz)
        return floor.isFinite ? floor : nil
    }

    /// The channel's power over `channelFloorDB`. The meter's own `snr_db` was power over the
    /// channel's running minimum, which on a carrier that never stops is the carrier itself and
    /// read 0 (`docs/plans/app.md`, APP-3); the daemon now measures the same floor, and the
    /// window still uses this value. Nil until the floor is known.
    var overNoiseDB: Double? {
        guard let m = meter, m.powerDbfs.isFinite, let floor = channelFloorDB else { return nil }
        return m.powerDbfs - floor
    }

    /// Folds one meter into `reading` with the floor and channel it was measured against.
    private func foldReading(_ m: Leyline_V1_Meter, atSeconds seconds: Double) {
        guard let ch = channel else { return }
        reading.fold(
            m, atSeconds: seconds, channelID: ch.channelID, floorDB: channelFloorDB,
            mode: ch.mode, bandwidthHz: ch.bandwidthHz)
    }

    /// The squelch threshold on the signal bar's scale, dB over the channel's floor; NaN with
    /// the squelch off or before the floor is known.
    var squelchOverNoiseDB: Double {
        ChannelReading.squelchOverNoiseDB(
            squelchDB: channel?.squelchDb ?? .nan, floorDB: channelFloorDB)
    }

    /// The wall clock of a time on the tuned capture, through its anchor and nothing else
    /// (invariant 5): nil until the anchor is dated, and the inspector then shows elapsed time
    /// instead of a guessed wall-clock time.
    func wallTime(of time: Leyline_V1_SampleTime) -> Date? {
        guard let cap = capture else { return nil }
        return SampleClock.wallTime(of: time, anchor: cap.anchor)
    }

    /// Seconds between a time on the tuned capture and the newest telemetry time, or nil when
    /// the two are not on one timeline.
    func secondsAgo(_ time: Leyline_V1_SampleTime) -> Double? {
        guard let now = telemetry.newestTime, let cap = capture, cap.sampleRate > 0,
            now.captureID == time.captureID, now.captureID == cap.captureID,
            now.sampleIndex >= time.sampleIndex
        else { return nil }
        return Double(now.sampleIndex - time.sampleIndex) / Double(cap.sampleRate)
    }

    /// The squelch as a level per bin, or nil when it is off or there is no floor to bound it.
    private var squelchPerBinDB: Float? {
        let feed = spectrum
        guard let ch = channel, ch.squelchDb.isFinite, let cap = capture, cap.sampleRate > 0,
            ch.bandwidthHz > 0, !feed.floorDB.isNaN
        else {
            return nil
        }
        let binWidth = Double(cap.sampleRate) / Double(SpectrumFeed.bins)
        let perBin = Float(ch.squelchDb - 10 * log10(Double(ch.bandwidthHz) / binWidth))
        return max(perBin, feed.floorDB - 10)
    }

    /// The radio whose tuning range applies: the capture's device, else the first connected one.
    private var radioRanges: [Leyline_V1_FrequencyRange] {
        (device ?? state.devices.first { $0.state != .disconnected })?.tuningRanges ?? []
    }

    /// The bands this radio can reach; without a radio, all of them.
    var tunableBands: [Band] { bands.filter { Bands.tunable($0, ranges: radioRanges) } }

    /// Why a band is out of this radio's reach, to follow its name, or nil.
    func outOfRangeWords(_ band: Band) -> String? {
        Bands.outOfRangeWords(band, ranges: radioRanges)
    }

    /// The sidebar rows this radio cannot tune, folded to one line; nil when it tunes them all.
    var outOfRange: OutOfRangeFold? { OutOfRangeFold(rows: sidebarRows, ranges: radioRanges) }

    /// The filter's match and order over the whole table, the bookmarks and the radio's reach
    /// (`SidebarIndex`); built on each read, which is one pass over a few hundred entries.
    var sidebarIndex: SidebarIndex {
        SidebarIndex(bookmarks: bookmarks.list, tunedHz: tunedHz, ranges: radioRanges)
    }

    /// The sidebar row the highlighted band files under: its group when it is a part, so the
    /// `GMRS` row is the tuned one while the capture sits on either half.
    var tunedRow: Band? { band.map { Bands.group(of: $0) ?? $0 } }

    /// Whether a sidebar row shows its contents: the tuned row always, and the one opened by
    /// its chevron.
    func isExpanded(_ row: Band) -> Bool {
        row.id == tunedRow?.id || row.id == expandedBandID
    }

    /// The chevron: opens or closes a row without tuning. The tuned row stays open.
    func toggleExpanded(_ row: Band) {
        guard row.id != tunedRow?.id else { return }
        expandedBandID = expandedBandID == row.id ? nil : row.id
    }

    /// What a tune into `row` closes: a row opened by its chevron elsewhere, the out-of-range
    /// line's rows, and the last sweep's hits when they belong to another row (R19). The only
    /// tune while `sweeping` holds is the resume after the sweep, which is nobody's tune
    /// elsewhere: it closes nothing, so a row opened by its chevron and swept keeps showing its
    /// hits when the radio goes back to the band it was on.
    private func closeOpenedRows(tuning row: Band?) {
        guard !sweeping else { return }
        if let id = expandedBandID, id != row?.id { expandedBandID = nil }
        outOfRangeExpanded = false
        if let s = sweep, s.row.id != row?.id {
            log("sweep", "hits of \(s.row.name) dropped: tuned elsewhere")
            sweep = nil
        }
    }

    /// The picker's rows: the open row's plan, narrowed by `pickerQuery`.
    var pickerRows: [PlanChannel] {
        guard let band = pickerBand else { return [] }
        let plan = band.plan()
        let key = pickerQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return plan }
        return plan.filter { channel in
            channel.name.lowercased().hasPrefix(key)
                || channel.aliases.contains { $0.lowercased().hasPrefix(key) }
        }
    }

    /// The band the sidebar highlights: the chosen one, else the one the tuned frequency lies in.
    /// Selection reflects state rather than causing it (the M1 handoff, "Decided 2026-09-21"):
    /// the band is the one the tuned frequency is in, and the clicked one only breaks a tie
    /// between overlapping bands or stands in before anything is tuned.
    var band: Band? {
        let clicked = selectedBandID.flatMap { id in bands.first { $0.id == id } }
        guard let hz = tunedHz else { return clicked }
        if let c = clicked, c.contains(hz) { return c }
        return Bands.band(containing: hz, in: bands)
    }

    /// Whether the tuned bookmark's saved settings and the channel's disagree: the mode, or the
    /// width when the bookmark names one. The row and the identity say "changed", and a click
    /// on the bookmark puts its settings back.
    var bookmarkModified: Bool {
        guard let b = tunedBookmark, let ch = channel, b.mode != .unspecified else { return false }
        if b.mode != ch.mode { return true }
        return b.bandwidthHz != 0 && b.bandwidthHz != ch.bandwidthHz
    }

    /// The bookmark whose row is an editor right now, after `＋` or Rename.
    var editingBookmarkID: String?
    /// Set by `tune(bookmark:)` for the tune it starts, so the band-follow rule does not write
    /// the band's mode over the bookmark's: one write, the bookmark's.
    private var tuningBookmark = false

    // Find active (docs/design/channels.md, "Find active"; the plan's KTD5). The job is the
    // mirror's; what is here is which job the row started, what the window was listening to
    // when it paused for it, and the outcome the row shows once the job has ended.
    /// The sweep the band row started, or nil. Kept after the job ends, with its outcome, until
    /// the next sweep or the next tune into another row (R19), because the row shows the hits,
    /// the empty line or the failure from it; a cancelled sweep is dropped at once.
    private(set) var sweep: SweepState?
    /// The action asked for while a sweep ran (a tune, or another row's Find active), run once
    /// the job's terminal event has put the radio back. The latest one wins.
    @ObservationIgnored private var afterSweep: (@MainActor () -> Void)?

    /// Between Find active and the channel and sink being back: no capture write leaves the
    /// window meanwhile, because the daemon refuses every one with `DEVICE_SWEEPING`.
    var sweeping: Bool { sweep.map { !$0.restored } ?? false }
    /// The row the last sweep was of, whose expanded row shows the outcome.
    var sweepRow: Band? { sweep?.row }
    /// The last sweep's detections, strongest first: the rail's hit ticks.
    var sweepHits: [SweepHit] {
        if case .found(let result)? = sweep?.outcome { return result.hits }
        return []
    }

    /// One sweep from the row's click to the radio being back.
    struct SweepState {
        /// What the window played before it paused, to put back on the terminal event.
        struct Paused {
            let hz: UInt64
            /// The bookmark tuned, whose saved settings come back with it.
            let bookmark: Bookmark?
            /// The part the frequency lies in, else the band the sidebar highlighted.
            let band: Band?
        }

        /// Empty until `StartJob` answers, which is milliseconds; a stop asked in that gap is
        /// sent as soon as the id is known (`stopAsked`).
        var jobID = ""
        let row: Band
        let startedAt = Date()
        var outcome: SweepOutcome?
        /// Nil when the window had no capture (after Stop listening): the daemon opened its own
        /// radio and the swept row is selected afterwards.
        let paused: Paused?
        var stopAsked = false
        /// The terminal event was seen and the scan is being read; the mirror's next change
        /// must not start a second read.
        var ending = false
        /// The channel and sink are back, or the sweep was cancelled: the window is listening
        /// again and the row shows the outcome.
        var restored = false
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

    /// The empty-state message, worded as in the guide, shown when there is nothing to draw.
    var emptyWords: (headline: String, detail: String)? {
        if let e = startupError { return ("Could not dial the daemon", e.message) }
        switch connection {
        case .idle, .connecting: return ("Connecting to leylined", socketPath)
        case .unavailable(let e, let retry):
            return e.daemonUnreachable
                ? (
                    "The daemon is not running",
                    "Start it with `ley daemon start`; retrying in \(retry)."
                )
                : (e.message, "Retrying in \(retry).")
        case .live: break
        }
        if state.devices.allSatisfy({ $0.state == .disconnected }) {
            return (
                "No radio is plugged in",
                "Plug in an RTL-SDR or HackRF, or attach a recording with `ley devices attach`."
            )
        }
        if capture == nil {
            return (
                "Pick a band to listen",
                "The sidebar's bands set the radio, the mode and the squelch at once."
            )
        }
        if capture?.state == .captureDetached {
            return (
                "The radio was unplugged", "Plug it back in and the capture rebinds on its own."
            )
        }
        return nil
    }

    // MARK: Lifecycle

    func start() async {
        guard running == nil else { return }
        captureLevel.onLevel = { [weak self] in
            self?.markClippedRows()
            self?.nameFailure()
        }
        audioLevels.onEnded = { [weak self] in self?.followAudioLevels() }
        telemetry.onMeter = { [weak self] m, seconds in
            self?.foldReading(m, atSeconds: seconds)
            self?.audioLevels.meterChanged(m)
        }
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
            logShownWords()
        }
    }

    /// An id the mirror never carried is dropped after this long: the gap between an RPC's
    /// response and its event closes in milliseconds, so an object still missing this long
    /// after the window took it has no event coming.
    static let neverSeenDropSeconds: TimeInterval = 3

    private func mirrorChanged(_ m: DaemonMirror) {
        let wasLive = isLive
        state = m.state
        connection = m.connection
        if wasLive != isLive {
            log(
                "session",
                isLive
                    ? "live: leylined \(state.daemon.version), \(state.devices.count) devices, \(state.captures.count) captures"
                    : "not live: \(connection)")
            // Once on adoption: the store as it is, and the manifests read afresh.
            if isLive {
                staleManifests.formUnion(manifests.keys)
                reloadRecordings()
            }
        }
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
            } else if Date().timeIntervalSince(captureSetAt) > Self.neverSeenDropSeconds {
                log(
                    "session",
                    "the mirror has no capture \(id) 3 s after the window took it; a new one will be made"
                )
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
            } else if Date().timeIntervalSince(channelSetAt) > Self.neverSeenDropSeconds {
                log("session", "the mirror has no channel \(id) 3 s after the window took it")
                dropChannel()
            }
        }
        if case .live = connection {
            // A sweep with no capture opens the daemon's own; adopting it would put a channel
            // on a radio being swept.
            if !adopted, !listeningStopped, !sweeping { adopt() }
        } else {
            adopted = false
            captureSeen = false
            channelSeen = false
        }
        spectrum.follow(capture, connection: daemon)
        telemetry.follow(
            channelID, offsetHz: channel?.offsetHz, centerHz: capture?.centerHz,
            mode: channel?.mode, captureRate: capture?.sampleRate ?? 0, connection: daemon)
        captureLevel.follow(capture?.captureID, connection: daemon)
        followAudioLevels()
        nameFailure()
        holdOutOfCapture()
        followRecordJobs()
        followScanJob()
        followPlayback()
        logShownWords()
        // The mirror keeps this client's rejections; a new one is the last thing that went wrong.
        if state.rejections.count != rejectionsSeen {
            rejectionsSeen = state.rejections.count
            if let r = state.rejections.last {
                lastError = LeylineError(
                    code: r.error.code, message: r.error.message, target: r.error.target)
                log("session", "write \(r.tag) rejected: \(r.error.code) \(r.error.message)")
            }
        }
    }

    /// Forgets the capture, and the channel with it: a channel cannot exist without its capture.
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
        if captureID == nil,
            let cap = state.captures.first(where: { $0.state == .captureActive })
                ?? state.captures.first
        {
            captureID = cap.captureID
            captureSetAt = Date()
            if channelID == nil, let ch = state.channels(in: cap.captureID).first {
                channelID = ch.channelID
                channelSetAt = Date()
            }
            log(
                "session",
                "adopted capture \(cap.captureID) at \(cap.centerHz) Hz, \(cap.sampleRate) S/s, channel \(channelID ?? "none")"
            )
            if channelID == nil, state.channels(in: cap.captureID).isEmpty {
                Task { await tuneCreating(hz: cap.centerHz) }
            }
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

    /// The band's centre and rate on the radio, its mode and width on the channel, a sink for
    /// audio, and a squelch measured from the floor. Creates what does not exist and writes
    /// what does (docs/design/app-design-handoff.md, Region 1). With `hz`, the band arrives
    /// tuned there rather than at its centre, and the capture sits where that frequency is
    /// inside it: a drag past the rail's end cap lands on the neighbour's near edge. A switch
    /// that would move the capture off a running recording asks first (`retuneQuestion`).
    func select(band: Band, at hz: UInt64? = nil) async {
        let waited = waitForSweep("select band \(band.name)") {
            Task { await self.select(band: band, at: hz) }
        }
        if waited { return }
        if let words = bandMoveWords(band, at: hz) {
            ask(words, before: "band \(band.name)") {
                Task { await self.moveToBand(band, at: hz) }
            }
            return
        }
        await moveToBand(band, at: hz)
    }

    /// A click on a sidebar row: the band tunes as it always has. A group row tunes through the
    /// part that holds the tuned frequency, else its first part, because `select(band:at:)`
    /// takes a part and never a group (R11, the plan's KTD4).
    func tune(row: Band) {
        if waitForSweep("tune row \(row.name)", { self.tune(row: row) }) { return }
        let part = part(of: row, near: tunedHz)
        Task { await select(band: part) }
    }

    /// The part of a group row that holds `hz`, else its first part in the group's order; a
    /// plain band is its own part.
    private func part(of row: Band, near hz: UInt64?) -> Band {
        guard row.isGroup else { return row }
        let parts = row.parts.compactMap { id in bands.first { $0.id == id } }
        if let hz, let part = parts.first(where: { $0.contains(hz) }) { return part }
        return parts.first ?? row
    }

    /// The plan picker's pick, and a channel row in the filter: the part that holds the channel
    /// arrives tuned there, and the channel's own mode and width follow where the plan sets them
    /// (MURS 4 and 5 are 20 kHz where the group is 11.25 kHz), the way a bookmark's do.
    func pick(channel: PlanChannel, in row: Band) {
        pickerBand = nil
        if waitForSweep("pick \(channel.name)", { self.pick(channel: channel, in: row) }) {
            return
        }
        let part = part(of: row, near: channel.hz)
        log("tune", "channel \(channel.name) of \(row.name) at \(channel.hz) Hz")
        Task {
            await select(band: part, at: channel.hz)
            let mode = part.mode(of: channel)
            let bw = part.bandwidth(of: channel)
            guard let ch = self.channel, tunedHz == channel.hz || requestedHz == channel.hz,
                ch.mode != mode || ch.bandwidthHz != bw
            else { return }
            await apply(mode: mode, bandwidthHz: bw, to: ch)
        }
    }

    /// Up and Down in the picker: the highlight moves one row and stops at the ends.
    func movePickerHighlight(_ delta: Int) {
        let count = pickerRows.count
        guard count > 0 else { return }
        pickerHighlight = min(max(pickerHighlight + delta, 0), count - 1)
    }

    /// Return in the picker: the highlighted row is picked.
    func pickHighlighted() {
        let rows = pickerRows
        guard let band = pickerBand, rows.indices.contains(pickerHighlight) else { return }
        pick(channel: rows[pickerHighlight], in: band)
    }

    /// A filter row: a band as a click on its row would, a bookmark as its row would, a plan
    /// channel as the picker would. A disabled row does nothing.
    func tune(match: SidebarMatch) {
        guard !match.disabled else { return }
        switch match.kind {
        case .band(let row): tune(row: row)
        case .bookmark(let bookmark, _): tune(bookmark: bookmark)
        case .channel(let channel, let row): pick(channel: channel, in: row)
        }
    }

    /// Return in the filter field: the first row the radio can tune (`SidebarIndex.firstTarget`),
    /// and the field is cleared and let go so the sidebar shows the tuned row open.
    func tuneFirstMatch() {
        guard let match = sidebarIndex.firstTarget(filterQuery) else { return }
        tune(match: match)
        clearFilter()
    }

    /// Escape in the filter field: the query goes and the field drops its focus.
    func clearFilter() {
        filterQuery = ""
        filterFocused = false
    }

    /// `Go to…` (⌘G): the Radio's filter field takes focus. A name goes here; the frequency
    /// field is a digit editor and stays one.
    func goTo() {
        place = .radio
        filterFocused = true
    }

    /// The question before `select(band:at:)` moves the capture: nil when the band change makes
    /// a new capture (no radio open, another radio) or leaves every recording inside the span.
    /// The centre is the one `moveToBand` computes.
    private func bandMoveWords(_ band: Band, at hz: UInt64?) -> String? {
        guard !busy, !sweeping, outOfRangeWords(band) == nil, let cap = capture,
            let dev = try? pickDevice(), dev.deviceID == cap.deviceID
        else { return nil }
        let centre =
            hz.map { captureCentre(for: band, at: $0, rate: cap.sampleRate) } ?? band.centerHz
        return leftOutWords(centre: Int64(centre), rate: cap.sampleRate)
    }

    private func moveToBand(_ band: Band, at hz: UInt64?) async {
        guard !busy, daemon != nil else { return }
        if let why = outOfRangeWords(band) {
            notice = "\(band.name) is \(why)"
            log("session", "select band \(band.name) refused: \(why)")
            return
        }
        busy = true
        defer { busy = false }
        listeningStopped = false
        selectedBandID = band.id
        closeOpenedRows(tuning: Bands.group(of: band) ?? band)
        UserDefaults.standard.set(band.id, forKey: Self.lastBandKey)
        lastError = nil
        log("session", "select band \(band.name)\(hz.map { " at \($0) Hz" } ?? "")")
        do {
            let dev = try pickDevice()
            // The capture's rate is the radio's setting: an existing capture keeps its own, a
            // new one opens at the remembered rate. The band only decides where the span sits.
            let existing = capture.flatMap { $0.deviceID == dev.deviceID ? $0 : nil }
            let rate = existing?.sampleRate ?? preferredSampleRate(for: dev)
            let target = hz ?? band.centerHz
            let centre =
                hz == nil ? band.centerHz : captureCentre(for: band, at: target, rate: rate)
            let cap = try await ensureCapture(on: dev, centerHz: centre, sampleRate: rate)
            let mode = band.mode(at: target)
            if hz != nil { request(target) }
            let ch = try await ensureChannel(
                in: cap, offsetHz: Int64(target) - Int64(centre), mode: mode,
                bandwidthHz: band.bandwidthHz)
            try await ensureSink(on: ch)
            spectrum.resetFolds()
            if band.widthHz > rate {
                notice =
                    "\(band.name) is \(Frequency.format(band.widthHz)) wide and the capture is \(Frequency.format(rate)); showing that much, centred on \(Frequency.format(centre))"
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
        if let d = state.devices.first(where: { $0.state == .available })
            ?? state.devices.first(where: { $0.state == .inUse })
        {
            return d
        }
        throw LeylineError(code: "DEVICE_NOT_FOUND", message: "No radio is plugged in")
    }

    private func ensureCapture(
        on dev: Leyline_V1_DeviceDescriptor, centerHz: UInt64, sampleRate: UInt64
    ) async throws -> Leyline_V1_Capture {
        guard let daemon, let writes else { throw LeylineError.notDialled }
        if var cap = capture, cap.deviceID == dev.deviceID {
            // The rate is not written here: it is the radio's setting and only the device
            // menu's picker moves it. A band change moves the centre alone.
            if cap.centerHz != centerHz { await writes.centerHz(centerHz, capture: cap.captureID) }
            cap.centerHz = centerHz
            return cap
        }
        var req = Leyline_V1_CreateCaptureRequest()
        req.deviceID = dev.deviceID
        req.centerHz = centerHz
        req.sampleRate = sampleRate
        let cap: Leyline_V1_Capture
        do { cap = try await daemon.control.createCapture(req) } catch { throw LeylineError(error) }
        log(
            "session",
            "created capture \(cap.captureID) on \(dev.model) at \(centerHz) Hz, \(sampleRate) S/s")
        // Restore only values previously written for this device/stage. A new multi-stage radio
        // keeps the driver's defaults.
        for g in preferredGains(for: dev) {
            log(
                "gain",
                "\(g.element) \(g.auto ? "auto" : String(format: "%.1f dB", g.db)), remembered for this radio"
            )
            await writes.gain(g, capture: cap.captureID)
        }
        captureID = cap.captureID
        captureSeen = false
        captureSetAt = Date()
        pendingCapture = cap
        dropChannel()
        return cap
    }

    private func ensureChannel(
        in cap: Leyline_V1_Capture, offsetHz: Int64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32
    ) async throws -> Leyline_V1_Channel {
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
        log(
            "session",
            "created channel \(ch.channelID): \(mode.word) \(bandwidthHz) Hz at offset \(offsetHz)")
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
    private func measureSquelch(
        channel ch: Leyline_V1_Channel, sampleRate: UInt64, bandwidthHz: UInt32
    ) async {
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
            log(
                "session",
                "no two rows of capture \(ch.captureID) within 3 s; squelch left off, so no station is muted by another band's floor"
            )
            return
        }
        let (threshold, floor) = SpectrumFold.autoSquelch(
            spectrum.latest, sampleRate: sampleRate, bandwidthHz: bandwidthHz)
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

    /// `146.520 MHz · −52 dBFS · 26 dB over the floor`, the level being the pointer column's
    /// (`levelDB`) against the held floor, dashes before one is held. During a drag the swept
    /// figure takes the level clause's place, so the badge stays one line.
    func pointerWords(_ hz: UInt64, levelDB: Float) -> String {
        let f = Frequency.fieldParts(hz)
        if let start = sweepFromHz, start != hz {
            let sweep = start > hz ? start - hz : hz - start
            return "\(f.major) MHz · \(Frequency.format(sweep)) swept"
        }
        let level = SpectrumFold.levelWords(levelDB: levelDB, floorDB: spectrum.floorDB)
        return "\(f.major) MHz · \(level)"
    }

    /// Every gesture ends here. Inside the capture it is one `offset_hz` write. Outside it the
    /// centre moves first and the offset follows once the capture's event confirms the move:
    /// the two in one tick land in the daemon's order, and an offset applied against the old
    /// centre tunes a frequency nobody asked for, which then moves again. A click, a step or a
    /// typed frequency puts the target an eighth of the span in from the edge it arrived
    /// through. A drag held past the edge pans the capture an eighth of the span at a time, no
    /// faster than every 300 ms, so the display pans at a followable rate rather than a span
    /// per event.
    func tune(to hz: UInt64, dragging: Bool = false) {
        // A drag's frames all wait as one click: the last frame is where the drag was going.
        if waitForSweep("tune to \(hz) Hz", { self.tune(to: hz) }) { return }
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
    /// A drag that would take the span off a running recording's frequency moves the pill and
    /// not the radio, and its release asks first (`retuneQuestion`); Move anyway performs the
    /// release's move (`askedFirst`), Cancel puts the pill back where the radio is.
    func pan(centreTo centre: Int64, ended: Bool, askedFirst: Bool = false) {
        guard let cap = capture, let ch = channel, let writes else { return }
        guard panCentre != nil || centreInFlight == nil else { return }
        let span = Int64(cap.sampleRate)
        var newCentre = clampCentre(centre, span: span)
        if let b = band {
            newCentre =
                b.widthHz > cap.sampleRate
                ? min(max(newCentre, Int64(b.minHz) + span / 2), Int64(b.maxHz) - span / 2)
                : Int64(cap.centerHz)
        }
        if !askedFirst, let words = leftOutWords(centre: newCentre, rate: cap.sampleRate) {
            panCentre = newCentre
            guard ended else { return }
            ask(words, before: "pan to \(newCentre) Hz") {
                self.pan(centreTo: centre, ended: true, askedFirst: true)
            } cancel: {
                self.panCentre = nil
                self.releaseCentreInFlight()
            }
            return
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
            log(
                "tune",
                "pan capture \(cap.centerHz) -> \(newCentre) Hz, station at \(held) Hz\(held != station ? ", pushed from \(station)" : "")"
            )
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

    /// After a cancelled pan: the centre the drag last wrote, if one, is still in flight, and is
    /// released once the capture's event carries it, as the release of a drag releases it.
    private func releaseCentreInFlight() {
        guard let written = centreInFlight else { return }
        let want = UInt64(max(0, written))
        Task {
            await confirmed { self.capture?.centerHz == want }
            if panCentre == nil, centreInFlight == written { centreInFlight = nil }
        }
    }

    /// A drag held past the capture's edge pans at most this often, so the display pans at a
    /// followable rate rather than a span per event.
    static let panRateLimitSeconds: TimeInterval = 0.3
    /// Where a click, a step or a typed frequency lands when the capture must re-centre: this
    /// many eighths of the span in from the edge it arrived through, so the new tuning is not
    /// pinned to the very edge.
    static let edgeInsetEighths: Int64 = 3

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
                if Date().timeIntervalSince(lastPan) > Self.panRateLimitSeconds,
                    centreInFlight == nil
                {
                    lastPan = Date()
                    let newCentre = clampCentre(
                        target < lo ? centre - span / 8 : centre + span / 8, span: span)
                    request(UInt64(max(0, target)))
                    log("tune", "pan \(centre) -> \(newCentre) Hz under a drag at \(target) Hz")
                    Task {
                        await retune(
                            centre: newCentre, offset: target - newCentre, capture: cap.captureID,
                            channel: ch.channelID)
                    }
                    followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
                    return
                }
            } else {
                let newCentre = clampCentre(
                    target < lo
                        ? target + span * Self.edgeInsetEighths / 8
                        : target - span * Self.edgeInsetEighths / 8, span: span)
                request(UInt64(max(0, target)))
                // One move at a time: while one is in flight the new one waits in the slot and
                // `retune` performs it next, because two of them leave the coalescer holding
                // only the last centre and the first offset written against a centre that
                // never applied.
                if centreInFlight != nil {
                    if let waiting = nextRetune {
                        log("tune", "centre \(waiting.centre) Hz superseded before it ran")
                    }
                    log(
                        "tune",
                        "centre \(newCentre) Hz for \(target) Hz waits on the move in flight")
                    nextRetune = (
                        centre: newCentre, offset: target - newCentre, capture: cap.captureID,
                        channel: ch.channelID
                    )
                } else {
                    log("tune", "centre \(centre) -> \(newCentre) Hz for \(target) Hz")
                    Task {
                        await retune(
                            centre: newCentre, offset: target - newCentre, capture: cap.captureID,
                            channel: ch.channelID)
                    }
                }
                followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
                return
            }
        }
        let offset = target - centre
        request(UInt64(max(0, target)))
        Task { await writes.offsetHz(offset, channel: ch.channelID) }
        if !quiet {
            log(
                "tune",
                "\(target) Hz (offset \(offset))\(hz != UInt64(max(0, target)) ? ", asked \(hz)" : "")"
            )
        }
        followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
    }

    /// A centre inside the radio's tuning range, with half a span to spare on each side.
    private func clampCentre(_ centre: Int64, span: Int64) -> Int64 {
        guard
            let r = device?.tuningRanges.first(where: {
                Int64($0.minHz) - span / 2 <= centre && centre <= Int64($0.maxHz) + span / 2
            })
                ?? device?.tuningRanges.first
        else { return max(0, centre) }
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
            if self.capture?.centerHz != want {
                log(
                    "tune",
                    "centre \(move.centre) not confirmed; capture is at \(self.capture?.centerHz ?? 0)"
                )
            }
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
        let bw =
            Bands.band(containing: hz, in: bands).map {
                $0.mode(at: hz) == mode ? $0.bandwidthHz : mode.defaultBandwidthHz
            } ?? mode.defaultBandwidthHz
        let span = Int64(cap.sampleRate)
        var centre = Int64(cap.centerHz)
        let target = Int64(hz)
        if target < centre - span / 2 + Int64(bw) || target > centre + span / 2 - Int64(bw) {
            centre = clampCentre(
                target < centre
                    ? target + span * Self.edgeInsetEighths / 8
                    : target - span * Self.edgeInsetEighths / 8, span: span)
            log(
                "tune",
                "centre \(cap.centerHz) -> \(centre) Hz for \(target) Hz, before the first channel")
            centreInFlight = centre
            await writes.centerHz(UInt64(max(0, centre)), capture: cap.captureID)
            await confirmed { self.capture?.centerHz == UInt64(max(0, centre)) }
            centreInFlight = nil
        }
        request(hz)
        do {
            let ch = try await ensureChannel(
                in: cap, offsetHz: target - centre, mode: mode, bandwidthHz: bw)
            try await ensureSink(on: ch)
            await measureSquelch(channel: ch, sampleRate: cap.sampleRate, bandwidthHz: bw)
        } catch {
            lastError = LeylineError(error)
            log("tune", "could not make a channel at \(hz) Hz: \(LeylineError(error))")
        }
    }

    /// Crossing into another band takes that band's mode and width, so the user does not have to
    /// pick a demodulator per band; inside one band the channel keeps whatever was chosen.
    private func followBand(from oldHz: UInt64?, to hz: UInt64, channel ch: Leyline_V1_Channel) {
        let was = oldHz.flatMap { Bands.band(containing: $0, in: bands) }
        let now = Bands.band(containing: hz, in: bands)
        if let b = band, !b.contains(hz) { selectedBandID = nil }
        closeOpenedRows(tuning: Bands.sidebarRow(for: hz))
        if tuningBookmark {
            // The bookmark's saved settings win over the band's defaults, and stand down the
            // band's write for this tune.
            tuningBookmark = false
            return
        }
        guard let now, now.id != was?.id else { return }
        let mode = now.mode(at: hz)
        guard ch.mode != mode || ch.bandwidthHz != now.bandwidthHz else { return }
        log(
            "tune", "band \(was?.name ?? "none") -> \(now.name): \(mode.word) \(now.bandwidthHz) Hz"
        )
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
            await confirmed {
                self.channel?.mode == mode && self.channel?.bandwidthHz == bandwidthHz
            }
            if channel?.mode == mode, channel?.bandwidthHz == bandwidthHz {
                log(
                    "tune",
                    "channel \(id) is \(mode.word) \(bandwidthHz) Hz\(attempt == 1 ? " on the second order" : "")"
                )
                return
            }
            log(
                "tune",
                "channel \(id) did not confirm \(mode.word) \(bandwidthHz) Hz (\(first ? "width first" : "mode first")); is \(channel?.mode.word ?? "?") \(channel?.bandwidthHz ?? 0)"
            )
        }
    }

    /// A channel needs room: the capture is widened to the smallest rate the radio offers that
    /// holds the width with a quarter to spare, and the move is confirmed before the channel is
    /// touched. WFM at 200 kHz on a 250 kS/s capture was refused for want of this.
    private func widenCapture(for bandwidthHz: UInt32) async {
        guard let cap = capture, let dev = device, let writes else { return }
        let need = UInt64(bandwidthHz) * 5 / 4
        guard cap.sampleRate < need else { return }
        guard let rate = dev.sampleRates.filter({ $0 >= need }).min() ?? dev.sampleRates.max(),
            rate > cap.sampleRate
        else { return }
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
        let bw =
            mode.offeredBandwidthsHz.contains(ch.bandwidthHz)
            ? ch.bandwidthHz : mode.defaultBandwidthHz
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

    /// Mute detaches the sink and unmute attaches one; the channel and its squelch stay, and so
    /// does the radio (plans/app.md, APP-5: the button is the audio control).
    func toggleMute() async {
        guard let daemon, let ch = channel else { return }
        do {
            if let s = sink {
                var req = Leyline_V1_DetachSinkRequest()
                req.sinkID = s.sinkID
                _ = try await daemon.control.detachSink(req)
                log("session", "muted: sink \(s.sinkID) detached")
            } else {
                try await ensureSink(on: ch)
                log("session", "unmuted: sink attached")
            }
        } catch {
            lastError = LeylineError(error)
        }
    }

    /// `ley stop`'s act (Tune ▸ Stop Listening, ⌘.): the channel removed and the capture this
    /// window made destroyed, so the waterfall shows its empty state and the radio is free. A
    /// capture another client made, or one another channel still rides on (a recording's, say),
    /// is left running: destroying it would silence them. The window adopts nothing afterwards
    /// until a band or a frequency is picked.
    func stopListening() async {
        guard let daemon, let ch = channel else { return }
        let cap = capture
        var req = Leyline_V1_DestroyChannelRequest()
        req.channelID = ch.channelID
        do { _ = try await daemon.control.destroyChannel(req) } catch {
            lastError = LeylineError(error)
            log("session", "stop listening: \(ch.channelID) not removed: \(LeylineError(error))")
            return
        }
        listeningStopped = true
        dropCapture()
        guard let cap else {
            log("session", "stopped; radio free")
            return
        }
        let others = state.channels(in: cap.captureID).filter { $0.channelID != ch.channelID }
        guard cap.createdBy.clientID == daemon.identity.id, others.isEmpty else {
            log(
                "session",
                "stopped; capture \(cap.captureID) left running: \(others.isEmpty ? "another client made it" : "\(others.count) other channels on it")"
            )
            notice =
                others.isEmpty
                ? "Stopped. The radio stays tuned: another client opened it."
                : "Stopped. The radio stays tuned for the other channels on it."
            return
        }
        var destroy = Leyline_V1_DestroyCaptureRequest()
        destroy.captureID = cap.captureID
        do {
            _ = try await daemon.control.destroyCapture(destroy)
            log("session", "stopped; radio free")
        } catch {
            log(
                "session", "stopped; capture \(cap.captureID) not destroyed: \(LeylineError(error))"
            )
        }
    }

    // MARK: Find active

    /// The band row's item (R17, R20): `ley scan --band`'s sweep on the window's own radio,
    /// with the window paused for it. On the row being swept it is Stop; on another row it
    /// stops that sweep and starts this one after its terminal event. A record job riding the
    /// window's capture would hear every hop, so the move alert asks first, Sweep anyway going
    /// ahead.
    func findActive(row: Band) {
        if let s = sweep, sweeping {
            if s.row.id == row.id {
                log("sweep", "stop asked on \(row.name)")
                afterSweep = nil
                cancelSweep()
            } else {
                _ = waitForSweep("find active on \(row.name)") { self.findActive(row: row) }
            }
            return
        }
        if let cap = capture,
            let words = Recordings.retuneWords(
                jobs: Recordings.jobs(riding: cap.captureID, in: state))
        {
            ask(words, before: "find active on \(row.name)", proceedLabel: "Sweep anyway") {
                Task { await self.startSweep(row: row) }
            }
            return
        }
        Task { await startSweep(row: row) }
    }

    /// A hit's row and its rail tick: the frequency tunes as a click on the chart would. With
    /// no capture (Stop listening after the sweep) the band opens the radio there, as a bookmark
    /// click does.
    func tune(hit: SweepHit) {
        log("tune", "hit \(hit.label) at \(hit.hz) Hz")
        if capture == nil, let b = Bands.band(containing: hit.hz, in: bands),
            outOfRangeWords(b) == nil
        {
            Task { await select(band: b, at: hit.hz) }
            return
        }
        tune(to: hit.hz)
    }

    /// `＋` on a hit: a bookmark named as the row names the hit, the plan channel's name else
    /// the frequency (R16, the plan's KTD7), with the band's mode and width there, and its row
    /// opened as an editor as ⌘D opens one. The same name on the same frequency twice updates
    /// the bookmark in place (`BookmarkStore.add`).
    func bookmark(hit: SweepHit) {
        let band = Bands.band(containing: hit.hz, in: bands)
        let mode = band?.mode(at: hit.hz) ?? Bands.defaultMode(at: hit.hz, in: bands)
        let bandwidthHz = band?.bandwidthHz ?? mode.defaultBandwidthHz
        do {
            let b = try bookmarks.add(
                name: hit.label, hz: hit.hz, mode: mode, bandwidthHz: bandwidthHz)
            try bookmarks.save()
            log("bookmark", "added \(hit.label) at \(hit.hz) Hz from a sweep hit")
            editingBookmarkID = b.id
        } catch {
            lastError = bookmarkWriteError(error)
        }
    }

    /// The pause, then the job. With a capture on the radio the job will take, the window
    /// pauses first and the job borrows that capture; with none (after Stop listening) the job
    /// runs on the radio the window would pick and the daemon opens its own. A refusal is a
    /// notice with the daemon's words and the pause is undone at once.
    private func startSweep(row: Band) async {
        guard let daemon, !sweeping else { return }
        let dev: Leyline_V1_DeviceDescriptor
        do {
            dev = try pickDevice()
        } catch {
            lastError = LeylineError(error)
            return
        }
        var paused: SweepState.Paused?
        if let cap = capture, cap.deviceID == dev.deviceID, let ch = channel, let hz = tunedHz {
            paused = SweepState.Paused(
                hz: hz, bookmark: tunedBookmark,
                band: Bands.band(containing: hz, in: bands) ?? band)
            guard await pauseForSweep(channel: ch) else { return }
        }
        sweep = SweepState(row: row, paused: paused)
        var req = Leyline_V1_StartJobRequest()
        req.scan = Sweep.config(for: row, in: Bands.builtIn, deviceID: dev.deviceID)
        do {
            let job = try await daemon.jobs.startJob(req)
            sweep?.jobID = job.jobID
            sweep?.outcome = .running(SweepProgress(statusDetail: job.statusDetail))
            log(
                "sweep",
                "\(job.jobID) started: \(row.name), \(req.scan.range.minHz) to \(req.scan.range.maxHz) Hz on \(dev.model)\(paused.map { ", paused at \($0.hz) Hz" } ?? ", no capture to pause")"
            )
            // A stop asked while `StartJob` was answering goes now that the id is known.
            if sweep?.stopAsked == true {
                sweep?.stopAsked = false
                cancelSweep()
            }
            followScanJob()
        } catch {
            let e = LeylineError(error)
            log("sweep", "refused on \(row.name): \(e.code) \(e.message)")
            notice = "Could not sweep \(row.name): \(e.message.isEmpty ? e.code : e.message)"
            await resumeAfterSweep(paused, row: row)
            sweep = nil
            runAfterSweep()
        }
    }

    /// The window lets go of the radio without releasing it (the plan's KTD5): the sink
    /// detached as Mute detaches it and the channel destroyed as Stop listening destroys it,
    /// the capture kept so the allocator borrows it rather than a second radio. False, with
    /// the error shown, when the channel could not be removed; nothing starts then. A sink
    /// that would not detach is logged and left to go with its channel.
    private func pauseForSweep(channel ch: Leyline_V1_Channel) async -> Bool {
        guard let daemon else { return false }
        if let s = sink {
            var detach = Leyline_V1_DetachSinkRequest()
            detach.sinkID = s.sinkID
            do {
                _ = try await daemon.control.detachSink(detach)
            } catch {
                log("sweep", "sink \(s.sinkID) not detached: \(LeylineError(error))")
            }
        }
        var destroy = Leyline_V1_DestroyChannelRequest()
        destroy.channelID = ch.channelID
        do {
            _ = try await daemon.control.destroyChannel(destroy)
        } catch {
            lastError = LeylineError(error)
            log("sweep", "not started: channel \(ch.channelID) not removed: \(LeylineError(error))")
            return false
        }
        dropChannel()
        log("sweep", "paused: channel \(ch.channelID) removed, capture \(ch.captureID) kept")
        return true
    }

    /// `CancelJob` on the sweep: the job ends CANCELLED and its terminal event puts the radio
    /// back. Asked before `StartJob` has answered, the stop waits for the id (`startSweep`).
    private func cancelSweep() {
        guard let s = sweep, !s.ending, !s.restored else { return }
        if s.jobID.isEmpty {
            sweep?.stopAsked = true
            return
        }
        guard !s.stopAsked, let daemon else { return }
        sweep?.stopAsked = true
        let id = s.jobID
        Task {
            var ref = Leyline_V1_JobRef()
            ref.jobID = id
            do {
                let job = try await daemon.jobs.cancelJob(ref)
                log("sweep", "\(id) stopped: \(job.statusDetail)")
            } catch {
                let e = LeylineError(error)
                log("sweep", "\(id) not stopped: \(e.code) \(e.message)")
                notice = "Could not stop the sweep: \(e.message.isEmpty ? e.code : e.message)"
            }
        }
    }

    /// While a sweep runs, a tune stops it and runs once the terminal event has put the radio
    /// back, so no write reaches the swept capture (R20). True when the caller must return.
    /// One action waits; the latest wins.
    private func waitForSweep(_ what: String, _ action: @escaping @MainActor () -> Void) -> Bool {
        guard sweeping else { return false }
        log(
            "sweep",
            "\(what) waits for the sweep to stop\(afterSweep == nil ? "" : ", in place of what waited before")"
        )
        afterSweep = action
        cancelSweep()
        return true
    }

    private func runAfterSweep() {
        guard let next = afterSweep else { return }
        afterSweep = nil
        next()
    }

    /// In the mirror-follow list: the row's words from the job's `status_detail` while it runs,
    /// and on its terminal event the scan read once and the radio put back (`endSweep`). A job
    /// the mirror does not list `neverSeenDropSeconds` after the start, or listed and then
    /// lost, ends the sweep as failed, so the window never waits on an event that is not
    /// coming.
    private func followScanJob() {
        guard let s = sweep, !s.restored, !s.ending, !s.jobID.isEmpty else { return }
        guard let job = state.jobs.first(where: { $0.jobID == s.jobID }) else {
            guard Date().timeIntervalSince(s.startedAt) > Self.neverSeenDropSeconds else {
                return
            }
            log(
                "sweep",
                "the mirror has no job \(s.jobID) \(Int(Self.neverSeenDropSeconds)) s after it started"
            )
            sweep?.ending = true
            Task { await endSweep(nil) }
            return
        }
        if job.isActive {
            let running = SweepOutcome.running(SweepProgress(statusDetail: job.statusDetail))
            if s.outcome != running {
                sweep?.outcome = running
                log("sweep", "\(job.jobID): \(job.statusDetail)")
            }
            return
        }
        sweep?.ending = true
        Task { await endSweep(job) }
    }

    /// The terminal event: a completed job's scan read through `GetScan`, the outcome set from
    /// the job and the scan (`SweepOutcome.from`), the radio put back whatever the outcome, then
    /// whatever waited on the sweep. Nil is a job the mirror lost.
    private func endSweep(_ job: Leyline_V1_Job?) async {
        guard let s = sweep else { return }
        let outcome: SweepOutcome
        if let job {
            var scan: Leyline_V1_Scan?
            if job.state == .completed, let daemon, let id = Sweep.scanID(of: job) {
                var ref = Leyline_V1_ScanRef()
                ref.scanID = id
                do {
                    scan = try await daemon.jobs.getScan(ref)
                } catch {
                    let e = LeylineError(error)
                    log(
                        "sweep",
                        "\(job.jobID): scan \(id) could not be read: \(e.code) \(e.message)")
                }
            }
            outcome =
                SweepOutcome.from(job: job, scan: scan, band: s.row, in: Bands.builtIn)
                ?? .failed(detail: "The sweep ended but its scan could not be read")
        } else {
            outcome = .failed(detail: "The daemon no longer lists the sweep")
        }
        log("sweep", "\(s.jobID) ended: \(Self.words(of: outcome))")
        sweep?.outcome = outcome
        await resumeAfterSweep(s.paused, row: s.row)
        if case .cancelled = outcome {
            sweep = nil
        } else {
            sweep?.restored = true
        }
        runAfterSweep()
    }

    /// The radio back as it was (R18): the bookmark re-tuned with its saved settings, else the
    /// band select at the paused frequency, so the channel and sink come back the way a click
    /// makes them; with nothing paused, the swept row's part, as a bookmark click after Stop
    /// listening selects one. Through `moveToBand` and `open(bookmark:in:)` directly, because
    /// `select(band:at:)` would wait on the sweep this ends, and a recording on the radio was
    /// asked about before the sweep, not after it.
    private func resumeAfterSweep(_ paused: SweepState.Paused?, row: Band) async {
        if let p = paused {
            if let b = p.bookmark, let band = p.band ?? Bands.band(containing: b.hz, in: bands) {
                log("sweep", "resuming bookmark \(b.name) at \(b.hz) Hz")
                await open(bookmark: b, in: band)
                return
            }
            if let band = p.band {
                log("sweep", "resuming \(band.name) at \(p.hz) Hz")
                await moveToBand(band, at: p.hz)
                return
            }
        }
        let part = part(of: row, near: paused?.hz)
        log("sweep", "selecting \(part.name) after the sweep")
        await moveToBand(part, at: nil)
    }

    /// The log's word for an outcome.
    private static func words(of outcome: SweepOutcome) -> String {
        switch outcome {
        case .running(let p): return "running, \(p.detail)"
        case .found(let r): return r.hits.count == 1 ? "1 hit" : "\(r.hits.count) hits"
        case .empty: return "nothing on the air"
        case .failed(let detail): return "failed: \(detail)"
        case .cancelled: return "cancelled"
        }
    }

    // MARK: Device and gain

    func setGain(element: String, db: Double) {
        guard let dev = device else { return }
        UserDefaults.standard.set(
            String(db),
            forKey: GainPreferences.storageKey(deviceID: dev.deviceID, element: element))
        spectrum.resetFolds()
        writeGain(element: element, String(format: "%.1f dB", db)) { $0.db = db }
    }

    func setGainAuto(element: String) {
        guard let dev = device else { return }
        UserDefaults.standard.set(
            GainPreferences.automatic,
            forKey: GainPreferences.storageKey(deviceID: dev.deviceID, element: element))
        spectrum.resetFolds()
        writeGain(element: element, "auto") { $0.auto = true }
    }

    /// A gain write always names its stage. For a radio without that stage the window shows a
    /// notice and writes nothing, rather than silently changing the first stage.
    private func writeGain(
        element elementName: String, _ words: String,
        _ fill: (inout Leyline_V1_GainWrite) -> Void
    ) {
        guard let cap = capture, let writes else { return }
        guard let element = device?.gainElements.first(where: { $0.name == elementName }) else {
            notice = "This radio reports no \(elementName) gain stage, so there is nothing to set."
            return
        }
        var w = Leyline_V1_GainWrite()
        w.element = element.name
        fill(&w)
        log("gain", "\(element.name) \(words)")
        Task { await writes.gain(w, capture: cap.captureID) }
    }

    /// A new capture width. The daemon keeps the centre where it was, so a station off-centre
    /// falls out of a narrower capture and goes silent (`OUT_OF_CAPTURE`, `engine-internals.md`);
    /// the window re-places the centre for the tuned frequency at the new width, as a band
    /// change does, and writes centre and rate in one tick: centre first when narrowing and rate
    /// first when widening, so the channel fits at each step the daemon applies. A width the
    /// channel cannot fit at all is refused here with a message.
    /// A narrower width that would leave a running recording outside the span asks first
    /// (`retuneQuestion`); Move anyway sets it (`askedFirst`), Cancel leaves the width.
    func setSampleRate(_ rate: UInt64, askedFirst: Bool = false) {
        guard let cap = capture, let writes, rate != cap.sampleRate else { return }
        guard centreInFlight == nil else {
            log("rate", "\(rate) S/s refused: a centre move is in flight")
            return
        }
        var centre = Int64(cap.centerHz)
        if let ch = channel, let hz = tunedHz {
            if Int64(ch.bandwidthHz) > Int64(rate) {
                notice =
                    "\(ch.mode.word) at \(Frequency.format(UInt64(ch.bandwidthHz))) wide does not fit a \(Frequency.format(rate)) capture. Pick a narrower width first."
                return
            }
            centre = placedCentre(for: ch, at: hz, rate: rate)
        }
        if !askedFirst, let words = leftOutWords(centre: centre, rate: rate) {
            ask(words, before: "\(rate) S/s") { self.setSampleRate(rate, askedFirst: true) }
            return
        }
        let want = UInt64(max(0, centre))
        let narrowing = rate < cap.sampleRate
        UserDefaults.standard.set(Int(rate), forKey: Self.sampleRateKey)
        centreInFlight = Int64(want)
        spectrum.resetFolds()
        log(
            "rate",
            "\(cap.sampleRate) -> \(rate) S/s, remembered; centre \(cap.centerHz) -> \(want) Hz\(tunedHz.map { " for \($0) Hz" } ?? "")"
        )
        Task {
            if narrowing, want != cap.centerHz {
                await writes.centerHz(want, capture: cap.captureID)
            }
            _ = await writes.set(.captureSampleRate(rate), target: cap.captureID)
            if !narrowing, want != cap.centerHz {
                await writes.centerHz(want, capture: cap.captureID)
            }
            await confirmed(within: 2) {
                self.capture?.centerHz == want && self.capture?.sampleRate == rate
            }
            if centreInFlight == Int64(want) { centreInFlight = nil }
        }
    }

    /// Where the capture's centre goes so the tuned channel at `hz` fits a capture `rate` wide:
    /// the band's rule when there is a band, then pulled in until the channel has its width to
    /// spare, then kept in the radio's range. `setSampleRate` and `tuneInside` place it the same
    /// way.
    private func placedCentre(for ch: Leyline_V1_Channel, at hz: UInt64, rate: UInt64) -> Int64 {
        let span = Int64(rate)
        let bw = Int64(ch.bandwidthHz)
        let target = Int64(hz)
        var centre = Int64(capture?.centerHz ?? hz)
        if let b = band { centre = Int64(captureCentre(for: b, at: hz, rate: rate)) }
        // The band's rule leaves the band's width to spare; the channel may be wider.
        centre = min(max(centre, target - span / 2 + bw), target + span / 2 - bw)
        return clampCentre(centre, span: span)
    }

    /// The tuned channel lies outside the capture, silent: another client narrowed or moved the
    /// capture (the window's own writes keep the station inside). The daemon holds the channel
    /// at its frequency until the capture covers it again. Shown under the frequency in the
    /// identity, with `Tune inside` beside it, once the mirror has reported the state for
    /// `outOfCaptureHoldSeconds`: the window's own retune writes the centre before the offset,
    /// and the channel event between the two reads out of capture for about 90 ms.
    var outOfCaptureWords: String? {
        guard let ch = channel, ch.state == .outOfCapture, outOfCaptureHeld == ch.channelID,
            let cap = capture
        else { return nil }
        return
            "Outside the radio's \(Frequency.format(cap.sampleRate)) around \(Frequency.format(cap.centerHz))"
    }

    /// How long the mirror must report the tuned channel out of capture before the words show.
    static let outOfCaptureHoldSeconds: Double = 1

    /// Starts the wait when the tuned channel goes out of capture, and cancels it, and hides the
    /// words, when the channel comes back inside or another channel is tuned.
    private func holdOutOfCapture() {
        let out = channel.flatMap { $0.state == .outOfCapture ? $0.channelID : nil }
        if outOfCaptureHeld != out { outOfCaptureHeld = nil }
        if let wait = outOfCaptureWait, wait.channel != out {
            wait.task.cancel()
            outOfCaptureWait = nil
        }
        guard let out, outOfCaptureHeld == nil, outOfCaptureWait == nil else { return }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.outOfCaptureHoldSeconds))
            guard !Task.isCancelled, let self, self.outOfCaptureWait?.channel == out else {
                return
            }
            self.outOfCaptureWait = nil
            self.outOfCaptureHeld = out
            self.logShownWords()
        }
        outOfCaptureWait = (channel: out, task: task)
    }

    /// `Tune inside`: the capture's centre moves so the tuned frequency is inside it again, at
    /// the capture's own rate, placed the way `setSampleRate` places it. Only the centre is
    /// written: the daemon keeps the channel at its absolute frequency and recomputes the offset.
    func tuneInside() {
        guard let cap = capture, let ch = channel, let hz = tunedHz, let writes else { return }
        guard centreInFlight == nil else {
            log("tune", "tune inside refused: a centre move is in flight")
            return
        }
        if UInt64(ch.bandwidthHz) > cap.sampleRate {
            notice =
                "\(ch.mode.word) at \(Frequency.format(UInt64(ch.bandwidthHz))) wide does not fit a \(Frequency.format(cap.sampleRate)) capture. Pick a wider sample rate first."
            return
        }
        let want = UInt64(max(0, placedCentre(for: ch, at: hz, rate: cap.sampleRate)))
        guard want != cap.centerHz else { return }
        centreInFlight = Int64(want)
        spectrum.resetFolds()
        log("tune", "tune inside: centre \(cap.centerHz) -> \(want) Hz for \(hz) Hz")
        Task {
            await writes.centerHz(want, capture: cap.captureID)
            await confirmed { self.capture?.centerHz == want }
            if centreInFlight == Int64(want) { centreInFlight = nil }
        }
    }

    /// Another radio: a new capture there on the current band, the old one left to its owner
    /// (destroyed only if this app made it).
    func choose(device: Leyline_V1_DeviceDescriptor) async {
        guard let daemon, device.deviceID != capture?.deviceID else { return }
        // `select(band:)` returns without doing anything while another band change is in flight,
        // so the switch must wait for that one rather than be dropped.
        await confirmed(within: 2) { !self.busy }
        guard !busy else {
            log(
                "session",
                "device \(device.model) not chosen: a band change was still in flight after 2 s")
            return
        }
        let old = capture
        dropCapture()
        if let b = band {
            await select(band: b)
        } else if let b = bands.first(where: { $0.id == "fm" }) {
            await select(band: b)
        }
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
            lastError = LeylineError(
                code: "BOOKMARKS_UNREADABLE", message: "bookmarks.json could not be read: \(error)",
                target: bookmarks.path)
        }
    }

    /// The message for a refused bookmark write. The unloaded case gets its own wording: the
    /// file is unchanged, so the message gives its path and says nothing was written.
    private func bookmarkWriteError(_ error: any Error) -> LeylineError {
        if let reason = error as? BookmarkError, case .notLoaded(let path) = reason {
            return LeylineError(
                code: "BOOKMARKS_UNREADABLE",
                message:
                    "\(path) could not be read, so nothing was written. Fix that file, or move it aside, and the list reloads.",
                target: path)
        }
        return LeylineError(
            code: "BOOKMARKS_UNWRITABLE", message: "bookmarks.json could not be written: \(error)",
            target: bookmarks.path)
    }

    /// Reloads when `ley bookmarks` or anyone else writes the file.
    private func watchBookmarks() {
        let dir = (bookmarks.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        bookmarkWatchFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.loadBookmarks() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        bookmarkWatch = source
    }

    /// `＋`: the tuned frequency becomes a bookmark named after the plan channel it sits on, else
    /// after itself (`BookmarkNaming`, the plan's KTD7), and its row opens as an editor at once
    /// so the name is typed where the bookmark appears.
    func bookmarkCurrent() {
        guard let ch = channel, let hz = tunedHz else { return }
        let name = BookmarkNaming.name(for: hz)
        do {
            let b = try bookmarks.add(
                name: name, hz: hz, mode: ch.mode, bandwidthHz: ch.bandwidthHz)
            try bookmarks.save()
            log("bookmark", "added \(name) at \(hz) Hz")
            editingBookmarkID = b.id
        } catch {
            lastError = bookmarkWriteError(error)
        }
    }

    /// The sidebar row's editor and the Rename item: the bookmark takes the name in place.
    func rename(bookmark: Bookmark, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != bookmark.name else { return }
        do {
            try bookmarks.renameBookmark(bookmark.id, to: name)
            try bookmarks.save()
            log("bookmark", "renamed \(bookmark.name) -> \(name) at \(bookmark.hz) Hz")
        } catch {
            lastError = bookmarkWriteError(error)
        }
    }

    /// The tuned bookmark takes the channel's current mode and width.
    func saveTunedBookmark() {
        guard let b = tunedBookmark, let ch = channel else { return }
        do {
            try bookmarks.updateBookmark(b.id, mode: ch.mode, bandwidthHz: ch.bandwidthHz)
            try bookmarks.save()
            log("bookmark", "\(b.name) takes \(ch.mode.word) \(ch.bandwidthHz) Hz")
        } catch {
            lastError = bookmarkWriteError(error)
        }
    }

    /// The row's "Replace with …": the bookmark keeps its name and takes the tuned frequency
    /// with the channel's current mode and width (the owner's choice over a match within the
    /// channel's width, 2026-09-21; `ley bookmarks move` is the terminal's).
    func replace(bookmark: Bookmark) {
        guard let ch = channel, let hz = tunedHz else { return }
        do {
            try bookmarks.updateBookmark(
                bookmark.id, hz: hz, mode: ch.mode, bandwidthHz: ch.bandwidthHz)
            try bookmarks.save()
            log(
                "bookmark",
                "\(bookmark.name) moved \(bookmark.hz) -> \(hz) Hz, \(ch.mode.word) \(ch.bandwidthHz) Hz"
            )
        } catch {
            lastError = bookmarkWriteError(error)
        }
    }

    /// The channel goes back to the tuned bookmark's saved settings.
    func revertToTunedBookmark() {
        guard let b = tunedBookmark, let ch = channel, b.mode != .unspecified else { return }
        let bw = b.bandwidthHz == 0 ? b.mode.defaultBandwidthHz : b.bandwidthHz
        log("bookmark", "\(b.name) put back: \(b.mode.word) \(bw) Hz")
        Task { await apply(mode: b.mode, bandwidthHz: bw, to: ch) }
    }

    /// The inspector's pencil: the bookmark on the tuned frequency takes the name, or one is
    /// made the way `bookmarkCurrent` makes it and named at once; committed empty, the new one
    /// takes the plan channel's name, else the frequency's (`BookmarkNaming`), and an existing
    /// one keeps its name. Either way the file is written and the watcher reloads it, so the
    /// sidebar and `ley bookmarks` see the name too.
    func renameTuned(to name: String) {
        guard let ch = channel, let hz = tunedHz else { return }
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            guard tunedBookmark == nil else { return }
            name = BookmarkNaming.name(for: hz)
        }
        do {
            if let b = tunedBookmark {
                guard b.name != name else { return }
                try bookmarks.renameBookmark(b.id, to: name)
                log("bookmark", "renamed \(b.name) -> \(name) at \(hz) Hz")
            } else {
                try bookmarks.add(name: name, hz: hz, mode: ch.mode, bandwidthHz: ch.bandwidthHz)
                log("bookmark", "added \(name) at \(hz) Hz from the inspector")
            }
            try bookmarks.save()
        } catch {
            lastError = bookmarkWriteError(error)
        }
    }

    func remove(bookmark: Bookmark) {
        do {
            try bookmarks.remove(bookmark.id)
            try bookmarks.save()
            log("bookmark", "removed \(bookmark.name) at \(bookmark.hz) Hz")
        } catch {
            lastError = bookmarkWriteError(error)
        }
    }

    func tune(bookmark: Bookmark) {
        if waitForSweep("tune bookmark \(bookmark.name)", { self.tune(bookmark: bookmark) }) {
            return
        }
        selectedBandID = nil
        log("tune", "bookmark \(bookmark.name) at \(bookmark.hz) Hz")
        // No capture (after Stop listening): the band opens the radio there first, then the
        // bookmark's settings are applied.
        if capture == nil, let b = Bands.band(containing: bookmark.hz, in: bands),
            outOfRangeWords(b) == nil
        {
            Task { await open(bookmark: bookmark, in: b) }
            return
        }
        tuningBookmark = bookmark.mode != .unspecified
        tune(to: bookmark.hz)
        if let ch = channel, bookmark.mode != .unspecified {
            let bw =
                bookmark.bandwidthHz == 0 ? bookmark.mode.defaultBandwidthHz : bookmark.bandwidthHz
            Task { await apply(mode: bookmark.mode, bandwidthHz: bw, to: ch) }
        }
    }

    /// The band opens the radio at the bookmark's frequency through the band-select path, then
    /// the bookmark's saved settings are applied: a bookmark tuned with no capture, and the
    /// resume after a sweep, which must not ask and must not wait on the sweep it ends.
    private func open(bookmark: Bookmark, in band: Band) async {
        await moveToBand(band, at: bookmark.hz)
        if let ch = channel, bookmark.mode != .unspecified {
            let bw =
                bookmark.bandwidthHz == 0 ? bookmark.mode.defaultBandwidthHz : bookmark.bandwidthHz
            await apply(mode: bookmark.mode, bandwidthHz: bw, to: ch)
        }
    }

    func snapToNearestBookmark() {
        guard let hz = tunedHz, let b = bookmarks.nearest(to: hz) else { return }
        tune(bookmark: b)
    }

    /// The loudest peak in the span by `ley spectrum`'s rule; a flat band tunes nothing.
    func centreOnStrongest() {
        guard let cap = capture,
            let peak = SpectrumFold.strongest(
                spectrum.latest, centerHz: cap.centerHz, spanHz: cap.sampleRate)
        else {
            notice =
                "Nothing in the span is \(Int(SpectrumFold.peakAboveFloorDB)) dB above the floor"
            return
        }
        log("tune", "strongest peak \(peak.centerHz) Hz at \(peak.db) dBFS")
        tune(to: peak.centerHz)
    }

    func zoomIn() { zoom = min(zoom * 2, 8) }
    func zoomOut() { zoom = max(zoom / 2, 1) }

    func clearMaxHold() {
        spectrum.clearMaxHold()
        log("spectrum", "max hold cleared")
    }

    /// The inspector's audio ladder follows the tuned channel while the Radio's panel is shown.
    private func followAudioLevels() {
        audioLevels.follow(
            channel, captureRate: capture?.sampleRate ?? 0,
            shown: inspectorShown && place == .radio,
            connection: daemon)
    }

    func toggleInspector() {
        inspectorShown.toggle()
        log("session", inspectorShown ? "inspector shown" : "inspector hidden")
    }

    func clearNotice() { notice = nil }
    func clearError() { lastError = nil }

    /// Marks the waterfall's rows the newest reading covers, when it is over the clipping floor
    /// and its capture is the one the waterfall's rows come from (plans/app.md, M2-8). The raw
    /// reading, not `failure`: the mark records every interval that clipped, the hold does not.
    private func markClippedRows() {
        guard let level = captureLevel.level, let time = captureLevel.time,
            let id = captureLevel.capture, id == spectrum.subscribedCapture
        else { return }
        spectrum.waterfall.markClipped(level, at: time)
    }

    /// The current failure state, from the capture's level and gains through the hold. A change
    /// logs one line, after the hold, so what the chip showed can be traced in the log.
    private func nameFailure() {
        let now: FailureState?
        if let cap = capture, isLive, spectrum.error == nil, let level = captureLevel.level,
            let time = captureLevel.time
        {
            now = failureHold.fold(
                level: level, at: time, sampleRate: cap.sampleRate, gains: cap.gains,
                elements: device?.gainElements ?? [])
        } else {
            failureHold.reset()
            now = nil
        }
        guard now != failure else { return }
        // The same state with a new number is not a change: skip the log.
        if let now, let was = failure, now.kind == was.kind {
            failure = now
            return
        }
        failure = now
        if let now {
            log("failure", "\(now.headline): \(now.detail)")
        } else {
            log("failure", "cleared")
        }
    }

    // MARK: Recording

    /// The record job on the tuned channel's frequency and mode, running or degraded, whoever
    /// started it (`Recordings.activeJob`): the Record transmissions switch's state and its
    /// status line (docs/design/app-design-handoff-m3.md, 8a and 8b). The switch remembers
    /// nothing, so a job `ley record` or an agent started shows the same.
    var recordingJob: Leyline_V1_Job? {
        guard let hz = tunedHz, let ch = channel else { return nil }
        return Recordings.activeJob(in: state.jobs, frequencyHz: hz, mode: ch.mode)
    }

    /// What the switch and File ▸ Record Transmissions show: the click while its job's event is
    /// in flight, else whether the job runs.
    var recordSwitchOn: Bool {
        switchOn(frequencyHz: tunedHz, mode: channel?.mode ?? .unspecified, job: recordingJob)
    }

    /// The channel page's switch: the record job on that channel's frequency and mode, whoever
    /// started it, or the click in flight. The log's switch shows the same when it is tuned
    /// there, because both read the job (M3 handoff, 8c: "one state, two places").
    func pageSwitchOn(for c: RecordingChannel) -> Bool {
        switchOn(frequencyHz: c.frequencyHz, mode: c.mode, job: activeRecordJob(for: c))
    }

    func activeRecordJob(for c: RecordingChannel) -> Leyline_V1_Job? {
        Recordings.activeJob(in: state.jobs, frequencyHz: c.frequencyHz, mode: c.mode)
    }

    private func switchOn(
        frequencyHz: UInt64?, mode: Leyline_V1_DemodMode, job: Leyline_V1_Job?
    ) -> Bool {
        RecordSwitchClick.shown(
            pending: recordSwitchPending, frequencyHz: frequencyHz, mode: mode,
            running: job != nil)
    }

    /// A sidebar bookmark's dot: a record job runs on its frequency and mode, tuned or not.
    func isRecording(_ b: Bookmark) -> Bool {
        Recordings.activeJob(in: state.jobs, frequencyHz: b.hz, mode: b.mode) != nil
    }

    /// Every recording on the tuned frequency and mode, newest first (`Recordings.recordingIDs`):
    /// the running job's, then the store's listing.
    private var tunedRecordingIDs: [String] {
        guard let hz = tunedHz, let ch = channel else { return [] }
        return Recordings.recordingIDs(
            onFrequencyHz: hz, mode: ch.mode, in: recordings, running: recordingJob?.jobID)
    }

    /// The manifests of `tunedRecordingIDs` read so far, newest first.
    var tunedManifests: [RecordingManifest] { tunedRecordingIDs.compactMap { manifests[$0] } }

    /// The running recording's manifest on the tuned channel, for the switch's status line; nil
    /// while the switch is off or before its first read.
    var recording: RecordingManifest? { recordingJob.flatMap { manifests[$0.jobID] } }

    /// Every closed part of every recording on the tuned channel: the time gutter's kept bars.
    var keptParts: [RecordingPart] { tunedManifests.flatMap(\.parts) }

    /// The part a closed transmission lies inside, in any recording of the tuned channel, as the
    /// URI that plays it: the row is kept. nil for a heard row, whose audio is not on disk
    /// (`RecordingParts.keptPartURI`).
    func keptPartURI(_ t: Transmission) -> String? {
        RecordingParts.keptPartURI(of: t, in: tunedManifests)
    }

    /// The window's playback, by the id `StartPlayback` returned, while the mirror carries it.
    var playback: Leyline_V1_Playback? {
        playbackID.flatMap { id in state.playbacks.first { $0.playbackID == id } }
    }

    /// How far the clip has played, 0 to 1: the mirror's playback, its position over its
    /// frames; nil when nothing plays or its length is unknown.
    var playbackProgress: Double? {
        guard playingURI != nil, let p = playback, p.samples > 0 else { return nil }
        return min(1, Double(p.position) / Double(p.samples))
    }

    /// The switch, and File ▸ Record Transmissions (⌘R): on starts the record job, off cancels
    /// the one the switch shows, whoever started it.
    func setRecording(_ on: Bool) async {
        let hz = tunedHz ?? 0
        let mode = channel?.mode ?? .unspecified
        guard on != (recordingJob != nil) else {
            letGoRecordSwitch(frequencyHz: hz, mode: mode, "the job already agrees")
            return
        }
        holdRecordSwitch(on, frequencyHz: hz, mode: mode)
        if on {
            await startRecording()
        } else {
            await stopRecording(recordingJob?.jobID, frequencyHz: hz, mode: mode)
        }
    }

    /// The channel page's switch: on starts the frequency form on that channel's frequency and
    /// mode, at the width of its newest recording and the daemon's auto squelch (NaN, the channel
    /// default), because the page has no channel of its own to copy a squelch from; off cancels
    /// the job the switch shows.
    func setRecording(_ on: Bool, channel c: RecordingChannel) async {
        let job = activeRecordJob(for: c)
        guard on != (job != nil) else {
            letGoRecordSwitch(frequencyHz: c.frequencyHz, mode: c.mode, "the job already agrees")
            return
        }
        holdRecordSwitch(on, frequencyHz: c.frequencyHz, mode: c.mode)
        guard on else {
            await stopRecording(job?.jobID, frequencyHz: c.frequencyHz, mode: c.mode)
            return
        }
        guard let daemon else {
            letGoRecordSwitch("not dialled")
            return
        }
        var req = Leyline_V1_StartJobRequest()
        req.record = Recordings.pageConfig(c, groups: pageGroups(for: c))
        let width = req.record.bandwidthHz
        do {
            let started = try await daemon.jobs.startJob(req)
            switchStartedJobs.insert(started.jobID)
            log(
                "record",
                "\(started.jobID) started from the channel page: \(c.frequencyHz) Hz \(c.mode.word) \(width) Hz, auto squelch, gated by squelch"
            )
        } catch {
            let e = LeylineError(error)
            letGoRecordSwitch("refused")
            log("record", "refused at \(c.frequencyHz) Hz from the page: \(e.code) \(e.message)")
            notice = "Could not record: \(e.message.isEmpty ? e.code : e.message)"
        }
    }

    /// The click shown until the job's event agrees, or for `RecordSwitchClick.holdSeconds`,
    /// after which the switch shows the mirror again. The hold never disables the switch.
    private func holdRecordSwitch(_ on: Bool, frequencyHz: UInt64, mode: Leyline_V1_DemodMode) {
        let click = RecordSwitchClick(frequencyHz: frequencyHz, mode: mode, on: on)
        recordSwitchPending = click
        log("record", "switch clicked \(on ? "on" : "off") at \(frequencyHz) Hz \(mode.word)")
        logRecordSwitch()
        recordSwitchExpiry?.cancel()
        recordSwitchExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RecordSwitchClick.holdSeconds))
            guard let self, !Task.isCancelled, self.recordSwitchPending == click else { return }
            self.letGoRecordSwitch(
                "no job event agreed within \(Int(RecordSwitchClick.holdSeconds)) s; active record jobs: \(self.activeRecordJobsWords)"
            )
        }
    }

    /// The held click is dropped, and the switch shows the job; with a frequency and mode, only a
    /// click on that channel. `why` goes to the log.
    private func letGoRecordSwitch(
        frequencyHz: UInt64? = nil, mode: Leyline_V1_DemodMode = .unspecified, _ why: String
    ) {
        guard let p = recordSwitchPending else { return }
        if let hz = frequencyHz, !p.names(frequencyHz: hz, mode: mode) { return }
        recordSwitchPending = nil
        recordSwitchExpiry?.cancel()
        recordSwitchExpiry = nil
        log(
            "record",
            "switch let go of its \(p.on ? "on" : "off") click at \(p.frequencyHz) Hz \(p.mode.word): \(why)"
        )
        logRecordSwitch()
    }

    /// `job_01… 462612500 Hz NFM running`, one per active record job, or `none`: what the expiry's
    /// log line compares the click with, so a job on a frequency the click did not match shows.
    private var activeRecordJobsWords: String {
        let words = state.jobs.filter { $0.isActive }.compactMap { j -> String? in
            guard let r = j.recordConfig else { return nil }
            let form = r.channelID.isEmpty ? "" : " on \(r.channelID)"
            return "\(j.jobID) \(r.frequencyHz) Hz \(r.mode.word)\(form) \(j.state)"
        }
        return words.isEmpty ? "none" : words.joined(separator: ", ")
    }

    /// Writes the log's switch to the log when what it shows changed: on or off, whether a click
    /// or a job decides it, and whether it is disabled (nothing tuned), so a switch seen grey can
    /// be read back from tmp/leyline-app.log: `record: switch on (job_01… running) at 462612500
    /// Hz NFM`.
    private func logRecordSwitch() {
        let on = recordSwitchOn
        let why: String
        if let p = recordSwitchPending, let hz = tunedHz,
            p.isHeld(now: Date()), p.names(frequencyHz: hz, mode: channel?.mode ?? .unspecified)
        {
            why = "the click, held"
        } else if let job = recordingJob {
            why = "\(job.jobID) \(job.state)"
        } else {
            why = "no record job"
        }
        let shown = "\(on ? "on" : "off")\(tunedHz == nil ? ", disabled" : "") (\(why))"
        // A retune with the switch off changes nothing it shows, so the frequency is left out of
        // the comparison and a drag writes no line per step.
        guard shown != recordSwitchLogged else { return }
        recordSwitchLogged = shown
        let at = tunedHz.map { "\($0) Hz \(channel?.mode.word ?? "")" } ?? "no tuned frequency"
        log("record", "switch \(shown) at \(at)")
    }

    /// A job a switch started has ended. FAILED is a notice with the daemon's reason, and the
    /// switch lets go of the click at once rather than after its expiry, so it goes back off with
    /// the reason beside it.
    private func noticeFailedRecordJobs() {
        for id in switchStartedJobs {
            guard let job = state.jobs.first(where: { $0.jobID == id }), !job.isActive else {
                continue
            }
            switchStartedJobs.remove(id)
            guard let words = Recordings.failureNotice(job) else { continue }
            log("record", "\(id) failed: \(job.error.code) \(job.statusDetail)")
            notice = words
            if let r = job.recordConfig {
                letGoRecordSwitch(frequencyHz: r.frequencyHz, mode: r.mode, "\(id) failed")
            }
        }
    }

    /// The job's event agrees with the click: the switch shows the mirror.
    private func settleRecordSwitch() {
        guard let p = recordSwitchPending else { return }
        let running =
            Recordings.activeJob(in: state.jobs, frequencyHz: p.frequencyHz, mode: p.mode) != nil
        guard p.on == running else { return }
        letGoRecordSwitch("the job's event agrees")
    }

    /// The frequency form of `RecordConfig`, gated by squelch, with the tuned channel's frequency,
    /// mode, width and squelch copied now, so the job owns its channel and outlives the window, a
    /// retune and a quit. The confirmation is the job's event, which the switch renders; a
    /// refusal is a notice with the daemon's words.
    private func startRecording() async {
        guard let daemon, let ch = channel, let hz = tunedHz else {
            letGoRecordSwitch("nothing tuned")
            notice =
                "Tune a channel first: a recording copies its frequency, mode, width and squelch."
            return
        }
        var req = Leyline_V1_StartJobRequest()
        req.record = Recordings.config(
            frequencyHz: hz, mode: ch.mode, bandwidthHz: ch.bandwidthHz, squelchDBFS: ch.squelchDb)
        let squelch = ch.squelchDb.isFinite ? String(format: "%.0f dBFS", ch.squelchDb) : "auto"
        do {
            let job = try await daemon.jobs.startJob(req)
            switchStartedJobs.insert(job.jobID)
            log(
                "record",
                "\(job.jobID) started: \(hz) Hz \(ch.mode.word) \(ch.bandwidthHz) Hz, squelch \(squelch), gated by squelch"
            )
        } catch {
            let e = LeylineError(error)
            letGoRecordSwitch("refused")
            log("record", "refused at \(hz) Hz: \(e.code) \(e.message)")
            notice = "Could not record: \(e.message.isEmpty ? e.code : e.message)"
        }
    }

    /// `CancelJob` on the job the switch shows: the daemon finalises the files and the job ends
    /// `CANCELLED`, which is how an open-ended recording is meant to stop.
    private func stopRecording(
        _ jobID: String?, frequencyHz: UInt64, mode: Leyline_V1_DemodMode
    ) async {
        guard let daemon, let id = jobID else {
            letGoRecordSwitch(frequencyHz: frequencyHz, mode: mode, "no job to stop")
            return
        }
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        do {
            let job = try await daemon.jobs.cancelJob(ref)
            log("record", "\(id) stopped: \(job.statusDetail)")
        } catch {
            let e = LeylineError(error)
            letGoRecordSwitch(frequencyHz: frequencyHz, mode: mode, "not stopped")
            log("record", "\(id) not stopped: \(e.code) \(e.message)")
            notice = "Could not stop the recording: \(e.message.isEmpty ? e.code : e.message)"
        }
    }

    /// A record job changed: the store's listing is read again (a part closed, a job started or
    /// ended, so the sidebar's rows and the footer's use moved), and so is every manifest read of
    /// a changed job, because the parts, the bytes and the gutter's kept bars come from it. Then
    /// the manifests follow the tuned channel and the page, and the switch settles.
    private func followRecordJobs() {
        let jobs = state.jobs.filter { $0.recordConfig != nil }
        if jobs != recordJobsSeen {
            let changed = Set(jobs.filter { !recordJobsSeen.contains($0) }.map(\.jobID))
            recordJobsSeen = jobs
            // A part closed or the job ended.
            staleManifests.formUnion(
                changed.filter { manifests[$0] != nil || failedManifests.contains($0) })
            failedManifests.subtract(changed)
            reloadRecordings()
        }
        followTunedRecordings()
        followPage()
        noticeFailedRecordJobs()
        settleRecordSwitch()
        markRecordToggles()
        logRecordSwitch()
    }

    /// A record job on the tuned log's frequency and mode started or ended: the log's open
    /// transmission is cut there, a manual marker (`TransmissionLog.mark`; docs/dev/app.md,
    /// "Transmissions and the clock"). From the job's state, not the click, so `ley record` from
    /// a terminal cuts the log too. The job is looked up on the log's own key rather than
    /// `tunedHz`, which passes through a wrong frequency for one event when the capture moves
    /// (`ChannelFrequencyWatch`); a retune or a new log is not a toggle. The cut is at the newest
    /// telemetry time, the capture's clock.
    private func markRecordToggles() {
        guard let key = telemetry.logs.current else {
            recordMarkSeen = nil
            return
        }
        let job = Recordings.activeJob(
            in: state.jobs, frequencyHz: key.frequencyHz, mode: key.mode)?.jobID
        let seen = recordMarkSeen
        recordMarkSeen = (key, job)
        guard let seen, seen.key == key, seen.jobID != job else { return }
        // One job giving way to another in one event is an off and an on.
        if seen.jobID != nil { markRecordToggle(.recordingOff, job: seen.jobID) }
        if job != nil { markRecordToggle(.recordingOn, job: job) }
    }

    private func markRecordToggle(_ marker: Transmission.Marker, job: String?) {
        let word = marker == .recordingOn ? "on" : "off"
        guard let now = telemetry.newestTime else {
            log("record", "marker \(word) (\(job ?? "")) not cut: no telemetry time yet")
            return
        }
        let cut = telemetry.mark(marker, at: now)
        log(
            "record",
            "marker \(word) at sample \(now.sampleIndex) (\(job ?? "")): \(cut ? "the log cut there" : "nothing on air to cut")"
        )
    }

    /// The tuned channel's manifests: every recording on its frequency and mode, not only the
    /// newest, so a row an earlier recording kept stays kept after the switch goes off and on
    /// again (plans/app.md, APP-5, "Fixed 2026-09-25 (second run)"). Each is read once and again
    /// when its job changes; the running one is the one whose job changes.
    private func followTunedRecordings() {
        for id in tunedRecordingIDs { readManifestIfNeeded(id) }
    }

    /// Reads `id`'s manifest when it has not been read and its last read did not fail, or when a
    /// job event made it stale, one read per recording at a time.
    private func readManifestIfNeeded(_ id: String) {
        let stale = staleManifests.contains(id)
        guard stale || (manifests[id] == nil && !failedManifests.contains(id)) else { return }
        guard stale || manifestLoads[id] == nil else { return }
        loadManifest(id)
    }

    /// `ListResources(RECORDING)` into `recordings`. A listing already in flight is replaced,
    /// so a burst of job events costs one read that lands.
    private func reloadRecordings() {
        guard let daemon else { return }
        recordingsLoad?.cancel()
        recordingsLoad = Task { [weak self] in
            var req = Leyline_V1_ListResourcesRequest()
            req.kind = .recording
            do {
                let listed = try await daemon.resources.listResources(req)
                guard let self, !Task.isCancelled else { return }
                let list = listed.resources.map(RecordingSummary.init)
                if list.count != self.recordings.count {
                    log("record", "\(list.count) recordings listed")
                }
                if list != self.recordings { self.recordings = list }
                self.prunePage()
                self.failedManifests = []
                if self.place == .library, self.selectedRecordingChannel == nil {
                    self.selectFirstChannel()
                }
                self.followTunedRecordings()
                self.followPage()
            } catch {
                guard !Task.isCancelled else { return }
                log("record", "recordings not listed: \(LeylineError(error))")
            }
        }
    }

    /// The Library's channel rows (`Recordings.channels`), before the search.
    var recordingChannels: [RecordingChannel] {
        Recordings.channels(recordings, bookmarks: bookmarks.list, jobs: state.jobs)
    }

    /// The store footer's use, the listing's sizes summed, and the daemon's cap (0 from a daemon
    /// that predates `DaemonInfo.recordings_cap_bytes`).
    var storeUsedBytes: UInt64 { Recordings.storeUsedBytes(recordings) }
    var storeCapBytes: UInt64 { state.daemon.recordingsCapBytes }

    /// What the tuned channel is called where it is heard: the bookmark's name, else the plan
    /// channel's (`ch5`, `WX3`; R16), else the frequency (`Frequency.format`); nil with no
    /// channel. The volume caption's name.
    var listeningName: String? {
        guard let hz = tunedHz else { return nil }
        return tunedBookmark?.name ?? Plans.name(at: hz) ?? Frequency.format(hz)
    }

    /// Whether the Library's centre column shows a channel page: the Library is showing and a
    /// row is selected. A selected channel whose recordings have all gone is still a page, with
    /// one sentence (`RecordingsPage`), so a delete of the last recording leaves the page in
    /// place rather than selecting another channel under the pointer.
    var recordingsPageShown: Bool {
        place == .library && selectedRecordingChannel != nil
    }

    /// Arriving in the Library, or its listing arriving while it shows: the first row is
    /// selected when none is, or when the selected one has gone from the listing.
    private func selectFirstChannel() {
        guard selectedRecordingChannel == nil || selectedChannel == nil else { return }
        let first = recordingChannels.first?.id
        if first != selectedRecordingChannel { selectedRecordingChannel = first }
    }

    /// The selected row's channel while the listing holds it.
    var selectedChannel: RecordingChannel? {
        guard let id = selectedRecordingChannel else { return nil }
        return recordingChannels.first { $0.id == id }
    }

    /// The page's cards for `c`, with the manifests read so far.
    func pageGroups(for c: RecordingChannel) -> [RecordingGroup] {
        Recordings.groups(c.recordings, manifests: manifests, jobs: state.jobs)
    }

    /// The part the inspector shows while the Library does: the selected part, else the one
    /// playing, once its recording's manifest has been read. nil shows the channel's summary.
    var inspectedPart: (manifest: RecordingManifest, part: RecordingPart, group: RecordingGroup)? {
        guard place == .library,
            let uri = selectedPartURI ?? playingURI, let ref = RecordingPartRef(uri: uri),
            let m = manifests[ref.jobID],
            let part = m.parts.first(where: { $0.part == ref.part }),
            let summary = recordings.first(where: { $0.jobID == ref.jobID })
        else { return nil }
        let running = state.jobs.contains { $0.jobID == ref.jobID && $0.isActive }
        return (m, part, RecordingGroup(summary: summary, manifest: m, running: running))
    }

    /// The selected channel's manifests, read as the tuned channel's are. Nothing is read for
    /// the page while it is not showing.
    private func followPage() {
        guard recordingsPageShown, let c = selectedChannel else { return }
        for r in c.recordings { readManifestIfNeeded(r.jobID) }
    }

    /// `ResolveLocalPath(ley://recordings/<id>)`, then `recording.json` from that directory:
    /// the window is local, as `ley recordings show` is, and samples are never streamed.
    private func loadManifest(_ id: String) {
        guard let daemon else { return }
        staleManifests.remove(id)
        manifestLoads[id]?.cancel()
        manifestLoads[id] = Task { [weak self] in
            var ref = Leyline_V1_ResourceRef()
            ref.uri = "ley://recordings/\(id)"
            do {
                let local: Leyline_V1_LocalPath = try await daemon.resources.resolveLocalPath(ref)
                let manifest = try RecordingManifest.read(at: URL(fileURLWithPath: local.path))
                guard let self, !Task.isCancelled else { return }
                self.manifestLoads[id] = nil
                if self.manifests[id] != manifest {
                    if self.manifests[id]?.parts.count != manifest.parts.count {
                        log(
                            "record", "\(id): \(manifest.parts.count) parts read from \(local.path)"
                        )
                    }
                    self.manifests[id] = manifest
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.manifestLoads[id] = nil
                self.failedManifests.insert(id)
                // A job's first second has no manifest on disk yet; its next event reads again.
                log("record", "manifest of \(id) not read: \(error)")
            }
        }
    }

    /// Forgets the manifests of recordings the listing no longer holds, except the running job's
    /// on the tuned channel (the listing can lag its start), and a selection or an opened card
    /// among them.
    private func prunePage() {
        var listed = Set(recordings.map(\.jobID))
        if let running = recordingJob?.jobID { listed.insert(running) }
        for id in manifests.keys where !listed.contains(id) { manifests[id] = nil }
        for (id, task) in manifestLoads where !listed.contains(id) {
            task.cancel()
            manifestLoads[id] = nil
        }
        staleManifests.formIntersection(listed)
        if let uri = selectedPartURI, let ref = RecordingPartRef(uri: uri),
            !listed.contains(ref.jobID)
        {
            selectedPartURI = nil
        }
        let gone = levelGraphs.keys.filter { uri in
            RecordingPartRef(uri: uri).map { !listed.contains($0.jobID) } ?? true
        }
        for uri in gone { levelGraphs[uri] = nil }
    }

    /// An EARLIER day's line: open it in place, or fold it again.
    func toggleOpened(day id: String) {
        if openedDays.contains(id) {
            openedDays.remove(id)
        } else {
            openedDays.insert(id)
        }
    }

    /// The page's days for `c` (10a): every part of its recordings whose manifests have been
    /// read, as rows by the day each started (`Recordings.dayRows`).
    func pageDays(for c: RecordingChannel) -> [DayRows] {
        Recordings.dayRows(pageGroups(for: c), now: Date())
    }

    /// A row's click (10a): the part is selected, so the inspector and the player show it, and
    /// plays; a click on the row playing pauses it, and on the row paused resumes it. Starting
    /// another part ends a Play all or a Play day.
    func clickRow(_ uri: String) async {
        selectedPartURI = uri
        if playingURI == uri, playback != nil {
            await pausePlayback(!isPaused)
        } else if playingURI != uri {
            await play(partURI: uri)
        }
    }

    /// Play day: the day's parts oldest first (`DayRows.playOrder`), queued as Play all queues a
    /// recording's, each selected as it starts.
    func playDay(_ day: DayRows) async {
        var queue = PlayQueue()
        guard let first = queue.start(parts: day.playOrder) else { return }
        log("playback", "play day \(day.id): \(day.rows.count) parts")
        selectedPartURI = first
        playQueue = queue
        await startPlayback(first)
    }

    /// The row's level graph: `ResolveLocalPath` of the part's URI, then one pass over the WAV
    /// off the main actor into `LevelGraph.columnCount(seconds:)` columns, cached by URI. Called
    /// as a row appears; a row already read or being read costs nothing. A path that does not
    /// resolve, or a file that is not here, caches an empty graph and says nothing: the column is
    /// empty, as 10a draws it for a remote daemon.
    func loadLevelGraph(_ row: PartRow) {
        let uri = row.uri
        guard levelGraphs[uri] == nil, !levelGraphLoads.contains(uri), let daemon else { return }
        levelGraphLoads.insert(uri)
        let columns = LevelGraph.columnCount(seconds: row.seconds)
        Task { [weak self] in
            var ref = Leyline_V1_ResourceRef()
            ref.uri = uri
            let path = try? await daemon.resources.resolveLocalPath(ref).path
            let graph: [Float]
            if let path {
                graph = await Task.detached(priority: .utility) {
                    (try? LevelGraph.columns(wav: URL(fileURLWithPath: path), columns: columns))
                        ?? []
                }.value
            } else {
                graph = []
            }
            guard let self else { return }
            self.levelGraphLoads.remove(uri)
            if graph.isEmpty { log("record", "no level graph for \(uri)") }
            self.levelGraphs[uri] = graph
        }
    }

    /// Play all: the recording's parts in part order, the next started on the tombstone of the
    /// one before (`endPlayback`), each selected as it starts so the inspector follows. The
    /// inspector's `Play all 4` (10a).
    func playAll(_ group: RecordingGroup) async {
        var queue = PlayQueue()
        guard let first = queue.start(group) else { return }
        log("playback", "play all \(group.uri): \(group.chips.count) parts")
        selectedPartURI = first
        playQueue = queue
        await startPlayback(first)
    }

    /// Plays one part through the daemon's speakers (`Control.StartPlayback` on
    /// `ley://recordings/<id>/<part>`). The live channel's sink is detached meanwhile and attached
    /// again when the clip ends, so the clip is heard alone; one playback at a time, so a clip
    /// already playing is stopped first, and a clip replays from its start. A Play all in
    /// progress is ended: this part is the one asked for. `row` is the start of the log row whose
    /// ▶ was clicked (`playingRowStart`), nil from anywhere else.
    func play(partURI uri: String, row: Leyline_V1_SampleTime? = nil) async {
        playQueue.clear()
        await startPlayback(uri, row: row)
    }

    /// `play(partURI:)` without touching Play all's queue, which `playAll` and `endPlayback`
    /// have set for the parts after this one.
    private func startPlayback(_ uri: String, row: Leyline_V1_SampleTime? = nil) async {
        guard let daemon else { return }
        if let old = playbackID {
            // Cleared first, so the old one's tombstone is not read as this one ending.
            playbackID = nil
            var stop = Leyline_V1_StopPlaybackRequest()
            stop.playbackID = old
            _ = try? await daemon.control.stopPlayback(stop)
            log("playback", "\(old) stopped for \(uri)")
        } else if playingURI == nil {
            reattachAfterPlayback = sink != nil
        }
        playingURI = uri
        playingRowStart = row
        if let s = sink {
            var detach = Leyline_V1_DetachSinkRequest()
            detach.sinkID = s.sinkID
            do {
                _ = try await daemon.control.detachSink(detach)
                log("playback", "live sink \(s.sinkID) detached for the clip")
            } catch {
                log("playback", "live sink \(s.sinkID) not detached: \(LeylineError(error))")
            }
        }
        var req = Leyline_V1_StartPlaybackRequest()
        req.resourceUri = uri
        do {
            let pb = try await daemon.control.startPlayback(req)
            playbackID = pb.playbackID
            playbackSeen = false
            playbackStartedAt = Date()
            log(
                "playback",
                "\(pb.playbackID) playing \(uri): \(pb.samples) frames at \(pb.sampleRate) Hz")
            // A clip so short that its tombstone was folded before `StartPlayback` answered is
            // never seen in the mirror, and a quiet daemon may send nothing else that would run
            // `followPlayback`: one check after the never-seen limit ends it.
            let id = pb.playbackID
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.neverSeenDropSeconds + 0.1))
                guard let self, self.playbackID == id else { return }
                self.followPlayback()
            }
        } catch {
            let e = LeylineError(error)
            log("playback", "\(uri) not played: \(e.code) \(e.message)")
            notice = "Could not play the part: \(e.message.isEmpty ? e.code : e.message)"
            playingURI = nil
            playingRowStart = nil
            playQueue.clear()
            await attachAfterPlayback()
        }
    }

    /// Stops the window's clip, and a Play all with it; its tombstone ends it here and attaches
    /// the live sink again.
    func stopPlayback() async {
        playQueue.clear()
        guard let daemon, let id = playbackID else { return }
        var req = Leyline_V1_StopPlaybackRequest()
        req.playbackID = id
        do {
            _ = try await daemon.control.stopPlayback(req)
            log("playback", "\(id) stopped")
        } catch {
            log("playback", "\(id) not stopped: \(LeylineError(error))")
        }
    }

    /// The playback's tombstone (or a playback the mirror never carried within 3 s) ends the
    /// clip: the row loses its stop glyph and the live sink comes back.
    private func followPlayback() {
        guard let id = playbackID else { return }
        if state.playbacks.contains(where: { $0.playbackID == id }) {
            playbackSeen = true
            return
        }
        guard
            playbackSeen || Date().timeIntervalSince(playbackStartedAt) > Self.neverSeenDropSeconds
        else { return }
        endPlayback(id)
    }

    /// A clip ended. During Play all the next part starts at once and the live sink stays
    /// detached between parts, so the channel is not heard in the gaps; `playingURI` is held on
    /// the next part meanwhile, which keeps `reattachAfterPlayback` for the end of the last one.
    private func endPlayback(_ id: String) {
        guard playbackID == id else { return }
        log("playback", "\(id) ended")
        playbackID = nil
        playbackSeen = false
        playingRowStart = nil
        var queue = playQueue
        if let next = queue.next() {
            playQueue = queue
            playingURI = next
            selectedPartURI = next
            log("playback", "play all: \(next) next, \(queue.pending.count) after it")
            Task { await startPlayback(next) }
            return
        }
        playQueue = queue
        playingURI = nil
        Task { await attachAfterPlayback() }
    }

    /// `Resources.DeleteResource` on the whole recording (8c, "The inspector, on a part"): the
    /// daemon refuses one whose job runs and stops a playback of its parts first, so the clip's
    /// tombstone ends it here as a stop would. On success the listing is read again, which
    /// forgets the recording's manifest and clears the selection (`prunePage`).
    func deleteRecording(uri: String) async {
        guard let daemon else { return }
        if playQueue.holds(recordingURI: uri) { playQueue.clear() }
        var ref = Leyline_V1_ResourceRef()
        ref.uri = uri
        do {
            let gone = try await daemon.resources.deleteResource(ref)
            log("record", "deleted \(gone.uri): \(gone.freedBytes) bytes freed")
            if let sel = selectedPartURI, RecordingPartRef(uri: sel)?.recordingURI == uri {
                selectedPartURI = nil
            }
            reloadRecordings()
        } catch {
            let e = LeylineError(error)
            log("record", "\(uri) not deleted: \(e.code) \(e.message)")
            notice = "Could not delete the recording: \(e.message.isEmpty ? e.code : e.message)"
        }
    }

    /// The page's Tune: back to the Radio and tuned to the channel, by the path a bookmark
    /// click takes (`tune(bookmark:)`), which opens the band that holds the frequency when no
    /// radio is open and otherwise tunes the frequency and lets the band follow it, then applies
    /// the mode and the width of the channel's newest recording.
    func tune(recordingChannel c: RecordingChannel) {
        place = .radio
        let mode =
            c.mode == .unspecified ? Bands.defaultMode(at: c.frequencyHz, in: bands) : c.mode
        let width = Recordings.channelWidth(pageGroups(for: c), channel: c) ?? 0
        log("tune", "recording channel \(c.title) at \(c.frequencyHz) Hz")
        tune(
            bookmark: Bookmark(
                id: "", name: c.title, hz: c.frequencyHz, mode: mode, bandwidthHz: width))
    }

    // MARK: The Library's player

    /// The part the player shows and ▶ plays (docs/design/app-design-handoff-m3.md, "Decided
    /// 2026-09-25: the Library", "The player"): the one playing, else the selected part, else
    /// the page's first row, once the manifest that holds it has been read. nil leaves the
    /// player with nothing to play.
    var player: (uri: String, manifest: RecordingManifest, part: RecordingPart)? {
        let uri: String
        if let u = playingURI ?? selectedPartURI {
            uri = u
        } else if let c = selectedChannel, let first = pageDays(for: c).first?.rows.first {
            uri = first.uri
        } else {
            return nil
        }
        guard let ref = RecordingPartRef(uri: uri), let m = manifest(ofJob: ref.jobID),
            let part = m.parts.first(where: { $0.part == ref.part })
        else { return nil }
        return (uri, m, part)
    }

    /// A recording's manifest as the window has read it, for the channel page or for the tuned
    /// channel, which is where a kept row's ▶ in the Radio plays from.
    private func manifest(ofJob id: String) -> RecordingManifest? { manifests[id] }

    /// What the player calls the channel a recording belongs to: its Library row's title (the
    /// bookmark's name, else the frequency), else the frequency.
    func channelTitle(of manifest: RecordingManifest) -> String {
        recordingChannels.first { c in c.recordings.contains { $0.jobID == manifest.jobID } }?
            .title ?? Frequency.format(manifest.frequencyHz)
    }

    /// Whether ⏮ (`-1`) or ⏭ (`1`) has a part to go to in the player's recording.
    func canStepPart(_ step: Int) -> Bool {
        guard let p = player else { return false }
        return Recordings.neighbourPart(of: p.uri, in: p.manifest, step: step) != nil
    }

    /// ⏮ and ⏭, ← and → in the Library: the previous or next part of the player's recording.
    /// While a part plays it is stopped and the neighbour started, and a Play all walks on from
    /// the neighbour; with nothing playing the neighbour is selected, so the inspector and the
    /// player show it, and ▶ plays it. Nothing happens at the ends.
    func stepPart(_ step: Int) async {
        guard let p = player,
            let n = Recordings.neighbourPart(of: p.uri, in: p.manifest, step: step)
        else { return }
        selectedPartURI = n
        guard playingURI != nil else { return }
        log("playback", "player: \(step < 0 ? "previous" : "next") part \(n)")
        if let q = playQueue.recordingURI, let ref = RecordingPartRef(uri: n),
            q == ref.recordingURI,
            let summary = recordings.first(where: { $0.jobID == ref.jobID })
        {
            let running = state.jobs.contains { $0.jobID == ref.jobID && $0.isActive }
            var queue = PlayQueue()
            let group = RecordingGroup(summary: summary, manifest: p.manifest, running: running)
            if let first = queue.start(group, at: n) {
                playQueue = queue
                await startPlayback(first)
                return
            }
        }
        await play(partURI: n)
    }

    /// The player's circle, and space in the Library (10a): while a playback exists, ⏸ pauses it
    /// and ▶ resumes it (`SetPlaybackPaused`, the position held); with none, ▶ plays the
    /// player's part and selects it. Between a part's `StartPlayback` and its answer there is a
    /// part but no playback yet, and the click does nothing rather than start it twice.
    func togglePlayer() async {
        if playback != nil {
            await pausePlayback(!isPaused)
            return
        }
        guard playingURI == nil, let p = player else { return }
        selectedPartURI = p.uri
        await play(partURI: p.uri)
    }

    /// Whether the window's playback is paused, from the mirror's `Playback.paused`: the row, the
    /// player and the menu read it, so a pause from `ley play` on the same playback shows here.
    var isPaused: Bool { playback?.paused ?? false }

    /// `Control.SetPlaybackPaused` on the window's playback: the daemon holds the position and
    /// publishes the playback with `paused`, which is what the window renders; the live channel
    /// stays held silent, since the part has not ended. A refusal is a notice.
    func pausePlayback(_ paused: Bool) async {
        guard let daemon, let id = playbackID else { return }
        var req = Leyline_V1_SetPlaybackPausedRequest()
        req.playbackID = id
        req.paused = paused
        do {
            _ = try await daemon.control.setPlaybackPaused(req)
            log("playback", "\(id) \(paused ? "paused" : "resumed")")
        } catch {
            let e = LeylineError(error)
            log("playback", "\(id) not \(paused ? "paused" : "resumed"): \(e.code) \(e.message)")
            notice =
                "Could not \(paused ? "pause" : "resume") the part: \(e.message.isEmpty ? e.code : e.message)"
        }
    }

    /// Space from the menu bar: the player's ▶/⏸ in the Library, Mute/Unmute in the Radio. The
    /// Tune menu's space and the Library menu's are one key; each item is disabled in the other
    /// place, and because a Commands body is not guaranteed to re-evaluate when `place`
    /// changes, whichever item fires does what the place showing means (`LeylineApp.swift`).
    func pressSpace() {
        if place == .library {
            if TextFieldKeys.forward(.space) { return }
            Task { await togglePlayer() }
        } else {
            Task { await toggleMute() }
        }
    }

    /// ← and → from the menu bar: the previous and next part in the Library, the band's step in
    /// the Radio (see `pressSpace`).
    func pressArrow(_ direction: Int) {
        if place == .library {
            if TextFieldKeys.forward(direction < 0 ? .leftArrow : .rightArrow) { return }
            Task { await stepPart(direction) }
        } else {
            step(direction)
        }
    }

    /// The live sink back on the tuned channel, when it was attached before the clip.
    private func attachAfterPlayback() async {
        guard reattachAfterPlayback else { return }
        reattachAfterPlayback = false
        guard let ch = channel else { return }
        do {
            try await ensureSink(on: ch)
            log("playback", "live sink attached again")
        } catch {
            lastError = LeylineError(error)
        }
    }

    /// A kept row's context menu, the part inspector and the channel summary: the file of a
    /// part, or a recording's directory, selected in Finder, found through `ResolveLocalPath` of
    /// its URI.
    func revealInFinder(uri: String) async {
        guard let path = await localPath(uri) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        log("record", "revealed \(path)")
    }

    /// File ▸ Show Recordings in Finder: the store's directory, found through the path of any
    /// recording the daemon lists, else the daemon's default store on macOS when it exists.
    func showRecordingsInFinder() async {
        let dir: URL
        if let uri = await anyRecordingURI(), let path = await localPath(uri) {
            dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let store = home.appendingPathComponent(Self.defaultRecordingsPath)
            guard FileManager.default.fileExists(atPath: store.path) else {
                notice =
                    "Nothing has been recorded yet. Record Transmissions (⌘R) records the tuned channel."
                return
            }
            dir = store
        }
        NSWorkspace.shared.open(dir)
        log("record", "opened \(dir.path)")
    }

    /// The first recording `ListResources(RECORDING)` lists, or nil with none.
    private func anyRecordingURI() async -> String? {
        guard let daemon else { return nil }
        var req = Leyline_V1_ListResourcesRequest()
        req.kind = .recording
        do {
            return try await daemon.resources.listResources(req).resources.first?.uri
        } catch {
            log("record", "recordings not listed: \(LeylineError(error))")
            return nil
        }
    }

    /// The daemon's store under the home directory on macOS (docs/design/recording.md, "Files");
    /// `leylined --recordings` moves it, which is why a recording's own path is tried first.
    static let defaultRecordingsPath = "Library/Application Support/Leyline/recordings"

    /// `ResolveLocalPath`, with a refusal shown as a notice.
    private func localPath(_ uri: String) async -> String? {
        guard let daemon else { return nil }
        var ref = Leyline_V1_ResourceRef()
        ref.uri = uri
        do {
            let local: Leyline_V1_LocalPath = try await daemon.resources.resolveLocalPath(ref)
            return local.path
        } catch {
            let e = LeylineError(error)
            log("record", "\(uri) not resolved: \(e.code) \(e.message)")
            notice = e.message.isEmpty ? e.code : e.message
            return nil
        }
    }

    // MARK: Moving the radio over a recording

    /// A move of the radio that would leave a record job's frequency outside the capture, until
    /// it is answered (M3 handoff, 8b, "Tuning while recording"). The daemon never refuses the
    /// move: it degrades the job and records the gap, so the window asks first, as `ley tune`
    /// refuses without `--retune`.
    struct RetuneQuestion: Identifiable {
        let id = UUID()
        /// `Recordings.retuneWords`: the job named and the gap the move would leave.
        let words: String
        /// The button that goes ahead: `Move anyway` before a move, `Sweep anyway` before Find
        /// active, which hops the radio across the band (R20).
        let proceedLabel: String
        let proceed: @MainActor () -> Void
        let cancel: @MainActor () -> Void
    }

    private(set) var retuneQuestion: RetuneQuestion?

    /// The question for moving the capture to `centre` at `rate`, or nil when every recording on
    /// it stays inside (or none runs): tuning inside the span never asks.
    private func leftOutWords(centre: Int64, rate: UInt64) -> String? {
        guard let cap = capture, rate > 0 else { return nil }
        let half = Int64(rate / 2)
        let span = UInt64(max(0, centre - half))...UInt64(max(0, centre + half))
        return Recordings.retuneWords(
            jobs: Recordings.leftOut(capture: cap.captureID, movingTo: span, in: state))
    }

    private func ask(
        _ words: String, before what: String, proceedLabel: String = "Move anyway",
        proceed: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void = {}
    ) {
        log("record", "asked before \(what): \(words)")
        retuneQuestion = RetuneQuestion(
            words: words, proceedLabel: proceedLabel, proceed: proceed, cancel: cancel)
    }

    /// The alert's buttons: Move anyway performs the move, Cancel leaves the radio where it is.
    func answerRetune(moveAnyway: Bool) {
        guard let q = retuneQuestion else { return }
        retuneQuestion = nil
        log("record", moveAnyway ? "moved anyway" : "move cancelled; the radio stays")
        if moveAnyway { q.proceed() } else { q.cancel() }
    }

    /// Logs one line when the waterfall's empty-state message or the out-of-capture message
    /// changes or clears.
    private func logShownWords() {
        let empty = emptyWords.map { "\($0.headline). \($0.detail)" }
        if empty != shownEmptyWords {
            shownEmptyWords = empty
            log("shown", empty.map { "words: \($0)" } ?? "words cleared")
        }
        let out = outOfCaptureWords
        if out != shownOutOfCapture {
            shownOutOfCapture = out
            log("shown", out.map { "out of capture: \($0)" } ?? "out of capture cleared")
        }
    }
}

extension FailureState {
    /// The case without its numbers, for telling a re-measurement from a change.
    fileprivate var kind: Int {
        switch self {
        case .clipping: return 0
        }
    }
}

extension LeylineError {
    static let notDialled = LeylineError(code: "UNAVAILABLE", message: "The daemon is not dialled")
}

/// The window's two places (docs/design/app-design-handoff-m3.md, "Decided 2026-09-25: the
/// Library"): Radio is the live window, the Library what has been kept. Presentation only; the
/// radio runs the same in both.
enum WindowPlace: String, CaseIterable, Identifiable {
    case radio
    case library

    var id: String { rawValue }
    var title: String { self == .radio ? "Radio" : "Library" }
    /// ⌘1 and ⌘2, the View menu's items and the switch's tooltip.
    var shortcut: Character { self == .radio ? "1" : "2" }
}
