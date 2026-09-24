// SPDX-License-Identifier: Apache-2.0

// The inspector on a part (docs/design/app-design-handoff-m3.md, 8c, "The inspector, on a part",
// and its screen): in place of the Channel panel's regions while the Recordings source shows and
// a part is selected or playing (`AppSession.inspectedPart`). The part's place in its recording,
// its time and length, the playback's position (the mirror's `Playback.position`; there is no
// seeking in v1, so the bar is display only), the levels and settings the manifest recorded, and
// the two things that can be done to a recording from here: its file shown in Finder, and the
// whole recording deleted. Every word is the façade's (`Recordings.partWords`, `partTable`,
// `deleteWords`), so the Linux tests hold them.

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
        let playback = session.playingURI == uri ? session.playback : nil
        let playing = session.playingURI == uri
        let words = Recordings.partWords(
            part: part, of: manifest, positionFrames: playing ? (playback?.position ?? 0) : nil,
            positionRate: playback?.sampleRate ?? 0, now: Date())
        let deleteLine = Recordings.deleteWords(parts: group.parts)
        let title = session.selectedChannel?.title ?? Frequency.format(manifest.frequencyHz)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(words.title).font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                Text(words.time).font(Theme.Font.name).monospacedDigit()
                    .foregroundStyle(Theme.ink).lineLimit(1)
                PartProgressBar(fraction: words.fraction).padding(.top, 4)
                Text(words.progress).font(Theme.Font.value).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Recordings.partTable(part: part, of: manifest, running: group.running)) {
                    row in
                    HStack(spacing: 0) {
                        Text(row.label).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
                            .frame(width: Theme.Layout.partTableLabelWidth, alignment: .leading)
                        Text(row.value).font(Theme.Font.value).foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Show in Finder") {
                        Task { await session.revealInFinder(partURI: uri) }
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
                Text(deleteLine).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
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
            Text(deleteLine)
        }
    }
}

/// The 3 pt `accent` bar on a `border` track, full width, as far as the part has played; empty
/// while it is not playing.
struct PartProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.border)
                Rectangle().fill(Theme.accent)
                    .frame(width: geo.size.width * min(max(fraction.isFinite ? fraction : 0, 0), 1))
            }
        }
        .frame(height: Theme.Layout.partProgressHeight)
    }
}
