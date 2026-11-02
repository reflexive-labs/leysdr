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
    /// The page's records, newest first, and the transmitters folded from them.
    private(set) var records = RecordLog()
    private(set) var table = EntityTable()
    /// Whether the history has landed, and whether the daemon cut it at its limit.
    private(set) var historyLoaded = false
    private(set) var historyTruncated = false
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
    /// The clock the alerts and the expiry read, moved every `tickSeconds` while a page shows.
    private(set) var now = Date()

    @ObservationIgnored private var daemon: DaemonConnection?
    @ObservationIgnored private var listing = false
    @ObservationIgnored private var feed: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var startExpiry: Task<Void, Never>?
    @ObservationIgnored private var labelWatch: DispatchSourceFileSystemObject?
    /// The decode jobs as last seen, so a change is logged once and Start's hold lets go.
    @ObservationIgnored private var jobsSeen: [Leyline_V1_Job] = []
    /// The mirror's captures, for dating a live record through its capture's anchor.
    @ObservationIgnored private var captures: [Leyline_V1_Capture] = []
    /// Whether a job of the selected decoder runs, which is when silence ages a transmitter out.
    @ObservationIgnored private var listening = false
    /// Whether the window shows the place, so the feed and the clock run only then.
    @ObservationIgnored private var shown = false

    /// A start's hold, as the record switch's.
    static let startHoldSeconds: Double = 5
    /// How often the page's clock moves: the alerts in effect and the expiry.
    static let tickSeconds: Double = 5
    /// After the record stream fails, this long before it is opened again.
    static let retrySeconds: Double = 2

    struct TakeOverAsk: Identifiable, Equatable {
        var decoder: String
        var frequencyHz: UInt64
        var reason: String
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
        if shown { openFeed() }
    }

    /// The mirror changed: the captures are kept for dating, and a change to a decode job is
    /// logged and lets Start's hold go.
    func mirrorChanged(_ state: MirrorState) {
        captures = state.captures
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
            readManifests()
            if selectedName == nil, let first = listed.first { select(first.name) }
            // `select` opened it when it chose a decoder.
            if feed == nil { openFeed() }
            startTicker()
        } else {
            feed?.cancel()
            feed = nil
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
        log("decoders", "\(list.count) decoders: \(list.map(\.name).joined(separator: ", "))")
        if let name = selectedName, let m = manifest(named: name) {
            table.display = m.hasDisplay ? m.display : nil
        } else if shown, let first = listed.first {
            select(first.name)
        }
    }

    // MARK: Selection

    /// Shows a decoder's page: its records are read afresh and the inspector is cleared.
    func select(_ name: String) {
        let canonical = manifest(named: name)?.name ?? name
        guard canonical != selectedName else { return }
        selectedName = canonical
        selectedTransmitter = nil
        selectedRecord = nil
        notice = nil
        let m = manifest(named: canonical)
        records = RecordLog()
        table = EntityTable(display: m.flatMap { $0.hasDisplay ? $0.display : nil })
        historyLoaded = false
        historyTruncated = false
        listening = m.map { !DecoderPages.running(of: $0, in: jobsSeen).isEmpty } ?? false
        log("decoders", "selected \(canonical)")
        if shown { openFeed() }
    }

    /// The tabs the page shows for the selected decoder.
    var tabs: [DecoderTab] {
        guard let m = selected else { return [.log] }
        return DecoderTab.available(m, anyPosition: records.anyPosition)
    }

    /// The tab drawn: the chosen one when the decoder has it, else the log.
    var shownTab: DecoderTab { tabs.contains(tab) ? tab : .log }

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

    /// Opens the selected decoder's record stream, then reads its last day. The stream opens
    /// first so a record written while the history is read is not missed; `RecordLog` keeps each
    /// once whichever arrives first.
    private func openFeed() {
        feed?.cancel()
        feed = nil
        guard let daemon, let name = selectedName else { return }
        let stream = daemon.records(scope: .protocol(name))
        feed = Task { [weak self] in
            self?.readHistory(name)
            do {
                for try await r in stream {
                    if Task.isCancelled { return }
                    self?.land(r)
                }
            } catch {
                if Task.isCancelled { return }
                log("decoders", "records of \(name) ended: \(LeylineError(error))")
            }
            if Task.isCancelled { return }
            // The daemon restarted or the stream failed: open it again while the page shows.
            try? await Task.sleep(for: .seconds(Self.retrySeconds))
            guard let self, !Task.isCancelled, self.shown, self.selectedName == name else { return }
            self.openFeed()
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
        guard name == selectedName else { return }
        let arrived = Date()
        records.insert(
            page.records.map { RecordEntry.dated($0, anchors: page.anchors, fallback: arrived) })
        refold()
        historyLoaded = true
        historyTruncated = page.truncated
        log(
            "decoders",
            "\(page.records.count) records of \(name) from the last day"
                + (page.truncated ? ", cut at the query's limit" : ""))
    }

    /// One live record: dated through its capture's anchor, kept once, and folded in.
    private func land(_ r: Leyline_V1_DecodeRecord) {
        guard r.protocol == selectedName || selectedName == nil else { return }
        let cap = captures.first { $0.captureID == r.time.captureID }
        let added = records.insert([RecordEntry.live(r, capture: cap, arrived: Date())])
        for e in added { table.apply(e.record, at: e.at) }
    }

    /// The transmitters folded again from the records held, oldest first, then aged.
    private func refold() {
        var t = EntityTable(display: table.display)
        for e in records.entries.reversed() { t.apply(e.record, at: e.at) }
        table = t
        expire()
    }

    /// Ages transmitters out by the manifest's `entity_silence_s`, but only while a job of the
    /// decoder runs: silence is only news while something listens, so a stopped decoder's page
    /// keeps what it last heard.
    private func expire() {
        guard listening, let m = selected, m.entitySilenceS > 0 else { return }
        var t = table
        if t.expire(now: now, silence: TimeInterval(m.entitySilenceS)) > 0 {
            table = t
            if let id = selectedTransmitter, table.entities[id] == nil { selectedTransmitter = nil }
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
                guard let self, !Task.isCancelled else { return }
                self.now = Date()
                self.expire()
            }
        }
    }

    // MARK: Start and stop

    /// Start: the kept decode job on the frequency the placement chose, after asking when the
    /// radio is somebody's (`takeOverAsk`, answered by `answerTakeOver`).
    func start(
        _ m: Leyline_V1_DecoderManifest, frequencyHz: UInt64, placement: DecoderPlacement
    ) async {
        if case .needsRadio(_, let reason) = placement {
            takeOverAsk = TakeOverAsk(decoder: m.name, frequencyHz: frequencyHz, reason: reason)
            log("decoders", "asked to take the radio for \(m.name): \(reason)")
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
        guard let daemon else { return }
        var cfg = Leyline_V1_DecodeConfig()
        cfg.decoder = name
        cfg.frequencyHz = frequencyHz
        cfg.keep = true
        cfg.takeOver = takeOver
        var req = Leyline_V1_StartJobRequest()
        req.decode = cfg
        holdStart(name)
        notice = nil
        do {
            let job = try await daemon.jobs.startJob(req)
            log(
                "decoders",
                "\(job.jobID) started: \(name) at \(frequencyHz) Hz, kept"
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

    /// The window's client id, so the placement calls its own channel "you".
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

    /// Where Start would put a decoder now, read from the mirror: the line under Start.
    func decoderPlacement(_ m: Leyline_V1_DecoderManifest) -> DecoderPlacement {
        DecoderPlacement.predict(
            m, frequencyHz: decoderFrequency(m), state: state, swept: sweptDevices,
            selfID: decoders.clientID, windowChannel: channelID)
    }

    /// The devices a running sweep names, whose captures no decoder joins. A sweep that names
    /// none is left out: which radio it took is not in the mirror, and the prediction is advice.
    private var sweptDevices: Set<String> {
        Set(
            state.jobs.compactMap { j in
                guard case .scan(let s)? = j.config, DecoderPages.isLive(j), !s.deviceID.isEmpty
                else { return nil }
                return s.deviceID
            })
    }
}
