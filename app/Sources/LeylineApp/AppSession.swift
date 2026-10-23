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

    // The daemon's launch agent, which the distributed bundle carries (`DaemonAgent`).
    /// What `SMAppService` reported at launch, read again while the daemon cannot be reached;
    /// nil when this run touches no agent (`LEYLINE_SOCKET` set).
    private(set) var agentStatus: DaemonAgent.Status?
    /// An update is installed, but a job was running when the app connected, so the daemon still
    /// runs the old build: the window shows `DaemonAgent.updatedWords` and a Restart button.
    private(set) var engineUpdatePending = false
    /// The app restarted the daemon this launch; it does not do it twice (`DaemonAgent.afterConnect`).
    @ObservationIgnored private var engineRestarted = false

    // The window's own selection: which capture it shows and which channel it plays. Ids only;
    // the objects are always read back from `state`, or from the RPC's copy until the mirror
    // carries them (`HeldObject`).
    private var heldCapture = HeldObject<Leyline_V1_Capture>()
    private var heldChannel = HeldObject<Leyline_V1_Channel>()
    var captureID: String? { heldCapture.id }
    var channelID: String? { heldChannel.id }
    /// The follow rule: another client's channel on this capture becomes the window's
    /// (`ChannelFollow`). Not observed: every tune moves its floor, and what a view reads from it
    /// (`followKeptWords`) changes only inside `mirrorChanged`, beside `state`, which is.
    @ObservationIgnored private var follow = ChannelFollow()
    /// The sink this window attached, held as the capture and channel are: a `Sink` names no
    /// owner, and after a follow another client's sink may play the held channel, which mute,
    /// volume, a sweep and a part's playback must never detach or change.
    private var heldSink = HeldObject<Leyline_V1_Sink>()
    /// The window's volume, given to every sink it attaches, so an unmute or a follow does not
    /// come back at full volume.
    @ObservationIgnored private var volume: Double = 1
    /// Whether the person muted the window: the intent, set by `toggleMute` and cleared by any
    /// attach, because no sink also means a channel playing through another client's, a part
    /// playing, or a channel just reconnected to. A follow, a reconnect and the settle timer
    /// attach nothing while it holds.
    @ObservationIgnored private var muted = false
    /// An attach in flight: a second would make a second sink, since the first's reply has not
    /// set `heldSink` yet.
    @ObservationIgnored private var attachingSink = false
    /// Sinks of the window's own being detached, so a fold does not ask twice.
    @ObservationIgnored private var detachingSinks: Set<String> = []
    /// The mirror's snapshot count last seen: a new snapshot (a connect, or a resync after a seq
    /// gap, which may be a restarted daemon counting from 0) resets the follow floor.
    @ObservationIgnored private var snapshotsSeen = 0
    private(set) var selectedBandID: String?
    private var adopted = false
    /// The frequency this app last asked for, until the daemon confirms it or two seconds pass:
    /// what the field shows and what a step is taken from, so two quick presses do not both
    /// start from the frequency before the first (`../dev/app.md`: a view previews its own
    /// writes and reconciles on the event).
    private(set) var requestedHz: UInt64?
    /// The clock that clears `requestedHz`, because a write the daemon never confirms leaves the
    /// field showing a frequency nothing is tuned to until the next event, and a quiet daemon
    /// sends none.
    private var requestedExpiry: Task<Void, Never>?
    /// The centre write not yet confirmed by the capture's event, and the move waiting behind
    /// it (`RetuneQueue`). No view reads it, so it is not observed.
    private let retunes = RetuneQueue()
    private var creatingChannel = false
    private var lastPan = Date.distantPast
    /// Where a rail drag is taking the centre, until the capture's event carries it: the rail
    /// draws its pill there so the region tracks the drag instead of lagging one event behind.
    private(set) var panCentre: Int64?

    // Files both clients own. `bands` is the part table, which every lookup below keeps reading
    // (`band(containing:)`, `defaultMode`, `tune(bookmark:)`, the last-band adoption): none of
    // them ever answers a group. `sidebarRows` is the fold the sidebar and
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

    /// A staged run for the site's screenshots (`Staging.swift`), or nil. While set, the
    /// session writes nothing to UserDefaults and does not reopen the remembered band, so a shot
    /// neither changes nor depends on what the person last used.
    #if LEYLINE_STAGING
        let staging = Staging.fromEnvironment()
        private var unstaged: Bool { staging == nil }
    #else
        private var unstaged: Bool { true }
    #endif

    // View state local to the window: presentation only, never radio state.
    var maxHold = true
    /// The view's width as a zoom, a view tool or a stage set it; nil fits the band
    /// (`ViewWindow.shown`). Picking a band puts it back to nil.
    private(set) var viewSpanHz: UInt64?
    /// Where a rail drag, a view tool, the edge marker or a tune outside the view put the view's
    /// centre; nil centres it on the band it fits, else on the tuned frequency.
    private(set) var viewCentreHz: UInt64?
    /// The tuned frequency the view last followed (`keepView`), so only a change of it moves the
    /// view.
    private var viewTunedHz: UInt64?
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
    /// Whether the inspector is on the window's right. Remembered in the defaults under
    /// `inspectorShownKey`, the way the last band is; shown until someone closes it, because the
    /// default window is sized with it.
    var inspectorShown =
        UserDefaults.standard.object(forKey: AppSession.inspectorShownKey) as? Bool
        ?? true
    {
        didSet {
            if unstaged {
                UserDefaults.standard.set(inspectorShown, forKey: Self.inspectorShownKey)
            }
            // The audio ladder subscribes only while the panel draws it.
            followAudioLevels()
        }
    }
    /// Which of the window's two places shows, the toolbar's `Radio | Library`. The live radio keeps running in the Library: its channel, sink and
    /// subscriptions are the session's, not the Radio body's. Remembered in the defaults under
    /// `placeKey`, the way `inspectorShown` is. Arriving in the Library selects its first channel
    /// when none is selected, so the centre is never blank.
    var place =
        UserDefaults.standard.string(forKey: AppSession.placeKey)
        .flatMap(WindowPlace.init(rawValue:)) ?? .radio
    {
        didSet {
            if unstaged { UserDefaults.standard.set(place.rawValue, forKey: Self.placeKey) }
            guard place != oldValue else { return }
            log("session", "place: \(place.rawValue)")
            if place == .library { selectFirstChannel() }
            followPage()
            // The audio ladder is drawn only by the Radio's inspector.
            followAudioLevels()
        }
    }
    /// Whether the assistant's panel is on the window's right, beside the inspector. Remembered
    /// in the defaults under `assistantShownKey`, as `inspectorShown` is; hidden until someone
    /// opens it, and drawn only while `hasAnyAI` holds (`assistantPanelShown`).
    var assistantShown =
        UserDefaults.standard.object(forKey: AppSession.assistantShownKey) as? Bool ?? false
    {
        didSet {
            if unstaged {
                UserDefaults.standard.set(assistantShown, forKey: Self.assistantShownKey)
            }
        }
    }
    /// What is typed in the assistant's field and not sent yet. Held here rather than in the
    /// field's own state, so it outlives the field being made again: once a question card was
    /// answered the field showed the text while its state had lost it, and Return sent nothing.
    var assistantDraft = ""
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
    /// rule the sidebar's filter uses. Typing puts the highlight back on the
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
    /// The Settings window's one line about the last key or model write: what the provider said
    /// about a key, or why a write failed. Its own line rather than `notice`, which shows over the
    /// main window's waterfall where a person in Settings would not see it; logged the same way.
    private(set) var settingsNotice: String? {
        didSet {
            if let n = settingsNotice, n != oldValue { log("shown", "settings: \(n)") }
        }
    }
    // The assistant (`AssistantController`): the conversation this window started, copied out
    // of the controller on every change as `state` is copied out of the mirror.
    @ObservationIgnored private var assistant: AssistantController?
    /// The conversation as the daemon last sent it, or nil before the first message and after
    /// New Conversation.
    private(set) var conversation: Leyline_V1_Conversation?
    /// Why the last start, message or answer failed, or that the daemon forgot the conversation.
    private(set) var assistantNotice: AssistantNotice? {
        didSet {
            if let n = assistantNotice, n != oldValue { log("shown", "assistant: \(n.text)") }
        }
    }
    /// A start or a message is on its way, and the field waits.
    private(set) var assistantSending = false
    /// The daemon no longer knows the conversation shown; only a new one can follow.
    private(set) var assistantLost = false
    /// The empty-state and out-of-capture messages last logged, so a change logs one line.
    private var shownEmptyWords: String?
    private var shownOutOfCapture: String?
    /// The problem the radio's level shows, or nil (`FailureState`): folded through
    /// `failureHold` on every `CaptureLevel` reading and on every mirror change (the gains pick
    /// the words), and logged when it is raised and when it clears. While it holds the device
    /// chip's dot is `caution` with the sentence as its tooltip and the gain slider's knob is
    /// `recording`; there is no close control, because it goes when the level clears.
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

    // Recording. The jobs and the playbacks are the mirror's; what is here is
    // the store's listing, the manifests of the recordings the window shows as read from disk, and
    // the switch's click until its job's event arrives.
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
    /// once and a switch seen grey can be explained from the log.
    @ObservationIgnored private var recordSwitchLogged: String?
    /// The tuned log's frequency and mode and the record job running there, as the last mirror
    /// change left them, so `markRecordToggles` cuts the log when the job starts or ends.
    @ObservationIgnored private var recordMarkSeen: (key: TransmissionLogs.Key, jobID: String?)?
    /// The record jobs either switch started, until each ends: `StartJob` answers before the
    /// radio is allocated, so a decline arrives as the job's FAILED event and is shown from
    /// there (`Recordings.failureNotice`).
    @ObservationIgnored private var switchStartedJobs: Set<String> = []
    /// Manifests by job id, read through `ResolveLocalPath`: every recording of the channel page's
    /// channel and every recording on the tuned frequency and mode, whose parts the log's kept rows
    /// and the time gutter's bars come from (`tunedManifests`). Each is kept while the listing
    /// holds the recording, read once, and read again on each event of its job, which is how a
    /// running card grows and a new row is kept as parts land.
    private(set) var manifests: [String: RecordingManifest] = [:] {
        didSet { forgetSpeech(changedIn: oldValue, manifests) }
    }
    @ObservationIgnored private var manifestLoads: [String: Task<Void, Never>] = [:]
    /// Job ids whose manifest a job event made stale.
    @ObservationIgnored private var staleManifests: Set<String> = []
    /// Job ids whose read failed, not tried again until their job changes or the listing is read
    /// again: a mirror change arrives four times a second while a part plays.
    @ObservationIgnored private var failedManifests: Set<String> = []
    /// The part the Library's inspector and player show: the last row clicked, and
    /// the part Play all or Play day moved on to. Cleared when its recording is deleted. Another
    /// part clears `selectedOver`.
    var selectedPartURI: String? {
        didSet { if selectedPartURI != oldValue { selectedOver = nil } }
    }
    /// The EARLIER days (older than `Recordings.collapseAfterDays`) opened in place by a click,
    /// by `DayRows.id`. Presentation only.
    var openedDays: Set<String> = []
    /// Each Library row's level graph (`LevelGraph.columns`), by part URI, once read: the part's
    /// WAV through `ResolveLocalPath`, one pass, off the main actor. An empty array is a part whose
    /// file could not be read here (a remote daemon, a file gone), not tried again.
    private(set) var levelGraphs: [String: [Float]] = [:]
    @ObservationIgnored private var levelGraphLoads: Set<String> = []
    /// The playback this window started, the part it plays and Play all's or Play day's parts
    /// still to play (`PartPlayback`). Its position is the mirror's: the daemon publishes a
    /// playing playback four times a second.
    private var partPlayback = PartPlayback()
    private var playbackID: String? { partPlayback.playbackID }
    var playingOver: Int? { partPlayback.playingOver }
    /// Speech lines by recording id, from the daemon's speech records (`SpeechRecords.byRecording`),
    /// read for each recording on the channel page and, while the search field holds words, for
    /// every recording listed; read again on each event of a transcription of the recording.
    private(set) var speechLines: [String: [SpeechLine]] = [:] {
        didSet { forgetSpeech(changedIn: oldValue, speechLines) }
    }
    /// Recordings whose last speech read the daemon cut at the query's limit: their lines are
    /// kept and the page says more were not loaded.
    private(set) var speechTruncated: Set<String> = []
    /// The read in flight for each recording, by a token that one read shares across the
    /// recordings it covers; a result is applied only to recordings still waiting on it.
    @ObservationIgnored private var speechLoads: [String: UUID] = [:]
    /// Recordings whose speech read failed, not read again until the listing is read again: a
    /// mirror change arrives four times a second while a part plays.
    @ObservationIgnored private var failedSpeech: Set<String> = []
    /// Recordings a transcription event asked to read again while a read was in flight.
    @ObservationIgnored private var staleSpeech: Set<String> = []
    /// `RecordingSpeech` per recording, built once and dropped when its lines or its manifest
    /// change (`forgetSpeech`), so a render of the page or the search does not rebuild it.
    @ObservationIgnored private var speechCache: [String: RecordingSpeech] = [:]
    /// The transcription jobs as last seen, so a change to one reads its recording's speech again.
    @ObservationIgnored private var transcriptionsSeen: [Leyline_V1_Job] = []
    /// The speech decoder as `ListDecoders` lists it, nil until read or when none is installed.
    private(set) var speechDecoder: Leyline_V1_DecoderManifest?
    @ObservationIgnored private var speechDecoderRead = false
    /// The over the search or a speech line's click selected in `selectedPartURI`, for the page
    /// to scroll to and mark. Presentation only.
    var selectedOver: Int?
    /// Transcribe's question while its dialog is up: the recording, the question's words, and the
    /// model "Transcribe again…" chose (empty: the speech feature's own).
    var transcribeAsk: TranscribeAsk?
    /// The recording whose Transcribe again sheet is up, or nil. Presentation only.
    var transcribeAgainFor: String?
    var playingURI: String? { partPlayback.playingURI }
    var playingRowStart: Leyline_V1_SampleTime? { partPlayback.playingRowStart }
    var playQueue: PlayQueue { partPlayback.queue }
    /// Set by Stop listening: the window adopts nothing until a band or a frequency is picked,
    /// or the next snapshot would put a capture back.
    private var listeningStopped = false

    private static let lastBandKey = "lastBand"
    /// The capture rate the window opens a radio at, 2.4 MSPS, until the device menu's picker
    /// sets another, which is remembered. The radio's setting, not the band's: a band change
    /// never moves it.
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
    private static let assistantShownKey = "assistantShown"

    // MARK: Derived

    var capture: Leyline_V1_Capture? { heldCapture.current { state.capture($0) } }
    var channel: Leyline_V1_Channel? { heldChannel.current { state.channel($0) } }
    var device: Leyline_V1_DeviceDescriptor? { capture.flatMap { state.device($0.deviceID) } }
    /// The window's own sink on the held channel; nil when it has none there, even while
    /// another client's sink plays the channel (`audioElsewhere`).
    var sink: Leyline_V1_Sink? {
        guard let channelID,
            let s = heldSink.current({ id in state.sinks.first { $0.sinkID == id } }),
            s.channelID == channelID
        else { return nil }
        return s
    }
    /// "The audio plays through another terminal.": another client's sink plays the held
    /// channel and the window has none, so mute and volume have nothing of the window's to act
    /// on.
    var audioElsewhere: String? {
        ChannelFollow.playsThroughWords(
            in: state, held: channelID, windowSinkID: heldSink.id,
            selfClientID: daemon?.identity.id ?? "")
    }
    var tunedHz: UInt64? { channel.flatMap { state.frequencyHz(of: $0) } }
    /// The frequency to show: the one asked for while it is in flight, else the daemon's.
    /// While a sweep borrows the radio there is no channel, and the field keeps showing the
    /// frequency the window paused on rather than going blank.
    var displayHz: UInt64? { requestedHz ?? tunedHz ?? (sweeping ? sweep?.paused?.hz : nil) }
    /// The transport bar's speaker: muted is no sink on the channel (the daemon has no mute), and
    /// the channel, its squelch and the meter carry on.
    var isMuted: Bool { sink == nil && audioElsewhere == nil }
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
    /// The tone heard on the tuned frequency since the tune, shown beside the bookmark's own
    /// tone as `heard PL 100.0` and never called a mismatch, because a repeater's output tone
    /// is not its input tone (docs/design/channels.md, "Bookmarks gain three fields"); nil
    /// when none was reported.
    var heardTone: SubAudibleTone? { transmissions?.heardTone(since: telemetry.tunedAt) }
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

    /// The channel's power over `channelFloorDB`, the band's floor at the channel's width, so a
    /// carrier that never stops reads its level over the noise rather than over itself. Nil
    /// until the floor is known.
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

    /// The radio whose tuning range applies: the capture's device, else the first connected one,
    /// with the span its capture holds now. A file radio's range is its recorded centre alone,
    /// and a band elsewhere in the capture is heard all the same: without the span, the tuned
    /// band of a wide recording was folded away as one the radio cannot tune.
    private var radioRanges: [Leyline_V1_FrequencyRange] {
        guard let radio = device ?? state.devices.first(where: { $0.state != .disconnected })
        else { return [] }
        var ranges = radio.tuningRanges
        // No range means every band is offered; a span would narrow that. Every capture on
        // the radio counts, as after Stop Listening the window holds none.
        guard !ranges.isEmpty else { return ranges }
        for cap in state.captures where cap.deviceID == radio.deviceID && cap.sampleRate > 0 {
            let span = ViewWindow.span(centerHz: cap.centerHz, sampleRate: cap.sampleRate)
            ranges.append(
                .with {
                    $0.minHz = span.lowerBound
                    $0.maxHz = span.upperBound
                })
        }
        return ranges
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

    /// Whether a sidebar row shows its contents: the tuned row always, the one opened by its
    /// chevron, and the one being swept, whose words and Stop are under its item while the
    /// sweep holds the radio and nothing is tuned.
    func isExpanded(_ row: Band) -> Bool {
        row.id == tunedRow?.id || row.id == expandedBandID
            || (sweeping && row.id == sweepRow?.id)
    }

    /// The chevron: opens or closes a row without tuning. The tuned row stays open.
    func toggleExpanded(_ row: Band) {
        guard row.id != tunedRow?.id else { return }
        expandedBandID = expandedBandID == row.id ? nil : row.id
    }

    /// What a tune into `row` closes: a row opened by its chevron elsewhere, the out-of-range
    /// line's rows, and the last sweep's hits when they belong to another row. The only
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
        // The sidebar filter's rule, from the library so the two agree.
        let key = Plans.presetKey(pickerQuery)
        guard !key.isEmpty else { return plan }
        return plan.filter { channel in
            Plans.presetKey(channel.name).hasPrefix(key)
                || channel.aliases.contains { Plans.presetKey($0).hasPrefix(key) }
        }
    }

    /// The band the sidebar highlights: the chosen one, else the one the tuned frequency lies in.
    /// Selection reflects state rather than causing it: the band is the one
    /// the tuned frequency is in, and the clicked one only breaks a tie between overlapping bands
    /// or stands in before anything is tuned.
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
    /// The sentence under the inspector's tone field after a tone the store refused
    /// (`ToneError.sentence`), until a tone is accepted, the field puts the saved tone back, or
    /// the tuned frequency changes; `toneErrorHz` is the frequency it was typed on.
    private(set) var toneError: String?
    private var toneErrorHz: UInt64?
    /// Set by `tune(bookmark:)` for the tune it starts, so the band-follow rule does not write
    /// the band's mode over the bookmark's: one write, the bookmark's.
    private var tuningBookmark = false

    // Scan band (docs/design/channels.md, "Scan the band"). The job is the
    // mirror's; what is here is which job the row started, what the window was listening to
    // when it paused for it, and the outcome the row shows once the job has ended.
    /// The sweep the band row started, or nil. Kept after the job ends, with its outcome, until
    /// the next sweep or the next tune into another row, because the row shows the hits,
    /// the empty line or the failure from it; a cancelled sweep is dropped at once.
    private(set) var sweep: SweepState?
    /// The action asked for while a sweep ran (a tune, or another row's Scan band), run once
    /// the job's terminal event has put the radio back. The latest one wins.
    @ObservationIgnored private var afterSweep: (@MainActor () -> Void)?

    /// Between Scan band and the channel and sink being back: no capture write leaves the
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

    /// The frequencies the spectrum and waterfall show, which the band rail draws as its thumb:
    /// the band fitted inside the capture until a zoom, a drag or a view tool chose otherwise,
    /// always inside the capture (`ViewWindow.shown`).
    var visibleRange: ClosedRange<UInt64>? {
        guard let cap = capture else { return nil }
        return ViewWindow.shown(
            centerHz: cap.centerHz, sampleRate: cap.sampleRate, bins: Self.viewBins,
            band: band.map { $0.minHz...$0.maxHz }, spanHz: viewSpanHz, centreHz: viewCentreHz,
            tunedHz: tunedHz)
    }

    /// The spectrum's bins, which set the narrowest view: the count the feed subscribes at and
    /// the daemon serves (`SpectrumFeed.bins`), read as a constant so the view does not follow
    /// every row.
    static let viewBins = Int(SpectrumFeed.bins)

    /// The band rail's ends: the band's; between bands, the capture's, so the rail still has
    /// ends to cross.
    var railRange: ClosedRange<UInt64>? {
        if let b = band { return b.minHz...b.maxHz }
        guard let cap = capture, cap.sampleRate > 0 else { return nil }
        return ViewWindow.span(centerHz: cap.centerHz, sampleRate: cap.sampleRate)
    }

    /// The rail's thumb: the part of the view on the rail.
    var railThumb: ClosedRange<UInt64>? {
        railRange.flatMap { ViewWindow.thumb(visibleRange, on: $0) }
    }

    /// The side of the view the tuned channel lies off, for the spectrum's edge marker; nil while
    /// the view shows it.
    var tunedEdge: ViewWindow.Edge? { ViewWindow.edge(of: tunedHz, in: visibleRange) }

    /// The edge marker's words (`146.940 ▸`), or nil while the view shows the tuned channel.
    var edgeMarkerWords: String? {
        guard let e = tunedEdge, let hz = tunedHz else { return nil }
        return ViewWindow.edgeWords(e, hz: hz)
    }

    /// The span shown, and how far `+` and `−` can go from it.
    var viewSpan: UInt64? { visibleRange.map { $0.upperBound - $0.lowerBound } }
    var canZoomIn: Bool {
        guard let cap = capture, let s = viewSpan else { return false }
        return s > ViewWindow.narrowest(sampleRate: cap.sampleRate, bins: Self.viewBins)
    }
    var canZoomOut: Bool {
        guard let cap = capture, let s = viewSpan else { return false }
        return s < cap.sampleRate
    }

    /// The empty-state message, worded as in the guide, shown when there is nothing to draw.
    var emptyWords: (headline: String, detail: String)? {
        if let e = startupError { return ("Could not dial the daemon", e.message) }
        switch connection {
        case .idle, .connecting: return ("Connecting to leylined", socketPath)
        case .unavailable(let e, let retry):
            if let unreachable = emptyUnreachable {
                return DaemonAgent.unreachableWords(unreachable, retryIn: retry)
            }
            return (e.message, "Retrying in \(retry).")
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

    /// Which unreachable state the empty state shows while nothing answers on the socket, and so
    /// which button it offers (`DaemonAgent.unreachable`): `ley daemon start` for a daemon that is
    /// not the app's, Login Items when the app's agent is switched off there, a restart when it is
    /// on. Nil when the daemon answers or the failure is another one; a daemon that answers anyway
    /// (a source build's, started by hand) is used, and then nothing is said about the agent.
    var emptyUnreachable: DaemonAgent.Unreachable? {
        guard startupError == nil, case .unavailable(let e, _) = connection, e.daemonUnreachable
        else { return nil }
        return DaemonAgent.unreachable(agentStatus: agentStatus)
    }

    /// What the empty state's button does for `emptyUnreachable`.
    func runEmptyAction(_ unreachable: DaemonAgent.Unreachable) {
        switch unreachable {
        case .startByHand: break
        case .openLoginItems: openLoginItems()
        case .restartEngine: Task { await restartEngine() }
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard running == nil else { return }
        prepareAgent()
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
        if unstaged {
            selectedBandID = UserDefaults.standard.string(forKey: Self.lastBandKey)
        }
        do {
            let daemon = try DaemonConnection(identity: .fresh(kind: "app", label: "Leyline"))
            self.daemon = daemon
            socketPath = daemon.socketPath
            let mirror = DaemonMirror(connection: daemon)
            mirror.onChange = { [weak self] m in self?.mirrorChanged(m) }
            self.mirror = mirror
            self.writes = WriteCoalescer(connection: daemon)
            let assistant = AssistantController(calls: daemon)
            assistant.performer = self
            assistant.onChange = { [weak self] a in self?.assistantChanged(a) }
            assistant.log = { line in log("assistant", line) }
            self.assistant = assistant
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
        if m.snapshots != snapshotsSeen {
            // A replaced state: a restarted daemon counts its seq from 0 again, so the follow
            // floor becomes the snapshot's. `snapshots` is counted before the state is replaced.
            snapshotsSeen = m.snapshots
            follow.connected(atSeq: state.seq)
        }
        keepView()
        // The conversation's event, which the watch may not have delivered yet.
        if let id = assistant?.conversationID,
            let c = state.conversations.first(where: { $0.conversationID == id })
        {
            assistant?.absorb(c)
        }
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
                followUpdate()
            }
        }
        // Switched on or off in System Settings while the window waited: launchd starts or stops
        // the daemon, and the words and their button (Login Items, or a restart) follow now.
        if !isLive, agentStatus == .requiresApproval || agentStatus == .enabled {
            let now = EngineAgent.status()
            if now != agentStatus { agentStatus = now }
        }
        if let r = requestedHz, r == tunedHz { clearRequested() }
        // Objects the window pointed at may be gone: a tombstone, or the daemon restarted. One
        // that was never in the mirror goes the same way after 3 s, because the gap between an
        // RPC's response and its event closes in milliseconds and an object evicted inside it
        // has no event coming.
        if let id = captureID {
            // Folded on a copy, so a mirror change that alters nothing here is not a change to
            // anything a view reads.
            var folded = heldCapture
            let verdict = folded.observe(
                inMirror: state.capture(id) != nil, now: Date(),
                dropAfter: Self.neverSeenDropSeconds)
            if folded != heldCapture { heldCapture = folded }
            switch verdict {
            case .lost:
                log("session", "capture \(id) is gone; a new one will be made")
                dropCapture()
            case .neverArrived:
                log(
                    "session",
                    "the mirror has no capture \(id) 3 s after the window took it; a new one will be made"
                )
                dropCapture()
            case .waiting, .present:
                break
            }
        }
        if let id = channelID {
            // Folded on a copy, so a mirror change that alters nothing here is not a change to
            // anything a view reads.
            var folded = heldChannel
            let verdict = folded.observe(
                inMirror: state.channel(id) != nil, now: Date(),
                dropAfter: Self.neverSeenDropSeconds)
            if folded != heldChannel { heldChannel = folded }
            switch verdict {
            case .lost:
                log("session", "channel \(id) is gone")
                let followed = follow.lost(id)
                dropChannel()
                // Its maker ended the channel the window followed: the window makes its own
                // where it was, so the picture stays on the frequency.
                if let followed { Task { await listenOnOwn(like: followed) } }
            case .neverArrived:
                log("session", "the mirror has no channel \(id) 3 s after the window took it")
                dropChannel()
            case .waiting, .present:
                break
            }
        }
        if let id = heldSink.id {
            var folded = heldSink
            let verdict = folded.observe(
                inMirror: state.sinks.contains { $0.sinkID == id }, now: Date(),
                dropAfter: Self.neverSeenDropSeconds)
            if folded != heldSink { heldSink = folded }
            if verdict == .lost || verdict == .neverArrived { heldSink.drop() }
        }
        followOwnSinks()
        if case .live = connection {
            // A sweep with no capture opens the daemon's own; adopting it would put a channel
            // on a radio being swept.
            if !adopted, !listeningStopped, !sweeping { adopt() }
        } else {
            adopted = false
            var capturesCopy = heldCapture
            var channelsCopy = heldChannel
            var sinkCopy = heldSink
            capturesCopy.disconnected()
            channelsCopy.disconnected()
            sinkCopy.disconnected()
            if capturesCopy != heldCapture { heldCapture = capturesCopy }
            if channelsCopy != heldChannel { heldChannel = channelsCopy }
            if sinkCopy != heldSink { heldSink = sinkCopy }
        }
        followOtherClients()
        spectrum.follow(capture, connection: daemon)
        telemetry.follow(
            channelID, offsetHz: channel?.offsetHz, centerHz: capture?.centerHz,
            mode: channel?.mode, captureRate: capture?.sampleRate ?? 0, connection: daemon)
        if toneError != nil, tunedHz != toneErrorHz { clearToneError() }
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
        heldCapture.drop()
        adopted = false
        dropChannel()
    }

    private func dropChannel() {
        heldChannel.drop()
    }

    /// The frequency the field shows until the daemon confirms it, with the clock that clears it
    /// armed afresh: a tune whose event never arrives stops showing after two seconds rather
    /// than until the mirror happens to change.
    private func request(_ hz: UInt64) {
        requestedHz = hz
        follow.tuned(at: state.seq)
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
            heldCapture.adopted(id: cap.captureID, at: Date())
            if channelID == nil,
                let ch = ChannelFollow.adoptable(in: state, captureID: cap.captureID, except: nil)
                    ?? state.channels(in: cap.captureID).first
            {
                heldChannel.adopted(id: ch.channelID, at: Date())
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
        if captureID != nil, let daemon {
            // Back after a disconnect: when another client moved the radio or tuned while the
            // window was away, its own channel is gone or out of capture, and the newest channel
            // on the capture is taken as a follow takes one (`ChannelFollow.stepOnConnect`).
            let step = follow.stepOnConnect(
                in: state, captureID: captureID, held: channel, windowSinkID: heldSink.id,
                muted: muted, audioHeld: playbackID != nil, selfClientID: daemon.identity.id)
            if let step { perform(step, daemon: daemon, why: "on reconnecting") }
            return
        }
        guard captureID == nil else { return }
        // No radio yet (a daemon just started, still finding its devices): adopt again on the
        // next change, so the capture and channel that come with the radio are taken.
        guard hasRadio else {
            adopted = false
            return
        }
        let id = selectedBandID ?? "fm"
        if let b = bands.first(where: { $0.id == id }) ?? bands.first(where: { $0.id == "fm" }) {
            // A radio that cannot tune the band (a file radio before its playback opens a
            // capture) is waited for: the capture that comes is adopted on a later change.
            guard outOfRangeWords(b) == nil else {
                adopted = false
                return
            }
            Task { await select(band: b) }
        }
    }

    private var hasRadio: Bool { state.devices.contains { $0.state != .disconnected } }

    // MARK: Bands

    /// The band's centre and rate on the radio, its mode and width on the channel, a sink for
    /// audio, and a squelch measured from the floor. Creates what does not exist and writes what
    /// does. With `hz`, the band arrives tuned there rather than at its centre, and the capture
    /// sits where that frequency is inside it: a drag past the rail's end cap lands on the
    /// neighbour's near edge. A switch that would move the capture off a running recording asks
    /// first (`retuneQuestion`).
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
    /// takes a part and never a group.
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
        guard !busy, !sweeping, outOfRangeWords(band) == nil, let dev = try? pickDevice(),
            let cap = movableCapture(on: dev)
        else { return nil }
        let centre =
            hz.map { captureCentre(for: band, at: $0, rate: cap.sampleRate) } ?? band.centerHz
        return leftOutWords(centre: Int64(centre), rate: cap.sampleRate)
    }

    /// The capture a band change moves: the window's on that radio, else, while the window
    /// holds none (after Stop Listening), the one another client left on it, since a radio
    /// opens one capture and asking for a second is refused with `DEVICE_BUSY`.
    private func movableCapture(on dev: Leyline_V1_DeviceDescriptor) -> Leyline_V1_Capture? {
        if let cap = capture { return cap.deviceID == dev.deviceID ? cap : nil }
        return state.captures.first {
            $0.deviceID == dev.deviceID && $0.state == .captureActive
        }
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
        // Picking a band fits the view to it; a channel picked inside the band keeps the view.
        if hz == nil || band.id != self.band?.id { setView(spanHz: nil, centreHz: nil) }
        selectedBandID = band.id
        closeOpenedRows(tuning: Bands.group(of: band) ?? band)
        if unstaged { UserDefaults.standard.set(band.id, forKey: Self.lastBandKey) }
        lastError = nil
        log("session", "select band \(band.name)\(hz.map { " at \($0) Hz" } ?? "")")
        do {
            let dev = try pickDevice()
            if capture == nil, let other = movableCapture(on: dev) {
                heldCapture.adopted(id: other.captureID, at: Date())
                log(
                    "session",
                    "adopted capture \(other.captureID) for \(band.name): it holds the radio")
            }
            // The capture's rate is the radio's setting: an existing capture keeps its own, a
            // new one opens at the remembered rate. The band only decides where the span sits.
            let existing = capture.flatMap { $0.deviceID == dev.deviceID ? $0 : nil }
            let rate = existing?.sampleRate ?? preferredSampleRate(for: dev)
            let target = hz ?? band.centerHz
            let centre =
                hz == nil
                ? UInt64(max(0, clampCentre(Int64(band.centerHz), span: Int64(rate))))
                : captureCentre(for: band, at: target, rate: rate)
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
            if cap.centerHz != centerHz { writes.centerHz(centerHz, capture: cap.captureID) }
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
            writes.gain(g, capture: cap.captureID)
        }
        heldCapture.made(cap, id: cap.captureID, at: Date())
        dropChannel()
        return cap
    }

    private func ensureChannel(
        in cap: Leyline_V1_Capture, offsetHz: Int64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32
    ) async throws -> Leyline_V1_Channel {
        guard let daemon, let writes else { throw LeylineError.notDialled }
        if var ch = channel, ch.captureID == cap.captureID {
            await apply(mode: mode, bandwidthHz: bandwidthHz, to: ch)
            if ch.offsetHz != offsetHz { writes.offsetHz(offsetHz, channel: ch.channelID) }
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
        heldChannel.made(ch, id: ch.channelID, at: Date())
        follow.tuned(at: state.seq)
        return ch
    }

    private func ensureSink(on ch: Leyline_V1_Channel) async throws {
        guard let daemon else { throw LeylineError.notDialled }
        // The window's own sink, one on its way, or another client's: a second would echo.
        if attachingSink || sink != nil || state.plays(ch.channelID) { return }
        attachingSink = true
        defer { attachingSink = false }
        var req = Leyline_V1_AttachSinkRequest()
        req.channelID = ch.channelID
        req.sink.systemAudio = Leyline_V1_SystemAudioSink()
        req.sink.systemAudio.volume = volume
        do {
            let s = try await daemon.control.attachSink(req)
            heldSink.made(s, id: s.sinkID, at: Date())
            muted = false
        } catch {
            throw LeylineError(error)
        }
    }

    /// The window's own sinks it does not hold (the mirror names who attached each): one on the
    /// held channel is held again when none is, unless the window is muted, and every other is
    /// detached, since nothing else would ever mute it. Not while an attach is in flight, whose
    /// sink's event may come before its reply.
    private func followOwnSinks() {
        guard let me = daemon?.identity.id, isLive, !attachingSink else { return }
        if heldSink.id == nil, !muted,
            let own = ChannelFollow.ownSink(in: state, held: channelID, selfClientID: me)
        {
            log("session", "sink \(own) is the window's own; held again")
            heldSink.adopted(id: own, at: Date())
        }
        for id in ChannelFollow.strayOwnSinks(
            in: state, windowSinkID: heldSink.id, selfClientID: me)
        where !detachingSinks.contains(id) {
            log("session", "sink \(id) is the window's own and not held; detached")
            Task { await detachSink(id) }
        }
    }

    // MARK: Following another client's channel

    /// The follow rule over the latest mirror state (`ChannelFollow`): a channel another client
    /// made on this capture becomes the held channel, the window's own is ended unless a
    /// recording runs on it, and the window's audio moves with it. Not while the window is making
    /// a channel itself, sweeping, or stopped.
    private func followOtherClients() {
        guard let daemon, isLive, !busy, !creatingChannel, !sweeping, !listeningStopped else {
            return
        }
        let step = follow.step(
            in: state, captureID: captureID, held: channel, windowSinkID: heldSink.id,
            muted: muted, audioHeld: playbackID != nil, selfClientID: daemon.identity.id)
        let endKept = step == nil ? follow.keptToEnd(in: state) : nil
        if let endKept {
            log("session", "channel \(endKept) no longer records; ended")
            Task { await destroyChannel(endKept) }
        }
        // Another client attached its sink to the channel the window plays: two sinks echo, so
        // the window's goes and the channel plays through theirs.
        // The held id goes with the sink's tombstone, not before, so a detach that fails leaves
        // the sink held and mutable.
        if let extra = ChannelFollow.redundantSink(
            in: state, held: channelID, windowSinkID: heldSink.id, selfClientID: daemon.identity.id),
            !detachingSinks.contains(extra)
        {
            log("session", "sink \(extra) detached: another client's sink plays this channel")
            Task { await detachSink(extra) }
        }
        guard let step else { return }
        perform(step, daemon: daemon, why: "")
    }

    /// Carries out a follow: the new channel held, the window's own ended or kept, its sink
    /// detached from a channel that keeps running, and after `ChannelFollow.attachSettle` a sink
    /// attached when the window wanted audio and nothing plays the channel by then (the maker
    /// may attach its own a moment after making it).
    private func perform(_ step: ChannelFollow.Step, daemon: DaemonConnection, why: String) {
        let by = state.made[step.follow.channelID].map { ChangeNote.author($0.causedBy) } ?? ""
        log(
            "session",
            "following \(step.follow.channelID)\(by.isEmpty ? "" : ", made by \(by)")\(why.isEmpty ? "" : " " + why), from \(step.from ?? "no channel")\(step.endFrom ? ", ended" : step.keepFrom ? ", kept for its recording" : "")"
        )
        heldChannel.drop()
        heldChannel.adopted(id: step.follow.channelID, at: Date())
        clearRequested()
        Task {
            if let s = step.detachSink { await detachSink(s) }
            if step.endFrom, let from = step.from { await destroyChannel(from) }
            guard step.attachSink else { return }
            try? await Task.sleep(for: ChannelFollow.attachSettle)
            guard
                ChannelFollow.shouldAttach(
                    in: state, channelID: step.follow.channelID, held: channelID, muted: muted),
                playbackID == nil, !sweeping
            else { return }
            do { try await ensureSink(on: step.follow) } catch {
                lastError = LeylineError(error)
            }
        }
    }

    /// Detaches one of the window's own sinks. A failure is logged and the sink stays in the
    /// mirror, where `followOwnSinks` finds it again.
    private func detachSink(_ id: String) async {
        guard let daemon, !detachingSinks.contains(id) else { return }
        detachingSinks.insert(id)
        defer { detachingSinks.remove(id) }
        var req = Leyline_V1_DetachSinkRequest()
        req.sinkID = id
        do { _ = try await daemon.control.detachSink(req) } catch {
            log("session", "sink \(id) not detached: \(LeylineError(error))")
        }
    }

    /// Ends one of the window's own channels; one already gone is not an error.
    private func destroyChannel(_ id: String) async {
        guard let daemon else { return }
        var req = Leyline_V1_DestroyChannelRequest()
        req.channelID = id
        do { _ = try await daemon.control.destroyChannel(req) } catch {
            let e = LeylineError(error)
            if e.code != "CHANNEL_NOT_FOUND" { log("session", "channel \(id) not ended: \(e)") }
        }
    }

    /// A channel of the window's own with the settings of the one its maker ended, and a sink
    /// unless a recorded part holds the audio.
    private func listenOnOwn(like was: Leyline_V1_Channel) async {
        guard let cap = capture, let writes, !creatingChannel, channelID == nil else { return }
        creatingChannel = true
        defer { creatingChannel = false }
        do {
            let ch = try await ensureChannel(
                in: cap, offsetHz: was.offsetHz, mode: was.mode, bandwidthHz: was.bandwidthHz)
            if was.squelchSource == .squelchAuto {
                writes.squelchAutoDb(was.squelchDb, channel: ch.channelID)
            } else if !was.squelchDb.isNaN {
                writes.squelchDb(was.squelchDb, channel: ch.channelID)
            }
            if playbackID == nil, !muted { try await ensureSink(on: ch) }
            log("session", "own channel \(ch.channelID) where \(was.channelID) was")
        } catch {
            lastError = LeylineError(error)
            log(
                "session",
                "no channel of its own where \(was.channelID) was: \(LeylineError(error))")
        }
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
        writes.squelchAutoDb(threshold, channel: ch.channelID)
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

    /// A rail drag that has taken the view past the capture's edge pushes the capture
    /// (`BandRail`, `ViewWindow.dragged`); short of that it moves only the view. It moves the
    /// capture, not the station, and never out of the band:
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
        guard panCentre != nil || retunes.centreInFlight == nil else { return }
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
        retunes.hold(centre: newCentre)
        request(UInt64(max(0, held)))
        spectrum.resetFolds()
        let want = UInt64(max(0, newCentre))
        writes.centerHz(want, capture: cap.captureID)
        writes.offsetHz(held - newCentre, channel: ch.channelID)
        if ended {
            log(
                "tune",
                "pan capture \(cap.centerHz) -> \(newCentre) Hz\(newCentre != centre ? " (asked \(centre))" : ""), station at \(held) Hz\(held != station ? ", pushed from \(station)" : "")"
            )
            followBand(from: tunedHz, to: UInt64(max(0, held)), channel: ch)
            Task {
                await confirmed { self.capture?.centerHz == want }
                if panCentre == newCentre {
                    panCentre = nil
                    retunes.release()
                }
            }
        }
    }

    /// After a cancelled pan: the centre the drag last wrote, if one, is still in flight, and is
    /// released once the capture's event carries it, as the release of a drag releases it.
    private func releaseCentreInFlight() {
        guard let written = retunes.centreInFlight else { return }
        let want = UInt64(max(0, written))
        Task {
            await confirmed { self.capture?.centerHz == want }
            if panCentre == nil { retunes.release(ifCentre: written) }
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
        let centre = retunes.centreInFlight ?? Int64(cap.centerHz)
        let lo = centre - span / 2 + margin
        let hi = centre + span / 2 - margin
        var target = Int64(hz)
        if target < lo || target > hi {
            if dragging {
                target = min(max(target, lo), hi)
                if Date().timeIntervalSince(lastPan) > Self.panRateLimitSeconds,
                    retunes.centreInFlight == nil
                {
                    lastPan = Date()
                    let newCentre = clampCentre(
                        target < lo ? centre - span / 8 : centre + span / 8, span: span)
                    request(UInt64(max(0, target)))
                    log("tune", "pan \(centre) -> \(newCentre) Hz under a drag at \(target) Hz")
                    let move = RetuneQueue.Move(
                        centre: newCentre, offset: target - newCentre, captureID: cap.captureID,
                        channelID: ch.channelID)
                    Task { await retune(move) }
                    followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
                    return
                }
            } else {
                let newCentre = clampCentre(
                    target < lo
                        ? target + span * Self.edgeInsetEighths / 8
                        : target - span * Self.edgeInsetEighths / 8, span: span)
                request(UInt64(max(0, target)))
                // One move at a time: while one is in flight the new one waits and `retune`
                // performs it next (`RetuneQueue`).
                let move = RetuneQueue.Move(
                    centre: newCentre, offset: target - newCentre, captureID: cap.captureID,
                    channelID: ch.channelID)
                switch retunes.request(move) {
                case .queued(let superseded):
                    if let superseded {
                        log("tune", "centre \(superseded.centre) Hz superseded before it ran")
                    }
                    log(
                        "tune",
                        "centre \(newCentre) Hz for \(target) Hz waits on the move in flight")
                case .start:
                    log("tune", "centre \(centre) -> \(newCentre) Hz for \(target) Hz")
                    Task { await retune(move) }
                }
                followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
                return
            }
        }
        let offset = target - centre
        request(UInt64(max(0, target)))
        writes.offsetHz(offset, channel: ch.channelID)
        if !quiet {
            log(
                "tune",
                "\(target) Hz (offset \(offset))\(hz != UInt64(max(0, target)) ? ", asked \(hz)" : "")"
            )
        }
        followBand(from: tunedHz, to: UInt64(max(0, target)), channel: ch)
    }

    /// A centre inside the radio's tuning range, with half a span to spare on each side. A
    /// range narrower than the span (a file radio's, which tunes only the centre it was
    /// recorded at) has no such centre, and the centre is kept inside the range itself.
    private func clampCentre(_ centre: Int64, span: Int64) -> Int64 {
        guard
            let r = device?.tuningRanges.first(where: {
                Int64($0.minHz) - span / 2 <= centre && centre <= Int64($0.maxHz) + span / 2
            })
                ?? device?.tuningRanges.first
        else { return max(0, centre) }
        var lo = Int64(r.minHz) + span / 2
        var hi = Int64(r.maxHz) - span / 2
        if lo > hi { (lo, hi) = (Int64(r.minHz), Int64(r.maxHz)) }
        return min(max(centre, lo), hi)
    }

    /// The centre write, the wait for its event, then the offset, and then whatever move was
    /// asked for in the meantime (`RetuneQueue.perform`).
    private func retune(_ first: RetuneQueue.Move) async {
        guard let writes else { return }
        await retunes.perform(
            first,
            moveCentre: { move in
                spectrum.resetFolds()
                let want = UInt64(max(0, move.centre))
                writes.centerHz(want, capture: move.captureID)
                await confirmed { self.capture?.centerHz == want }
                if self.capture?.centerHz != want {
                    log(
                        "tune",
                        "centre \(move.centre) not confirmed; capture is at \(self.capture?.centerHz ?? 0)"
                    )
                }
            },
            writeOffset: { move in writes.offsetHz(move.offset, channel: move.channelID) },
            onNext: { move, next in
                log("tune", "centre \(move.centre) -> \(next.centre) Hz, the move that was waiting")
            })
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
            retunes.hold(centre: centre)
            writes.centerHz(UInt64(max(0, centre)), capture: cap.captureID)
            await confirmed { self.capture?.centerHz == UInt64(max(0, centre)) }
            retunes.release()
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
            if ch.bandwidthHz != bandwidthHz { writes.bandwidthHz(bandwidthHz, channel: id) }
            return
        }
        let widthFirst = bandwidthHz < ch.bandwidthHz
        for attempt in 0..<2 {
            let first = (attempt == 0) == widthFirst
            if first {
                writes.bandwidthHz(bandwidthHz, channel: id)
                await confirmed { self.channel?.bandwidthHz == bandwidthHz }
                writes.mode(mode, channel: id)
            } else {
                writes.mode(mode, channel: id)
                await confirmed { self.channel?.mode == mode }
                writes.bandwidthHz(bandwidthHz, channel: id)
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
        writes.set(.captureSampleRate(rate), target: cap.captureID)
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
            writes.bandwidthHz(hz, channel: ch.channelID)
        }
    }

    func setSquelch(_ db: Double) {
        guard let ch = channel, let writes else { return }
        writes.squelchDb(db, channel: ch.channelID)
    }

    func setVolume(_ v: Double) {
        guard let s = sink, let writes else { return }
        volume = v.clamped(to: 0...1)
        writes.volume(volume, sink: s.sinkID)
    }

    /// Mute detaches the sink and unmute attaches one; the channel and its squelch stay, and so
    /// does the radio: the button is the audio control.
    func toggleMute() async {
        // Another client's sink plays the channel: the window has nothing of its own to mute,
        // and attaching one would echo.
        guard let daemon, let ch = channel, audioElsewhere == nil else { return }
        do {
            if let s = sink {
                var req = Leyline_V1_DetachSinkRequest()
                req.sinkID = s.sinkID
                _ = try await daemon.control.detachSink(req)
                muted = true
                log("session", "muted: sink \(s.sinkID) detached")
            } else {
                muted = false
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

    // MARK: Scan band

    /// The band row's item: `ley scan --band`'s sweep on the window's own radio,
    /// with the window paused for it. On the row being swept it is Stop; on another row it
    /// stops that sweep and starts this one after its terminal event. A record job riding the
    /// window's capture would hear every hop, so the move alert asks first, Sweep anyway going
    /// ahead.
    func scanBand(row: Band) {
        if let s = sweep, sweeping {
            if s.row.id == row.id {
                log("sweep", "stop asked on \(row.name)")
                afterSweep = nil
                cancelSweep()
            } else {
                _ = waitForSweep("scan \(row.name)") { self.scanBand(row: row) }
            }
            return
        }
        if let cap = capture,
            let words = Recordings.retuneWords(
                jobs: Recordings.jobs(riding: cap.captureID, in: state))
        {
            ask(words, before: "scan \(row.name)", proceedLabel: "Sweep anyway") {
                Task { await self.startSweep(row: row) }
            }
            return
        }
        Task { await startSweep(row: row) }
    }

    /// A hit's row and its rail tick: the hit's frequency (`SweepHit.tuneHz`) tunes as
    /// a click on the chart would. With
    /// no capture (Stop listening after the sweep) the band opens the radio there, as a bookmark
    /// click does.
    func tune(hit: SweepHit) {
        log("tune", "hit \(hit.label) at \(hit.tuneHz) Hz")
        if capture == nil, let b = Bands.band(containing: hit.tuneHz, in: bands),
            outOfRangeWords(b) == nil
        {
            Task { await select(band: b, at: hit.tuneHz) }
            return
        }
        tune(to: hit.tuneHz)
    }

    /// `＋` on a hit: a bookmark named as the row names the hit, the plan channel's name else
    /// the frequency, on that frequency (`SweepHit.tuneHz`) with the band's mode and width, and its row
    /// opened as an editor as ⌘D opens one. The same name on the same frequency twice updates
    /// the bookmark in place (`BookmarkStore.add`).
    func bookmark(hit: SweepHit) {
        let band = Bands.band(containing: hit.tuneHz, in: bands)
        let mode = band?.mode(at: hit.tuneHz) ?? Bands.defaultMode(at: hit.tuneHz, in: bands)
        let bandwidthHz = band?.bandwidthHz ?? mode.defaultBandwidthHz
        do {
            let b = try bookmarks.add(
                name: hit.label, hz: hit.tuneHz, mode: mode, bandwidthHz: bandwidthHz)
            try bookmarks.save()
            log("bookmark", "added \(hit.label) at \(hit.tuneHz) Hz from a sweep hit")
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

    /// The window lets go of the radio without releasing it: the sink
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
                if sweep?.jobID == id { sweep?.stopAsked = false }
                log("sweep", "\(id) not stopped: \(e.code) \(e.message)")
                notice = "Could not stop the sweep: \(e.message.isEmpty ? e.code : e.message)"
            }
        }
    }

    /// While a sweep runs, a tune stops it and runs once the terminal event has put the radio
    /// back, so no write reaches the swept capture. True when the caller must return.
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

    /// The radio back as it was: the bookmark re-tuned with its saved settings, else the
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
        writes.gain(w, capture: cap.captureID)
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
        guard retunes.centreInFlight == nil else {
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
        retunes.hold(centre: Int64(want))
        spectrum.resetFolds()
        log(
            "rate",
            "\(cap.sampleRate) -> \(rate) S/s, remembered; centre \(cap.centerHz) -> \(want) Hz\(tunedHz.map { " for \($0) Hz" } ?? "")"
        )
        if narrowing, want != cap.centerHz {
            writes.centerHz(want, capture: cap.captureID)
        }
        writes.set(.captureSampleRate(rate), target: cap.captureID)
        if !narrowing, want != cap.centerHz {
            writes.centerHz(want, capture: cap.captureID)
        }
        Task {
            await confirmed(within: 2) {
                self.capture?.centerHz == want && self.capture?.sampleRate == rate
            }
            retunes.release(ifCentre: Int64(want))
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
        guard retunes.centreInFlight == nil else {
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
        retunes.hold(centre: Int64(want))
        spectrum.resetFolds()
        log("tune", "tune inside: centre \(cap.centerHz) -> \(want) Hz for \(hz) Hz")
        writes.centerHz(want, capture: cap.captureID)
        Task {
            await confirmed { self.capture?.centerHz == want }
            retunes.release(ifCentre: Int64(want))
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
        let fd = Darwin.open(dir, O_EVTONLY)
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
    /// after itself (`BookmarkNaming`), and its row opens as an editor at once
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

    /// File ▸ Import CHIRP…: the export's memories become bookmarks under their bands, by the
    /// rules `CHIRP` and the store share with `ley bookmarks import` (docs/design/channels.md,
    /// "CHIRP import"). One notice carries the counts the verb prints, the skipped and warned
    /// lines go to the log, and no row opens: a hundred memories are 2 m and 70 cm rows folded
    /// until opened. A file with no Frequency column is refused with nothing written.
    func importCHIRP(url: URL) {
        let file = url.lastPathComponent
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            lastError = LeylineError(
                code: "CHIRP_UNREADABLE", message: "\(file) could not be read: \(error)",
                target: url.path)
            return
        }
        let parsed: (rows: [CHIRP.Row], skipped: [CHIRP.Skipped])
        do {
            parsed = try CHIRP.parse(text)
        } catch {
            lastError = LeylineError(
                code: "CHIRP_NO_FREQUENCY", message: CHIRP.refusalWords(file: file),
                target: url.path)
            return
        }
        let tag = url.deletingPathExtension().lastPathComponent
        var result: CHIRP.Result
        do {
            result = try CHIRP.apply(parsed.rows, to: &bookmarks, tag: tag)
        } catch {
            lastError = bookmarkWriteError(error)
            return
        }
        do {
            try bookmarks.save()
        } catch {
            loadBookmarks()
            lastError = bookmarkWriteError(error)
            return
        }
        result.skipped = (parsed.skipped + result.skipped).sorted { $0.line < $1.line }
        for s in result.skipped { log("bookmark", "\(file) line \(s.line): \(s.reason)") }
        for w in result.warnings { log("bookmark", "\(file) line \(w.line): \(w.reason)") }
        notice = CHIRP.summary(result, file: file)
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
    /// with the channel's current mode and width, exactly rather than within the channel's
    /// width (`ley bookmarks move` is the terminal's).
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

    /// The inspector's tone field: the bookmark the field was made for takes the tone, trimmed,
    /// in the file's spelling; empty clears it. By id rather than the tuned bookmark, because a
    /// field left by a tune away saves as the tune happens, and the text belongs to the
    /// bookmark it was typed on. A tone the store refuses (`Tone.parse`) leaves the bookmark as
    /// it was and puts the shared sentence in `toneError`, under the field, rather than in
    /// `lastError`: it is the field's mistake, not the file's. The sentence is kept only while
    /// that bookmark is the tuned one, so it never shows under the next bookmark's field. Not
    /// `setX`: that verb is one coalesced parameter write to the daemon
    /// (`../dev/swift-style.md`, "Naming"), and this writes a file.
    func editBookmark(_ id: String, tone text: String) {
        guard let b = bookmarks.bookmarks[id] else { return }
        let tone = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tuned = tunedBookmark?.id == id
        guard tone != b.tone else {
            if tuned { clearToneError() }
            return
        }
        do {
            try bookmarks.setTone(b.id, to: tone)
            try bookmarks.save()
            if tuned { clearToneError() }
            log("bookmark", tone.isEmpty ? "\(b.name) tone cleared" : "\(b.name) tone \(tone)")
        } catch BookmarkError.invalidTone(let sentence) {
            if tuned {
                toneError = sentence
                toneErrorHz = b.hz
            }
            log("bookmark", "tone \"\(tone)\" refused for \(b.name): \(sentence)")
        } catch {
            lastError = bookmarkWriteError(error)
        }
    }

    /// The inspector's note field: the bookmark the field was made for takes the note,
    /// trimmed; empty clears it.
    func editBookmark(_ id: String, note text: String) {
        guard let b = bookmarks.bookmarks[id] else { return }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note != b.note else { return }
        do {
            try bookmarks.setNote(b.id, to: note)
            try bookmarks.save()
            log("bookmark", note.isEmpty ? "\(b.name) note cleared" : "\(b.name) note set")
        } catch {
            lastError = bookmarkWriteError(error)
        }
    }

    /// The tone field put the saved tone back (Escape, or `ley bookmarks` writing the bookmark
    /// while a refused tone waited in the field), so the sentence about the typed one goes with
    /// it.
    func clearToneError() {
        toneError = nil
        toneErrorHz = nil
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

    /// `+` and `−`: half or twice the width shown, centred on the tuned channel while the view
    /// shows it, else where the view is (`ViewWindow.zoomedIn`).
    func zoomIn() { stepZoom(ViewWindow.zoomedIn) }
    func zoomOut() { stepZoom(ViewWindow.zoomedOut) }

    private func stepZoom(_ step: (UInt64, UInt64, Int) -> UInt64) {
        guard let cap = capture, let r = visibleRange else { return }
        let span = step(r.upperBound - r.lowerBound, cap.sampleRate, Self.viewBins)
        let centre =
            tunedHz.flatMap { r.contains($0) ? $0 : nil } ?? (r.lowerBound + r.upperBound) / 2
        setView(spanHz: span, centreHz: centre)
        log("view", "span \(span) Hz around \(centre) Hz")
    }

    /// The view `spanHz` wide around `centreHz`, as a stage or a view tool sets it; the span is
    /// held between the narrowest the spectrum allows and the capture when the view is drawn.
    func setView(spanHz: UInt64?, centreHz: UInt64?) {
        viewSpanHz = spanHz
        viewCentreHz = centreHz
    }

    /// A rail drag's view centre; nothing is retuned (`BandRail`, `ViewWindow.dragged`).
    func moveView(centreTo hz: Int64) {
        viewCentreHz = UInt64(max(0, hz))
    }

    /// The edge marker: the view moves to the tuned channel, and nothing is retuned.
    func showTuned() {
        guard let hz = tunedHz else { return }
        viewCentreHz = hz
        log("view", "back to the tuned channel at \(hz) Hz")
    }

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
    /// and its capture is the one the waterfall's rows come from. The raw
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
    /// started it (`Recordings.activeJob`): the Record transmissions switch's state and its status
    /// line. The switch remembers nothing, so a job `ley record` or an agent started shows the
    /// same.
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
    /// there, because both read the job: one state, two places.
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
        followTranscriptions()
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
    /// again. Each is read once and again
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
                self.failedSpeech = []
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
    /// channel's (`ch5`, `WX3`), else the frequency (`Frequency.format`); nil with no
    /// channel. The volume caption's name.
    var listeningName: String? {
        guard let hz = tunedHz else { return nil }
        return tunedBookmark?.name ?? BookmarkNaming.name(for: hz)
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
        // One read for the channel's recordings whose speech has not been read.
        loadSpeech(of: c.recordings.map(\.jobID).filter { speechLines[$0] == nil })
        readSpeechDecoderIfNeeded()
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
                // The sidecar reads are file I/O: off the main actor, and only the sidecars of parts
                // the earlier read did not have.
                let earlier = self?.manifests[id]
                let url = URL(fileURLWithPath: local.path)
                let manifest = try await Task.detached(priority: .utility) {
                    try RecordingManifest.read(at: url, reusing: earlier)
                }.value
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
        for id in speechLines.keys where !listed.contains(id) { speechLines[id] = nil }
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

    /// The page's days for `c`: every part of its recordings whose manifests have been read, as
    /// rows by the day each started (`Recordings.dayRows`).
    func pageDays(for c: RecordingChannel) -> [DayRows] {
        Recordings.dayRows(pageGroups(for: c), now: Date())
    }

    /// A row's click: the part is selected, so the inspector and the player show it, and plays; a
    /// click on the row playing pauses it, and on the row paused resumes it. Starting another part
    /// ends a Play all or a Play day.
    func clickRow(_ uri: String) async {
        selectedPartURI = uri
        selectedOver = nil
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
        partPlayback.queue = queue
        await startPlayback(first)
    }

    /// The row's level graph: `ResolveLocalPath` of the part's URI, then one pass over the WAV
    /// off the main actor into `LevelGraph.columnCount(seconds:)` columns, cached by URI. Called
    /// as a row appears; a row already read or being read costs nothing. A path that does not
    /// resolve, or a file that is not here, caches an empty graph and says nothing: the column is
    /// empty, as the design draws it for a remote daemon.
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

    /// Play all: the recording's parts in part order, the next started on the tombstone of the one
    /// before (`endPlayback`), each selected as it starts so the inspector follows. The inspector's
    /// `Play all 4`.
    func playAll(_ group: RecordingGroup) async {
        var queue = PlayQueue()
        guard let first = queue.start(group) else { return }
        log("playback", "play all \(group.uri): \(group.chips.count) parts")
        selectedPartURI = first
        partPlayback.queue = queue
        await startPlayback(first)
    }

    /// Plays one part through the daemon's speakers (`Control.StartPlayback` on
    /// `ley://recordings/<id>/<part>`). The live channel's sink is detached meanwhile and attached
    /// again when the clip ends, so the clip is heard alone; one playback at a time, so a clip
    /// already playing is stopped first, and a clip replays from its start. A Play all in
    /// progress is ended: this part is the one asked for. `row` is the start of the log row whose
    /// ▶ was clicked (`playingRowStart`), nil from anywhere else.
    func play(partURI uri: String, row: Leyline_V1_SampleTime? = nil) async {
        partPlayback.queue.clear()
        await startPlayback(uri, row: row)
    }

    /// `play(partURI:)` without touching Play all's queue, which `playAll` and `endPlayback`
    /// have set for the parts after this one.
    private func startPlayback(
        _ uri: String, row: Leyline_V1_SampleTime? = nil, over: Int? = nil,
        range: (start: UInt64, end: UInt64)? = nil
    ) async {
        guard let daemon else { return }
        if let old = partPlayback.replace(sinkAttached: sink != nil) {
            var stop = Leyline_V1_StopPlaybackRequest()
            stop.playbackID = old
            _ = try? await daemon.control.stopPlayback(stop)
            log("playback", "\(old) stopped for \(uri)")
        }
        partPlayback.playing(uri, row: row, over: over)
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
        if let range {
            req.startSample = range.start
            req.endSample = range.end
        }
        do {
            let pb = try await daemon.control.startPlayback(req)
            partPlayback.started(id: pb.playbackID, at: Date())
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
            partPlayback.failed()
            await attachAfterPlayback()
        }
    }

    /// Stops the window's clip, and a Play all with it; its tombstone ends it here and attaches
    /// the live sink again.
    func stopPlayback() async {
        partPlayback.queue.clear()
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
        let listed = state.playbacks.contains { $0.playbackID == id }
        // Folded on a copy, so a mirror change that alters nothing here is not a change to
        // anything a view reads.
        var folded = partPlayback
        let ended = folded.observe(
            listed: listed, now: Date(), dropAfter: Self.neverSeenDropSeconds)
        if folded != partPlayback { partPlayback = folded }
        if let ended { endPlayback(ended) }
    }

    /// A clip ended. During Play all the next part starts at once and the live sink stays
    /// detached between parts, so the channel is not heard in the gaps; `playingURI` is held on
    /// the next part meanwhile, which keeps the sink's earlier state for the end of the last one.
    private func endPlayback(_ id: String) {
        guard let ending = partPlayback.end(id) else { return }
        log("playback", "\(id) ended")
        switch ending {
        case .next(let next):
            selectedPartURI = next
            log("playback", "play all: \(next) next, \(playQueue.pending.count) after it")
            Task { await startPlayback(next) }
        case .finished:
            Task { await attachAfterPlayback() }
        }
    }

    /// `Resources.DeleteResource` on the whole recording, from the inspector on a part: the
    /// daemon refuses one whose job runs and stops a playback of its parts first, so the clip's
    /// tombstone ends it here as a stop would. On success the listing is read again, which
    /// forgets the recording's manifest and clears the selection (`prunePage`).
    func deleteRecording(uri: String) async {
        guard let daemon else { return }
        if playQueue.holds(recordingURI: uri) { partPlayback.queue.clear() }
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

    /// The part the player shows and ▶ plays: the one playing, else the
    /// selected part, else the page's first row, once the manifest that holds it has been read. nil
    /// leaves the player with nothing to play.
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
                partPlayback.queue = queue
                await startPlayback(first)
                return
            }
        }
        await play(partURI: n)
    }

    /// The player's circle, and space in the Library: while a playback exists, ⏸ pauses it and ▶
    /// resumes it (`SetPlaybackPaused`, the position held); with none, ▶ plays the player's part
    /// and selects it. Between a part's `StartPlayback` and its answer there is a part but no
    /// playback yet, and the click does nothing rather than start it twice.
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
        guard partPlayback.reattachAfterPlayback, partPlayback.takeReattach() else { return }
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

    // MARK: Speech in the Library

    /// A recording's speech as the page shows it: its lines dated through its manifest, the
    /// newest transcription of each over shown (`RecordingSpeech.shown`). nil until read.
    func speech(for recordingID: String) -> RecordingSpeech? {
        if let held = speechCache[recordingID] { return held }
        guard let lines = speechLines[recordingID] else { return nil }
        let built = RecordingSpeech(lines: lines, manifest: manifests[recordingID])
        speechCache[recordingID] = built
        return built
    }

    /// Drops the cached speech of every recording whose entry differs between `old` and `new`.
    private func forgetSpeech<V: Equatable>(changedIn old: [String: V], _ new: [String: V]) {
        guard !speechCache.isEmpty else { return }
        for id in Set(old.keys).union(new.keys) where old[id] != new[id] {
            speechCache[id] = nil
        }
    }

    /// Reads `recordingID`'s speech again now, or once the read in flight lands: a transcription
    /// of it changed.
    func loadSpeech(for recordingID: String) {
        if speechLoads[recordingID] != nil {
            staleSpeech.insert(recordingID)
            return
        }
        failedSpeech.remove(recordingID)
        loadSpeech(of: [recordingID])
    }

    /// `Decoders.QueryRecords` for some recordings' speech in one call: protocol `speech` over
    /// their span (`SpeechRecords.query`), since a record query has no filter on `clip_uri`, and
    /// each recording's own sorted out by `SpeechRecords.byRecording`. A recording whose read is
    /// in flight, or whose last read failed, is left out. A failure is logged and leaves what was
    /// read before: the words are an addition to the page.
    private func loadSpeech(of ids: [String]) {
        guard let daemon else { return }
        let summaries = recordings.filter {
            ids.contains($0.jobID) && speechLoads[$0.jobID] == nil
                && !failedSpeech.contains($0.jobID)
        }
        guard !summaries.isEmpty else { return }
        let token = UUID()
        let covered = summaries.map(\.jobID)
        for id in covered { speechLoads[id] = token }
        let query = SpeechRecords.query(for: summaries, now: Date())
        Task { [weak self] in
            let result: Result<Leyline_V1_RecordPage, LeylineError>
            do {
                result = .success(try await daemon.decoders.queryRecords(query))
            } catch {
                result = .failure(LeylineError(error))
            }
            self?.landSpeech(result, for: covered, token: token)
        }
    }

    /// A speech read landed: each recording still waiting on it takes its lines (none is an
    /// answer too), or on a failure is not read again until the listing is.
    private func landSpeech(
        _ result: Result<Leyline_V1_RecordPage, LeylineError>, for ids: [String], token: UUID
    ) {
        let mine = ids.filter { speechLoads[$0] == token }
        for id in mine { speechLoads[id] = nil }
        switch result {
        case .success(let page):
            let byRecording = SpeechRecords.byRecording(page.records)
            for id in mine {
                let lines = byRecording[id] ?? []
                if speechLines[id] != lines { speechLines[id] = lines }
                if page.truncated {
                    speechTruncated.insert(id)
                } else {
                    speechTruncated.remove(id)
                }
            }
            log(
                "speech",
                "\(page.records.count) speech records for \(mine.count) recordings"
                    + (page.truncated ? ", cut at the query's limit" : ""))
        case .failure(let e):
            failedSpeech.formUnion(mine)
            log("speech", "speech of \(mine.joined(separator: ", ")) not read: \(e)")
        }
        let again = staleSpeech.intersection(mine)
        staleSpeech.subtract(again)
        for id in again { loadSpeech(for: id) }
    }

    /// A transcription job (a decode job reading a recording) changed: its recording's speech is
    /// read again, so lines appear as the job writes them, and a failure is the session's notice.
    private func followTranscriptions() {
        let jobs = state.jobs.filter {
            if case .decode(let d)? = $0.config { return !d.sourceUri.isEmpty }
            return false
        }
        guard jobs != transcriptionsSeen else { return }
        let changed = jobs.filter { !transcriptionsSeen.contains($0) }
        transcriptionsSeen = jobs
        for j in changed {
            guard case .decode(let d)? = j.config,
                let id = RecordingPartRef.recordingID(of: d.sourceUri)
            else { continue }
            loadSpeech(for: id)
            if j.state == .failed,
                let line = SpeechRecords.statusLine(job: j, speech: speech(for: id))
            {
                notice = line
            }
        }
    }

    /// The newest transcription of a recording and its status line (`Transcribing · 3 overs so
    /// far`, the daemon's `status_detail` while degraded, `Could not transcribe: …`); nil when none
    /// runs or failed.
    func transcriptionStatus(for recordingID: String) -> (job: Leyline_V1_Job, line: String)? {
        guard
            let job = SpeechRecords.transcription(
                of: "ley://recordings/\(recordingID)", in: state.jobs),
            let line = SpeechRecords.statusLine(job: job, speech: speech(for: recordingID))
        else { return nil }
        return (job, line)
    }

    /// `ListDecoders` once, for the speech decoder's manifest: whether Transcribe is offered,
    /// whether it needs a key, and which hosts the question names.
    private func readSpeechDecoderIfNeeded() {
        guard !speechDecoderRead, let daemon else { return }
        speechDecoderRead = true
        Task { [weak self] in
            do {
                let listed = try await daemon.decoders.listDecoders(
                    Leyline_V1_ListDecodersRequest())
                let found = listed.decoders.first {
                    $0.name == SpeechRecords.protocolName
                        || $0.aliases.contains(SpeechRecords.protocolName)
                }
                self?.speechDecoder = found
                log(
                    "speech",
                    found.map { "speech decoder \($0.name) \($0.version)" }
                        ?? "no speech decoder installed")
            } catch {
                self?.speechDecoderRead = false
                log("speech", "decoders not listed: \(LeylineError(error))")
            }
        }
    }

    /// Whether a recording's manifest lists squelch openings: speech is cut at the squelch, so only
    /// a gated recording can be transcribed. False until the manifest has been read.
    func isGated(recordingID: String) -> Bool {
        manifests[recordingID]?.parts.contains { $0.squelchOpens > 0 } ?? false
    }

    /// Whether the Library offers Transcribe: a speech decoder is installed, and it needs no key
    /// or a key is set. While false no speech control shows (docs/design/ai.md).
    var canTranscribe: Bool { SpeechRecords.canTranscribe(decoder: speechDecoder, ai: state.ai) }

    /// The speech model in use and the models "Transcribe again…" offers.
    var speechModels: (current: String, offered: [String]) { SpeechRecords.models(state.ai) }

    /// Transcribe and Transcribe again…: puts the question `ley transcribe` asks into
    /// `transcribeAsk`, which the view shows as a confirmation dialog; nothing is sent until
    /// `transcribe(recordingID:model:)`.
    func askTranscribe(recordingID: String, model: String = "") {
        guard let m = manifests[recordingID], let d = speechDecoder else {
            notice =
                "Could not transcribe: the recording or the speech decoder has not been read yet."
            return
        }
        transcribeAsk = TranscribeAsk(
            recordingID: recordingID, model: model,
            question: SpeechRecords.question(manifest: m, decoder: d, model: model))
    }

    /// Starts the kept speech job over the stored recording (`StartJob` with `source_uri`), as
    /// `ley transcribe --yes` does. With `model`, the speech feature is set to it first, because the
    /// model reaches the plugin when it starts, and put back when the daemon refuses the job. The
    /// job's records arrive through `followTranscriptions`.
    func transcribe(recordingID: String, model: String = "") async {
        transcribeAsk = nil
        guard let daemon, let d = speechDecoder else { return }
        let previous =
            state.ai.features.first { $0.feature == SpeechRecords.feature }
            ?? .with { $0.feature = SpeechRecords.feature }
        if !model.isEmpty {
            var fm = Leyline_V1_FeatureModel()
            fm.feature = SpeechRecords.feature
            fm.provider = d.credentialProvider
            fm.model = model
            do {
                _ = try await daemon.credentials.setFeatureModel(fm)
            } catch {
                let e = LeylineError(error)
                notice =
                    "Could not choose the speech model: \(e.message.isEmpty ? e.code : e.message)"
                return
            }
        }
        var req = Leyline_V1_StartJobRequest()
        req.decode = SpeechRecords.transcribeConfig(
            recordingURI: "ley://recordings/\(recordingID)", decoder: d.name)
        do {
            let job = try await daemon.jobs.startJob(req)
            log(
                "speech",
                "\(job.jobID) transcribing \(recordingID)\(model.isEmpty ? "" : " with \(model)")")
        } catch {
            let e = LeylineError(error)
            log("speech", "\(recordingID) not transcribed: \(e.code) \(e.message)")
            notice = "Could not transcribe: \(e.message.isEmpty ? e.code : e.message)"
            // An empty provider and model clear the choice, which is what it was if none was set.
            if !model.isEmpty {
                let restore =
                    previous.model.isEmpty
                    ? Leyline_V1_FeatureModel.with { $0.feature = SpeechRecords.feature } : previous
                _ = try? await daemon.credentials.setFeatureModel(restore)
            }
        }
    }

    /// Writes a recording's shown speech to `url` as plain text or SRT (`SpeechRecords.export`);
    /// the view's save panel chose the file. A failure is the session's notice.
    func exportSpeech(recordingID: String, format: SpeechExportFormat, to url: URL) {
        guard let s = speech(for: recordingID), let m = manifests[recordingID] else { return }
        let t = SpeechRecords.timings(speechDecoder)
        let out = SpeechRecords.export(
            s, manifest: m, format: format, preRollMs: t.preRollMs, hangMs: t.hangMs)
        do {
            try Data(out.text.utf8).write(to: url)
            log("speech", "\(recordingID) exported as \(format.rawValue) to \(url.path)")
            if out.skipped > 0 {
                log("speech", "\(out.skipped) lines left out of the SRT: nothing dates them")
            }
        } catch {
            notice = "Could not export the words: \(error.localizedDescription)"
        }
    }

    /// A speech line's click: the part is selected with the over, and only that over plays, its
    /// segment as the speech decoder heard it (`SpeechRecords.range`, `StartPlayback`'s sample
    /// range); a part whose openings were not read plays whole. A click on the over playing
    /// pauses or resumes it.
    func play(part uri: String, over: Int) async {
        selectedPartURI = uri
        selectedOver = over
        if playingURI == uri, playingOver == over, playback != nil {
            await pausePlayback(!isPaused)
            return
        }
        partPlayback.queue.clear()
        var range: (start: UInt64, end: UInt64)?
        if let ref = RecordingPartRef(uri: uri), let m = manifests[ref.jobID],
            let part = m.parts.first(where: { $0.part == ref.part })
        {
            let t = SpeechRecords.timings(speechDecoder)
            range = SpeechRecords.range(
                over: over, of: part, in: m, preRollMs: t.preRollMs, hangMs: t.hangMs)
        }
        log("playback", "over \(over) of \(uri)\(range == nil ? ", whole part" : "")")
        // Without a range the whole part plays, and no one line is what is playing.
        await startPlayback(uri, over: range == nil ? nil : over, range: range)
    }

    /// The search field's words changed: while it holds some, each channel's unread speech is
    /// read, one query a channel, once (a read in flight or failed is not sent again), so a
    /// channel is found by what was said in it.
    func searchSpeech() {
        guard !recordingsQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        for c in recordingChannels {
            loadSpeech(of: c.recordings.map(\.jobID).filter { speechLines[$0] == nil })
        }
    }

    /// The speech line the search finds in `c`, or nil.
    func speechHit(in c: RecordingChannel) -> SpeechHit? {
        var speech: [String: RecordingSpeech] = [:]
        for r in c.recordings { speech[r.jobID] = self.speech(for: r.jobID) }
        return SpeechRecords.hit(recordingsQuery, in: c, speech: speech)
    }

    /// The search's hit chosen: the channel, the part and the over are selected, and the page
    /// scrolls to the over (`selectedOver`), its EARLIER day opened first.
    func select(hit: SpeechHit, in c: RecordingChannel) {
        if selectedRecordingChannel != c.id { selectedRecordingChannel = c.id }
        selectedPartURI = hit.partURI
        selectedOver = hit.over
        openDay(holding: hit.partURI)
    }

    /// Opens the EARLIER day that holds `partURI`, so a row the page is asked to show is not
    /// folded away; a recent day is always open.
    func openDay(holding partURI: String) {
        guard let c = selectedChannel,
            let day = pageDays(for: c).first(where: { d in d.rows.contains { $0.uri == partURI } }),
            day.earlier, !openedDays.contains(day.id)
        else { return }
        openedDays.insert(day.id)
    }

    // MARK: Moving the radio over a recording

    /// A move of the radio that would leave a record job's frequency outside the capture, until
    /// it is answered. The daemon never refuses the move: it degrades the job and records the gap,
    /// so the window asks first, as `ley tune` refuses without `--retune`.
    struct RetuneQuestion: Identifiable {
        let id = UUID()
        /// `Recordings.retuneWords`: the job named and the gap the move would leave.
        let words: String
        /// The button that goes ahead: `Move anyway` before a move, `Sweep anyway` before Find
        /// active, which hops the radio across the band.
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

    // MARK: Settings, AI

    /// An AI control shows outside Settings only while this holds, which is when the daemon
    /// holds a key or a feature names an on-device engine (`AISettings.hasAnyAI`).
    var hasAnyAI: Bool { AISettings.hasAnyAI(state.ai) }

    /// Stores `secret` as the key for `provider` and has the daemon check it once
    /// (`Credentials.SetCredential`). The secret lives in this call's request and nowhere else:
    /// never in the session's state and never in a log line. The reply's check is worded into
    /// `settingsNotice`; the key's row arrives with the mirror's `ai` event, as a key `ley ai add`
    /// stored does. Returns whether the daemon stored the key, so the form can clear its field.
    func addKey(provider: String, secret: String, label: String, endpoint: String) async -> Bool {
        guard let daemon else {
            settingsNotice = Self.notDialledWords
            return false
        }
        var req = Leyline_V1_SetCredentialRequest()
        req.provider = provider
        req.secret = secret
        req.label = label
        req.endpoint = endpoint
        do {
            let c = try await daemon.credentials.setCredential(req)
            log("ai", "\(AISettings.keyWords(c)) added: \(KeyOutcome(c.lastCheck).word)")
            settingsNotice = AISettings.addedWords(c)
            return true
        } catch {
            settingsNotice = aiFailed("add the \(ProviderCatalog.name(provider)) key", error)
            return false
        }
    }

    /// Tries the stored key against the provider again (`Credentials.CheckCredential`).
    func checkKey(provider: String) async {
        guard let daemon else {
            settingsNotice = Self.notDialledWords
            return
        }
        var ref = Leyline_V1_CredentialRef()
        ref.provider = provider
        do {
            let c = try await daemon.credentials.checkCredential(ref)
            log("ai", "\(AISettings.keyWords(c)) checked: \(KeyOutcome(c.lastCheck).word)")
            settingsNotice = AISettings.checkedWords(c)
        } catch {
            settingsNotice = aiFailed("check the \(ProviderCatalog.name(provider)) key", error)
        }
    }

    /// Removes the key (`Credentials.DeleteCredential`); the daemon ends every job and
    /// conversation that uses it, each with a line naming the key.
    func removeKey(provider: String) async {
        guard let daemon else {
            settingsNotice = Self.notDialledWords
            return
        }
        var ref = Leyline_V1_CredentialRef()
        ref.provider = provider
        do {
            _ = try await daemon.credentials.deleteCredential(ref)
            log("ai", "\(provider) key removed")
            settingsNotice =
                "\(ProviderCatalog.name(provider)) key removed; anything that was using it has stopped."
        } catch {
            settingsNotice = aiFailed("remove the \(ProviderCatalog.name(provider)) key", error)
        }
    }

    /// Chooses the provider and model a feature calls (`Credentials.SetFeatureModel`), as `ley ai
    /// use` does; the pane's pickers show the mirror's value once the `ai` event carries it.
    func setFeatureModel(feature: String, provider: String, model: String) async {
        guard let daemon else {
            settingsNotice = Self.notDialledWords
            return
        }
        var fm = Leyline_V1_FeatureModel()
        fm.feature = feature
        fm.provider = provider
        fm.model = model
        do {
            let got = try await daemon.credentials.setFeatureModel(fm)
            log("ai", "\(got.feature) now calls \(got.provider) \(got.model)")
            settingsNotice = AISettings.nowCallsWords(got)
        } catch {
            let what = "choose the \(AISettings.title(feature).lowercased()) model"
            settingsNotice = aiFailed(what, error)
        }
    }

    func clearSettingsNotice() { settingsNotice = nil }

    private static let notDialledWords = "The daemon is not running, so nothing was written."

    /// The settings line for a write the daemon refused or never received, logged with its code.
    private func aiFailed(_ what: String, _ error: any Error) -> String {
        let e = LeylineError(error)
        log("ai", "could not \(what): \(e.code) \(e.message)")
        // No daemon answered: the transport's own words name its channel states and the socket.
        if e.daemonUnreachable {
            return "Could not \(what): the daemon is not running."
        }
        return "Could not \(what): \(e.message.isEmpty ? e.code : e.message)"
    }

    // MARK: The assistant

    /// The panel shows while it is switched on and any AI feature can run (`hasAnyAI`): no AI
    /// control appears outside Settings until a key or an on-device engine is set
    /// (`docs/design/ai.md`, "Context").
    var assistantPanelShown: Bool { assistantShown && hasAnyAI }

    /// A provider is chosen for the assistant (`ley ai use assistant`, or the Settings pane);
    /// without one a start is refused, so the empty panel says where to choose it.
    var hasAssistantModel: Bool {
        state.ai.features.contains { $0.feature == "assistant" && !$0.provider.isEmpty }
    }

    var conversationView: ConversationView? { conversation.map(ConversationView.init) }

    /// The tokens the conversation shown has used, from the mirror's usage lines.
    var assistantUsage: UsageSoFar {
        UsageSoFar(lines: state.usage, conversationID: conversation?.conversationID ?? "")
    }

    /// The inspector's line while the window follows another client's channel and its own stays
    /// for a recording (`ChannelFollow.keptRecording`).
    var keptRecording: ChannelFollow.KeptRecording? {
        follow.keptRecording(in: state, bookmarks: bookmarks.list)
    }

    /// The kept line's Stop: `CancelJob` on the recording that keeps the window's old channel
    /// open, as the Record switch's off does; once the job ends the window ends that channel
    /// (`followOtherClients`).
    func stopKeptRecording() async {
        guard let k = keptRecording else { return }
        await stopRecording(k.jobID, frequencyHz: k.hz, mode: k.mode)
    }

    /// The inspector's line under the channel's parameters: the newest change to the tuned
    /// channel when another client made it (`ChangeNote`).
    var changeNote: ChangeNote? {
        guard let ch = channel, let id = daemon?.identity.id else { return nil }
        return ChangeNote.latest(for: ch, in: state, selfClientID: id)
    }

    func toggleAssistant() {
        assistantShown.toggle()
        log("session", assistantShown ? "assistant shown" : "assistant hidden")
    }

    /// The field's Return: the message, starting a conversation first when none is going, with
    /// the app's view tools and on the assistant feature's provider and model (the request names
    /// neither). No key or no model is a notice that points to Settings
    /// (`AssistantWords.failed`).
    /// Returns whether the daemon took it, so the field keeps what was typed when it did not.
    func send(_ text: String) async -> Bool {
        guard let assistant else {
            assistantNotice = AssistantNotice(text: Self.notDialledWords)
            return false
        }
        return await assistant.send(text)
    }

    /// Allow, once or, with `forConversation`, for the rest of the conversation: the worker then
    /// runs later calls of that kind without asking (`docs/dev/assistant.md`, "The gate").
    func approve(callID: String, forConversation: Bool = false) async {
        await assistant?.resolve(
            callID: callID, approve: true, scope: forConversation ? .conversation : .once)
    }

    func decline(callID: String) async {
        await assistant?.resolve(callID: callID, approve: false)
    }

    func stopTurn() async { await assistant?.stopTurn() }

    /// New Conversation: the one shown ends, if it is still going, and the panel empties.
    func newConversation() async { await assistant?.clear() }

    /// After every mirror change: a tune that leaves the view brings the view to the tuned
    /// channel, and one inside it leaves the view alone (`ViewWindow.followed`). While a rail
    /// drag moves the capture the station it pushes is not followed, or the thumb would jump
    /// back under the pointer. A centre a drag left past the capture's edge is pulled in to
    /// where the view stands once the capture's move has landed.
    private func keepView() {
        if tunedHz != viewTunedHz {
            viewTunedHz = tunedHz
            if panCentre == nil {
                let followed = ViewWindow.followed(
                    centreHz: viewCentreHz, shown: visibleRange, tunedHz: tunedHz)
                if followed != viewCentreHz { viewCentreHz = followed }
            }
        }
        if panCentre == nil, viewCentreHz != nil, let r = visibleRange {
            let centre = r.lowerBound + (r.upperBound - r.lowerBound) / 2
            if centre != viewCentreHz { viewCentreHz = centre }
        }
    }

    private func assistantChanged(_ a: AssistantController) {
        if conversation != a.conversation { conversation = a.conversation }
        if assistantNotice != a.notice { assistantNotice = a.notice }
        if assistantSending != a.sending { assistantSending = a.sending }
        if assistantLost != a.isLost { assistantLost = a.isLost }
    }

    /// Opens the Library on recording `id` (its job id), and on its part `part` when one is
    /// given, as a click on its channel's row and then on the part's row would. Returns false
    /// when the listing has no such recording. A part whose manifest has not been read yet is
    /// selected anyway; the inspector shows it once the read lands, as after a click.
    @discardableResult
    func selectRecording(id: String, part: Int?) -> Bool {
        guard
            let row = recordingChannels.first(where: { c in
                c.recordings.contains { $0.jobID == id }
            })
        else { return false }
        place = .library
        // A new channel row clears the selected part, so the part is set after it.
        selectedRecordingChannel = row.id
        selectedPartURI = part.map { "ley://recordings/\(id)/\($0)" }
        log("session", "select recording \(id)\(part.map { " part \($0)" } ?? "")")
        return true
    }

    /// The Library row's title for recording `id`: its bookmark's name, else its frequency.
    private func recordingTitle(_ id: String) -> String? {
        recordingChannels.first { c in c.recordings.contains { $0.jobID == id } }?.title
    }

    // MARK: The daemon's launch agent

    /// Registers the launch agent the bundle carries, unless a source build's job holds the label
    /// or the run names its own socket (`DaemonAgent.launch`). Before the first dial, so the
    /// daemon is starting while the mirror waits for it; registering starts it (`RunAtLoad`).
    private func prepareAgent() {
        let env = ProcessInfo.processInfo.environment
        guard DaemonAgent.agentApplies(environment: env) else { return }
        let status = EngineAgent.status()
        let launch = DaemonAgent.launch(
            environment: env, status: status,
            sourcePlistExists: EngineAgent.sourceBuildPlistExists(),
            bundledPlistExists: EngineAgent.bundledPlistExists())
        log("session", "agent: \(status), \(launch)")
        agentStatus = status
        guard launch == .register else { return }
        do {
            try EngineAgent.register()
        } catch {
            log("session", "agent: could not register: \(error)")
        }
        let now = EngineAgent.status()
        agentStatus = now
        log("session", "agent: registered, now \(now)")
    }

    /// After an update the daemon still runs the old bundle's binary: restart it onto this one,
    /// or ask first when a job is running (`DaemonAgent.afterConnect`). Run each time the mirror
    /// goes live; after one restart it does nothing.
    private func followUpdate() {
        let info = Bundle.main.infoDictionary
        let action = DaemonAgent.afterConnect(
            daemonVersion: state.daemon.version,
            bundleVersion: info?["CFBundleShortVersionString"] as? String,
            bundleBuild: info?["CFBundleVersion"] as? String,
            appOwnsAgent: agentStatus == .enabled,
            runningJobs: DaemonAgent.runningJobs(state.jobs),
            alreadyRestarted: engineRestarted)
        switch action {
        case .nothing:
            break
        case .restartNow:
            Task { await restartEngine() }
        case .askToRestart:
            log("session", "leylined \(state.daemon.version) is not this build; a job is running")
            engineUpdatePending = true
        }
    }

    /// `launchctl kickstart -k` on the app's agent: the daemon stops, ending every job, and
    /// launchd starts the bundle's binary; the mirror reconnects on its own.
    func restartEngine() async {
        engineRestarted = true
        engineUpdatePending = false
        log("session", "restarting leylined \(state.daemon.version) onto this bundle's build")
        if let failure = await EngineAgent.kickstart() {
            lastError = LeylineError(
                code: "RESTART_FAILED", message: "Could not restart the engine: \(failure)")
        }
    }

    /// The update strip's close: the daemon keeps the old build until it next starts.
    func dismissEngineUpdate() { engineUpdatePending = false }

    func openLoginItems() { EngineAgent.openLoginItems() }

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

/// The window's two places: Radio is the live window, the Library what has
/// been kept. Presentation only; the radio runs the same in both.
enum WindowPlace: String, CaseIterable, Identifiable {
    case radio
    case library

    var id: String { rawValue }
    var title: String { self == .radio ? "Radio" : "Library" }
    /// ⌘1 and ⌘2, the View menu's items and the switch's tooltip.
    var shortcut: Character { self == .radio ? "1" : "2" }
}

/// The view tools the window declares (`AppViewTools`), performed on the main actor when the
/// assistant calls one. None of them moves the radio: `show_band` sizes and centres the view
/// inside the span the radio captures and says to tune when the band is outside it, because
/// retuning goes through the radio tools and their don't-disturb check.
extension AppSession: ViewToolPerformer {
    func perform(_ request: AppViewTools.Request) async -> ViewToolAnswer {
        switch request {
        case .showRange(let lowHz, let highHz, let label):
            let (answer, fit) = AppViewTools.showRange(
                lowHz: lowHz, highHz: highHz, label: label, centerHz: capture?.centerHz,
                sampleRate: capture?.sampleRate ?? 0, bins: Self.viewBins)
            if let fit {
                place = .radio
                setView(spanHz: fit.spanHz, centreHz: fit.focusHz)
                log("assistant", "view \(fit.shown.lowerBound)-\(fit.shown.upperBound) Hz")
            }
            return answer
        case .selectRecording(let id, let part):
            if let part, let m = manifests[id], !m.parts.contains(where: { $0.part == part }) {
                return AppViewTools.unknownRecording(id, part: part)
            }
            guard selectRecording(id: id, part: part), let title = recordingTitle(id) else {
                return AppViewTools.unknownRecording(id)
            }
            return AppViewTools.selected(recording: id, part: part, title: title)
        case .showPlace(let p):
            place = p == .library ? .library : .radio
            return AppViewTools.shown(p)
        }
    }
}

/// Transcribe's question while it is asked: the recording, the model chosen (empty for the
/// speech feature's own) and `ley transcribe`'s words.
struct TranscribeAsk: Equatable, Identifiable {
    var recordingID: String
    var model: String
    var question: String

    var id: String { recordingID + "\u{0}" + model }
}
