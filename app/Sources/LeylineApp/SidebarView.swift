// SPDX-License-Identifier: Apache-2.0

// Region 1: bands, bookmarks and recordings (docs/design/app-design-handoff.md; the recordings
// section is docs/design/app-design-handoff-m3.md, "Region 3"). A band is a frequency range; a
// bookmark is a saved station; a recording is a record job's output, listed from the daemon's
// store. Selecting a band applies all of its settings and the expanded row shows them.

import LeylineClient
import LeylineProto
import SwiftUI

struct SidebarView: View {
    @Environment(AppSession.self) private var session
    /// The recording Delete… asked about, until the alert is answered.
    @State private var pendingDelete: RecordingSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header("Bands") { EmptyView() }
                ForEach(session.bands) { band in
                    // A band the radio cannot reach stays listed, disabled, and the tooltip
                    // explains why: a click that could only fail is not offered.
                    let why = session.outOfRangeWords(band)
                    BandRow(
                        band: band, selected: session.band?.id == band.id,
                        squelchDb: session.channel?.squelchDb, disabled: why != nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { if why == nil { Task { await session.select(band: band) } } }
                    .help(why.map { "\(band.name) is \($0)" } ?? "")
                }
                header("Bookmarks") {
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
                if session.bookmarks.list.isEmpty {
                    Text(
                        "Nothing saved yet. ＋ keeps the tuned frequency; `ley bookmarks` shows the same list."
                    )
                    .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
                ForEach(session.bookmarks.list) { b in
                    let tuned = session.tunedHz == b.hz
                    BookmarkRow(
                        bookmark: b, selected: tuned, modified: tuned && session.bookmarkModified,
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
                recordingsSection
                Spacer(minLength: 12)
            }
        }
        .background(Theme.panel)
        .alert(
            "Delete this recording?",
            isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { r in
            Button("Delete", role: .destructive) {
                Task { await session.deleteRecording(r) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text(
                "\(RecordingRow.title(r)) from \(r.startedAt.map { WallClock.dayHM($0) } ?? "an unknown time"), \(RecordingSummary.partsWords(r.parts)). Its parts and its manifest are removed from disk."
            )
        }
    }

    /// Newest first, the running ones at the top with their dot and the daemon's live counters.
    /// A click tunes there and the log shows the recording's parts; the menu reveals it in
    /// Finder, deletes it (the daemon refuses while its job runs) or stops the running one.
    @ViewBuilder private var recordingsSection: some View {
        header("Recordings") { EmptyView() }
        let list = session.sidebarRecordings
        if list.isEmpty {
            Text(
                "Nothing recorded yet. ⌘R records the tuned channel; `ley recordings` lists the same store."
            )
            .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        ForEach(list) { r in
            let job = session.activeRecordJob(r.jobID)
            RecordingRow(
                recording: r, running: job, selected: session.recording?.jobID == r.jobID
            )
            .contentShape(Rectangle())
            .onTapGesture { Task { await session.tune(recording: r) } }
            .contextMenu {
                Button("Reveal in Finder") { Task { await session.revealInFinder(r) } }
                if job != nil {
                    Button("Stop Recording") {
                        Task { await session.stopRecording(jobID: r.jobID) }
                    }
                }
                Button("Delete…", role: .destructive) { pendingDelete = r }
            }
        }
    }

    private func header(_ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            SectionHeader(text: text)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

struct BandRow: View {
    let band: Band
    let selected: Bool
    let squelchDb: Double?
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(band.name).font(Theme.Font.label)
                    .foregroundStyle(
                        disabled ? Theme.inkDisabled : selected ? Theme.ink : Theme.inkSecondary)
                Spacer()
                Text(band.modeWord).font(Theme.Font.valueSmall).foregroundStyle(
                    disabled ? Theme.inkDisabled : Theme.inkFaint)
            }
            if selected {
                Text(detail).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, selected ? 7 : 5)
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

/// The same "selected" style as the band row's: `selected` ground and a `good` dot on the tuned
/// bookmark, a faint dot on the rest (the in-span meaning the dot carried in M1 was not read
/// as one; the owner, 2026-09-21). `changed` in `caution` where the frequency was, when the
/// bookmark's settings and the channel's disagree. The row is an editor while `editing`.
struct BookmarkRow: View {
    let bookmark: Bookmark
    let selected: Bool
    let modified: Bool
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
            if modified {
                Text("changed").font(Theme.Font.valueSmall).foregroundStyle(Theme.caution)
            } else {
                Text(Frequency.fieldParts(bookmark.hz).major)
                    .font(Theme.Font.valueSmall)
                    .foregroundStyle(selected ? Theme.inkTertiary : Theme.inkFaint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(selected ? Theme.selected : Color.clear)
    }
}

/// `462.5625 NFM` over `Tue 18:09 · 12 min · 4 parts`: two lines, because one did not fit the
/// sidebar's 236 pt (M3 handoff, "Decided 2026-09-24"). A running recording's dot is `recording`
/// and its second line is the daemon's live counters, in `caution` while the job is degraded; a
/// finished one has the faint dot the bookmark rows have.
struct RecordingRow: View {
    let recording: RecordingSummary
    let running: Leyline_V1_Job?
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if running != nil {
                RecordingDot(size: Theme.Layout.sidebarDot)
            } else {
                Circle().fill(Theme.borderStrong)
                    .frame(width: Theme.Layout.sidebarDot, height: Theme.Layout.sidebarDot)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(recording)).font(Theme.Font.label)
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary).lineLimit(1)
                Text(detail).font(Theme.Font.valueSmall)
                    .foregroundStyle(running?.state == .degraded ? Theme.caution : Theme.inkFaint)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(selected ? Theme.selected : Color.clear)
        .help(running.map { $0.statusDetail.isEmpty ? "Recording" : $0.statusDetail } ?? "")
    }

    /// `462.5625 NFM`: the frequency as the bookmark rows print it, and the mode.
    static func title(_ r: RecordingSummary) -> String {
        let hz = Frequency.fieldParts(r.frequencyHz).major
        return r.mode == .unspecified ? hz : "\(hz) \(r.mode.word)"
    }

    private var detail: String {
        let day = recording.startedAt.map { WallClock.dayHM($0) } ?? Reading.absent
        if let running {
            return "\(day) · \(Recordings.statusWords(running.statusDetail))"
        }
        return
            "\(day) · \(RecordingSummary.durationWords(ms: recording.durationMs)) · \(RecordingSummary.partsWords(recording.parts))"
    }
}
