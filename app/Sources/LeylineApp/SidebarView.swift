// SPDX-License-Identifier: Apache-2.0

// The Radio's sidebar: the bands as one list in frequency order, each row opening to what is inside
// it (docs/design/channels.md, "Bands are the spine of the sidebar"). A click on a band tunes it as
// it always has, and the tuned row is the open one because selection reflects state rather than
// causing it; the chevron opens a row without tuning. A group (`GMRS`, `MURS`) is one row standing
// for its parts. Open, a row shows its range line, a compact strip for Scan band and `Channels…`,
// then the sweep's words or hits and its bookmarks (the design's "Scan the band"); `Channels…`
// opens the plan picker (`PlanPickerView.swift`). The bands the radio cannot tune fold to one dim
// line at the top, a bookmark in no band goes under `Other`, and the filter field flattens
// everything into one list. Every rule here is `LeylineClient`'s (`Sidebar.swift`) and the
// session's; the views read them.

import AppKit
import LeylineClient
import LeylineProto
import SwiftUI

struct SidebarView: View {
    @Environment(AppSession.self) private var session
    @FocusState private var filterFocused: Bool

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
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    /// The filter field in the Library search field's shape, with `＋` beside it. Return tunes the
    /// first row the radio can tune, Escape clears the field and lets it go, and `Go to…` (⌘G)
    /// gives it focus through the session.
    private var filter: some View {
        @Bindable var session = session
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
                    .foregroundStyle(Theme.inkFaint)
                TextField("Band, bookmark or channel", text: $session.filterQuery)
                    .textFieldStyle(.plain).font(Theme.Font.label).foregroundStyle(Theme.ink)
                    .focused($filterFocused)
                    .onSubmit { session.tuneFirstMatch() }
                    .onExitCommand { session.clearFilter() }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .modifier(TuningKeyGuard(focused: filterFocused))
            Button {
                session.bookmarkCurrent()
            } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkTertiary)
            .disabled(session.tunedHz == nil)
            .help("Bookmark the tuned frequency (⌘D)")
        }
        .padding(.horizontal, 14).padding(.top, 12)
        // The session asks for focus (⌘G) and is told when the field has or loses it, so the
        // two never disagree and Escape in the field reaches the menu's state too.
        .onChange(of: session.filterFocused) { _, wanted in
            if filterFocused != wanted { filterFocused = wanted }
        }
        .onChange(of: filterFocused) { _, has in
            if session.filterFocused != has { session.filterFocused = has }
        }
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

    /// One band row and, when it is open, its contents in the design's order: the range line
    /// (in the row), the action strip, the sweep outcome and the bookmarks.
    @ViewBuilder private func bandRow(_ row: Band, bookmarks: [Bookmark]) -> some View {
        // A band the radio cannot reach stays listed, disabled, and the tooltip explains why: a
        // click that could only fail is not offered.
        let why = session.outOfRangeWords(row)
        let tuned = session.tunedRow?.id == row.id
        let expanded = session.isExpanded(row)
        BandRow(
            band: row, selected: tuned, expanded: expanded,
            squelchDb: tuned ? session.channel?.squelchDb : nil, disabled: why != nil
        ) {
            session.toggleExpanded(row)
        }
        .contentShape(Rectangle())
        .onTapGesture { if why == nil { session.tune(row: row) } }
        .help(why.map { "\(row.name) is \($0)" } ?? "")
        .contextMenu {
            Button(scanBandTitle(row)) { session.scanBand(row: row) }.disabled(why != nil)
        }
        if expanded {
            bandActions(row, scanDisabled: why != nil)
            if session.sweepRow?.id == row.id, let outcome = session.sweep?.outcome {
                sweepOutcome(outcome, row: row)
            }
            ForEach(bookmarks) { bookmarkRow($0) }
        }
    }

    /// `Stop` while this row is being swept, else `Scan band`.
    private func scanBandTitle(_ row: Band) -> String {
        session.sweeping && session.sweepRow?.id == row.id ? "Stop" : "Scan band"
    }

    /// The expanded row's controls. Their raised, bordered treatment separates operations from
    /// the bookmark rows that follow; the plan action is absent when the band has no plan.
    private func bandActions(_ row: Band, scanDisabled: Bool) -> some View {
        let stopping = session.sweeping && session.sweepRow?.id == row.id
        let pickerOpen = session.pickerBand?.id == row.id
        return HStack(spacing: Theme.Layout.sidebarActionGap) {
            Button {
                session.scanBand(row: row)
            } label: {
                actionLabel(
                    scanBandTitle(row), systemImage: stopping ? "stop.fill" : "waveform",
                    active: stopping, disabled: scanDisabled)
            }
            .buttonStyle(.plain)
            .disabled(scanDisabled)
            .help(
                stopping
                    ? "Stop the sweep; listening comes back where it was"
                    : "Sweep \(row.name) for what is on the air now. The radio is taken for a few seconds and the audio stops meanwhile."
            )

            if !row.plan().isEmpty {
                Button {
                    session.pickerBand = row
                } label: {
                    actionLabel(
                        "Channels…", systemImage: "list.bullet", active: pickerOpen,
                        disabled: false)
                }
                .buttonStyle(.plain)
                .help("The \(row.name) plan: pick a channel by name")
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
            Spacer(minLength: 0)
        }
        .padding(.leading, 14 + Theme.Layout.sidebarIndent).padding(.trailing, 14)
        .padding(.vertical, 4)
    }

    private func actionLabel(
        _ title: String, systemImage: String, active: Bool, disabled: Bool
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(Theme.Font.footnote)
            .foregroundStyle(disabled ? Theme.inkDisabled : Theme.inkTertiary)
            .padding(.horizontal, Theme.Layout.sidebarActionPaddingX)
            .padding(.vertical, Theme.Layout.sidebarActionPaddingY)
            .background(
                active ? Theme.selected : Theme.raised,
                in: RoundedRectangle(cornerRadius: Theme.Layout.sidebarActionRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.sidebarActionRadius)
                    .stroke(active ? Theme.borderFocus : Theme.border)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Layout.sidebarActionRadius))
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
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkTertiary)
            .help("Bookmark \(hit.label)")
        }
        .padding(.leading, 14 + Theme.Layout.sidebarIndent).padding(.trailing, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { session.tune(hit: hit) }
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
        }
    }
}

