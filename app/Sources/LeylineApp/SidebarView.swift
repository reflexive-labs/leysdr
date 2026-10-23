// SPDX-License-Identifier: Apache-2.0

// The Radio's sidebar: the bands as one list in frequency order, each row opening to what is inside
// it (docs/design/channels.md, "Bands are the spine of the sidebar"). A click on a band tunes it as
// it always has, and the tuned row is the open one because selection reflects state rather than
// causing it; the chevron opens a row without tuning. A group (`GMRS`, `MURS`) is one row standing
// for its parts. Open, a row shows its range line, two action rows, Scan band and `Channels ›`,
// then the sweep's words or hits and its bookmarks (the design's "Scan the band"), all on one
// raised ground; `Channels` opens the plan picker (`PlanPickerView.swift`). The bands the radio
// cannot tune fold to one dim line at the top, a bookmark in no band goes under `Other`, and the
// filter field flattens everything into one list. Every rule here is `LeylineClient`'s (`Sidebar.swift`) and the
// session's; the views read them.

import AppKit
import LeylineClient
import LeylineProto
import SwiftUI

struct SidebarView: View {
    @Environment(AppSession.self) private var session
    @FocusState private var filterFocused: Bool
    /// When the plan picker last closed, by a pick, Escape or a click away.
    @State private var pickerClosedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filter.padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if session.filterQuery.isEmpty {
                        spine
                    } else {
                        matches
                    }
                    Spacer(minLength: 12)
                }
            }
            // The rows arrive in several passes (the bands, then the radio's range, then the
            // open band's channels), and without an anchor the list sometimes settled a couple
            // of points scrolled: it opens at the top whatever arrives first.
            .defaultScrollAnchor(.top)
            .accessibilityIdentifier("sidebar.list")
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .identifiedGroup("sidebar")
    }

    /// The filter field in the Library search field's shape, with `＋` beside it. Return tunes the
    /// first row the radio can tune, Escape clears the field and lets it go, and `Go to…` (⌘G)
    /// gives it focus through the session.
    private var filter: some View {
        @Bindable var session = session
        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(Theme.Font.fieldGlyph)
                    .foregroundStyle(Theme.inkFaint)
                TextField("", text: $session.filterQuery)
                    .textFieldStyle(.plain).font(Theme.Font.label).foregroundStyle(Theme.ink)
                    .frame(height: Theme.Layout.labelFieldHeight)
                    .focused($filterFocused)
                    .onSubmit { session.tuneFirstMatch() }
                    .onExitCommand { session.clearFilter() }
                    .accessibilityIdentifier("sidebar.filter")
                    .accessibilityLabel("Band, bookmark or channel")
                    .fieldPlaceholder(
                        "Band, bookmark or channel", font: Theme.Font.label,
                        shown: session.filterQuery.isEmpty)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .modifier(TuningKeyGuard(focused: filterFocused))
            Button {
                session.bookmarkCurrent()
            } label: {
                Image(systemName: "plus").font(Theme.Font.buttonGlyph)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkTertiary)
            .disabled(session.tunedHz == nil)
            .help("Bookmark the tuned frequency (⌘D)")
            .accessibilityIdentifier("sidebar.add")
        }
        .padding(.horizontal, 14).padding(.top, 12)
        // The session asks for focus (⌘G) and is told when the field has or loses it, so the
        // two never disagree and Escape in the field reaches the menu's state too.
        .onChange(of: session.filterFocused) { _, wanted in
            if filterFocused != wanted { filterFocused = wanted }
        }
        .onChange(of: filterFocused) { _, has in
            if has, !session.filterFocused, unaskedAfterPicker() {
                filterFocused = false
                return
            }
            if session.filterFocused != has { session.filterFocused = has }
        }
        .onChange(of: session.pickerBand?.id) { was, now in
            if was != nil, now == nil { pickerClosedAt = Date() }
        }
        // ⌘G from the Library asks for the focus before this field exists, so the change
        // above never fires; it is given once the field is in the window.
        .onAppear {
            if session.filterFocused {
                DispatchQueue.main.async { filterFocused = true }
            }
        }
    }

    /// Whether the filter took the focus by itself as the plan picker closed: AppKit gives a
    /// window that becomes key with nothing focused to its first key view, the filter, so
    /// Space and the arrows typed there rather than muting and tuning. The filter takes the
    /// focus on ⌘G (the session asks first) or a click only, so a focus within a second of the
    /// close that no click in the window brought is given back.
    private func unaskedAfterPicker() -> Bool {
        guard let closed = pickerClosedAt, Date().timeIntervalSince(closed) < 1 else {
            return false
        }
        let event = NSApp.currentEvent
        let click =
            event?.type == .leftMouseDown && event?.window?.styleMask.contains(.titled) == true
        return !click
    }

    /// The list with nothing typed: the out-of-range line and, opened, its rows; the rows the
    /// radio tunes; then `Other` for the bookmarks in no band.
    @ViewBuilder private var spine: some View {
        let byRow = Dictionary(grouping: session.bookmarks.list) {
            Bands.sidebarRow(for: $0.hz)?.id ?? ""
        }
        let fold = session.outOfRange
        let folded = Set(fold?.bands.map(\.id) ?? [])
        if let fold {
            OutOfRangeLine(fold: fold, expanded: session.outOfRangeExpanded)
                .contentShape(Rectangle())
                .onTapGesture { session.outOfRangeExpanded.toggle() }
                .pressableGroup("sidebar.outofrange") { session.outOfRangeExpanded.toggle() }
            if session.outOfRangeExpanded {
                ForEach(fold.bands) { row in bandRow(row, bookmarks: byRow[row.id] ?? []) }
            }
        }
        ForEach(session.sidebarRows.filter { !folded.contains($0.id) }) { row in
            bandRow(row, bookmarks: byRow[row.id] ?? [])
        }
        if let other = byRow[""], !other.isEmpty {
            SectionHeader(text: "Other")
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
            ForEach(other) { bookmarkRow($0) }
        }
    }

    /// One band row and, when it is open, its contents in the design's order on one raised
    /// ground: the range line (in the row), the two action rows, the sweep outcome and the
    /// bookmarks.
    private func bandRow(_ row: Band, bookmarks: [Bookmark]) -> some View {
        // A band the radio cannot reach stays listed and reads disabled, its actions too, and
        // its help says why: a click that could only fail is not offered. Its chevron still
        // opens it, to show its bookmarks.
        let why = session.outOfRangeWords(row).map { "\(row.name) is \($0)" }
        let tuned = session.tunedRow?.id == row.id
        let expanded = session.isExpanded(row)
        return VStack(alignment: .leading, spacing: 0) {
            BandRow(
                band: row, selected: tuned, expanded: expanded,
                squelch: tuned
                    ? session.channel.map {
                        SquelchWords.short($0.squelchDb, auto: session.squelchIsAuto)
                    } : nil,
                disabled: why != nil
            ) {
                session.toggleExpanded(row)
            }
            .contentShape(Rectangle())
            .onTapGesture { if why == nil { session.tune(row: row) } }
            .contextMenu {
                Button(scanBandTitle(row)) { session.scanBand(row: row) }.disabled(why != nil)
            }
            .pressableGroup("sidebar.band.\(row.id)") { if why == nil { session.tune(row: row) } }
            .help(why ?? "")
            .disabled(why != nil)
            if expanded {
                bandActions(row, why: why)
                if session.sweepRow?.id == row.id, let outcome = session.sweep?.outcome {
                    sweepOutcome(outcome, row: row)
                }
                ForEach(bookmarks) { bookmarkRow($0) }
            }
        }
        .background(expanded ? Theme.raised : Color.clear)
    }

    /// `Stop` while this row is being swept, else `Scan band`.
    private func scanBandTitle(_ row: Band) -> String {
        session.sweeping && session.sweepRow?.id == row.id ? "Stop" : "Scan band"
    }

    /// The open row's two actions as rows of the list, at a bookmark row's height and indent:
    /// the glyph where a bookmark's dot is, the label where its name is, in a dimmer ink and
    /// with no chrome. `Channels` ends in `›` and opens the picker beside it; it is absent when
    /// the band has no plan. `why` disables both and is their help.
    private func bandActions(_ row: Band, why: String?) -> some View {
        let stopping = session.sweeping && session.sweepRow?.id == row.id
        let pickerOpen = session.pickerBand?.id == row.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                session.scanBand(row: row)
            } label: {
                SidebarActionRow(
                    title: scanBandTitle(row), systemImage: stopping ? "stop.fill" : "waveform",
                    active: stopping, disabled: why != nil)
            }
            .buttonStyle(.plain)
            .disabled(why != nil)
            .accessibilityIdentifier("sidebar.band.\(row.id).scan")
            .help(
                why
                    ?? (stopping
                        ? "Stop the sweep; listening comes back where it was"
                        : "Sweep \(row.name) for what is on the air now. The radio is taken for a few seconds and the audio stops meanwhile.")
            )

            if !row.plan().isEmpty {
                Button {
                    session.pickerBand = row
                } label: {
                    SidebarActionRow(
                        title: "Channels", systemImage: "list.bullet", active: pickerOpen,
                        disabled: why != nil, opens: true)
                }
                .buttonStyle(.plain)
                .disabled(why != nil)
                .help(why ?? "The \(row.name) plan: pick a channel by name")
                .accessibilityIdentifier("sidebar.band.\(row.id).channels")
                .popover(
                    isPresented: Binding(
                        get: { session.pickerBand?.id == row.id },
                        set: {
                            if !$0, session.pickerBand?.id == row.id {
                                session.pickerBand = nil
                            }
                        }
                    ), arrowEdge: .trailing
                ) {
                    PlanPickerView(band: row)
                }
            }
        }
    }

    /// Under the item, for the row the sweep is of: the progress words while it runs; then the
    /// hits strongest first, or the one line for nothing found, or a failed job's reason in
    /// `caution`; and the coverage note when the sweep looked at less than the band.
    @ViewBuilder private func sweepOutcome(_ outcome: SweepOutcome, row: Band) -> some View {
        switch outcome {
        case .running(let progress):
            sweepLine(progress.words(band: row), ink: Theme.inkFaint)
        case .found(let result):
            ForEach(result.hits) { hitRow($0) }
            if let words = result.coverageWords(band: row) {
                sweepLine(words, ink: Theme.inkFaintest)
            }
        case .empty(let result):
            sweepLine(SweepResult.emptyWords, ink: Theme.inkFaintest)
            if let words = result.coverageWords(band: row) {
                sweepLine(words, ink: Theme.inkFaintest)
            }
        case .failed(let detail):
            sweepLine(detail, ink: Theme.caution)
        case .cancelled:
            EmptyView()
        }
    }

    /// One line of the sweep's words, wrapping, indented with the row's contents.
    private func sweepLine(_ words: String, ink: Color) -> some View {
        Text(words).font(Theme.Font.footnote).foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 14 + Theme.Layout.sidebarIndent).padding(.trailing, 14)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A hit: its name or frequency, its SNR, and `＋` at the trailing edge to bookmark it. A
    /// tap on the row tunes it.
    private func hitRow(_ hit: SweepHit) -> some View {
        let snr = String(format: "%.0f", hit.snrDb)
        return HStack(spacing: 8) {
            Text(hit.label).font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            Spacer()
            Text("\(snr) dB").font(Theme.Font.valueSmall).foregroundStyle(Theme.inkTertiary)
            Button {
                session.bookmark(hit: hit)
            } label: {
                Image(systemName: "plus").font(Theme.Font.buttonGlyph)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkTertiary)
            .help("Bookmark \(hit.label)")
            .accessibilityIdentifier(
                "sidebar.hit.\(ViewIdentifier.hitSlug(hit, among: session.sweepHits)).add")
        }
        .padding(.leading, 14 + Theme.Layout.sidebarIndent).padding(.trailing, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { session.tune(hit: hit) }
        .pressableGroup(
            "sidebar.hit.\(ViewIdentifier.hitSlug(hit, among: session.sweepHits))"
        ) { session.tune(hit: hit) }
        .help(
            "\(Frequency.format(hit.hz)) · \(snr) dB over the floor · heard in \(hit.looks) of \(hit.looksPossible) looks"
        )
    }

    private func bookmarkRow(_ b: Bookmark) -> some View {
        let tuned = session.tunedHz == b.hz
        return BookmarkRow(
            bookmark: b, selected: tuned, modified: tuned && session.bookmarkModified,
            recording: session.isRecording(b),
            editing: Binding(
                get: { session.editingBookmarkID == b.id },
                set: {
                    if !$0, session.editingBookmarkID == b.id {
                        session.editingBookmarkID = nil
                    }
                })
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if session.editingBookmarkID != b.id { session.tune(bookmark: b) }
        }
        .contextMenu {
            Button("Tune") { session.tune(bookmark: b) }
            Button("Rename") { session.editingBookmarkID = b.id }
            if tuned, session.bookmarkModified {
                Button("Save mode and width") { session.saveTunedBookmark() }
            }
            // Moves the bookmark to the tuned frequency: the name stays, the
            // frequency, mode and width become the channel's. Shown only when the
            // tuned frequency differs from the bookmark's.
            if let hz = session.tunedHz, hz != b.hz {
                Button("Replace with \(Frequency.format(hz))") {
                    session.replace(bookmark: b)
                }
            }
            Button("Remove", role: .destructive) { session.remove(bookmark: b) }
        }
        .pressableGroup("sidebar.bookmark.\(ViewIdentifier.slug(b.name))") {
            if session.editingBookmarkID != b.id { session.tune(bookmark: b) }
        }
    }

    /// The flat list while something is typed: the index's rows in its order, each naming its
    /// band at the trailing edge; a row the radio cannot tune is dimmed and does nothing; none
    /// is one line on the Library's pattern.
    @ViewBuilder private var matches: some View {
        let query = session.filterQuery
        let rows = session.sidebarIndex.matches(query)
        if rows.isEmpty {
            Text("No matches for “\(query)”.")
                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                .padding(.horizontal, 14).padding(.vertical, 6)
        }
        ForEach(rows) { match in
            MatchRow(match: match)
                .contentShape(Rectangle())
                .onTapGesture { session.tune(match: match) }
                .pressableGroup("sidebar.match.\(ViewIdentifier.slug(match.id))") {
                    session.tune(match: match)
                }
        }
    }
}

