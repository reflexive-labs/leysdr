// SPDX-License-Identifier: Apache-2.0

// The Library's player, in the transport bar's place and at its 88 pt, with the bar's layout
// rule (docs/design/app-design-handoff-m3.md, "Decided 2026-09-25: the Library", "The player"):
// the 44 pt `accent` circle with ▶ or ■, ⏮ and ⏭ for the previous and next part of the same
// recording, the part's two lines, a progress track, and the volume with its caption. The track
// is display only: the engine's playback `position` is not writable, so there is no seeking in
// v1. The part is `AppSession.player` (the one playing, else the selected part, else the first
// part of the selected channel's top card); the words are the façade's (`Recordings.playerWords`),
// so the Linux tests hold them; the position is the mirror's, which the daemon publishes four
// times a second while a part plays. Space, ← and → are the Library menu's (`LeylineApp.swift`).

import LeylineClient
import LeylineProto
import SwiftUI

struct PlayerBar: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let player = session.player
        let playing = session.playingURI != nil
        let words = player.map { p in
            let isPlaying = session.playingURI == p.uri
            let playback = isPlaying ? session.playback : nil
            return Recordings.playerWords(
                channelTitle: session.channelTitle(of: p.manifest), part: p.part, of: p.manifest,
                positionFrames: isPlaying ? (playback?.position ?? 0) : nil,
                positionRate: playback?.sampleRate ?? 0, now: Date())
        }
        HStack(alignment: .top, spacing: 20) {
            PlayerButton(playing: playing, enabled: playing || player != nil)
                .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                PartStepButton(symbol: "backward.end.fill", enabled: session.canStepPart(-1)) {
                    Task { await session.stepPart(-1) }
                }
                .help("Previous part of this recording (←)")
                PartStepButton(symbol: "forward.end.fill", enabled: session.canStepPart(1)) {
                    Task { await session.stepPart(1) }
                }
                .help("Next part of this recording (→)")
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                if let words {
                    Text(words.title).font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1).truncationMode(.tail)
                    Text(words.time).font(Theme.Font.value).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                } else {
                    Text("No part selected. Click a part on the page to play it.")
                        .font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
                        .lineLimit(2)
                }
            }
            .frame(width: Theme.Layout.playerWordsWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                Text(words?.played ?? "0:00.0").font(Theme.Font.valueSmall)
                    .foregroundStyle(words == nil ? Theme.inkDisabled : Theme.inkMuted)
                PartProgressBar(fraction: words?.fraction ?? 0)
                Text(words?.length ?? "0:00.0").font(Theme.Font.valueSmall)
                    .foregroundStyle(words == nil ? Theme.inkDisabled : Theme.inkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help("How far the part has played; a part plays from its start (no seeking in v1)")
            VolumeControl(library: true)
                .frame(width: 142)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Theme.chrome)
    }
}

/// The player's ▶ and ■ in the transport bar's 44 pt `accent` circle: ▶ plays the player's part,
/// ■ stops the part playing and a Play all with it (`AppSession.togglePlayer`).
struct PlayerButton: View {
    let playing: Bool
    let enabled: Bool
    @Environment(AppSession.self) private var session

    var body: some View {
        Button {
            Task { await session.togglePlayer() }
        } label: {
            ZStack {
                let size = Theme.Layout.transportButton
                Circle().fill(enabled ? Theme.accent : Theme.border)
                    .frame(width: size, height: size)
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(Theme.Font.transportGlyph)
                    .foregroundStyle(enabled ? Theme.ground : Theme.inkDisabled)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(
            playing
                ? "Stop the part (space); the channel's audio comes back"
                : "Play the part (space); the channel's audio is held silent until it ends")
    }
}

/// ⏮ or ⏭: a bordered mini button, disabled at the recording's ends.
struct PartStepButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(Theme.Font.glyph)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .disabled(!enabled)
    }
}
