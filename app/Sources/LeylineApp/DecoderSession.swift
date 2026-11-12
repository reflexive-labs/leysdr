// SPDX-License-Identifier: Apache-2.0

// The Decoders place's state (docs/plans/decoders-app.md, DA-8): the installed decoders as
// `ListDecoders` lists them, the decoder selected, its tab and its selected transmitter or record,
// the page's records (the last day from `QueryRecords`, then `SubscribeRecords` for the protocol)
// folded into transmitters, and the labels file. `AppSession` owns one and wires it: it hands over
// the connection, says when the daemon is live and when the jobs change, and the views read the
// mirror's jobs and captures from the session itself, so nothing here copies the mirror. Nothing
// here is the daemon's truth (AGENTS.md, invariant 7): a decoder runs as a kept job, its state and
// detail are the mirror's, and Start and Stop are `StartJob` and `CancelJob`.

import Foundation
import LeylineClient
import LeylineProto

@MainActor
@Observable
final class DecoderSession {
    /// Every installed decoder as `ListDecoders` gave them, nil until read. The sidebar lists
    /// each name once (`DecoderPages.listed`); the Library's speech decoder is read from here too,
    /// so the list is fetched once.
    private(set) var manifests: [Leyline_V1_DecoderManifest]?
    /// Why the list could not be read, until it is.
    private(set) var listError: LeylineError?
    /// The decoder whose page shows, by manifest name.
    private(set) var selectedName: String?
    /// The page's tab; a tab the decoder does not have shows the log.
    var tab: DecoderTab = .log {
        didSet { if tab != oldValue { log("decoders", "tab \(tab.rawValue)") } }
    }
    /// The transmitter the inspector shows, by `device_id`, or nil.
    var selectedTransmitter: String? {
        didSet {
            if selectedTransmitter != oldValue, selectedTransmitter != nil {
                selectedRecord = nil
            }
        }
    }
    /// The record the inspector shows, by `record_id`: a click on a log row. It wins over the
    /// transmitter until another transmitter is chosen.
    var selectedRecord: String?
    /// Whether the inspector's Raw group is open: closed at launch, then as the person left it,
    /// whichever record is shown. Presentation only.
    var rawOpen = false
    /// Whether the log follows its newest record (`LogFollowing`): the log starts it again each
    /// time it is drawn for a decoder, so opening a page or switching decoders follows.
    var logFollowing = LogFollowing()
    /// Each decoder's records and transmitters, by manifest name, kept for the session once its
    /// page has shown (`DecoderFold`): nothing but `entity_silence_s` takes a transmitter away.
    private(set) var folds: [String: DecoderFold] = [:]
    /// The labels file (`LabelStore`), read at start and again whenever it changes on disk.
    private(set) var labels = LabelStore(path: LabelStore.defaultPath())
    /// Start's question while it is asked: the decoder needs a radio somebody is using.
    var takeOverAsk: TakeOverAsk?
    /// The decoder Start was clicked for, until its job's event arrives or `startHoldSeconds`
    /// pass, so the button does not flick back for the round trip.
    private(set) var starting: String?
    /// The page's one line about the last refusal: a start or a stop the daemon declined.
    private(set) var notice: String? {
        didSet { if let n = notice, n != oldValue { log("shown", "decoders: \(n)") } }
    }
    /// The decoder whose Notify Me… sheet is up, by manifest name, or nil. Presentation only.
    var watchFor: String?
    /// The clock the alerts and the expiry read, moved every `tickSeconds` while a page shows.
    private(set) var now = Date()
    /// The daemon's plan for the selected decoder (`Control.Plan`), worded, with the request it
    /// answers; `placement(for:)` reads it.
    private(set) var plan: PlanAnswer?

