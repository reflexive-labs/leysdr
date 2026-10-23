// SPDX-License-Identifier: Apache-2.0

// A staged run, for the site's screenshots and for check runs (docs/dev/app.md, "Staged runs";
// docs/plans/site-shots.md, "App shots"; docs/plans/mac-loop.md). `LEYLINE_APP_STAGE` names a
// stage file (`ShotStage`); once the daemon is live the window is set to it and, `settle` seconds
// later, measured into `regions.json` and drawn into `window.png` beside it for `leyshots` to crop
// by. `LEYLINE_APP_CONTROL` names a directory of commands the run then takes (`Control.swift`).
// The stage sets only what the window's own controls set: the place, the inspector, an opened
// sidebar row, a bookmark tuned the way a click on its row tunes it, a Library part selected, and
// a CHIRP file imported through the same call File ▸ Import CHIRP… makes. The radio is the
// daemon's as in any other run (invariant 7), and a staged session writes nothing to UserDefaults
// (`AppSession.staging`), so a shot leaves the person's last band, place and inspector setting as
// they were. A staged run draws the same frame twice: no animation, a caret that does not blink
// (`DeterministicFrames`).
//
// Each region is measured by a `WindowFrameProbe` under its view, the measurement the splash's
// flight already relies on, in the window's coordinates, which run up from the bottom-left corner
// of the frame, toolbar included. The toolbar is hosted outside the content's view tree, so its
// region is the strip above `NSWindow.contentLayoutRect` instead.

import AppKit
import LeylineClient
import SwiftUI

