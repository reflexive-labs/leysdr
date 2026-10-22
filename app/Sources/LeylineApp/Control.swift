// SPDX-License-Identifier: Apache-2.0

// The command file a check run drives the window through (docs/dev/app.md, "The command file";
// the shapes are `AppControl` in LeylineClient). Once the stage is applied the app writes
// `ready.json`, then reads `commands.jsonl` every 100 ms and runs each new line in order, one at a
// time, answering each in `out/<id>.json` by rename so a reader never sees half an answer. A key
// is posted to the app's own event queue, where a real keyboard's arrives, so the event monitors
// (the filter's Return and arrows, `TuningKeyGuard`), a menu's key equivalent (⌘G) and a focused
// field all see it: `NSApp.sendEvent` alone skips the monitors, which run as an event is taken
// from the queue.

import AppKit
import LeylineClient

@MainActor
final class ControlChannel {
    /// Between two characters of `type`, so a field's binding and its `onChange` run once per
    /// key as they do for a person typing.
    static let typeGapMilliseconds = 20
    /// After a key, before the answer: a key that moves the focus (⌘G) has SwiftUI give it on
    /// a later pass, and a key sent sooner would reach the view that had it before.
    static let keySettleMilliseconds = 150

    let directory: URL
    private let staging: Staging
    private let session: AppSession
    private var lines = ControlLines()
    private var offset: UInt64 = 0

    init(directory: URL, staging: Staging, session: AppSession) {
        self.directory = directory
        self.staging = staging
        self.session = session
    }