    @ObservationIgnored private var daemon: DaemonConnection?
    @ObservationIgnored private var listing = false
    /// Each decoder's record stream, by manifest name, open from its page's first showing until
    /// the session ends; reopened, and merged, after an error.
    @ObservationIgnored private var feeds: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var startExpiry: Task<Void, Never>?
    @ObservationIgnored private var labelWatch: DispatchSourceFileSystemObject?
    /// The decode jobs as last seen, so a change is logged once and Start's hold lets go.
    @ObservationIgnored private var jobsSeen: [Leyline_V1_Job] = []
    /// The mirror's captures, for dating a live record through its capture's anchor.
    @ObservationIgnored private var captures: [Leyline_V1_Capture] = []
    /// Whether a job of the selected decoder runs, which is when silence ages a transmitter out.
    @ObservationIgnored private var listening = false
    /// The frequency Start would use for a decoder, the window's tuned channel and the mirror,
    /// which the session gives; the plan is asked for with them.
    @ObservationIgnored var planInputs:
        ((Leyline_V1_DecoderManifest) -> (hz: UInt64?, windowChannel: String?))?
    @ObservationIgnored private var mirror = MirrorState()
    @ObservationIgnored private var planning: Task<Void, Never>?
    /// Whether the window shows the place, so the feed and the clock run only then.
    @ObservationIgnored private var shown = false

    /// A start's hold, as the record switch's.
    static let startHoldSeconds: Double = 5
    /// How often the page's clock moves: the alerts in effect and the expiry.
    static let tickSeconds: Double = 5
    /// After the record stream fails, this long before it is opened again.
    static let retrySeconds: Double = 2
    /// How long a plan waits after the change that asked for it, so a burst of state events is
    /// one `Control.Plan`.
    static let planDebounceSeconds: Double = 0.2

    /// A plan and the decoder and frequency it was asked for.
    struct PlanAnswer: Equatable {
        var decoder: String
        var frequencyHz: UInt64
        var placement: DecoderPlacement
    }

    struct TakeOverAsk: Identifiable, Equatable {
        var decoder: String
        var frequencyHz: UInt64
        /// The daemon's reason it would not start without the radio, nil when the plan was a
        /// retune that moves a person's channel.
        var reason: String?
        /// What taking the radio does.
        var takes: DecoderPlacement.Retune
        var id: String { decoder }
    }

    // MARK: Wiring

    /// The session dialled the daemon.
    func connect(_ daemon: DaemonConnection) {
        self.daemon = daemon
        loadLabels()
        watchLabels()
    }

    /// The daemon became live (a connect, or a reconnect after a restart): the list is read
    /// again, and the page's records are read afresh, because a restarted daemon's stream starts
    /// over.
    func becameLive() {
        listing = false
        readManifests()
        // A restarted daemon's streams start over; what they and the history bring merges.
        for name in feeds.keys { openFeed(name) }
        replan()
    }

    /// The mirror changed: the captures are kept for dating, and a change to a decode job is
    /// logged and lets Start's hold go.
    func mirrorChanged(_ state: MirrorState) {
        captures = state.captures
        mirror = state
        // State events are what move a plan: a capture retuned, a channel or a job come or gone.
        replan()
        let jobs = state.jobs.filter { if case .decode? = $0.config { true } else { false } }
        if let m = selected {
            let live = !DecoderPages.running(of: m, in: jobs).isEmpty
            if live != listening { listening = live }
        }
        guard jobs != jobsSeen else { return }
        let changed = jobs.filter { !jobsSeen.contains($0) }
        jobsSeen = jobs
        for j in changed {
            guard case .decode(let d)? = j.config else { continue }
            log(
                "decoders",
                "job \(j.jobID) \(d.decoder) \(DecoderPages.stateWord(j).lowercased())"
                    + (DecoderPages.detail(j).isEmpty ? "" : ": \(DecoderPages.detail(j))"))
            if d.hasPredicate {
                // A watch is not Start's: its end is the page's notice, in its own words.
                if j.state == .failed {
                    let words = Watches.words(j, manifest: manifest(named: d.decoder))
                    notice = "The watch for \(words) stopped: \(DecoderPages.detail(j))"
                }
                continue
            }
            if let s = starting,
                d.decoder == s || manifest(named: s)?.aliases.contains(d.decoder) == true
            {
                letGoStart("its job's event arrived")
                if j.state == .failed {
                    notice = "Could not start \(s): \(DecoderPages.detail(j))"
                }
            }
        }
    }

