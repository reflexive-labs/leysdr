// SPDX-License-Identifier: Apache-2.0

// The Mac app: a peer client of the daemon (AGENTS.md invariant 1). It renders what the mirror
// holds and writes through the coalescer; nothing here is authoritative (invariant 7). The window
// is the sidebar, spectrum, waterfall, transport bar, the device menu, the inspector on the right
// and a Tune menu that lists every gesture, plus the Library, the window's second place, with its
// own menu. The app menu checks for updates through Sparkle (`Updater.swift`).

import AppKit
import LeylineClient
import LeylineProto
import SwiftUI
import UniformTypeIdentifiers

@main
struct LeylineApp: App {
    @NSApplicationDelegateAdaptor(Activation.self) private var activation
    @State private var session = AppSession()
    @StateObject private var updater = AppUpdater()

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
            CommandGroup(after: .appInfo) { CheckForUpdatesItem(updater: updater) }
            TuneCommands(session: session)
            LibraryCommands(session: session)
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
        if ShotStage.path() != nil {
            // A staged run waits on the window's task; without a window it would wait silently.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let shown = NSApp.windows.filter(\.isVisible).count
                if shown == 0 { log("stage", "no window opened within 3 s of launch") }
            }
        }
    }
}

/// The menu bar is the reference for every tuning gesture: the canvas shows no gesture hints.
struct TuneCommands: Commands {
    let session: AppSession

    var body: some Commands {
        // The arrows and space belong to the frequency field while it is being typed into, and
        // it keeps them itself: its event monitor swallows them (TransportBarView.swift,
        // `watchClicks`), because a Commands body is not guaranteed to re-evaluate when the
        // session's frequencyEntryShown changes. The bare arrows and space are the Library
        // menu's too: these items are disabled in the Library, and their actions go through
        // `pressArrow` and `pressSpace`, which act for the place showing whichever item fires.
        CommandMenu("Tune") {
            Button("Tune Up") { session.pressArrow(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(session.place == .library)
            Button("Tune Down") { session.pressArrow(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(session.place == .library)
            Button("Fine Tune Up") { session.step(1, fine: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
            Button("Fine Tune Down") { session.step(-1, fine: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
            Divider()
            Button("Enter Frequency…") { session.frequencyEntryShown = true }
                .keyboardShortcut("l", modifiers: [.command])
            // The sidebar's filter takes a name where the field above takes digits.
            Button("Go to…") { session.goTo() }
                .keyboardShortcut("g", modifiers: [.command])
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
            Button(session.isMuted ? "Unmute" : "Mute") { session.pressSpace() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(session.place == .library)
            // `ley stop`'s act: the channel removed, the capture this window made destroyed.
            Button("Stop Listening") { Task { await session.stopListening() } }
                .keyboardShortcut(".", modifiers: [.command])
        }
        CommandGroup(before: .sidebar) {
            // The toolbar's `Radio | Library` switch; checked by the place showing, which the
            // switch shows live if the menu's check lags.
            ForEach(WindowPlace.allCases) { p in
                Toggle(
                    p.title,
                    isOn: Binding(
                        get: { session.place == p }, set: { if $0 { session.place = p } })
                )
                .keyboardShortcut(KeyEquivalent(p.shortcut), modifiers: [.command])
            }
            Divider()
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

/// The Library menu: the player's three controls on space, ← and →, the keys
/// the Tune menu takes in the Radio, and Stop with no key. Space pauses and resumes while a part
/// plays (the player's ⏸) and plays otherwise. Stop ends the part and a Play all or Play day, which
/// the player's circle no longer does, so a paused part is not left holding the live channel
/// silent. They are enabled only in the Library, and the Tune menu's are disabled there; each
/// action goes through `pressSpace`/`pressArrow`, which act for the place showing, so a stale
/// enabled state (a Commands body is not guaranteed to re-evaluate) still does the right thing.
/// Previous and Next are not disabled at a recording's ends for the same reason: a stale disabled
/// item would swallow the key after the selection moved; at an end they do nothing, and the
/// player's buttons show the ends. A text field being typed into keeps the keys (`TextFieldKeys`).
struct LibraryCommands: Commands {
    let session: AppSession

    var body: some Commands {
        CommandMenu("Library") {
            Button(session.playback == nil ? "Play" : session.isPaused ? "Resume" : "Pause") {
                session.pressSpace()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(session.place != .library)
            Button("Stop") { Task { await session.stopPlayback() } }
                .disabled(session.place != .library)
            Button("Previous Part") { session.pressArrow(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(session.place != .library)
            Button("Next Part") { session.pressArrow(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(session.place != .library)
        }
    }
}

/// A bare key a menu item took while a text field is being typed into (the Library's search
/// field), handed to the field's editor as the key would have acted there: a menu's key
/// equivalent can reach the menu before the field sees the key, and a search for `gmrs ch3`
/// must not start a part. The frequency field is not an `NSTextView` and keeps its keys itself
/// (`FrequencyField.watchClicks`).
@MainActor
enum TextFieldKeys {
    enum Key { case space, leftArrow, rightArrow }

    /// true when a text field was being edited and has had the key.
    static func forward(_ key: Key) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable
        else { return false }
        switch key {
        case .space: editor.insertText(" ", replacementRange: editor.selectedRange())
        case .leftArrow: editor.moveLeft(nil)
        case .rightArrow: editor.moveRight(nil)
        }
        return true
    }
}

/// File ▸ the recording items and `Import CHIRP…` (docs/design/channels.md,
/// "CHIRP import"). `Record Transmissions` (⌘R) is the log's switch: checked while a record job
/// runs on the tuned channel, and choosing it flips the switch. Its precondition is checked in the
/// session, which says what is missing in a notice, rather than the item being disabled: a Commands
/// body is not guaranteed to re-evaluate when the session changes, so a disabled item could stay
/// stale, and the check mark can lag the same way; the switch in the log is the live one, as the
/// toolbar's toggle is for the inspector.
struct RecordCommands: Commands {
    let session: AppSession

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Toggle(
                "Record Transmissions",
                isOn: Binding(
                    get: { session.recordSwitchOn },
                    set: { on in Task { await session.setRecording(on) } })
            )
            .keyboardShortcut("r", modifiers: [.command])
            Divider()
            Button("Show Recordings in Finder") { Task { await session.showRecordingsInFinder() } }
            Button("Import CHIRP…") { importCHIRP() }
        }
    }

    /// The open panel for a CHIRP CSV export; the session reads it and says what it did in a
    /// notice. Modal rather than a completion handler, so nothing crosses an AppKit closure.
    @MainActor
    private func importCHIRP() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a CHIRP CSV export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.importCHIRP(url: url)
    }
}
