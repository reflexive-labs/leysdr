// SPDX-License-Identifier: Apache-2.0

// A staged run for the site's screenshots (docs/dev/app.md, "Staged runs"; docs/plans/
// site-shots.md, "App shots"). `LEYLINE_APP_STAGE` names a stage file (`ShotStage`); once the
// daemon is live the window is set to it and, `settle` seconds later, measured into
// `regions.json` beside it for `leyshots` to crop by. The stage sets only what the window's own
// controls set: the place, the inspector, an opened sidebar row, a bookmark tuned the way a click
// on its row tunes it, a Library part selected, and a CHIRP file imported through the same call
// File ▸ Import CHIRP… makes. The radio is the daemon's as in any other run (invariant 7), and a
// staged session writes nothing to UserDefaults (`AppSession.staging`), so a shot leaves the
// person's last band, place and inspector setting as they were.
//
// Each region is measured by a `WindowFrameProbe` under its view, the measurement the splash's
// flight already relies on, in the window's coordinates, which run up from the bottom-left corner
// of the frame, toolbar included. The toolbar is hosted outside the content's view tree, so its
// region is the strip above `NSWindow.contentLayoutRect` instead.

import AppKit
import LeylineClient
import SwiftUI

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

    let stageURL: URL
    /// nil when the file could not be read or was refused; the run is still staged, so nothing
    /// is written to UserDefaults, but nothing is applied and no regions are written.
    let stage: ShotStage?
    private var anchors: [ShotRegion: WindowFrameAnchor] = [:]
    private var started = false

    /// The staged run `LEYLINE_APP_STAGE` asks for, or nil with the variable unset.
    static func fromEnvironment() -> Staging? {
        ShotStage.path().map { Staging(path: $0) }
    }

    init(path: String) {
        stageURL = URL(fileURLWithPath: path)
        do {
            stage = try ShotStage.read(at: stageURL)
            log("stage", "staged from \(path)")
        } catch {
            stage = nil
            log("stage", "stage file \(path) not used: \(error)")
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

    private var window: NSWindow? { anchors[.window]?.view?.window }

    /// Applies the stage once and writes the regions. Called from the first window's task; a
    /// second window's call returns at once.
    func run(_ session: AppSession) async {
        guard !started, let stage else { return }
        started = true
        if let size = stage.window { await sizeWindow(size) }
        guard await until(seconds: Self.liveSeconds, { session.isLive }) else {
            log(
                "stage",
                "the daemon was not live within \(Int(Self.liveSeconds)) s; nothing applied, no regions written"
            )
            return
        }
        if !(await until(seconds: Self.channelSeconds, { session.channel != nil })) {
            log("stage", "no channel within \(Int(Self.channelSeconds)) s; applying anyway")
        }
        if let shown = stage.inspector {
            session.inspectorShown = shown
            log("stage", shown ? "inspector shown" : "inspector hidden")
        }
        if let name = stage.selectBookmark { await tune(bookmark: name, session) }
        if let path = stage.importCHIRP {
            log("stage", "import CHIRP \(path)")
            session.importCHIRP(url: URL(fileURLWithPath: path))
        }
        if let id = stage.expandedBand {
            open(row: id, session)
            if stage.scanBand { await scan(row: id, session) }
        }
        if let z = stage.zoom {
            session.zoom = z
            log("stage", "zoom \(z)")
        }
        if let p = stage.place, let place = WindowPlace(rawValue: p.rawValue) {
            session.place = place
        }
        if let index = stage.selectPart { await select(part: index, session) }
        log("stage", "applied; regions in \(stage.settle) s")
        try? await Task.sleep(for: .seconds(stage.settle))
        if stage.onAir { await waitOnAir(session) }
        // A shot shows no text cursor: the sidebar's search field takes focus at launch.
        window?.makeFirstResponder(nil)
        // Stage Manager shrinks a window that is not in front into its strip, and
        // `screencapture -l` takes it as that tilted thumbnail; the window comes forward first.
        NSApp.activate(ignoringOtherApps: true)
        window?.orderFrontRegardless()
        window?.makeKey()
        try? await Task.sleep(for: .seconds(Self.frontSeconds))
        writeRegions()
    }

    /// Presses the row's Scan band as its click does and waits for the sweep to end.
    private func scan(row id: String, _ session: AppSession) async {
        guard let row = session.sidebarRows.first(where: { $0.id == id }) else { return }
        session.scanBand(row: row)
        _ = await until(seconds: Self.confirmSeconds) { session.sweeping }
        let done = await until(seconds: Self.sweepSeconds) { !session.sweeping }
        log(
            "stage",
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
            guard await until(seconds: left, { session.transmissions?.onAir != nil }) else { break }
            try? await Task.sleep(for: .seconds(Self.onAirFillSeconds))
            if session.transmissions?.onAir != nil {
                log("stage", "on the air")
                return
            }
        }
        log("stage", "no over held the squelch open within \(Int(Self.onAirSeconds)) s")
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
        log(
            "stage",
            "window \(window.windowNumber) asked for \(Int(size.width))×\(Int(size.height)) pt, is \(Int(window.frame.width))×\(Int(window.frame.height)) pt"
        )
    }

    /// The first bookmark in list order with this name, tuned as its sidebar row's click tunes
    /// it (`AppSession.tune(bookmark:)`).
    private func tune(bookmark name: String, _ session: AppSession) async {
        guard let b = session.bookmarks.list.first(where: { $0.name == name }) else {
            log("stage", "no bookmark named \(name); nothing tuned")
            return
        }
        session.tune(bookmark: b)
        let tuned = await until(seconds: Self.confirmSeconds) { session.tunedHz == b.hz }
        log(
            "stage",
            tuned
                ? "bookmark \(name) tuned at \(b.hz) Hz"
                : "bookmark \(name) at \(b.hz) Hz not confirmed within \(Int(Self.confirmSeconds)) s"
        )
    }

    /// Opens a sidebar row as its chevron does. The tuned row is open already.
    private func open(row id: String, _ session: AppSession) {
        guard let row = session.sidebarRows.first(where: { $0.id == id }) else {
            log("stage", "no sidebar row \(id); none opened")
            return
        }
        if !session.isExpanded(row) { session.toggleExpanded(row) }
        log("stage", "row \(row.name) open")
    }

    /// Selects a part of the selected channel's page, counted down the recent days' rows as the
    /// page draws them. Without `play_part` it does not play: a row's click would play it
    /// through the speakers.
    private func select(part index: Int, _ session: AppSession) async {
        var uri: String?
        _ = await until(seconds: Self.librarySeconds) {
            guard let c = session.selectedChannel else { return false }
            let rows = session.pageDays(for: c).filter { !$0.earlier }.flatMap(\.rows)
            uri = index < rows.count ? rows[index].uri : nil
            return uri != nil
        }
        guard let uri else {
            log(
                "stage",
                "the page has no part \(index) within \(Int(Self.librarySeconds)) s; none selected")
            return
        }
        session.selectedPartURI = uri
        log("stage", "part \(index) selected: \(uri)")
        guard stage?.playPart == true else { return }
        // Played and paused at once, so the row draws as the current one with a fraction of a
        // second of audio; the pause leaves the player where it stopped.
        await session.clickRow(uri)
        try? await Task.sleep(for: .seconds(Self.playPartSeconds))
        await session.pausePlayback(true)
        log("stage", "part \(index) played and paused")
    }

    /// `regions.json`: the whole frame as `window`, the strip above the content layout rect as
    /// `toolbar`, and each probed region whose view is in this window, clipped to the frame. A
    /// region not on screen (the inspector closed, the Library's regions in the Radio) is left
    /// out.
    private func writeRegions() {
        guard let window else {
            log("stage", "no window to measure; no regions written")
            return
        }
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
        let url = ShotStage.regionsURL(besideStage: stageURL)
        do {
            try ShotRegions(windowNumber: window.windowNumber, regions: regions).write(to: url)
            let names = regions.keys.map(\.rawValue).sorted().joined(separator: ", ")
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