/// The band's name and mode, the chevron at the trailing edge, and the range line when the row
/// is open. `selected` is the tuned row's ground and ink; `expanded` is the tuned row and the
/// one the chevron opened. The chevron is a button of its own so its click never reaches the
/// row's tap, which tunes.
struct BandRow: View {
    let band: Band
    let selected: Bool
    let expanded: Bool
    let squelchDb: Double?
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
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.inkFaint)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Close \(band.name)" : "Open \(band.name) without tuning it")
            }
            if expanded {
                Text(detail).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, expanded ? 7 : 5)
        .background(selected ? Theme.selected : Color.clear)
    }

    /// `87.5 – 108 MHz · 200 kHz · sq −28`, one line: the band's range, never the capture's,
    /// with trailing zeros dropped.
    private var detail: String {
        var parts = [
            "\(Frequency.mhz(band.minHz)) – \(Frequency.mhz(band.maxHz)) MHz",
            Frequency.width(band.bandwidthHz),
        ]
        if let s = squelchDb {
            parts.append(
                s.isNaN
                    ? "sq off"
                    : "sq \(String(Int(s.rounded())).replacingOccurrences(of: "-", with: "−"))")
        }
        return parts.joined(separator: " · ")
    }
}

/// `7 bands below what this radio tunes`, one dim line at the top of the list, with the chevron
/// showing whether its rows are out. The rows are the disabled band rows themselves.
struct OutOfRangeLine: View {
    let fold: OutOfRangeFold
    let expanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(fold.words).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
            Spacer()
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.inkFaint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .help(expanded ? "Hide them" : "Show them; they cannot be tuned with this radio")
    }
}

/// The same "selected" style as the band row's: `selected` ground and a `good` dot on the tuned
/// bookmark, a faint dot on the rest; a dot meaning "inside the span" was not read as one.
/// `changed` in `caution` where the frequency was, when the
/// bookmark's settings and the channel's disagree. While a record job runs on the bookmark's
/// frequency and mode, tuned or not and whoever started it, a 6 pt `accentRec` dot sits 6 pt
/// left of the frequency, whose ink does not change. The row is an editor while `editing`. A
/// bookmark on a plan channel shows the channel's name in the frequency's place (`ch17`, `WX3`),
/// what `ley monitor` prints in its CHANNEL column. The row sits in from the band's name by
/// `sidebarIndent`, under its band.
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
                NameField(initial: bookmark.name, font: Theme.Font.label, editing: $editing) {
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
                    Text(Plans.name(at: bookmark.hz) ?? Frequency.fieldParts(bookmark.hz).major)
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
        ownWindow = NSApp.keyWindow.map { ObjectIdentifier($0) }
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
            let taken: Bool = MainActor.assumeIsolated {
                Self.take(keyCode: code, shift: shift, picker: picker, move: move)
            }
            return taken ? nil : event
        }
    }

    /// Space and the two arrows, performed on the field editor from the key code; Up and Down
    /// for the picker. Anything else goes on to the menu and the field as usual. Returns true
    /// when the key was taken.
    @MainActor
    private static func take(
        keyCode: UInt16, shift: Bool, picker: Bool, move: Binding<Int>
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
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
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
