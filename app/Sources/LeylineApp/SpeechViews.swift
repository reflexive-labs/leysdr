// SPDX-License-Identifier: Apache-2.0

// Speech in the Library: under each part row of the channel page, the words of each over as the
// speech decoder heard them, with the model and its confidence muted beside them and the callsigns
// a pattern found as chips; a click on a line plays that over alone (`AppSession.play(part:over:)`,
// `StartPlayback`'s sample range). The actions on a recording's speech (Transcribe, Transcribe
// again… with the model picker, Export words…) are one menu, shown in a part row's context menu
// and the part inspector, and the question Transcribe asks is a confirmation dialog in
// `ley transcribe`'s words. Every word and rule is the façade's (`SpeechRecords`), so the Linux
// tests hold them; nothing here keeps state beyond the sheet's own field.

import AppKit
import LeylineClient
import LeylineProto
import SwiftUI
import UniformTypeIdentifiers

/// A part's speech lines under its row, and on a recording's first row the line of a
/// transcription that runs, is held up or failed. Nothing while no speech has been read for the
/// recording.
struct PartSpeechLines: View {
    let row: PartRow
    @Environment(AppSession.self) private var session

    var body: some View {
        let lines = session.speech(for: row.jobID)?.shown(part: row.part) ?? []
        let first = row.bracket == .none || row.bracket == .first
        let status = first ? session.transcriptionStatus(for: row.jobID) : nil
        let cut = first && session.speechTruncated.contains(row.jobID)
        if !lines.isEmpty || status != nil || cut {
            VStack(alignment: .leading, spacing: Theme.Layout.speechLineGap) {
                if let status {
                    Text(status.line).font(Theme.Font.footnote)
                        .foregroundStyle(statusInk(status.job.state)).lineLimit(2)
                        .padding(.horizontal, Theme.Layout.speechLinePaddingX)
                }
                ForEach(lines) { line in
                    SpeechLineView(line: line)
                        .id(SpeechLineView.scrollID(partURI: line.partURI, over: line.over))
                }
                if cut {
                    // The daemon cut the read at its limit: the lines here are kept, and some are
                    // missing.
                    Text("(more words not loaded)").font(Theme.Font.footnote)
                        .foregroundStyle(Theme.inkFaintest)
                        .padding(.horizontal, Theme.Layout.speechLinePaddingX)
                }
            }
            .padding(.leading, Theme.Layout.speechIndent)
            .padding(.vertical, 2)
        }
    }

    /// A held-up job's `status_detail` in `caution`, as a degraded record job's line is; a failure
    /// in `accentRec`; a running one muted.
    private func statusInk(_ state: Leyline_V1_JobState) -> Color {
        switch state {
        case .degraded: Theme.caution
        case .failed: Theme.accentRec
        default: Theme.inkMuted
        }
    }
}

/// One over's words: the text in `body`, then the model and confidence in `footnote` `inkFaint`,
/// then each callsign as a chip. The line is a button of its own, a sibling of the part row's,
/// so no button holds another; a click plays the over, and on the over playing pauses or resumes
/// it. The playing over sits on `raised` with its text in `accent`; the over the search or a
/// click selected sits on `selected`.
struct SpeechLineView: View {
    let line: SpeechLine
    @Environment(AppSession.self) private var session

    /// The id the page scrolls to when the search selects this over.
    static func scrollID(partURI: String, over: Int) -> String { "\(partURI)#\(over)" }

