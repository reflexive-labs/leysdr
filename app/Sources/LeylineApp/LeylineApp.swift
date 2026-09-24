// SPDX-License-Identifier: Apache-2.0

// The Mac app: a peer client of the daemon (AGENTS.md invariant 1). It renders what the mirror
// holds and writes through the coalescer; nothing here is authoritative (invariant 7). The window
// is M1 of docs/design/app-design-handoff.md: sidebar, spectrum, waterfall, transport bar, the
// device menu, and a Tune menu that lists every gesture (docs/plans/app.md, "The M1 cut"), plus
// M2's inspector on the right (docs/design/app-design-handoff-m2.md).

import AppKit
import LeylineClient
import LeylineProto
import SwiftUI

@main
struct LeylineApp: App {
    @NSApplicationDelegateAdaptor(Activation.self) private var activation
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup("Leyline") {
            MainWindow()
                .environment(session)
                .task { await session.start() }
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(
            width: Theme.Layout.defaultWindow.width, height: Theme.Layout.defaultWindow.height
        )
        .windowToolbarStyle(.unified)
        .commands {
            TuneCommands(session: session)
            RecordCommands(session: session)
        }
    }
}

/// A bare executable (`make app-run`, no bundle) is not activated by macOS: its window opens
/// behind the terminal without focus or a Dock icon. This is the launch a bundle would get.
final class Activation: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

/// The menu bar is the reference for every tuning gesture: the canvas shows no gesture hints
/// (docs/design/app-design-handoff.md, "Tuning").
struct TuneCommands: Commands {
    let session: AppSession

    var body: some Commands {
        // The arrows and space belong to the frequency field while it is being typed into, and
        // it keeps them itself: its event monitor swallows them (TransportBarView.swift,
        // `watchClicks`), because a Commands body is not guaranteed to re-evaluate when the
        // session's frequencyEntryShown changes.
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
            Button(session.isMuted ? "Unmute" : "Mute") { Task { await session.toggleMute() } }
                .keyboardShortcut(.space, modifiers: [])
            // `ley stop`'s act: the channel removed, the capture this window made destroyed.
            Button("Stop Listening") { Task { await session.stopListening() } }
                .keyboardShortcut(".", modifiers: [.command])
        }
        CommandGroup(after: .sidebar) {
            // The title is read when the menu is built; as with Mute/Unmute above, a Commands
            // body is not guaranteed to re-evaluate, so the toolbar's toggle is the live one.
            Button(session.inspectorShown ? "Hide Inspector" : "Show Inspector") {
                session.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { session.zoomIn() }.keyboardShortcut("=", modifiers: [.command])
            Button("Zoom Out") { session.zoomOut() }.keyboardShortcut("-", modifiers: [.command])
            Toggle(
                "Max Hold", isOn: Binding(get: { session.maxHold }, set: { session.maxHold = $0 }))
            Button("Clear Max Hold") { session.clearMaxHold() }
        }
    }

    static let modes: [Leyline_V1_DemodMode] = [.am, .nfm, .wfm, .usb, .lsb, .cw]
}

/// File ▸ the recording items (plans/app.md, APP-5). Each one checks its own precondition in the
/// session and says what is missing in a notice, rather than being disabled: a Commands body is
/// not guaranteed to re-evaluate when the session changes, so a disabled item could stay stale.
struct RecordCommands: Commands {
    let session: AppSession

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Record Channel") { Task { await session.startRecording(continuous: false) } }
                .keyboardShortcut("r", modifiers: [.command])
            Button("Record Continuously") {
                Task { await session.startRecording(continuous: true) }
            }
            Button("Stop Recording") { Task { await session.stopRecording() } }
            Divider()
            Button("Show Recordings in Finder") { Task { await session.showRecordingsInFinder() } }
        }
    }
}