/// The band's name and mode, the chevron at the trailing edge, and the range line when the row
/// is open. `selected` is the tuned row's ink; `expanded` is the tuned row and the one the
/// chevron opened, whose ground the sidebar raises with its contents'. The chevron is a button
/// of its own so its click never reaches the row's tap, which tunes, and it stays enabled on a
/// band the radio cannot tune, whose row is disabled.
struct BandRow: View {
    let band: Band
    let selected: Bool
    let expanded: Bool
    /// `sq −53`, `sq auto` or `sq off` on the tuned row (`SquelchWords.short`), else nil.
    let squelch: String?
    var disabled = false
    let onChevron: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(band.name).font(Theme.Font.label)
                    .foregroundStyle(
                        disabled ? Theme.inkDisabled : selected ? Theme.ink : Theme.inkSecondary)
                Spacer()
                Text(band.modeWord).font(Theme.Font.valueSmall).foregroundStyle(
                    disabled ? Theme.inkDisabled : Theme.inkFaint)
                Button(action: onChevron) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(Theme.Font.glyph)
                        .foregroundStyle(Theme.inkFaint)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Close \(band.name)" : "Open \(band.name) without tuning it")
                .accessibilityIdentifier("sidebar.band.\(band.id).chevron")
                .environment(\.isEnabled, true)
            }
            if expanded {
                // The longest form the sidebar's width holds, so the squelch at its end is
                // never the part cut (`462.5375 – 467.7375 MHz` alone is 22 characters).
                let forms = detailForms
                ViewThatFits(in: .horizontal) {
                    Text(forms.0).fixedSize()
                    Text(forms.1).fixedSize()
                    Text(forms.2).lineLimit(1).truncationMode(.tail)
                }
                .font(Theme.Font.valueSmall).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, expanded ? 7 : 5)
    }

    /// `87.5 – 108 MHz · 200 kHz · sq −28`, one line: the band's range, never the capture's,
    /// with trailing zeros dropped. Then the same closed up around the dash, then without the
    /// width, for the bands whose edges carry four decimals (GMRS, MURS).
    private var detailForms: (String, String, String) {
        let lo = Frequency.mhz(band.minHz)
        let hi = Frequency.mhz(band.maxHz)
        let tail = squelch.map { " · \($0)" } ?? ""
        let width = Frequency.width(band.bandwidthHz)
        return (
            "\(lo) – \(hi) MHz · \(width)\(tail)",
            "\(lo)–\(hi) MHz · \(width)\(tail)",
            "\(lo)–\(hi) MHz\(tail)"
        )
    }
}

