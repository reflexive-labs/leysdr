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
    /// The tooltip of what the last `hover` rested on, until the next `hover` or `click`.
    private var hoverHelp: String?

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
            case .snapshot(let settle, let which):
                try? await Task.sleep(for: .seconds(settle))
                guard let window = staging.window else { return noWindow }
                guard which == .settings else { return try snapshot(c.id, window) }
                guard let settings = Staging.settingsWindow else {
                    return ControlAnswer(
                        id: c.id, ok: false, error: "the Settings window is not open")
                }
                if settings.colorSpace != .sRGB {
                    // Opened by ⌘, or the menu rather than the stage: steadied now, and given
                    // a moment to draw again before its picture.
                    Staging.steady(settings: settings)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                return try snapshot(c.id, settings, regions: false)
            case .state:
                if let window = staging.window { await AccessibilityTree.ready(window) }
                let focusedID = AccessibilityTree.focusedIdentifier()
                var state = viewState(staging.window, focusedID)
                if let window = staging.window {
                    state.assistant = assistantState(window, state.focused)
                    if state.focused == "sidebar.filter" { state.filterCaret = Self.caret(window) }
                }
                return ControlAnswer(
                    id: c.id, ok: true, result: try ControlAnswer.result(state))
            case .ax(let which):
                guard let window = staging.window else { return noWindow }
                let file = "\(AppControl.outName)/\(c.id).ax.txt"
                let read: NSWindow
                var part: String?
                switch which {
                case .main: read = window
                case .settings:
                    guard let w = Staging.settingsWindow else {
                        return ControlAnswer(
                            id: c.id, ok: false, error: "the Settings window is not open")
                    }
                    read = w
                case .popover:
                    read = window
                    part = kAXPopoverRole
                case .sheet:
                    // The sheet over the main window, else the one over Settings.
                    read = window.attachedSheet == nil ? Staging.settingsWindow ?? window : window
                    part = kAXSheetRole
                }
                await AccessibilityTree.ready(read)
                try AppControl.writeReplacing(
                    Data(try AccessibilityTree.text(of: read, part: part).utf8),
                    to: directory.appendingPathComponent(file))
                // The regions are the main window's, and mean nothing in another.
                guard read === window else {
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
                send(chord, to: Self.keyTarget(window))
                try? await Task.sleep(for: .milliseconds(Self.keySettleMilliseconds))
                return ControlAnswer(id: c.id, ok: true)
            case .type(let text):
                guard let window = staging.window else { return noWindow }
                for ch in text {
                    send(.typing(ch), to: Self.keyTarget(window))
                    try? await Task.sleep(for: .milliseconds(Self.typeGapMilliseconds))
                }
                try? await Task.sleep(for: .milliseconds(Self.keySettleMilliseconds))
                return ControlAnswer(id: c.id, ok: true)
            case .press(let identifier):
                guard let window = staging.window else { return noWindow }
                // A sheet's button is pressed in the window it covers; any other identifier is
                // looked for in the main window, then in Settings while it is open.
                var windows = [window]
                if let settings = Staging.settingsWindow {
                    let alert = identifier.hasPrefix(AXWalk.alertPrefix)
                    if alert && window.attachedSheet == nil {
                        windows = [settings]
                    } else if !alert {
                        windows.append(settings)
                    }
                }
                var why: PressRefusal?
                for w in windows {
                    await AccessibilityTree.ready(w)
                    why = AccessibilityTree.press(identifier, in: w)
                    // Found, pressed or disabled: the next window is not looked in.
                    if why == nil || why?.disabled == true { break }
                }
                return ControlAnswer(id: c.id, ok: why == nil, error: why?.description ?? "")
            case .pick(let identifier, let item):
                guard let window = staging.window else { return noWindow }
                var why: String?
                for w in [window, Staging.settingsWindow].compactMap({ $0 }) {
                    why = AccessibilityTree.pick(identifier, item: item, in: w)
                    if why?.hasPrefix("no element has") != true { break }
                }
                try? await Task.sleep(for: .milliseconds(Self.keySettleMilliseconds))
                return ControlAnswer(id: c.id, ok: why == nil, error: why ?? "")
            case .hover(let target):
                guard let window = staging.window else { return noWindow }
                await AccessibilityTree.ready(window)
                guard let p = Self.point(target, in: window) else {
                    return ControlAnswer(id: c.id, ok: false, error: Self.noTarget(target))
                }
                post([.mouseMoved], at: p, in: window)
                try? await Task.sleep(for: .milliseconds(Self.keySettleMilliseconds))
                hoverHelp = AccessibilityTree.help(at: p, in: window)
                return ControlAnswer(
                    id: c.id, ok: true,
                    result: .object(["tooltip": hoverHelp.map(JSONValue.string) ?? .null]))
            case .click(let target, let right):
                guard let window = staging.window else { return noWindow }
                await AccessibilityTree.ready(window)
                guard let p = Self.point(target, in: window) else {
                    return ControlAnswer(id: c.id, ok: false, error: Self.noTarget(target))
                }
                hoverHelp = nil
                post(
                    right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp],
                    at: p, in: window)
                try? await Task.sleep(for: .milliseconds(Self.keySettleMilliseconds))
                return ControlAnswer(id: c.id, ok: true)
            case .menu(let path, let read):
                switch AppMenus.item(path: path) {
                case .failure(let why):
                    return ControlAnswer(id: c.id, ok: false, error: "\(why)")
                case .success(let (menu, index)):
                    let item = menu.items[index]
                    let result: JSONValue = .object([
                        "title": .string(item.title),
                        "enabled": .bool(item.isEnabled),
                        "checked": .bool(item.state == .on),
                        "items": .array(AppMenus.titles(of: menu).map(JSONValue.string)),
                    ])
                    guard !read else { return ControlAnswer(id: c.id, ok: true, result: result) }
                    guard item.isEnabled else {
                        return ControlAnswer(
                            id: c.id, ok: false, error: "\(path) is disabled", result: result)
                    }
                    log("control", "menu \(path) pressed")
                    menu.performActionForItem(at: index)
                    try? await Task.sleep(for: .milliseconds(Self.keySettleMilliseconds))
                    return ControlAnswer(id: c.id, ok: true, result: result)
                }
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

    /// The window's picture; with `regions`, the main window's regions beside it, and none for
    /// another window, whose frame they do not describe.
    private func snapshot(_ id: Int, _ window: NSWindow, regions: Bool = true) throws
        -> ControlAnswer
    {
        let measured = regions ? staging.measure() : nil
        guard let png = WindowPicture.png(of: window), !regions || measured != nil else {
            return ControlAnswer(id: id, ok: false, error: "the window drew no picture")
        }
        let file = "\(AppControl.outName)/\(id).png"
        try AppControl.writeReplacing(png, to: directory.appendingPathComponent(file))
        let shot = ControlSnapshot(
            scale: measured?.scale ?? Double(window.backingScaleFactor),
            widthPt: Double(window.frame.width), heightPt: Double(window.frame.height),
            regions: measured?.regions ?? [:])
        return ControlAnswer(
            id: id, ok: true, files: [file], result: try ControlAnswer.result(shot))
    }

    /// A target's point in points from the window's top-left corner: the element's centre, or
    /// the point given.
    private static func point(_ target: ControlCommand.PointTarget, in window: NSWindow)
        -> CGPoint?
    {
        switch target {
        case .point(let x, let y): return CGPoint(x: x, y: y)
        case .identifier(let id):
            guard let r = AccessibilityTree.frame(of: id, in: window) else { return nil }
            return CGPoint(x: r.midX, y: r.midY)
        }
    }

    private static func noTarget(_ target: ControlCommand.PointTarget) -> String {
        if case .identifier(let id) = target { return "no element has the identifier \(id)" }
        return "no point"
    }

    /// Mouse events at `p` (from the window's top-left corner) posted to this process's own
    /// queue, as `send` posts keys: the window's tracking areas, gestures and menus see them as
    /// a mouse's, and nothing reaches another app or moves the person's pointer. A point over an
    /// open popover goes to the popover, which is a window of its own.
    private func post(_ types: [NSEvent.EventType], at p: CGPoint, in main: NSWindow) {
        let screen = NSPoint(x: main.frame.minX + p.x, y: main.frame.maxY - p.y)
        let window =
            main.childWindows?.last { $0.isVisible && $0.frame.contains(screen) } ?? main
        if NSApp.keyWindow !== window { window.makeKey() }
        // The event's location is from the window's bottom-left corner.
        let location = window.convertPoint(fromScreen: screen)
        for type in types {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: type == .mouseMoved ? 0 : 1,
                    pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0)
            else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// The window a key goes to: the sheet over the main window, else its open popover (whose
    /// key monitor takes Up and Down), else the app's key window while it is on screen
    /// (Settings), else another window being typed into, else the main window.
    private static func keyTarget(_ main: NSWindow) -> NSWindow {
        if let sheet = main.attachedSheet { return sheet }
        if let popover = main.childWindows?.last(where: \.isVisible) {
            return popover
        }
        if let key = NSApp.keyWindow, key.isVisible { return key }
        // An inactive app has no key window, whatever makeKey asked: the window being typed
        // into (a field pressed in Settings), else the main window.
        return typingWindow(besides: main) ?? main
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
    private func viewState(_ window: NSWindow?, _ focusedID: String?) -> ControlViewState {
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
            focused: window.map { main in
                let w = Self.focusWindow(main)
                return Self.describeFocus(w.firstResponder, in: w, focusedID)
            } ?? "",
            notices: notices,
            popover: popover, selectedRecordingChannel: s.selectedRecordingChannel,
            selectedPart: s.selectedPartURI, heard: s.heardTone?.words,
            hits: s.sweepHits.map(\.label), muted: s.isMuted,
            volume: s.sink.map { $0.systemAudio.hasVolume ? $0.systemAudio.volume : 1 },
            sink: s.sink != nil ? "own" : s.audioElsewhere != nil ? "other" : "none",
            window: window.map {
                ControlWindowSize(
                    width: Double($0.frame.width), height: Double($0.frame.height),
                    minWidth: Double($0.minSize.width), minHeight: Double($0.minSize.height))
            },
            settingsOpen: Staging.settingsWindow != nil,
            alert: window.flatMap { Self.alert(over: [$0, Staging.settingsWindow]) },
            viewWindow: s.visibleRange.map {
                ControlViewWindow(lowHz: $0.lowerBound, highHz: $0.upperBound)
            },
            // The charts draw their own readout under the pointer rather than a tooltip.
            tooltip: hoverHelp
                ?? s.pointerHz.map { "\(Frequency.fieldParts($0).major) MHz" },
            transport: window.flatMap(Self.transportState))
    }

    /// The transport bar's words as its elements read, so a word the bar dropped is absent; nil
    /// when the window draws no bar (the Library).
    private static func transportState(_ window: NSWindow) -> ControlTransport? {
        let elements = AccessibilityTree.elements(withPrefix: "t", in: window)
        func words(_ e: AXElementInfo) -> String { e.value ?? e.label }
        let tuning = elements.first { $0.identifier == "tuning.text" }.map(words)
        // The short caption is `transport.squelch.caption.short`.
        let caption = elements.first { $0.identifier.hasPrefix("transport.squelch.caption") }
        guard tuning != nil || caption != nil else { return nil }
        return ControlTransport(
            tuning: tuning, squelchCaption: caption.map(words),
            squelchCaptionShort: caption.map { $0.identifier.hasSuffix(".short") },
            squelchWords: elements.filter { $0.identifier.hasPrefix("transport.squelch.words.") }
                .map(words).joined(separator: " · "))
    }

    /// The assistant's panel as `state` gives it, or nil while it is hidden. The turns and the
    /// thinking row come from the conversation the panel draws; the field and the buttons from
    /// their accessibility elements, since the field's text is the view's own.
    private func assistantState(_ window: NSWindow, _ focused: String)
        -> ControlAssistant?
    {
        guard session.assistantPanelShown else { return nil }
        let view = session.conversationView
        let elements = AccessibilityTree.elements(withPrefix: "assistant.", in: window)
        let input = elements.first { $0.identifier == "assistant.input" }
        return ControlAssistant(
            turns: (view?.turns ?? []).map {
                ControlAssistant.Turn(role: $0.role == .user ? "user" : "assistant", text: $0.text)
            },
            state: session.assistantLost ? "gone" : view?.stateWord,
            thinking: view?.isWaitingOnModel ?? false,
            input: input?.value ?? "",
            inputFocused: focused == "assistant.input",
            stopShown: elements.contains { $0.identifier == "assistant.stop" },
            buttons: elements.filter { $0.role == kAXButtonRole }.map {
                ControlAssistant.Button(id: $0.identifier, title: $0.label, enabled: $0.enabled)
            })
    }

    /// The insertion point of the field being typed into, in characters from its start.
    private static func caret(_ window: NSWindow) -> Int? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
            return nil
        }
        return editor.selectedRange().location
    }

    /// The first sheet over one of `windows`: its texts (the first the title, the second the
    /// message) and its buttons' titles, read from its views.
    private static func alert(over windows: [NSWindow?]) -> ControlAlert? {
        guard let sheet = windows.compactMap({ $0?.attachedSheet }).first,
            let root = sheet.contentView
        else { return nil }
        var texts: [String] = []
        var buttons: [String] = []
        func visit(_ v: NSView) {
            if v.isHidden { return }
            if let b = v as? NSButton, !b.title.isEmpty {
                buttons.append(b.title)
            } else if let t = v as? NSTextField, !t.isEditable, !t.stringValue.isEmpty {
                texts.append(t.stringValue)
            }
            v.subviews.forEach(visit)
        }
        visit(root)
        return ControlAlert(
            title: texts.first ?? sheet.title, message: texts.dropFirst().first, buttons: buttons)
    }

    /// The window whose focus `state` names: the key window, else another being typed into
    /// (Settings, in an app that is never active and so has no key window), else the main one.
    private static func focusWindow(_ main: NSWindow) -> NSWindow {
        if let key = NSApp.keyWindow, key.isVisible { return key }
        return typingWindow(besides: main) ?? main
    }

    /// A visible window of its own other than `main` (not a popover, which `keyTarget` takes
    /// first) whose text field is being typed into.
    private static func typingWindow(besides main: NSWindow) -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0 !== main && $0.parent == nil
                && ($0.firstResponder as? NSTextView)?.isFieldEditor == true
        }
    }

    /// The first responder by its accessibility identifier, else its role and label; a field
    /// editor stands for the field it edits. Empty when the window itself holds the focus.

    private static func describeFocus(
        _ responder: NSResponder?, in window: NSWindow, _ focusedID: String?
    ) -> String {
        guard var view = responder as? NSView, responder !== window else { return "" }
        if let editor = view as? NSTextView, editor.isFieldEditor,
            let field = editor.delegate as? NSView
        {
            view = field
        }
        let id = view.accessibilityIdentifier()
        if !id.isEmpty { return id }
        if let focusedID { return focusedID }
        // When the API names no focused element (the screen is locked, or a field editor is on
        // its way in), the identified text field over the focused view is the one it names.
        if view.window === window,
            let id = AccessibilityTree.textFieldIdentifier(over: view, in: window)
        {
            return id
        }
        let role = view.accessibilityRole()?.rawValue ?? String(describing: type(of: view))
        let label =
            view.accessibilityLabel() ?? (view as? NSTextField)?.placeholderString
            ?? view.accessibilityTitle() ?? ""
        return label.isEmpty ? role : "\(role) \"\(label)\""
    }
}
