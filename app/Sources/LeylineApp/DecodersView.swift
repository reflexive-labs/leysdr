// SPDX-License-Identifier: Apache-2.0

// Decoders, the window's third place (docs/plans/decoders-app.md, DA-8): what the daemon's
// decoders hear, drawn from each decoder's manifest so a decoder added later shows with no app
// change. The same three columns as the Library: a sidebar of the installed decoders with their
// running jobs, the selected decoder's page, and the inspector on a transmitter or a record
// (`DecoderInspector.swift`). The page's header starts and stops the decoder as a kept job, with
// the daemon's plan in `DecoderPlacement`'s words before it starts and the job's own state and
// detail once it runs; under it the tabs the decoder's output shapes call for: the log always, with the alerts in
// effect above it, the transmitter table for a decoder that declares entities, and the map once a
// record carries a position, or from the start, disabled until then, for a decoder whose display
// says it reports positions (`DecoderMap.swift`). The radio keeps running underneath, as it does
// in the Library. Every word on a record is the manifest's display template, as `ley decode`
// prints it.

import LeylineClient
import LeylineProto
import SwiftUI

struct DecodersBody: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        HStack(spacing: 0) {
            DecodersSidebar()
                .frame(width: Theme.Layout.sidebarWidth)
                .stageRegion(.sidebar)
                .identifiedGroup("decoders.sidebar")
            Rectangle().fill(Theme.border).frame(width: 1)
            DecoderPage()
                .identifiedGroup("decoders.page")
            if session.inspectorShown {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                DecoderInspector()
                    .frame(width: Theme.Layout.inspectorWidth)
                    .stageRegion(.inspector)
                    .identifiedGroup("decoders.inspector")
            }
        }
        .modifier(TakeOverQuestion())
        .sheet(
            isPresented: Binding(
                get: { session.decoders.watchFor != nil },
                set: { if !$0 { session.decoders.watchFor = nil } })
        ) {
            if let name = session.decoders.watchFor, let m = session.decoders.manifest(named: name)
            {
                DecoderWatchSheet(manifest: m).environment(session)
            }
        }
    }
}

/// Start's question when the plan takes a radio from somebody: the daemon's own reason, what
/// `take_over` would retune and pause as its plan says, every frequency in MHz
/// (`DecoderPages.frequencyWords`), and Take the radio, which starts the job with `take_over`. The
/// binding's setter does nothing, as the retune question's does, so the buttons alone answer it.
struct TakeOverQuestion: ViewModifier {
    @Environment(AppSession.self) private var session

    func body(content: Content) -> some View {
        let d = session.decoders
        content.alert(
            "Take the radio?",
            isPresented: Binding(get: { d.takeOverAsk != nil }, set: { _ in }),
            presenting: d.takeOverAsk
        ) { _ in
            Button("Cancel", role: .cancel) { Task { await d.answerTakeOver(false) } }
            Button("Take the radio") { Task { await d.answerTakeOver(true) } }
        } message: { ask in
            let title = d.manifest(named: ask.decoder).map(DecoderPages.title) ?? ask.decoder
            let why = ask.reason.map { ", and \(DecoderPlacement.unstopped($0))" } ?? ""
            Text(
                "\(title) needs the radio at \(DecoderPages.frequencyWords(ask.frequencyHz))\(why). Taking it \(ask.takes.clause). The radio goes back when the decoder stops."
            )
        }
    }
}

// MARK: The sidebar

