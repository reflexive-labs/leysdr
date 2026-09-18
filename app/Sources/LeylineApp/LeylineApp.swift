// SPDX-License-Identifier: Apache-2.0

// The Mac app: a peer client of the daemon (CLAUDE.md invariant 1). It renders what the mirror
// holds and writes through the coalescer; nothing here is authoritative (invariant 7). The window
// is M1 of docs/design/app-design-handoff.md: sidebar, spectrum, waterfall, transport bar, the
// device menu, and a Tune menu that names every gesture (docs/plans/app.md, "The M1 cut").

import LeylineClient
import LeylineProto
import SwiftUI

@main
struct LeylineApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup("Leyline") {
            MainWindow()
                .environment(session)
                .task { await session.start() }
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: Theme.Layout.defaultWindow.width, height: Theme.Layout.defaultWindow.height)
        .windowToolbarStyle(.unified)
        .commands { TuneCommands(session: session) }
    }
}

/// The menu bar is the reference for every tuning gesture: the canvas never explains itself
/// (docs/design/app-design-handoff.md, "Tuning").
struct TuneCommands: Commands {
    let session: AppSession

    var body: some Commands {
        CommandMenu("Tune") {
            Button("Tune Up") { session.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Tune Down") { session.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Fine Tune Up") { session.step(1, fine: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
            Button("Fine Tune Down") { session.step(-1, fine: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
            Divider()
            Button("Enter Frequency…") { session.frequencyEntryShown = true }
                .keyboardShortcut("l", modifiers: [.command])
            Button("Snap to Nearest Bookmark") { session.snapToNearestBookmark() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Centre on Strongest Signal") { session.centreOnStrongest() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Menu("Mode") {
                ForEach(TuneCommands.modes, id: \.rawValue) { m in
                    Button(m.word) { session.setMode(m) }
                }
            }
            Menu("Bandwidth") {
                let mode = session.channel?.mode ?? .nfm
                ForEach(mode.offeredBandwidthsHz, id: \.self) { bw in
                    Button(Frequency.width(bw)) { session.setBandwidth(bw) }
                }
            }
            Divider()
            Button("Bookmark This Frequency") { session.bookmarkCurrent() }
                .keyboardShortcut("d", modifiers: [.command])
            Button(session.isPlaying ? "Pause" : "Play") { Task { await session.togglePlay() } }
                .keyboardShortcut(.space, modifiers: [])
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { session.zoomIn() }.keyboardShortcut("=", modifiers: [.command])
            Button("Zoom Out") { session.zoomOut() }.keyboardShortcut("-", modifiers: [.command])
            Toggle("Max Hold", isOn: Binding(get: { session.maxHold }, set: { session.maxHold = $0 }))
        }
    }

    static let modes: [Leyline_V1_DemodMode] = [.am, .nfm, .wfm, .usb, .lsb, .cw]
}