/// An open band's action as a row of the list: the glyph centred where a bookmark row draws
/// its dot, the label where its name starts, in `inkTertiary` with the glyph in `inkFaint`
/// (a step up each while `active`: the sweep running, the picker open), and `›` at the trailing
/// edge, under the band rows' chevrons, when it `opens` something beside it.
struct SidebarActionRow: View {
    let title: String
    let systemImage: String
    let active: Bool
    let disabled: Bool
    var opens = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(Theme.Font.rowGlyph)
                .foregroundStyle(
                    disabled ? Theme.inkDisabled : active ? Theme.inkTertiary : Theme.inkFaint
                )
                .frame(width: Theme.Layout.sidebarDot)
            Text(title).font(Theme.Font.label)
                .foregroundStyle(
                    disabled ? Theme.inkDisabled : active ? Theme.inkSecondary : Theme.inkTertiary
                )
                .lineLimit(1)
            Spacer(minLength: 0)
            if opens {
                Image(systemName: "chevron.right").font(Theme.Font.glyph)
                    .foregroundStyle(disabled ? Theme.inkDisabled : Theme.inkFaint)
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.leading, 14 + Theme.Layout.sidebarIndent).padding(.trailing, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// `17 bands out of range`, one dim line at the top of the list, with the chevron showing
/// whether its rows are out and the help saying where they lie. The rows are the disabled band
/// rows themselves.
struct OutOfRangeLine: View {
    let fold: OutOfRangeFold
    let expanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(fold.words).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
            Spacer()
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(Theme.Font.glyph)
                .foregroundStyle(Theme.inkFaint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .help(expanded ? "Hide them" : "Show them; they lie \(fold.side)")
    }
}

/// The same "selected" style as the band row's: `selected` ground and a `good` dot on the tuned
/// bookmark, a faint dot on the rest; a dot meaning "inside the span" was not read as one.
/// `changed` in `caution` where the frequency was, when the
/// bookmark's settings and the channel's disagree. While a record job runs on the bookmark's
/// frequency and mode, tuned or not and whoever started it, a 6 pt `accentRec` dot sits 6 pt
/// left of the frequency, whose ink does not change. The row is an editor while `editing`. A
/// bookmark on a plan channel shows the channel's name in the frequency's place (`ch17`, `WX3`),
/// what `ley monitor` prints in its CHANNEL column, and `≈ calling` for one near a channel but
/// not on it (`Plans.rowLabel`). The row never shows the bookmark's tone, which the inspector's
/// field holds. The row sits in from the band's name by `sidebarIndent`, under its band.
struct BookmarkRow: View {
    let bookmark: Bookmark
    let selected: Bool
    let modified: Bool
    let recording: Bool
    @Binding var editing: Bool
    @Environment(AppSession.self) private var session

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(selected ? Theme.good : Theme.borderStrong).frame(width: 6, height: 6)
            if editing {
                NameField(
                    initial: bookmark.name, font: Theme.Font.label,
                    height: Theme.Layout.labelFieldHeight, editing: $editing
                ) {
                    session.rename(bookmark: bookmark, to: $0)
                }
            } else {
                Text(bookmark.name).font(Theme.Font.label)
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary).lineLimit(1)
            }
            Spacer()
            // The dot sits against the frequency, 6 pt from it, not against the name.
            HStack(spacing: Theme.Layout.bookmarkDotGap) {
                if recording {
                    RecordingDot(size: Theme.Layout.sidebarDot)
                        .help("Recording \(bookmark.name) while its squelch is open")
                }
                if modified {
                    Text("changed").font(Theme.Font.valueSmall).foregroundStyle(Theme.caution)
                } else {
                    Text(Plans.rowLabel(at: bookmark.hz) ?? Frequency.fieldParts(bookmark.hz).major)
                        .font(Theme.Font.valueSmall)
                        .foregroundStyle(selected ? Theme.inkTertiary : Theme.inkFaint)
                        .help(Frequency.format(bookmark.hz))
                }
            }
        }
        .padding(.leading, 14 + Theme.Layout.sidebarIndent).padding(.trailing, 14)
        .padding(.vertical, 5)
        .background(selected ? Theme.selected : Color.clear)
    }
}