/// `DECODERS`, then one row per installed decoder: its symbol, its title, and what it is doing,
/// with a line under it for each running job (its frequency and liveness). A click shows its page.
struct DecodersSidebar: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let d = session.decoders
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(text: "Decoders")
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            if d.manifests == nil {
                note(
                    d.listError.map { "The decoders could not be listed: \($0.message)" }
                        ?? (session.isLive ? "Reading the decoders…" : "The daemon is not running.")
                )
            } else if d.listed.isEmpty {
                note("No decoders are installed. ley decoders says where the daemon looks.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(d.listed, id: \.name) { m in
                        let running = DecoderPages.running(of: m, in: session.state.jobs)
                        DecoderRow(
                            manifest: m, running: running, selected: d.selectedName == m.name
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { d.select(m.name) }
                        .pressableGroup("decoders.decoder.\(ViewIdentifier.slug(m.name))") {
                            d.select(m.name)
                        }
                        ForEach(Array(running.enumerated()), id: \.element.jobID) { i, j in
                            DecoderJobLine(job: j)
                                .identifiedGroup(
                                    "decoders.decoder.\(ViewIdentifier.slug(m.name)).job.\(i)")
                        }
                        let watches = Watches.watches(of: m, in: session.state.jobs)
                        ForEach(Array(watches.enumerated()), id: \.element.jobID) { i, j in
                            DecoderWatchLine(
                                job: j, manifest: m,
                                identifier:
                                    "decoders.decoder.\(ViewIdentifier.slug(m.name)).watch.\(i)"
                            ) { Task { await d.stop([j]) } }
                        }
                    }
                    Spacer(minLength: 12)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 6)
    }
}

/// A decoder's row: its symbol, its title in `label`, and under it `Running` in `good`,
/// `Degraded` in `caution`, or its name and first frequency in `inkFaint`; `raised` when selected.
struct DecoderRow: View {
    let manifest: Leyline_V1_DecoderManifest
    let running: [Leyline_V1_Job]
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: DecoderPages.symbol(manifest))
                .font(Theme.Font.decoderGlyph)
                .foregroundStyle(running.isEmpty ? Theme.inkTertiary : Theme.good)
                .frame(width: Theme.Layout.decoderSymbolWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(DecoderPages.title(manifest)).font(Theme.Font.label)
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary).lineLimit(1)
                Text(subtitle).font(Theme.Font.footnote).foregroundStyle(subtitleInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(selected ? Theme.raised : Color.clear)
        .help(manifest.description_p)
    }

    private var subtitle: String {
        if running.contains(where: { $0.state == .degraded }) { return "Degraded" }
        if running.count > 1 { return "\(running.count) running" }
        if !running.isEmpty { return "Running" }
        let hz = manifest.recipe.frequenciesHz.first.map { " · \(Frequency.format($0))" } ?? ""
        return manifest.name + hz
    }

    private var subtitleInk: Color {
        if running.contains(where: { $0.state == .degraded }) { return Theme.caution }
        return running.isEmpty ? Theme.inkFaint : Theme.good
    }
}

/// A running job under its decoder: `144.390 MHz · 12 records, last 3 s ago`, in `caution` while
/// it is degraded.
struct DecoderJobLine: View {
    let job: Leyline_V1_Job

    var body: some View {
        let hz = DecoderPages.frequencyHz(job)
        let detail = DecoderPages.detail(job)
        let words = [hz > 0 ? Frequency.format(hz) : "", detail].filter { !$0.isEmpty }
            .joined(separator: " · ")
        Text(words.isEmpty ? DecoderPages.stateWord(job) : words)
            .font(Theme.Font.footnote)
            .foregroundStyle(job.state == .degraded ? Theme.caution : Theme.inkFaint)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 14 + Theme.Layout.decoderJobIndent).padding(.trailing, 14)
            .padding(.bottom, 6)
            .help("\(job.jobID): \(DecoderPages.stateWord(job))")
    }
}

// MARK: The page

