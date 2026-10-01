// SPDX-License-Identifier: Apache-2.0

// The inspector on a part, which does not repeat the transport: the Library's inspector while a
// part is selected or playing (`AppSession.inspectedPart`). The part's place in its recording, its
// time and length, its levels and overs, and when the capture clipped during it one sentence on
// what to do next; then the recording it belongs to, with Play all, its span, how it ended and what
// it was recorded with; then the two things that can be done to a recording from here: its file
// shown in Finder, and the whole recording deleted. No progress bar: the player has it. Every word
// is the façade's (`Recordings.partInspectorWords`), so the Linux tests hold them.

import LeylineClient
import LeylineProto
import SwiftUI

struct PartInspector: View {
    let manifest: RecordingManifest
    let part: RecordingPart
    let group: RecordingGroup
    @Environment(AppSession.self) private var session
    /// The delete confirmation is this view's alone, and transient.
    @State private var confirmingDelete = false

    var body: some View {
        let uri = manifest.uri(of: part)
        let words = Recordings.partInspectorWords(
            part: part, of: manifest, running: group.running)
        let title = session.selectedChannel?.title ?? Frequency.format(manifest.frequencyHz)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ColumnHeadText(text: words.heading)
                Text(words.time).font(Theme.Font.name).monospacedDigit()
                    .foregroundStyle(Theme.ink).lineLimit(1)
                    .padding(.bottom, 4)
                PartTable(
                    rows: words.levels,
                    ink: { row in
                        row.label == "Peak" && words.clipped ? Theme.accentRec : Theme.inkSecondary
                    })
                if let sentence = words.clippedSentence {
                    Text(sentence).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    ColumnHeadText(text: "Recording")
                    Spacer(minLength: 8)
                    Button {
                        Task { await session.playAll(group) }
                    } label: {
                        Text(words.playAll).font(Theme.Font.label).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Play all")
                }
                .padding(.bottom, 4)
                PartTable(rows: words.recording, ink: { _ in Theme.inkSecondary })
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Show in Finder") {
                        Task { await session.revealInFinder(uri: uri) }
                    }
                    .help("Select this part's file in Finder")
                    // The tooltip sits on a wrapper: a disabled button shows none of its own.
                    HStack {
                        Button {
                            confirmingDelete = true
                        } label: {
                            Text("Delete recording…")
                                .foregroundStyle(
                                    group.running ? Theme.inkDisabled : Theme.accentRec)
                        }
                        .disabled(group.running)
                    }
                    .help(
                        group.running
                            ? Recordings.deleteRefusalWords(jobID: group.jobID)
                            : "Delete every part of this recording")
                }
                .buttonStyle(.bordered)
                Text(words.deleteLine).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .alert(
            Recordings.deleteQuestion(channelTitle: title, group: group, now: Date()),
            isPresented: $confirmingDelete
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await session.deleteRecording(uri: group.uri) }
            }
        } message: {
            Text(words.deleteLine)
        }
    }
}

/// `PART 4 OF 4`, `RECORDING`: an inspector section's head in `columnHead`, tracked as the
/// section headers are, `inkFaint`.
struct ColumnHeadText: View {
    let text: String

    var body: some View {
        Text(text.uppercased()).font(Theme.Font.columnHead).tracking(Theme.sectionTracking)
            .foregroundStyle(Theme.inkFaint).lineLimit(1)
    }
}

/// A label and value table: the label in `label` `inkMuted` in the reading rows' 62 pt column,
/// the value in `value`, its ink chosen per row (the clipped peak's `accentRec`).
struct PartTable: View {
    let rows: [PartTableRow]
    let ink: (PartTableRow) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                HStack(spacing: 0) {
                    Text(row.label).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
                        .frame(width: Theme.Layout.partTableLabelWidth, alignment: .leading)
                    Text(row.value).font(Theme.Font.value).foregroundStyle(ink(row))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