/// One row of the filtered list: the match's label, its band's name at the trailing edge in
/// `inkFaint`, and `inkDisabled` throughout for a row the radio cannot tune.
struct MatchRow: View {
    let match: SidebarMatch

    var body: some View {
        HStack(spacing: 8) {
            Text(match.label).font(Theme.Font.label)
                .foregroundStyle(match.disabled ? Theme.inkDisabled : Theme.inkSecondary)
                .lineLimit(1)
            Spacer()
            Text(match.rowName).font(Theme.Font.valueSmall)
                .foregroundStyle(match.disabled ? Theme.inkDisabled : Theme.inkFaint)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .help(match.hz.map(Frequency.format) ?? "")
    }
}

/// `NameField`'s key monitor (`InspectorView.swift`) for the filter field and the picker's field:
/// while the field has focus its window's bare space and arrow keys go to
/// the field editor directly, because the Tune menu holds them as key equivalents and a menu's
/// equivalent is matched before a text field sees the key, so typing `24 coast` would mute the
/// radio and tune it. With `pickerKeys` the Up and Down arrows move the picker's highlight
/// through the session instead. Only scalars and a state binding cross into the main actor: an
/// NSEvent and the session are not Sendable.
struct TuningKeyGuard: ViewModifier {
    let focused: Bool
    var pickerKeys = false
    @Environment(AppSession.self) private var session
    @State private var monitor: Any?
    /// The window the field was focused in, compared by identity out on the monitor's side.
    @State private var ownWindow: ObjectIdentifier?
    @State private var pickerMove = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: focused) { _, isFocused in
                if isFocused { watchKeys() } else { end() }
            }
            .onChange(of: pickerMove) { old, new in
                session.movePickerHighlight(new - old)
            }
            // A popover or window that closes mid-edit never reports the focus lost; without
            // this the monitor would outlive the field and swallow keys for the process.
            .onDisappear { end() }
    }

    private func end() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        ownWindow = nil
    }

    private func watchKeys() {
        if monitor != nil { return }
        // The key window. A check run never activates the app, and an inactive app has no key
        // window, so a staged run alone falls back to the window being typed into, a popover's
        // before the window it opened from.
        var window = NSApp.keyWindow
        if window == nil, DeterministicFrames.staged {
            // A field editor, or the text view a multi-line field (the assistant's) types into.
            window = NSApp.windows.filter {
                $0.isVisible && ($0.firstResponder as? NSTextView)?.isEditable == true
            }.min { a, _ in a.parent != nil }
        }
        ownWindow = window.map { ObjectIdentifier($0) }
        let own = ownWindow
        let move = $pickerMove
        let picker = pickerKeys
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard let own, let window = event.window, ObjectIdentifier(window) == own else {
                return event
            }
            let code = event.keyCode
            // The arrows carry the keypad and function flags on their own; those are not
            // modifiers the user held.
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            guard held.isEmpty || held == [.shift] else { return event }
            let shift = held == [.shift]
            let number = window.windowNumber
            let taken: Bool = MainActor.assumeIsolated {
                Self.take(
                    keyCode: code, shift: shift, picker: picker, move: move, window: number)
            }
            return taken ? nil : event
        }
    }

    /// Space and the two arrows, performed on the field editor from the key code; Up and Down
    /// for the picker. Anything else goes on to the menu and the field as usual. Returns true
    /// when the key was taken.
    @MainActor
    private static func take(
        keyCode: UInt16, shift: Bool, picker: Bool, move: Binding<Int>, window: Int
    )
        -> Bool
    {
        if picker, !shift {
            switch keyCode {
            case 126:  // Up arrow: the highlight, one row up
                move.wrappedValue -= 1
                return true
            case 125:  // Down arrow: one row down
                move.wrappedValue += 1
                return true
            default:
                break
            }
        }
        // The editor of the window the key came to, which is the key window when the app is
        // active; a check run's app never is, and has no key window.
        guard let editor = NSApp.window(withWindowNumber: window)?.firstResponder as? NSTextView
        else { return false }
        switch keyCode {
        case 49:  // Space: the Tune menu's Mute/Unmute, and a word break in a name
            editor.insertText(" ", replacementRange: editor.selectedRange())
            return true
        case 123:  // Left arrow: Tune Down, and Fine Tune Down with ⇧
            if shift { editor.moveLeftAndModifySelection(nil) } else { editor.moveLeft(nil) }
            return true
        case 124:  // Right arrow: likewise
            if shift { editor.moveRightAndModifySelection(nil) } else { editor.moveRight(nil) }
            return true
        default:
            return false
        }
    }
}