struct DecoderPage: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let d = session.decoders
        ZStack {
            Theme.ground
            if let m = d.selected {
                content(m, d)
            } else if d.manifests != nil, !d.listed.isEmpty {
                Text("Pick a decoder.").font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    private func content(_ m: Leyline_V1_DecoderManifest, _ d: DecoderSession) -> some View {
        VStack(spacing: 0) {
            DecoderPageHeader(manifest: m)
                .frame(minHeight: Theme.Layout.pageHeaderHeight)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 12) {
                if d.tabs.count > 1 { DecoderTabSwitch() }
                Spacer(minLength: 8)
                Text(countWords(d)).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                    .lineLimit(1)
                    .stageRegion(.counts)
            }
            .padding(.horizontal, Theme.Layout.pageInset)
            .frame(height: Theme.Layout.decoderTabBarHeight)
            if let n = d.notice {
                Text(n).font(Theme.Font.label).foregroundStyle(Theme.accentRec)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Layout.pageInset).padding(.bottom, 8)
                    .accessibilityIdentifier("decoders.page.notice")
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            switch d.shownTab {
            case .log: DecoderLog()
            case .table: DecoderTable(manifest: m)
            case .map: DecoderMapTab()
            }
        }
    }

    /// `7 records · 7 transmitters`, `(more not loaded)` when the history was cut.
    private func countWords(_ d: DecoderSession) -> String {
        let n = d.records.entries.count
        let t = d.table.entities.count
        var words = n == 1 ? "1 record" : "\(n) records"
        if t > 0 { words += t == 1 ? " · 1 transmitter" : " · \(t) transmitters" }
        if d.historyTruncated { words += " (older not loaded)" }
        if !d.historyLoaded, n == 0 { words = "" }
        return words
    }
}

/// The decoder's symbol and title over what it is doing, and Start or Stop. While a job runs the
/// line is its state and frequency (`Running · 144.390 MHz`; `caution` while degraded), its
/// `status_detail` being the sidebar's job line and this line's tooltip; otherwise it is where
/// Start would put it (`DecoderPlacement.words`, the daemon's plan), and under it the newest job's
/// failure when it failed for another reason (`DecoderPages.failedLine`).
struct DecoderPageHeader: View {
    let manifest: Leyline_V1_DecoderManifest
    @Environment(AppSession.self) private var session

    var body: some View {
        let d = session.decoders
        let jobs = DecoderPages.jobs(of: manifest, in: session.state.jobs)
        let running = jobs.filter(DecoderPages.isLive)
        let placement = session.decoderPlacement(manifest)
        HStack(spacing: 12) {
            Image(systemName: DecoderPages.symbol(manifest))
                .font(Theme.Font.decoderTitleGlyph)
                .foregroundStyle(running.isEmpty ? Theme.inkTertiary : Theme.good)
            VStack(alignment: .leading, spacing: 3) {
                Text(DecoderPages.title(manifest))
                    .font(Theme.Font.name).tracking(Theme.nameTracking)
                    .foregroundStyle(Theme.ink).lineLimit(1)
                if let j = running.first {
                    // The state and frequency only: the detail is the sidebar's line under the
                    // decoder, so the page does not say it twice; the tooltip carries it.
                    Text(DecoderPages.headerWords(j)).font(Theme.Font.value)
                        .foregroundStyle(j.state == .degraded ? Theme.caution : Theme.inkMuted)
                        .lineLimit(1)
                        .help(DecoderPages.detail(j))
                        .accessibilityIdentifier("decoders.page.state")
                } else {
                    // A sentence, so in `label` and not the numbers' `value`.
                    Text(placement.words).font(Theme.Font.label)
                        .foregroundStyle(placementInk(placement)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("decoders.page.placement")
                    if let failed = DecoderPages.failedLine(
                        newest: jobs.first,
                        placement: placement.declineReason ?? placement.words)
                    {
                        Text(failed).font(Theme.Font.footnote)
                            .foregroundStyle(Theme.accentRec).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("decoders.page.failed")
                    }
                }
            }
            Spacer(minLength: 12)
            // Off where Start is: a watch is placed as a run is, so the sheet could start none.
            // Notify Me… and Stop are icons beside Start's words; the label and tooltip say them.
            Button {
                d.watchFor = manifest.name
            } label: {
                Label("Notify Me…", systemImage: "bell").labelStyle(.iconOnly)
                    .frame(
                        width: Theme.Layout.decoderHeaderIcon,
                        height: Theme.Layout.decoderHeaderIcon)
            }
            .buttonStyle(.bordered)
            .disabled(!session.isLive || !placement.canStart)
            .help("Notify Me…")
            .accessibilityLabel("Notify Me…")
            .accessibilityIdentifier("decoders.page.notify")
            if running.isEmpty {
                let starting = d.starting == manifest.name
                Button(starting ? "Starting…" : "Start") {
                    guard let hz = session.decoderFrequency(manifest) else { return }
                    Task { await d.start(manifest, frequencyHz: hz, placement: placement) }
                }
                .buttonStyle(.bordered)
                .disabled(!session.isLive || !placement.canStart || starting)
                .help(startHelp(placement))
                .accessibilityIdentifier("decoders.page.start")
            } else {
                Button {
                    Task { await d.stop(running) }
                } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly)
                        .frame(
                            width: Theme.Layout.decoderHeaderIcon,
                            height: Theme.Layout.decoderHeaderIcon)
                }
                .buttonStyle(.bordered)
                .help("Stop")
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("decoders.page.stop")
            }
        }
        .padding(.horizontal, Theme.Layout.pageInset).padding(.vertical, 10)
    }

    private func placementInk(_ p: DecoderPlacement) -> Color {
        if p.needsTakeOver { return Theme.caution }
        switch p {
        case .asking, .needsFrequency, .decline: return Theme.inkFaint
        default: return Theme.inkMuted
        }
    }

    private func startHelp(_ p: DecoderPlacement) -> String {
        guard let hz = session.decoderFrequency(manifest) else { return p.words }
        let ask = p.needsTakeOver ? " Asks first, because the radio is in use." : ""
        return
            "Decode \(DecoderPages.frequencyWords(hz)) as a kept job: it runs until Stop, after the window closes too.\(ask)"
    }
}