    /// Whether the place shows: the feed and the clock run only while it does. Arriving selects
    /// the first decoder when none is.
    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        if on {
            now = Date()
            readManifests()
            if selectedName == nil, let first = listed.first { select(first.name) }
            if let name = selectedName, feeds[name] == nil { openFeed(name) }
            startTicker()
            replan()
        } else {
            // The streams stay open, so coming back shows what arrived meanwhile.
            ticker?.cancel()
            ticker = nil
        }
    }

    // MARK: The list

    /// The decoders the sidebar lists, each name once.
    var listed: [Leyline_V1_DecoderManifest] { DecoderPages.listed(manifests ?? []) }

    var selected: Leyline_V1_DecoderManifest? { selectedName.flatMap(manifest(named:)) }

    func manifest(named name: String) -> Leyline_V1_DecoderManifest? {
        manifests?.first { $0.name == name || $0.aliases.contains(name) }
    }

    /// `ListDecoders`, once per live connection; a failure is read again on the next call.
    func readManifests() {
        guard !listing, let daemon else { return }
        listing = true
        Task { [weak self] in
            do {
                let listed = try await daemon.decoders.listDecoders(
                    Leyline_V1_ListDecodersRequest())
                self?.landManifests(listed.decoders)
            } catch {
                self?.listing = false
                self?.listError = LeylineError(error)
                log("decoders", "decoders not listed: \(LeylineError(error))")
            }
        }
    }

    private func landManifests(_ list: [Leyline_V1_DecoderManifest]) {
        listError = nil
        if manifests != list { manifests = list }
        replan()
        log("decoders", "\(list.count) decoders: \(list.map(\.name).joined(separator: ", "))")
        for (name, _) in folds {
            guard let m = manifest(named: name) else { continue }
            folds[name]?.setDisplay(m.hasDisplay ? m.display : nil)
        }
        if selectedName == nil, shown, let first = listed.first {
            select(first.name)
        }
    }

    // MARK: Selection

    /// Shows a decoder's page and clears the inspector. Its records and transmitters are the ones
    /// the session already holds for it, or read now on its first showing.
    func select(_ name: String) {
        let canonical = manifest(named: name)?.name ?? name
        guard canonical != selectedName else { return }
        selectedName = canonical
        selectedTransmitter = nil
        selectedRecord = nil
        notice = nil
        let m = manifest(named: canonical)
        if folds[canonical] == nil {
            folds[canonical] = DecoderFold(display: m.flatMap { $0.hasDisplay ? $0.display : nil })
        }
        listening = m.map { !DecoderPages.running(of: $0, in: jobsSeen).isEmpty } ?? false
        log("decoders", "selected \(canonical)")
        if shown, feeds[canonical] == nil { openFeed(canonical) }
        expire()
        replan()
    }

    /// The selected decoder's fold, empty before one is selected.
    var fold: DecoderFold { selectedName.flatMap { folds[$0] } ?? DecoderFold() }
    /// The page's records, newest first, and the transmitters folded from them.
    var records: RecordLog { fold.records }
    var table: EntityTable { fold.table }
    /// Whether the history has landed, and whether the daemon cut it at its limit.
    var historyLoaded: Bool { fold.historyLoaded }
    var historyTruncated: Bool { fold.historyTruncated }
    /// The selected decoder's map camera rule.
    var framing: MapFraming { fold.framing }

    /// The person moved the selected decoder's map: it stops framing itself until Fit All.
    func personMovedMap(to visible: MapRegion) {
        guard let name = selectedName, let f = folds[name] else { return }
        guard f.framing.following || f.framing.region != visible else { return }
        if f.framing.following { log("decoders", "map moved by the person") }
        folds[name]?.personMoved(to: visible)
    }

    /// Fit All: the map frames every transmitter once and follows the rule again.
    func fitAllOnMap() {
        guard let name = selectedName else { return }
        folds[name]?.fitAll()
        log("decoders", "map fit to all")
    }

    /// Whether a transmitter draws dimmed: silent for half of `entity_silence_s` while a job of
    /// the decoder listens.
    func fading(_ e: DecoderEntity) -> Bool {
        guard listening, let m = selected else { return false }
        return EntityTable.fading(e, now: now, silence: TimeInterval(m.entitySilenceS))
    }

    /// The tabs the page shows for the selected decoder.
    var tabs: [DecoderTab] {
        guard let m = selected else { return [.log] }
        return DecoderTab.available(m, anyPosition: records.anyPosition)
    }

    /// Whether a tab of the page can be chosen: the map waits for the first position.
    func tabEnabled(_ t: DecoderTab) -> Bool { t.enabled(anyPosition: records.anyPosition) }

    /// The tab drawn: the chosen one when the decoder has it and it can be chosen, else the log.
    var shownTab: DecoderTab { tabs.contains(tab) && tabEnabled(tab) ? tab : .log }

    /// The transmitter the inspector shows: the selected one, else the selected record's.
    var inspectedEntity: DecoderEntity? {
        let id = selectedTransmitter ?? inspectedRecord?.record.deviceID
        return id.flatMap { table.entities[$0] }
    }

    /// The record the inspector shows: the one clicked, else the selected transmitter's newest.
    var inspectedRecord: RecordEntry? {
        if let id = selectedRecord, let e = records.entries.first(where: { $0.id == id }) {
            return e
        }
        guard let device = selectedTransmitter else { return nil }
        return records.entries.first { $0.record.deviceID == device }
    }

    /// A transmitter's name on the page: the person's label, else the display's entity name,
    /// else its `device_id`.
    /// The transmitters as the table and the map list them (`DecoderPages.byName`).
    var listedTransmitters: [DecoderEntity] {
        DecoderPages.byName(table.rows) { name(of: $0.deviceID) }
    }

    func name(of deviceID: String) -> String {
        if let l = labels.name(of: deviceID) { return l }
        if let e = table.entities[deviceID] { return table.name(of: e) }
        return deviceID
    }

    /// The alerts in effect, newest first.
    var alerts: [RecordEntry] {
        DecoderPages.alerts(records.entries, display: table.display, now: now)
    }

    /// One record's line under the decoder's display, with its transmitter's label.
    func summary(_ r: Leyline_V1_DecodeRecord) -> String {
        DisplayTemplate.summary(
            table.display, record: r, label: labels.name(of: r.deviceID) ?? "")
    }

    // MARK: The records

    /// Opens a decoder's record stream, then reads its last day. The stream opens first so a
    /// record written while the history is read is not missed; `RecordLog` keeps each once
    /// whichever arrives first, and the fold merges what it did not hold.
    private func openFeed(_ name: String) {
        feeds[name]?.cancel()
        feeds[name] = nil
        guard let daemon else { return }
        let stream = daemon.records(scope: .protocol(name))
        feeds[name] = Task { [weak self] in
            self?.readHistory(name)
            do {
                for try await r in stream {
                    if Task.isCancelled { return }
                    self?.land(r, for: name)
                }
            } catch {
                if Task.isCancelled { return }
                log("decoders", "records of \(name) ended: \(LeylineError(error))")
            }
            if Task.isCancelled { return }
            // The daemon restarted or the stream failed: open it again, merging what it brings.
            try? await Task.sleep(for: .seconds(Self.retrySeconds))
            guard let self, !Task.isCancelled else { return }
            self.openFeed(name)
        }
    }

    /// `QueryRecords` for the protocol over the last day, dated through the page's anchors and
    /// folded oldest first, so the transmitters stand as they did when each was last heard.
    private func readHistory(_ name: String) {
        guard let daemon else { return }
        var q = Leyline_V1_RecordQuery()
        q.protocol = name
        q.sinceNs = Int64((Date().timeIntervalSince1970 - DecoderPages.historySeconds) * 1e9)
        q.limit = UInt32(DecoderPages.logLimit)
        Task { [weak self] in
            do {
                let page = try await daemon.decoders.queryRecords(q)
                self?.landHistory(page, for: name)
            } catch {
                log("decoders", "history of \(name) not read: \(LeylineError(error))")
            }
        }
    }

    private func landHistory(_ page: Leyline_V1_RecordPage, for name: String) {
        guard folds[name] != nil else { return }
        let arrived = Date()
        let added = folds[name]!.landHistory(
            page.records.map { RecordEntry.dated($0, anchors: page.anchors, fallback: arrived) },
            truncated: page.truncated)
        if name == selectedName { expire() }
        log(
            "decoders",
            "\(page.records.count) records of \(name) from the last day, \(added) new"
                + (page.truncated ? ", cut at the query's limit" : ""))
    }

    /// One live record: dated through its capture's anchor, kept once, and folded in.
    private func land(_ r: Leyline_V1_DecodeRecord, for name: String) {
        let cap = captures.first { $0.captureID == r.time.captureID }
        folds[name]?.landLive(RecordEntry.live(r, capture: cap, arrived: Date()))
    }

    /// Ages transmitters out by the manifest's `entity_silence_s`, but only while a job of the
    /// decoder runs: silence is only news while something listens, so a stopped decoder's page
    /// keeps what it last heard.
    private func expire() {
        guard listening, let name = selectedName, let m = selected, m.entitySilenceS > 0,
            var f = folds[name]
        else { return }
        let gone = f.expire(now: now, silence: TimeInterval(m.entitySilenceS))
        guard gone > 0 else { return }
        folds[name] = f
        log("decoders", "\(gone) transmitters of \(name) aged out")
        if let id = selectedTransmitter, f.table.entities[id] == nil { selectedTransmitter = nil }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
                guard let self, !Task.isCancelled else { return }
                self.now = Date()
                self.expire()
                // A person's claim ends a minute after their last write with no event of its
                // own, so the plan is asked for again on the clock too.
                self.replan()
            }
        }
    }

    // MARK: The plan

    /// Where Start would put the decoder: the daemon's answer for it at `frequencyHz`, `asking`
    /// until one arrives, and `needsFrequency` with no frequency to ask about.
    func placement(for m: Leyline_V1_DecoderManifest, frequencyHz: UInt64?) -> DecoderPlacement {
        guard let hz = frequencyHz else { return .needsFrequency }
        guard let p = plan, p.decoder == m.name, p.frequencyHz == hz else { return .asking }
        return p.placement
    }

    /// Asks `Control.Plan` for the selected decoder, `planDebounceSeconds` after the last call,
    /// while the place shows. A decline is asked again with `take_over`, which says whether
    /// Start can take the radio. The answer before stays on the page until the new one lands.
    func replan() {
        guard shown, daemon != nil, let m = selected else { return }
        planning?.cancel()
        planning = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.planDebounceSeconds))
            guard let self, !Task.isCancelled else { return }
            await self.askPlan(m)
        }
    }

    private func askPlan(_ m: Leyline_V1_DecoderManifest) async {
        guard let daemon, let inputs = planInputs?(m), let hz = inputs.hz else { return }
        var cfg = DecoderPlacement.startConfig(
            m, frequencyHz: hz, windowChannel: inputs.windowChannel, takeOver: false)
        var req = Leyline_V1_PlanRequest()
        req.decode = cfg
        let placement: DecoderPlacement
        do {
            let p = try await daemon.control.plan(req)
            var insisting: Leyline_V1_CapturePlan?
            if case .decline? = p.outcome, cfg.channelID.isEmpty {
                cfg.takeOver = true
                req.decode = cfg
                insisting = try await daemon.control.plan(req)
            }
            guard !Task.isCancelled else { return }
            placement = DecoderPlacement.from(
                p, insisting: insisting, state: mirror, selfID: clientID,
                windowChannel: inputs.windowChannel, titles: titles)
        } catch {
            guard !Task.isCancelled else { return }
            let e = LeylineError(error)
            placement = .decline(
                code: e.code, reason: e.message.isEmpty ? e.code : e.message, insist: nil)
        }
        let answer = PlanAnswer(decoder: m.name, frequencyHz: hz, placement: placement)
        guard answer != plan else { return }
        plan = answer
        log("decoders", "plan for \(m.name) at \(hz) Hz: \(placement.words)")
    }

    /// Each decoder's title by its manifest name, for naming a decode job a plan would pause or
    /// a claim holds.
    var titles: [String: String] {
        Dictionary(
            (manifests ?? []).map { ($0.name, DecoderPages.title($0)) },
            uniquingKeysWith: { a, _ in a })
    }

    // MARK: Start and stop

    /// Start: the kept decode job on the frequency the placement chose, after asking when the
    /// plan takes the radio from somebody (`takeOverAsk`, answered by `answerTakeOver`).
    func start(
        _ m: Leyline_V1_DecoderManifest, frequencyHz: UInt64, placement: DecoderPlacement
    ) async {
        if let takes = placement.takeOver {
            takeOverAsk = TakeOverAsk(
                decoder: m.name, frequencyHz: frequencyHz, reason: placement.declineReason,
                takes: takes)
            log("decoders", "asked to take the radio for \(m.name): \(placement.words)")
            return
        }
        await startJob(m.name, frequencyHz: frequencyHz, takeOver: false)
    }

    /// The question's answer: Take the radio sends `take_over`; Cancel starts nothing.
    func answerTakeOver(_ take: Bool) async {
        guard let ask = takeOverAsk else { return }
        takeOverAsk = nil
        log("decoders", "take the radio for \(ask.decoder): \(take ? "yes" : "no")")
        if take { await startJob(ask.decoder, frequencyHz: ask.frequencyHz, takeOver: true) }
    }

    private func startJob(_ name: String, frequencyHz: UInt64, takeOver: Bool) async {
        guard let daemon, let m = manifests?.first(where: { $0.name == name }) else { return }
        // Speech borrows the window's channel, so it hears that channel's mode and squelch.
        let cfg = DecoderPlacement.startConfig(
            m, frequencyHz: frequencyHz, windowChannel: planInputs?(m).windowChannel,
            takeOver: takeOver)
        var req = Leyline_V1_StartJobRequest()
        req.decode = cfg
        holdStart(name)
        notice = nil
        do {
            let job = try await daemon.jobs.startJob(req)
            log(
                "decoders",
                "\(job.jobID) started: \(name) "
                    + (cfg.channelID.isEmpty ? "at \(frequencyHz) Hz" : "on \(cfg.channelID)")
                    + ", kept"
                    + (takeOver ? ", taking the radio" : ""))
        } catch {
            let e = LeylineError(error)
            letGoStart("refused")
            log("decoders", "\(name) refused at \(frequencyHz) Hz: \(e.code) \(e.message)")
            notice = "Could not start \(name): \(e.message.isEmpty ? e.code : e.message)"
        }
    }

    /// Stop: `CancelJob` on every running job of the decoder, which hands the radio back.
    func stop(_ jobs: [Leyline_V1_Job]) async {
        guard let daemon else { return }
        for j in jobs {
            var ref = Leyline_V1_JobRef()
            ref.jobID = j.jobID
            do {
                _ = try await daemon.jobs.cancelJob(ref)
                log("decoders", "\(j.jobID) stopped")
            } catch {
                let e = LeylineError(error)
                log("decoders", "\(j.jobID) not stopped: \(e.code) \(e.message)")
                notice = "Could not stop \(j.jobID): \(e.message.isEmpty ? e.code : e.message)"
            }
        }
    }

    // MARK: Watches

    /// Notify Me…'s start: the kept job `Watches.config` builds, on the frequency Start would
    /// use, with the predicate and a macOS notification, never taking a radio. True when the
    /// daemon took it; a refusal is the page's notice.
    func startWatch(
        _ m: Leyline_V1_DecoderManifest, frequencyHz: UInt64, predicate: Leyline_V1_Predicate
    ) async -> Bool {
        guard let daemon else { return false }
        var req = Leyline_V1_StartJobRequest()
        req.decode = Watches.config(
            decoder: m.name, frequencyHz: frequencyHz, predicate: predicate)
        // A speech watch borrows the window's channel as Start does.
        let start = DecoderPlacement.startConfig(
            m, frequencyHz: frequencyHz, windowChannel: planInputs?(m).windowChannel,
            takeOver: false)
        if !start.channelID.isEmpty {
            req.decode.channelID = start.channelID
            req.decode.frequencyHz = 0
        }
        let words = Watches.words(predicate, manifest: m)
        notice = nil
        do {
            let job = try await daemon.jobs.startJob(req)
            log("decoders", "\(job.jobID) watching: \(m.name) at \(frequencyHz) Hz for \(words)")
            return true
        } catch {
            let e = LeylineError(error)
            log("decoders", "watch on \(m.name) refused: \(e.code) \(e.message)")
            notice = "Could not start the watch: \(e.message.isEmpty ? e.code : e.message)"
            return false
        }
    }

    private func holdStart(_ name: String) {
        starting = name
        startExpiry?.cancel()
        startExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.startHoldSeconds))
            guard let self, !Task.isCancelled, self.starting == name else { return }
            self.letGoStart("no job event within \(Int(Self.startHoldSeconds)) s")
        }
    }

    private func letGoStart(_ why: String) {
        guard let s = starting else { return }
        starting = nil
        startExpiry?.cancel()
        startExpiry = nil
        log("decoders", "start of \(s) let go: \(why)")
    }

    /// The window's client id, so the plan calls its own channel "you".
    var clientID: String { daemon?.identity.id ?? "" }

    // MARK: Labels

    /// The inspector's name field: names the transmitter in `labels.json`, which `ley track` and
    /// `ley records` read too; an empty name removes the label.
    func setLabel(_ deviceID: String, name: String) {
        let protocolName = selectedName ?? ""
        do {
            try labels.set(deviceID: deviceID, name: name, protocolName: protocolName)
            log(
                "decoders",
                name.isEmpty ? "label of \(deviceID) removed" : "\(deviceID) labelled \(name)")
        } catch {
            notice = "Could not save the name: \(labels.path) \(error)"
            log("decoders", "label of \(deviceID) not saved: \(error)")
        }
    }

    private func loadLabels() {
        do {
            try labels.load()
        } catch {
            log("decoders", "labels not read from \(labels.path): \(error)")
        }
    }

    /// Reads the file again when `ley label` or anyone else writes it.
    private func watchLabels() {
        guard labelWatch == nil else { return }
        let dir = (labels.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.loadLabels() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        labelWatch = source
    }
}

extension AppSession {
    /// The frequency Start uses for a decoder: the first recipe frequency inside the window's
    /// capture, else the first, else the tuned one (`DecoderPlacement.frequency`).
    func decoderFrequency(_ m: Leyline_V1_DecoderManifest) -> UInt64? {
        DecoderPlacement.frequency(for: m, capture: capture, tunedHz: tunedHz)
    }

    /// Where Start would put a decoder now, as the daemon's last plan says: the line under
    /// Start.
    func decoderPlacement(_ m: Leyline_V1_DecoderManifest) -> DecoderPlacement {
        decoders.placement(for: m, frequencyHz: decoderFrequency(m))
    }
}