    /// Writes `ready.json`, `ok` false with `problem` when there is one, then takes commands
    /// until `quit` or the end of the process.
    func run(problem: String?) async {
        clearOutputs()
        do {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(AppControl.outName),
                withIntermediateDirectories: true)
            let window = staging.window
            let ready = ControlReady(
                ok: problem == nil, pid: Int(ProcessInfo.processInfo.processIdentifier),
                windowNumber: window?.windowNumber ?? 0,
                scale: Double(window?.backingScaleFactor ?? 0), error: problem ?? "")
            try AppControl.writeReplacing(
                AppControl.encoded(ready),
                to: directory.appendingPathComponent(AppControl.readyName))
            log("control", "ready in \(directory.path)\(problem.map { ": \($0)" } ?? "")")
        } catch {
            log(
                "control",
                "ready.json not written in \(directory.path): \(error); no commands taken")
            return
        }
        while !Task.isCancelled {
            for line in readLines() {
                switch ControlCommand.parse(line) {
                case .command(let c):
                    let answer = await perform(c)
                    write(answer)
                    if case .quit = c.action, answer.ok {
                        NSApp.terminate(nil)
                        return
                    }
                case .refused(let id?, let reason):
                    log("control", "command \(id) refused: \(reason)")
                    write(ControlAnswer(id: id, ok: false, error: reason))
                case .refused(nil, let reason):
                    log("control", "a line with no id skipped: \(reason)")
                }
            }
            try? await Task.sleep(for: .milliseconds(AppControl.pollMilliseconds))
        }
    }

    /// A directory used before must not answer for this run: an old `ready.json` would read as
    /// this launch being ready, and old answers as this run's. They are removed, and the
    /// commands already in `commands.jsonl` are skipped, not replayed.
    private func clearOutputs() {
        let fm = FileManager.default
        for name in [AppControl.readyName, AppControl.outName] {
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                log("control", "removed the last run's \(name) from \(directory.path)")
            } catch {
                log("control", "could not remove the last run's \(name): \(error)")
            }
        }
        let commands = directory.appendingPathComponent(AppControl.commandsName)
        if let size = (try? fm.attributesOfItem(atPath: commands.path))?[.size] as? UInt64,
            size > 0
        {
            offset = size
            log("control", "skipping the \(size) bytes already in \(AppControl.commandsName)")
        }
    }

    /// The complete lines appended to `commands.jsonl` since the last read; none while the file
    /// does not exist yet. A file shorter than what was read has been replaced, and is read from
    /// its start.
    private func readLines() -> [Data] {
        let url = directory.appendingPathComponent(AppControl.commandsName)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        if let end = try? handle.seekToEnd(), end < offset {
            log(
                "control",
                "\(AppControl.commandsName) shrank to \(end) bytes; reading it from the start")
            offset = 0
            lines = ControlLines()
        }
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.readToEnd(), !data.isEmpty
        else { return [] }
        offset += UInt64(data.count)
        return lines.append(data)
    }

    private func write(_ answer: ControlAnswer) {
        let url = directory.appendingPathComponent(ControlAnswer.path(id: answer.id))
        do {
            try AppControl.writeReplacing(AppControl.encoded(answer), to: url)
        } catch {
            log("control", "answer \(answer.id) not written to \(url.path): \(error)")
        }
    }

    private func perform(_ c: ControlCommand) async -> ControlAnswer {
        log("control", "command \(c.id): \(c.action)")
        let noWindow = ControlAnswer(id: c.id, ok: false, error: "the app has no window")
        do {
            switch c.action {
            case .stage(let stage):
                if stage.window != nil, staging.window == nil { return noWindow }
                let applied = await staging.applyCommand(stage, session)
                return ControlAnswer(
                    id: c.id, ok: true,
                    result: .object(["applied": .array(applied.map(JSONValue.string))]))
            case .snapshot(let settle):
                try? await Task.sleep(for: .seconds(settle))
                guard let window = staging.window else { return noWindow }
                return try snapshot(c.id, window)
            case .state:
                return ControlAnswer(
                    id: c.id, ok: true,
                    result: try ControlAnswer.result(viewState(staging.window)))
            case .ax(let which):
                guard let window = staging.window else { return noWindow }
                let file = "\(AppControl.outName)/\(c.id).ax.txt"
                guard let read = which == .main ? window : Self.settingsWindow() else {
                    return ControlAnswer(
                        id: c.id, ok: false, error: "the Settings window is not open")
                }
                try AppControl.writeReplacing(
                    Data(try AccessibilityTree.text(of: read).utf8),
                    to: directory.appendingPathComponent(file))
                // The regions are the main window's, and mean nothing in another.
                guard which == .main else {
                    return ControlAnswer(id: c.id, ok: true, files: [file])
                }
                // The regions as a snapshot gives them, so the checker can mask the values of
                // the elements inside the live ones.
                guard let regions = staging.measure() else {
                    return ControlAnswer(id: c.id, ok: true, files: [file])
                }
                let shot = ControlSnapshot(
                    scale: regions.scale, widthPt: Double(window.frame.width),
                    heightPt: Double(window.frame.height), regions: regions.regions)
                return ControlAnswer(
                    id: c.id, ok: true, files: [file], result: try ControlAnswer.result(shot))
            case .key(let chord):
                guard let window = staging.window else { return noWindow }
                send(chord, to: window)
                try? await Task.sleep(for: .milliseconds(Self.keySettleMilliseconds))
                return ControlAnswer(id: c.id, ok: true)
            case .type(let text):
                guard let window = staging.window else { return noWindow }
                for ch in text {
                    send(.typing(ch), to: window)
                    try? await Task.sleep(for: .milliseconds(Self.typeGapMilliseconds))
                }
                try? await Task.sleep(for: .milliseconds(Self.keySettleMilliseconds))
                return ControlAnswer(id: c.id, ok: true)
            case .press(let identifier):
                guard let window = staging.window else { return noWindow }
                let why = AccessibilityTree.press(identifier, in: window)
                return ControlAnswer(id: c.id, ok: why == nil, error: why ?? "")
            case .wait(let seconds):
                try? await Task.sleep(for: .seconds(seconds))
                return ControlAnswer(id: c.id, ok: true)
            case .quit:
                return ControlAnswer(id: c.id, ok: true)
            }
        } catch {
            return ControlAnswer(id: c.id, ok: false, error: "\(error)")
        }
    }

    private func snapshot(_ id: Int, _ window: NSWindow) throws -> ControlAnswer {
        guard let png = WindowPicture.png(of: window), let regions = staging.measure() else {
            return ControlAnswer(id: id, ok: false, error: "the window drew no picture")
        }
        let file = "\(AppControl.outName)/\(id).png"
        try AppControl.writeReplacing(png, to: directory.appendingPathComponent(file))
        let shot = ControlSnapshot(
            scale: regions.scale, widthPt: Double(window.frame.width),
            heightPt: Double(window.frame.height), regions: regions.regions)
        return ControlAnswer(
            id: id, ok: true, files: [file], result: try ControlAnswer.result(shot))
    }

    /// A key down and up, as the keyboard sends them, to `window`. The events go to this
    /// process's own queue only (`NSApp.postEvent`), so nothing is typed into another app, and the
    /// app need not be frontmost: a check run does not take the focus from the person at the
    /// Mac. The window is made key within the app, which is where a field's focus lives.
    private func send(_ chord: KeyChord, to window: NSWindow) {
        if NSApp.keyWindow !== window { window.makeKey() }
        var flags: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.command) { flags.insert(.command) }
        if chord.modifiers.contains(.shift) { flags.insert(.shift) }
        if chord.modifiers.contains(.option) { flags.insert(.option) }
        if chord.modifiers.contains(.control) { flags.insert(.control) }
        if chord.isFunctionKey { flags.insert(.function) }
        if chord.isArrow { flags.insert(.numericPad) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: chord.characters,
                    charactersIgnoringModifiers: chord.charactersIgnoringModifiers,
                    isARepeat: false, keyCode: chord.keyCode)
            else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// `state`'s result, read from the session as the views read it.
    private func viewState(_ window: NSWindow?) -> ControlViewState {
        let s = session
        var notices: [String] = []
        if let n = s.notice { notices.append(n) }
        if let e = s.lastError { notices.append(e.message.isEmpty ? e.code : e.message) }
        if let w = s.emptyWords { notices.append("\(w.headline). \(w.detail)") }
        if let w = s.outOfCaptureWords { notices.append(w) }
        if let n = s.assistantNotice { notices.append(n.text) }
        var popover = ""
        if let b = s.pickerBand {
            popover = "channels:\(b.id)"
        } else if s.deviceMenuShown {
            popover = "device_menu"
        }
        return ControlViewState(
            place: s.place.rawValue, tunedHz: s.tunedHz, mode: s.channel?.mode.word,
            bandwidthHz: s.channel?.bandwidthHz, channelID: s.channel?.channelID,
            captureID: s.capture?.captureID, band: s.band?.id, bookmark: s.tunedBookmark?.name,
            openRows: s.sidebarRows.filter { s.isExpanded($0) }.map(\.id),
            filterQuery: s.filterQuery, inspectorShown: s.inspectorShown,
            assistantShown: s.assistantPanelShown, zoom: s.zoom,
            focused: window.map { Self.describeFocus($0.firstResponder, in: $0) } ?? "",
            notices: notices,
            popover: popover, selectedRecordingChannel: s.selectedRecordingChannel,
            selectedPart: s.selectedPartURI, heard: s.heardTone?.words,
            hits: s.sweepHits.map(\.label))
    }

    /// The Settings scene's window while it is on screen. SwiftUI names it
    /// `com_apple_SwiftUI_Settings_window`.
    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true
        }
    }

    /// The first responder by its accessibility identifier, else its role and label; a field
    /// editor stands for the field it edits. Empty when the window itself holds the focus.
    private static func describeFocus(_ responder: NSResponder?, in window: NSWindow) -> String {
        guard var view = responder as? NSView, responder !== window else { return "" }
        if let editor = view as? NSTextView, editor.isFieldEditor,
            let field = editor.delegate as? NSView
        {
            view = field
        }
        let id = view.accessibilityIdentifier()
        if !id.isEmpty { return id }
        if let id = AccessibilityTree.focusedIdentifier() { return id }
        let role = view.accessibilityRole()?.rawValue ?? String(describing: type(of: view))
        let label =
            view.accessibilityLabel() ?? (view as? NSTextField)?.placeholderString
            ?? view.accessibilityTitle() ?? ""
        return label.isEmpty ? role : "\(role) \"\(label)\""
    }
}