#if LEYLINE_STAGING
    /// Whether this launch is staged (`AppControl.isStaged`); read once, as the environment does not
    /// change.
    let stagedLaunch = AppControl.isStaged()

    @MainActor
    final class Staging {
        /// The daemon gets this long to be live before the stage is given up and no regions are
        /// written: `leyshots` starts the daemon before the app, so a live state is a dial away.
        static let liveSeconds: Double = 15
        /// The window's first channel, made on adoption (`AppSession.adopt`), gets this long before a
        /// bookmark is tuned without it; a control write's round trip is well under a second.
        static let channelSeconds: Double = 5
        /// A tune, and the window appearing, each get this long to be confirmed.
        static let confirmSeconds: Double = 5
        /// The Library's listing and the selected channel's manifests are read after the place
        /// switches, one `ResolveLocalPath` each; this long covers a scene's few recordings.
        static let librarySeconds: Double = 10
        /// `on_air` waits this long for the squelch to open; the scene fixtures key every carrier at
        /// least every 15 s.
        static let onAirSeconds: Double = 30
        /// Once the squelch opens, the inspector's readings get this long to fill before the regions
        /// are written.
        static let onAirFillSeconds: Double = 1.5
        /// After the window is brought forward, this long for Stage Manager's animation to finish.
        static let frontSeconds: Double = 1
        /// A band sweep from the row's Scan band gets this long to finish; 2 m takes a few seconds.
        static let sweepSeconds: Double = 60
        /// A staged part plays this long before it is paused, so the player has started.
        static let playPartSeconds: Double = 0.4
        /// The window's top-left corner, this far in from the top-left of the menu bar's screen's
        /// visible frame.
        static let windowInset: CGFloat = 40

        /// The stage file, and the stage it held; both nil with only a control directory. The
        /// stage is nil too when the file could not be read or was refused: the run is still
        /// staged, so nothing is written to UserDefaults, but nothing is applied and no regions are
        /// written.
        let stageURL: URL?
        let stage: ShotStage?
        /// The command file's directory (`AppControl`), or nil.
        let controlURL: URL?
        private var anchors: [ShotRegion: WindowFrameAnchor] = [:]
        private var started = false
        /// What the stage being applied did, as its log lines say it: a `stage` command's result.
        private var applied: [String] = []
        /// Held for the run's lifetime, so App Nap neither slows the window's timers nor coalesces
        /// the command file's 100 ms reads while the app is in the background or the display is
        /// asleep (docs/plans/mac-loop.md, ML-11). Only a staged run holds it.
        private let activity: NSObjectProtocol

        /// The staged run `LEYLINE_APP_STAGE` and `LEYLINE_APP_CONTROL` ask for, or nil with both
        /// unset.
        static func fromEnvironment() -> Staging? {
            let stage = ShotStage.path()
            let control = AppControl.directory()
            guard stage != nil || control != nil else { return nil }
            return Staging(stagePath: stage, controlPath: control)
        }

        init(stagePath: String?, controlPath: String?) {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason:
                    "a staged run for leyshots: its timers and command file must keep their pace")
            controlURL = controlPath.map { URL(fileURLWithPath: $0) }
            guard let stagePath else {
                stageURL = nil
                stage = nil
                log("stage", "staged by the command file in \(controlPath ?? "")")
                return
            }
            stageURL = URL(fileURLWithPath: stagePath)
            do {
                stage = try ShotStage.read(at: URL(fileURLWithPath: stagePath))
                log("stage", "staged from \(stagePath)")
            } catch {
                stage = nil
                log("stage", "stage file \(stagePath) not used: \(error)")
            }
        }

        /// The probe anchor for a region, made on first use. `window` is the window's content, which
        /// is how the run finds its `NSWindow`; the regions file gives the whole frame for it.
        func anchor(_ region: ShotRegion) -> WindowFrameAnchor {
            if let a = anchors[region] { return a }
            let a = WindowFrameAnchor()
            anchors[region] = a
            return a
        }

        var window: NSWindow? { anchors[.window]?.view?.window }

        /// Applies the stage once, writes the regions and the picture, then takes commands when
        /// the run has a control directory. Called from the first window's task; a second window's
        /// call returns at once.
        func run(_ session: AppSession) async {
            guard !started else { return }
            started = true
            if await until(seconds: Self.confirmSeconds, { self.window != nil }), let window {
                DeterministicFrames.drawAsKey(window)
                place(window)
            }
            if let size = stage?.window { await sizeWindow(size) }
            let live = await until(seconds: Self.liveSeconds) { session.isLive }
            if live, !(await until(seconds: Self.channelSeconds, { session.channel != nil })) {
                log("stage", "no channel within \(Int(Self.channelSeconds)) s; applying anyway")
            }
            let notLive = "the daemon was not live within \(Int(Self.liveSeconds)) s"
            if let stage, let stageURL {
                if live {
                    await apply(stage, session)
                    await front()
                    writeRegions(besideStage: stageURL)
                } else {
                    log("stage", "\(notLive); nothing applied, no regions written")
                }
            }
            guard let controlURL else { return }
            await front()
            await ControlChannel(directory: controlURL, staging: self, session: session)
                .run(problem: live ? nil : notLive)
        }

        /// A `stage` command: the stage applied to the running window, and what it did.
        func applyCommand(_ stage: ShotStage, _ session: AppSession) async -> [String] {
            if let size = stage.window { await sizeWindow(size) }
            await apply(stage, session)
            return applied
        }

        /// Sets what the stage sets, in the order of the table in docs/dev/app.md, "Staged runs",
        /// then lets the window draw for `settle` seconds (and, with `on_air`, waits for an over).
        private func apply(_ stage: ShotStage, _ session: AppSession) async {
            applied = []
            if let shown = stage.inspector {
                session.inspectorShown = shown
                note(shown ? "inspector shown" : "inspector hidden")
            }
            if let name = stage.selectBookmark { await tune(bookmark: name, session) }
            if let path = stage.importCHIRP {
                note("import CHIRP \(path)")
                session.importCHIRP(url: URL(fileURLWithPath: path))
            }
            if let id = stage.expandedBand {
                open(row: id, session)
                if stage.scanBand { await scan(row: id, session) }
            }
            if let z = stage.zoom {
                session.zoom = z
                note("zoom \(z)")
            }
            if let p = stage.place, let place = WindowPlace(rawValue: p.rawValue) {
                session.place = place
                note("place \(p.rawValue)")
            }
            if let index = stage.selectPart {
                await select(part: index, play: stage.playPart, session)
            }
            if let shown = stage.assistant {
                session.assistantShown = shown
                note(shown ? "assistant shown" : "assistant hidden")
            }
            if let id = stage.channelsPicker { openPicker(row: id, session) }
            if let open = stage.settings { await settings(open: open) }
            log("stage", "applied; settling \(stage.settle) s")
            try? await Task.sleep(for: .seconds(stage.settle))
            if stage.onAir { await waitOnAir(session) }
            // A shot shows no text cursor: the sidebar's search field takes focus at launch. A
            // stage that asks for the filter's focus gives it last, so nothing takes it back.
            window?.makeFirstResponder(nil)
            if stage.focusFilter {
                session.goTo()
                note("filter focused")
            }
        }

        /// Stage Manager shrinks a window that is not in front into its strip, and
        /// `screencapture -l` takes it as that tilted thumbnail; the window comes forward first.
        /// A run with a command file takes its own picture, which needs neither, so it leaves the
        /// focus with the person at the Mac and only makes the window key within the app.
        private func front() async {
            guard controlURL == nil else {
                window?.makeKey()
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKey()
            try? await Task.sleep(for: .seconds(Self.frontSeconds))
        }

        /// Logs a step of the stage and keeps it for a `stage` command's answer.
        private func note(_ step: String) {
            applied.append(step)
            log("stage", step)
        }

        /// Presses the row's Scan band as its click does and waits for the sweep to end.
        private func scan(row id: String, _ session: AppSession) async {
            guard let row = session.sidebarRows.first(where: { $0.id == id }) else { return }
            session.scanBand(row: row)
            _ = await until(seconds: Self.confirmSeconds) { session.sweeping }
            let done = await until(seconds: Self.sweepSeconds) { !session.sweeping }
            note(
                done
                    ? "scanned \(row.name)"
                    : "the scan of \(row.name) did not end within \(Int(Self.sweepSeconds)) s")
        }

        /// Waits for an over to start and stay on the air through the fill time, so the readings and
        /// the audio meters are live in the shot with the rest of the over still to come. An over
        /// already on the air when the wait begins is passed over, since it may be about to end, and
        /// so is one that ends during the fill. Gives up after `onAirSeconds` in all.
        private func waitOnAir(_ session: AppSession) async {
            let deadline = Date().addingTimeInterval(Self.onAirSeconds)
            while Date() < deadline {
                _ = await until(seconds: deadline.timeIntervalSinceNow) {
                    session.transmissions?.onAir == nil
                }
                let left = deadline.timeIntervalSinceNow
                guard await until(seconds: left, { session.transmissions?.onAir != nil }) else {
                    break
                }
                try? await Task.sleep(for: .seconds(Self.onAirFillSeconds))
                if session.transmissions?.onAir != nil {
                    note("on the air")
                    return
                }
            }
            note("no over held the squelch open within \(Int(Self.onAirSeconds)) s")
        }

        /// The window on the screen with the menu bar, at the same corner every run, and drawn in
        /// sRGB: a window draws in its screen's colour space, so the same frame on another display
        /// came out several per cent different in every pixel, and macOS moves a popover to fit the
        /// screen it is on. The person's own windows are not touched.
        private func place(_ window: NSWindow) {
            window.colorSpace = .sRGB
            guard let screen = NSScreen.screens.first else { return }
            let visible = screen.visibleFrame
            window.setFrameTopLeftPoint(
                NSPoint(x: visible.minX + Self.windowInset, y: visible.maxY - Self.windowInset))
            log(
                "stage",
                "window \(window.windowNumber) placed on \(window.screen?.localizedName ?? "no screen"), in sRGB"
            )
        }

        /// The window's frame, toolbar included, at the stage's size with its top-left corner kept.
        /// The frame is not autosaved, so the next unstaged launch opens at the size the person left
        /// it. The window stays restorable: marking it otherwise had macOS save the app as having no
        /// windows, and the next launch, staged or not, opened none. `leyshots` launches the app with
        /// `-ApplePersistenceIgnoreState YES`, so a staged run does not reopen saved windows either.
        private func sizeWindow(_ size: ShotStage.WindowSize) async {
            guard await until(seconds: Self.confirmSeconds, { self.window != nil }),
                let window
            else {
                log("stage", "no window within \(Int(Self.confirmSeconds)) s; size not set")
                return
            }
            window.setFrameAutosaveName("")
            let f = window.frame
            window.setFrame(
                NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height),
                display: true)
            note(
                "window \(window.windowNumber) asked for \(Int(size.width))×\(Int(size.height)) pt, is \(Int(window.frame.width))×\(Int(window.frame.height)) pt"
            )
        }

        /// The first bookmark in list order with this name, tuned as its sidebar row's click tunes
        /// it (`AppSession.tune(bookmark:)`).
        private func tune(bookmark name: String, _ session: AppSession) async {
            guard let b = session.bookmarks.list.first(where: { $0.name == name }) else {
                note("no bookmark named \(name); nothing tuned")
                return
            }
            session.tune(bookmark: b)
            let tuned = await until(seconds: Self.confirmSeconds) { session.tunedHz == b.hz }
            note(
                tuned
                    ? "bookmark \(name) tuned at \(b.hz) Hz"
                    : "bookmark \(name) at \(b.hz) Hz not confirmed within \(Int(Self.confirmSeconds)) s"
            )
        }

        /// Opens a sidebar row as its chevron does. The tuned row is open already.
        private func open(row id: String, _ session: AppSession) {
            guard let row = session.sidebarRows.first(where: { $0.id == id }) else {
                note("no sidebar row \(id); none opened")
                return
            }
            if !session.isExpanded(row) { session.toggleExpanded(row) }
            note("row \(row.name) open")
        }

        /// The Settings window, while it is on screen. SwiftUI names its window
        /// `com_apple_SwiftUI_Settings_window`.
        static var settingsWindow: NSWindow? {
            NSApp.windows.first {
                $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true
            }
        }

        /// The Settings window in sRGB and drawn as key, as the main window is, so its picture is
        /// the same on every run however it was opened (the stage, ⌘, or the app menu).
        static func steady(settings w: NSWindow) {
            if w.colorSpace != .sRGB { w.colorSpace = .sRGB }
            DeterministicFrames.drawAsKey(w)
        }

        /// Opens Settings through the app menu's item, as ⌘, does, and waits for its window; or
        /// closes the window.
        private func settings(open: Bool) async {
            if !open {
                Self.settingsWindow?.close()
                note("settings closed")
                return
            }
            if Self.settingsWindow == nil, let (menu, index) = AppMenus.settingsItem() {
                menu.performActionForItem(at: index)
            }
            let shown = await until(seconds: Self.confirmSeconds) { Self.settingsWindow != nil }
            if shown, let w = Self.settingsWindow { Self.steady(settings: w) }
            note(
                shown
                    ? "settings open" : "settings did not open within \(Int(Self.confirmSeconds)) s"
            )
        }

        /// Opens a sidebar row's Channels… popover, as its button does.
        private func openPicker(row id: String, _ session: AppSession) {
            guard let row = session.sidebarRows.first(where: { $0.id == id }) else {
                note("no sidebar row \(id); no channels opened")
                return
            }
            session.pickerBand = row
            note("channels of \(row.name) open")
        }

        /// Selects a part of the selected channel's page, counted down the recent days' rows as the
        /// page draws them. Without `play_part` it does not play: a row's click would play it
        /// through the speakers.
        private func select(part index: Int, play: Bool, _ session: AppSession) async {
            var uri: String?
            _ = await until(seconds: Self.librarySeconds) {
                guard let c = session.selectedChannel else { return false }
                let rows = session.pageDays(for: c).filter { !$0.earlier }.flatMap(\.rows)
                uri = index < rows.count ? rows[index].uri : nil
                return uri != nil
            }
            guard let uri else {
                note(
                    "the page has no part \(index) within \(Int(Self.librarySeconds)) s; none selected"
                )
                return
            }
            session.selectedPartURI = uri
            note("part \(index) selected: \(uri)")
            guard play else { return }
            // Played and paused at once, so the row draws as the current one with a fraction of a
            // second of audio; the pause leaves the player where it stopped.
            await session.clickRow(uri)
            try? await Task.sleep(for: .seconds(Self.playPartSeconds))
            await session.pausePlayback(true)
            note("part \(index) played and paused")
        }

        /// The regions as `regions.json` gives them: the whole frame as `window`, the strip above the
        /// content layout rect as `toolbar`, and each probed region whose view is in this window,
        /// clipped to the frame. A region not on screen (the inspector closed, the Library's regions
        /// in the Radio) is left out. nil before the window exists.
        func measure() -> ShotRegions? {
            guard let window else { return nil }
            let size = window.frame.size
            let height = Double(size.height)
            let bounds = CGRect(origin: .zero, size: size)
            var regions: [ShotRegion: ShotRegions.Rect] = [:]
            regions[.window] = ShotRegions.Rect(windowRect: bounds, windowHeight: height)
            let content = window.contentLayoutRect
            regions[.toolbar] = ShotRegions.Rect(
                windowRect: CGRect(
                    x: 0, y: content.maxY, width: size.width, height: size.height - content.maxY),
                windowHeight: height)
            for (region, anchor) in anchors where region != .window && region != .toolbar {
                guard anchor.view?.window === window, let r = anchor.frameInWindow else { continue }
                regions[region] = ShotRegions.Rect(
                    windowRect: r.intersection(bounds), windowHeight: height)
            }
            return ShotRegions(
                windowNumber: window.windowNumber, scale: Double(window.backingScaleFactor),
                regions: regions)
        }

        /// `window.png` and `regions.json` beside the stage file, the picture first: `leyshots`
        /// takes the regions file as the sign that both are there.
        private func writeRegions(besideStage stageURL: URL) {
            guard let window, let regions = measure() else {
                log("stage", "no window to measure; no regions written")
                return
            }
            let picture = ShotStage.pictureURL(besideStage: stageURL)
            if let png = WindowPicture.png(of: window) {
                do {
                    try AppControl.writeReplacing(png, to: picture)
                    log("stage", "picture written to \(picture.path)")
                } catch {
                    log("stage", "picture not written to \(picture.path): \(error)")
                }
            } else {
                log("stage", "the window drew no picture")
            }
            let url = ShotStage.regionsURL(besideStage: stageURL)
            do {
                try regions.write(to: url)
                let names = regions.regions.keys.map(\.rawValue).sorted().joined(separator: ", ")
                log("stage", "regions written to \(url.path): \(names)")
            } catch {
                log("stage", "regions not written to \(url.path): \(error)")
            }
        }

        /// Waits up to `seconds` for `condition`, checking every 50 ms as
        /// `AppSession.confirmed(within:_:)` does; true when it held.
        private func until(seconds: Double, _ condition: () -> Bool) async -> Bool {
            for _ in 0..<max(0, Int(seconds * 20)) {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }
    }

    extension View {
        /// Measures this view as `region` for a staged run's `regions.json`; nothing without one.
        func stageRegion(_ region: ShotRegion) -> some View {
            modifier(StageRegionProbe(region: region))
        }
    }

    /// The probe `stageRegion(_:)` lays under a view: a `WindowFrameProbe` on the region's anchor in
    /// a staged run, and the view unchanged otherwise.
    struct StageRegionProbe: ViewModifier {
        @Environment(AppSession.self) private var session
        let region: ShotRegion

        @ViewBuilder
        func body(content: Content) -> some View {
            if let staging = session.staging {
                content.background(WindowFrameProbe(anchor: staging.anchor(region)))
            } else {
                content
            }
        }
    }

#else
    /// Whether this launch is staged: never, in a build without the harness.
    let stagedLaunch = false

    extension View {
        /// Without the harness (a notarized build) no region is measured.
        func stageRegion(_ region: ShotRegion) -> some View { self }
    }
#endif