/// `Log | Table | Map`, the place switch's look: the tab showing raised on `border` in `ink`, the
/// others on none in `inkTertiary`, and a tab that cannot be chosen yet (the map before the first
/// position) in `inkFaint` with its reason as the tooltip.
struct DecoderTabSwitch: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let d = session.decoders
        let outer = Theme.Layout.placeSwitchRadius
        let inset = Theme.Layout.placeSwitchInset
        HStack(spacing: 0) {
            ForEach(d.tabs) { t in
                let shown = d.shownTab == t
                let enabled = d.tabEnabled(t)
                Button {
                    d.tab = t
                } label: {
                    Text(t.title).font(Theme.Font.label)
                        .foregroundStyle(
                            shown ? Theme.ink : enabled ? Theme.inkTertiary : Theme.inkFaint
                        )
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        .background(
                            shown ? Theme.border : Color.clear,
                            in: RoundedRectangle(cornerRadius: outer - inset)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(enabled ? "" : DecoderTab.noPositions)
                .accessibilityAddTraits(shown ? .isSelected : [])
                .accessibilityIdentifier("decoders.tab.\(t.rawValue)")
            }
        }
        .padding(inset)
        .background(Theme.chrome, in: RoundedRectangle(cornerRadius: outer))
        .overlay(RoundedRectangle(cornerRadius: outer).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: The log

/// The alerts in effect, then every record newest first: its time, its transmitter, its kind and
/// its line. The kind column is as wide as the longest kind in the log
/// (`Theme.Layout.decoderKindColumn`). A click shows the record in the inspector.
struct DecoderLog: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let d = session.decoders
        let entries = d.records.entries
        let kindWidth = Theme.Layout.decoderKindColumn(Set(entries.map(\.record.kind))).width
        VStack(spacing: 0) {
            let alerts = d.alerts
            if !alerts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(alerts.enumerated()), id: \.element.id) { i, e in
                        DecoderAlertLine(entry: e)
                            .identifiedGroup("decoders.alert.\(i)")
                    }
                }
                .padding(.horizontal, Theme.Layout.pageInset).padding(.vertical, 10)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            if entries.isEmpty {
                // While a job runs, Start is not there to press: the page says it is listening.
                // While Start is off, the page does not ask for it.
                let listening =
                    d.selected.map { !DecoderPages.running(of: $0, in: session.state.jobs).isEmpty }
                    ?? false
                let canStart =
                    d.selected.map {
                        session.isLive && session.decoderPlacement($0).canStart
                            && d.starting != $0.name
                    } ?? false
                Text(
                    DecoderPages.emptyLogWords(
                        historyLoaded: d.historyLoaded, listening: listening, canStart: canStart)
                )
                .font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            DecoderLogRow(
                                entry: e, name: d.name(of: e.record.deviceID),
                                summary: d.summary(e.record), kindWidth: kindWidth,
                                selected: d.selectedRecord == e.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { d.selectedRecord = e.id }
                            .pressableGroup("decoders.record.\(i)") { d.selectedRecord = e.id }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

/// One record: `19:42:31  N0CALL-3  position  37.8717N 122.2633W # fill-in digipeater`. The time
/// is `inkFaint` when no anchor dated it and it is when the record reached the window.
struct DecoderLogRow: View {
    let entry: RecordEntry
    let name: String
    let summary: String
    /// The kind column's width, the longest kind's in the log.
    let kindWidth: CGFloat
    let selected: Bool

    var body: some View {
        HStack(spacing: Theme.Layout.logColumnGap) {
            Text(DecoderPages.clock(entry.at)).font(Theme.Font.value)
                .foregroundStyle(entry.dated ? Theme.inkMuted : Theme.inkFaint)
                .frame(width: Theme.Layout.decoderTimeWidth, alignment: .leading)
            Text(name.isEmpty ? "—" : name).font(Theme.Font.label)
                .foregroundStyle(Theme.inkSecondary).lineLimit(1)
                .frame(width: Theme.Layout.decoderNameWidth, alignment: .leading)
            Text(entry.record.kind).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
                .frame(width: kindWidth, alignment: .leading)
            Text(summary).font(Theme.Font.label).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Layout.pageInset)
        .frame(height: Theme.Layout.decoderRowHeight)
        .background(selected ? Theme.raised : Color.clear)
        .help(
            entry.dated ? "" : "No anchor dates this record: the time is when it reached the window"
        )
    }
}

/// An alert in effect: its line in `ink` on `alertGround`, with who sent it and until when.
struct DecoderAlertLine: View {
    let entry: RecordEntry
    @Environment(AppSession.self) private var session

    var body: some View {
        let d = session.decoders
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(Theme.Font.rowGlyph)
                .foregroundStyle(Theme.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.summary(entry.record)).font(Theme.Font.label).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    [
                        d.name(of: entry.record.deviceID),
                        DecoderPages.untilWords(entry.record) ?? "",
                    ]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                )
                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Layout.decoderAlertPadding)
        .background(
            Theme.alertGround, in: RoundedRectangle(cornerRadius: Theme.Layout.decoderAlertRadius)
        )
        .contentShape(Rectangle())
        .onTapGesture { d.selectedRecord = entry.id }
    }
}

// MARK: The table

/// The transmitters by name (`DecoderPages.byName`), in `ley track`'s columns: the name (the
/// person's label, else the display's entity name, else the id), the display's columns headed
/// as `ley track` heads them and printed at their precision, how many records, when last heard and
/// the latest line. A click shows
/// it in the inspector.
struct DecoderTable: View {
    let manifest: Leyline_V1_DecoderManifest
    @Environment(AppSession.self) private var session

    var body: some View {
        let d = session.decoders
        let columns = DecoderPages.tableColumns(d.table.display)
        let rows = d.listedTransmitters
        VStack(spacing: 0) {
            // Bottom-aligned, so a head that takes two lines (`GROUND SPEED (kn)`) keeps the
            // row's foot.
            HStack(alignment: .bottom, spacing: Theme.Layout.logColumnGap) {
                head(DecoderPages.tableNameHead, width: Theme.Layout.decoderTableNameWidth)
                ForEach(Array(columns.enumerated()), id: \.element) { i, c in
                    head(
                        DecoderPages.columnHead(c, manifest: manifest),
                        width: Theme.Layout.decoderTableColumnWidth,
                        trailing: DecoderPages.columnIsNumeric(c, manifest: manifest)
                    )
                    .padding(.leading, gap(before: i, columns))
                }
                head(
                    DecoderPages.tableSeenHead, width: Theme.Layout.decoderTableCountWidth,
                    trailing: true)
                head(DecoderPages.tableHeardHead, width: Theme.Layout.decoderTableTimeWidth)
                    .padding(.leading, Theme.Layout.decoderTableTimeGap)
                head(DecoderPages.tableLatestHead, width: nil)
            }
            .padding(.horizontal, Theme.Layout.pageInset).padding(.vertical, 8)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if rows.isEmpty {
                Text("No transmitter heard yet.").font(Theme.Font.label)
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { e in
                            row(e, columns: columns, d: d)
                                .contentShape(Rectangle())
                                .onTapGesture { d.selectedTransmitter = e.deviceID }
                                .pressableGroup(
                                    "decoders.transmitter.\(ViewIdentifier.slug(e.deviceID))"
                                ) { d.selectedTransmitter = e.deviceID }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// The extra gap before a flush-left column that follows a flush-right one, so `TRACK`'s
    /// `135` does not run into `SQUAWK`'s `2761`.
    private func gap(before i: Int, _ columns: [String]) -> CGFloat {
        guard i > 0, DecoderPages.columnIsNumeric(columns[i - 1], manifest: manifest),
            !DecoderPages.columnIsNumeric(columns[i], manifest: manifest)
        else { return 0 }
        return Theme.Layout.decoderTableTimeGap
    }

    /// A column's head as given: `columnHead` writes a field's in capitals with its unit as
    /// `ley track` does (`ALTITUDE (ft)`), so it is not upper-cased again. Two lines at most.
    private func head(_ text: String, width: CGFloat?, trailing: Bool = false) -> some View {
        Text(text).font(Theme.Font.columnHead).tracking(Theme.sectionTracking)
            .foregroundStyle(Theme.inkFaint).lineLimit(2)
            .multilineTextAlignment(trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: trailing ? .trailing : .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func row(_ e: DecoderEntity, columns: [String], d: DecoderSession) -> some View {
        let label = d.labels.name(of: e.deviceID) ?? ""
        let name = d.name(of: e.deviceID)
        let selected = d.selectedTransmitter == e.deviceID
        return HStack(spacing: Theme.Layout.logColumnGap) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.Font.label).foregroundStyle(Theme.ink).lineLimit(1)
                if name != e.deviceID {
                    Text(e.deviceID).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }
            }
            .frame(width: Theme.Layout.decoderTableNameWidth, alignment: .leading)
            ForEach(Array(columns.enumerated()), id: \.element) { i, c in
                Text(d.table.column(c, of: e, label: label) ?? "—").font(Theme.Font.value)
                    .foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    .frame(
                        width: Theme.Layout.decoderTableColumnWidth,
                        alignment: DecoderPages.columnIsNumeric(c, manifest: manifest)
                            ? .trailing : .leading
                    )
                    .padding(.leading, gap(before: i, columns))
            }
            Text("\(e.count)").font(Theme.Font.value).foregroundStyle(Theme.inkSecondary)
                .frame(width: Theme.Layout.decoderTableCountWidth, alignment: .trailing)
            Text(DecoderPages.clock(e.lastHeard)).font(Theme.Font.value)
                .foregroundStyle(Theme.inkMuted)
                .frame(width: Theme.Layout.decoderTableTimeWidth, alignment: .leading)
                .padding(.leading, Theme.Layout.decoderTableTimeGap)
                .help("Heard \(DecoderPages.agoWords(Date().timeIntervalSince(e.lastHeard)))")
            Text(e.summary).font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(e.summary)
        }
        .padding(.horizontal, Theme.Layout.pageInset)
        .padding(.vertical, 4)
        .background(selected ? Theme.raised : Color.clear)
    }
}
