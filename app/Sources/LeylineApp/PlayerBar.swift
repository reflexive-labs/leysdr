// SPDX-License-Identifier: Apache-2.0

// The Library's player, in the transport bar's place and at its 88 pt, with the bar's layout
// rule: ⏮, the 44 pt `accent` circle with ⏸ while a part plays and ▶
// otherwise, ⏭, the part's two lines (`GMRS CH3 · Today`, `14:03:20 · part 4 of 4`), a progress
// track, and the volume with its caption. ⏸ is a pause (`Control.SetPlaybackPaused`, the position
// held), not the first build's stop. The track is display only: there is no seeking in v1. The part
// is `AppSession.player` (the one playing, else the selected part, else the page's first row); the
// words are the façade's (`Recordings.playerWords`), so the Linux tests hold them; the position and
// the pause are the mirror's playback, which the daemon publishes four times a second while a part
// plays and once on each pause and resume. Space, ← and → are the Library menu's
// (`LeylineApp.swift`).

import LeylineClient
import LeylineProto
import SwiftUI

struct PlayerBar: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let player = session.player
        // A part is sounding: a playback exists and is not paused. The circle shows ⏸ then.
        let sounding = session.playback != nil && !session.isPaused
        let words = player.map { p in
            let isPlaying = session.playingURI == p.uri
            let playback = isPlaying ? session.playback : nil
            return Recordings.playerWords(
                channelTitle: session.channelTitle(of: p.manifest), part: p.part, of: p.manifest,
                positionFrames: isPlaying ? (playback?.position ?? 0) : nil,
                positionRate: playback?.sampleRate ?? 0, now: Date())
        }
        HStack(alignment: .top, spacing: 20) {
            HStack(spacing: 10) {
                PartStepButton(symbol: "backward.end.fill", enabled: session.canStepPart(-1)) {
                    Task { await session.stepPart(-1) }
                }
                .help("Previous part")
                PlayerButton(
                    sounding: sounding,
                    enabled: session.playback != nil || session.playingURI != nil || player != nil)
                PartStepButton(symbol: "forward.end.fill", enabled: session.canStepPart(1)) {
                    Task { await session.stepPart(1) }
                }
                .help("Next part")
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

/// The player's ⏸ and ▶ in the transport bar's 44 pt `accent` circle: ⏸ while a part sounds pauses
/// it, ▶ resumes a paused one or, with no playback, plays the player's part
/// (`AppSession.togglePlayer`).
struct PlayerButton: View {
    /// A playback exists and is not paused.
    let sounding: Bool
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
                Image(systemName: sounding ? "pause.fill" : "play.fill")
                    .font(Theme.Font.transportGlyph)
                    .foregroundStyle(enabled ? Theme.ground : Theme.inkDisabled)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(sounding ? "Pause" : "Play")
    }
}

/// ⏮ or ⏭ beside the circle, as the design draws them: a bare glyph in `inkTertiary`, `inkDisabled`
/// at the recording's ends, where it is disabled.
struct PartStepButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(Theme.Font.glyph)
                .foregroundStyle(enabled ? Theme.inkTertiary : Theme.inkDisabled)
                .frame(width: Theme.Layout.logRingSize, height: Theme.Layout.logRingSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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
