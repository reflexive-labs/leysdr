// SPDX-License-Identifier: Apache-2.0

// The inspector on a transmission, which does not repeat the transport: the Library's inspector
// while a transmission is selected or playing (`AppSession.inspectedPart`). Its place among its
// recording's transmissions, its time and length, its levels, and when the capture clipped during
// it one sentence on what to do next; then the recording it belongs to, with Play all, its span,
// how it ended and what it was recorded with, how much of it is transcribed, and its speech
// actions; then Delete recording…. Show in Finder is in a row's context menu. No progress bar: the
// player has it. Every word is the façade's (`Recordings.partInspectorWords`), so the Linux tests
// hold them.

import LeylineClient
import LeylineProto
import SwiftUI

struct PartInspector: View {
    let manifest: RecordingManifest
    let part: RecordingPart
    /// The over that picks the transmission out of a split part; nil is the part's first.
    let over: Int?
    let group: RecordingGroup
    @Environment(AppSession.self) private var session
    /// The delete confirmation is this view's alone, and transient.
    @State private var confirmingDelete = false

    var body: some View {
        let t = session.speechTimings
        let words = Recordings.partInspectorWords(
            part: part, over: over, of: manifest, running: group.running,
            preRollMs: t.preRollMs, hangMs: t.hangMs)
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
                        row.id == words.levels.first?.id && words.clipped
                            ? Theme.accentRec : Theme.inkSecondary
                    })
                if let sentence = words.clippedSentence {
                    Text(sentence).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                if let sentence = words.droppedSentence {
                    Text(sentence).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .accessibilityIdentifier("library.inspector.dropped")
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
                    .accessibilityIdentifier("library.inspector.playall")
                }
                .padding(.bottom, 4)
                // The recording's grid, then a Decoded row per decoder that ran over it, each a
                // link to the decoder's page.
                VStack(alignment: .leading, spacing: 8) {
                    PartTable(rows: words.recording, ink: { _ in Theme.inkSecondary })
                    let decodes = session.recordingDecodes(for: group.jobID)
                    ForEach(Array(decodes.enumerated()), id: \.element.decoder) { i, found in
                        DecodedRow(
                            label: RecordingDecodes.label(at: i), value: found.line,
                            identifier:
                                "library.inspector.decoded.\(ViewIdentifier.slug(found.decoder))"
                        ) { session.openDecoder(found.decoder) }
                    }
                }
                if let line = session.transcriptionStatus(for: group.jobID)?.line
                    ?? session.coverageLine(for: group.jobID)
                {
                    Text(line).font(Theme.Font.footnote).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .accessibilityIdentifier("library.inspector.transcribed")
                }
                // Transcribe, Transcribe again…, Export words… and Decode With, when any applies.
                HStack(spacing: 8) {
                    SpeechActions(recordingID: group.jobID)
                    DecodeWithMenu(recordingID: group.jobID)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
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
                        .accessibilityIdentifier("library.inspector.delete")
                    }
                    .help(
                        group.running
                            ? Recordings.deleteRefusalWords(jobID: group.jobID)
                            : "Delete this recording and every transmission in it")
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

/// Decode With: the installed decoders whose input is the recording's kind, Transcribe's speech
/// decoder aside (`RecordingDecodes.offered`); a choice starts the kept job over the recording.
/// Nothing while none is offered. A recording still being made is decoded once it has ended, as
/// the daemon says, so its items are off until then. Used in a row's context menu, where it is a
/// submenu, and in the inspector.
struct DecodeWithMenu: View {
    let recordingID: String
    @Environment(AppSession.self) private var session

    var body: some View {
        let offered = session.decodersOffered(for: recordingID)
        let recording = session.manifests[recordingID]?.endedBy.isEmpty ?? true
        if !offered.isEmpty {
            Menu("Decode With") {
                ForEach(offered, id: \.name) { m in
                    Button(DecoderPages.title(m)) {
                        Task { await session.decodeWith(recordingID: recordingID, decoder: m.name) }
                    }
                    .disabled(recording)
                }
            }
            .fixedSize()
            .help(
                recording
                    ? "Decode this recording once it has ended"
                    : "Run a decoder over this recording; its records show on the decoder's page"
            )
            .accessibilityIdentifier("library.decode_with")
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

/// One decoder's row under the recording's table, in its columns: `Decoded` (the first row's
/// label alone) and `APRS · 7 records` in `value` and `accent`, a link to the decoder's page.
struct DecodedRow: View {
    let label: String
    let value: String
    /// The link's identifier: `library.inspector.decoded.<decoder>`.
    let identifier: String
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
                .frame(width: Theme.Layout.partTableLabelWidth, alignment: .leading)
            Button(action: open) {
                Text(value).font(Theme.Font.value).foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .help("Show these records in Decoders")
            .accessibilityIdentifier(identifier)
            Spacer(minLength: 0)
        }
    }
}

/// A label and value table: the label in `label` `inkMuted` in the reading rows' 62 pt column,
/// the value in `value`, its ink chosen per row (the clipped peak's `accentRec`).
///
/// The decoder inspector passes its fields' column (`decoderFieldLabelWidth`), so its grids
/// share one value column, and `fits`: a value wider than what is left breaks after its ` · `
/// when it has one (the signal's level and SNR), else is cut in the middle on one line with the
/// whole of it in its tooltip (a job's id).
struct PartTable: View {
    let rows: [PartTableRow]
    let ink: (PartTableRow) -> Color
    var labelWidth: CGFloat = Theme.Layout.partTableLabelWidth
    var fits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                HStack(alignment: fits ? .firstTextBaseline : .center, spacing: 0) {
                    Text(row.label).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
                        .frame(width: labelWidth, alignment: .leading)
                    if fits {
                        ViewThatFits(in: .horizontal) {
                            value(row, row.value).lineLimit(1).fixedSize()
                            if row.value.contains(" · ") {
                                value(row, row.value.replacingOccurrences(of: " · ", with: " ·\n"))
                                    .fixedSize()
                            }
                            value(row, row.value).lineLimit(1).truncationMode(.middle)
                                .help(row.value)
                        }
                    } else {
                        value(row, row.value).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func value(_ row: PartTableRow, _ text: String) -> some View {
        Text(text).font(Theme.Font.value).foregroundStyle(ink(row))
    }
}