    var body: some View {
        let playing = session.playingURI == line.partURI && session.playingOver == line.over
        let picked = session.selectedPartURI == line.partURI && session.selectedOver == line.over
        Button {
            Task { await session.play(part: line.partURI, over: line.over) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.text.isEmpty ? "(nothing heard)" : line.text)
                    .font(Theme.Font.body)
                    .foregroundStyle(
                        playing ? Theme.accent : line.text.isEmpty ? Theme.inkFaint : Theme.ink
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(line.callsigns, id: \.self) { call in
                    CallsignChip(call: call)
                }
                if !sourceWords.isEmpty {
                    Text(sourceWords).font(Theme.Font.footnote)
                        .foregroundStyle(Theme.inkFaint).lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Layout.speechLinePaddingX)
            .padding(.vertical, Theme.Layout.speechLinePaddingY)
            .background(
                playing ? Theme.raised : picked ? Theme.selected : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Layout.speechLineRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(playing: playing))
    }

    /// The model and confidence after the words; a staged shot may hide them
    /// (`ShotStage.hideEngineLabel`), since its engine is the scripted one.
    private var sourceWords: String {
        #if LEYLINE_STAGING
            if session.hidesEngineLabel { return "" }
        #endif
        return line.sourceWords
    }

    private func help(playing: Bool) -> String {
        if playing { return session.isPaused ? "Resume this over" : "Pause this over" }
        return "Play over \(line.over) of part \(line.part): what the model heard, to check by ear"
    }
}

/// A callsign the pattern found, in `valueSmall` on a `border` ground: a pattern match over the
/// text, not a decoded identity, which the tooltip says.
struct CallsignChip: View {
    let call: String

    var body: some View {
        Text(call).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .padding(.horizontal, Theme.Layout.chipPaddingX)
            .padding(.vertical, Theme.Layout.chipPaddingY)
            .background(Theme.border, in: RoundedRectangle(cornerRadius: Theme.Layout.chipRadius))
            .help("A callsign pattern found in the words, not a decoded identity")
    }
}

/// The actions on one recording's speech, as menu items: Transcribe while it has none and none
/// runs, Transcribe again… once it has some, and Export words… as text or SRT once it has some.
/// Transcribe is left out entirely while `canTranscribe` is false (no speech decoder, or one that
/// needs a key and none is set), so no AI control shows without a key. Used in a part row's
/// context menu and, as buttons, in the part inspector.
struct SpeechActions: View {
    let recordingID: String
    @Environment(AppSession.self) private var session

    var body: some View {
        let speech = session.speech(for: recordingID)
        let hasWords = !(speech?.all.isEmpty ?? true)
        let running =
            session.transcriptionStatus(for: recordingID).map {
                $0.job.state == .running || $0.job.state == .degraded
            } ?? false
        if session.canTranscribe, session.isGated(recordingID: recordingID), !running {
            if hasWords {
                Button("Transcribe again…") { session.transcribeAgainFor = recordingID }
            } else {
                Button("Transcribe") { session.askTranscribe(recordingID: recordingID) }
            }
        }
        if hasWords {
            Menu("Export words…") {
                ForEach(SpeechExportFormat.allCases, id: \.self) { format in
                    Button(format == .text ? "As text…" : "As SRT subtitles…") {
                        SpeechExportPanel.run(
                            session: session, recordingID: recordingID, format: format)
                    }
                }
            }
        }
    }
}

/// Export words…: the save panel, then the session writes the file. Run from a menu item, on the
/// main actor.
enum SpeechExportPanel {
    @MainActor static func run(session: AppSession, recordingID: String, format: SpeechExportFormat)
    {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "\(recordingID).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.exportSpeech(recordingID: recordingID, format: format, to: url)
    }
}

/// Transcribe again…: the speech model to use, picked from the ones the catalogue lists with the
/// one in use first, or Custom… and typed, as `ley transcribe --model` takes it; Continue asks the
/// question. The field shows only for Custom…, so the picker and the field never disagree.
struct TranscribeAgainSheet: View {
    let recordingID: String
    @Environment(AppSession.self) private var session
    /// The picker's choice and the typed model, transient to the sheet.
    @State private var picked = ""
    @State private var typed = ""
    /// The picker's tag for a typed model; no model is called this.
    private static let customTag = "\u{0}custom"

    var body: some View {
        let models = session.speechModels
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcribe again").font(Theme.Font.title).foregroundStyle(Theme.ink)
            Text(
                "The earlier words stay; the Library shows the newest. The model chosen here is the speech model for later jobs too."
            )
            .font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            Picker("Model", selection: $picked) {
                ForEach(models.offered, id: \.self) { Text($0).tag($0) }
                Text("Custom…").tag(Self.customTag)
            }
            if picked == Self.customTag {
                TextField("Model", text: $typed).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { session.transcribeAgainFor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    session.transcribeAgainFor = nil
                    let chosen =
                        picked == Self.customTag
                        ? typed.trimmingCharacters(in: .whitespaces) : picked
                    session.askTranscribe(
                        recordingID: recordingID, model: chosen == models.current ? "" : chosen)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    picked == Self.customTag && typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: Theme.Layout.transcribeSheetWidth)
        .background(Theme.panel)
        .onAppear { picked = models.offered.first ?? Self.customTag }
    }
}

/// The Library's speech dialogs, on its body once: Transcribe's question in `ley transcribe`'s
/// words, and the Transcribe again sheet.
struct SpeechDialogs: ViewModifier {
    @Environment(AppSession.self) private var session

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                session.transcribeAsk?.question ?? "",
                isPresented: Binding(
                    get: { session.transcribeAsk != nil },
                    set: { if !$0 { session.transcribeAsk = nil } }),
                titleVisibility: .visible,
                presenting: session.transcribeAsk
            ) { ask in
                Button("Transcribe") {
                    Task {
                        await session.transcribe(recordingID: ask.recordingID, model: ask.model)
                    }
                }
                Button("Cancel", role: .cancel) { session.transcribeAsk = nil }
            } message: { _ in
                Text("Nothing is sent until you choose Transcribe.")
            }
            .sheet(
                isPresented: Binding(
                    get: { session.transcribeAgainFor != nil },
                    set: { if !$0 { session.transcribeAgainFor = nil } })
            ) {
                if let id = session.transcribeAgainFor {
                    TranscribeAgainSheet(recordingID: id)
                        .environment(session)
                }
            }
    }
}
