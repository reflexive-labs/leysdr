// SPDX-License-Identifier: Apache-2.0

// The command file a check run drives the app through (docs/dev/app.md, "The command file";
// docs/plans/mac-loop.md, "The protocol"). `LEYLINE_APP_CONTROL` names a directory: the app
// writes `ready.json` there once it is live, reads one JSON command per line from
// `commands.jsonl`, and answers each in `out/<id>.json`. A file the app watches, rather than a
// socket, keeps one protocol to the daemon (invariant 1) and needs no port or socket permission.
// The shapes are plain data, kept here so the Linux tests hold the keys `go/cmd/leyshots` reads
// and writes; the app runs the commands.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The command file's names, and whether this run is staged at all.
public enum AppControl {
    /// The variable naming the control directory. With it unset no command is read.
    public static let environmentKey = "LEYLINE_APP_CONTROL"
    /// The app reads new lines this often; the client's appends are seen within this long.
    public static let pollMilliseconds = 100
    public static let readyName = "ready.json"
    public static let commandsName = "commands.jsonl"
    public static let outName = "out"

    /// The control directory from the environment, or nil when the run takes no commands.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let d = environment[environmentKey], !d.isEmpty else { return nil }
        return d
    }

    /// Whether this is a staged run: a stage file, a control directory, or both. A staged run
    /// writes nothing to UserDefaults and draws deterministic frames.
    public static func isStaged(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        ShotStage.path(environment: environment) != nil
            || directory(environment: environment) != nil
    }

    /// Writes a temp file beside `url`, then rename(2), so a reader waiting for the file never
    /// sees half of it (`docs/dev/swift-style.md`, "Foundation on two platforms").
    public static func writeReplacing(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp, options: .atomic)
        guard rename(tmp.path, url.path) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// JSON with sorted keys, so two runs of one state give the same bytes, and paths with
    /// their slashes as they are.
    public static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// The window's accessibility identifiers, which the command file's `press` names and `ax`
/// prints (docs/dev/app.md, "Staged runs", has the scheme): lowercase words joined by dots, the
/// area first. A list's rows end in their data, slugged here so a name with spaces or capitals
/// still makes one word of the identifier.
public enum ViewIdentifier {
    /// `Club repeater` → `club-repeater`: lowercase ASCII letters and digits, every other run of
    /// characters one hyphen, none at either end. A name with no letter or digit is `_`.
    public static func slug(_ s: String) -> String {
        var out = ""
        var gap = false
        for ch in s.lowercased().unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
                if gap, !out.isEmpty { out.append("-") }
                out.unicodeScalars.append(ch)
                gap = false
            } else {
                gap = true
            }
        }
        return out.isEmpty ? "_" : out
    }

    /// A sweep hit's slug, unique among `hits`: its label's, and when another hit has the same
    /// label (two hits on one plan channel, two plans naming a channel `WX`), `-2`, `-3` on
    /// the second and later of them by frequency. The first keeps the plain slug, so a sweep with
    /// no repeated label names its hits as it always has; the count is used rather than the
    /// frequency because the frequency a sweep measures moves from run to run.
    public static func hitSlug(_ hit: SweepHit, among hits: [SweepHit]) -> String {
        let base = slug(hit.label)
        let before = hits.filter { $0.hz < hit.hz && slug($0.label) == base }.count
        return before == 0 ? base : "\(base)-\(before + 1)"
    }
}

/// `ready.json`: written once the session is live and has its first channel, or when the waits
/// for those run out (`ok` false then, with the reason in `error`).
public struct ControlReady: Sendable, Equatable, Codable {
    public var ok: Bool
    public var pid: Int
    public var windowNumber: Int
    /// The window's backing scale: pixels per point in every picture the run takes.
    public var scale: Double
    public var error: String

    enum CodingKeys: String, CodingKey {
        case ok, pid, scale, error
        case windowNumber = "window_number"
    }

    public init(ok: Bool, pid: Int, windowNumber: Int, scale: Double, error: String = "") {
        self.ok = ok
        self.pid = pid
        self.windowNumber = windowNumber
        self.scale = scale
        self.error = error
    }
}

/// One line of `commands.jsonl`, checked: every field the command needs is present and usable.
public struct ControlCommand: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// A `ShotStage` applied to the running window; its `settle` is slept and its `window`
        /// resizes.
        case stage(ShotStage)
        /// The picture of the main window, or of Settings, after `settle` seconds.
        case snapshot(settle: Double, window: TreeWindow)
        case state
        /// The tree of one of the app's windows.
        case ax(window: TreeWindow)
        case key(KeyChord)
        case type(String)
        case press(identifier: String)
        /// Chooses an item of a pop-up or segmented control by its title.
        case pick(identifier: String, item: String)
        /// Rests the pointer on an element or a point; `state.tooltip` then says what shows.
        case hover(PointTarget)
        /// A mouse click there, left or right, for what `press` cannot reach.
        case click(PointTarget, right: Bool)
        /// A menu bar item by its titles (`View>Show Assistant`): pressed, or with `read` only
        /// described.
        case menu(path: String, read: Bool)
        case wait(seconds: Double)
        case quit
    }

    /// Where a `hover` or a `click` goes: the centre of the element with an identifier, or a
    /// point in points from the window's top-left corner, toolbar included, as the regions and
    /// the `ax` frames are measured.
    public enum PointTarget: Sendable, Equatable {
        case identifier(String)
        case point(x: Double, y: Double)
    }

    /// The window an `ax` reads: the main window, popovers and sheets included, by default; the
    /// Settings window, while it is open; or the open popover or sheet alone (a sheet over the
    /// main window, else over Settings).
    public enum TreeWindow: String, Sendable, Equatable, CaseIterable {
        case main, settings, popover, sheet
    }

    public var id: Int
    public var action: Action

    public init(id: Int, action: Action) {
        self.id = id
        self.action = action
    }

    /// A line as it parsed: a command to run, or the reason it cannot run. A refusal with an
    /// id is answered `ok:false`; one without has nowhere to be answered and is only logged.
    public enum Parsed: Sendable, Equatable {
        case command(ControlCommand)
        case refused(id: Int?, reason: String)
    }

    private struct Line: Decodable {
        var id: Int?
        var cmd: String?
        var stage: ShotStage?
        var settle: Double?
        var keys: String?
        var text: String?
        var identifier: String?
        var seconds: Double?
        var window: String?
        var x: Double?
        var y: Double?
        var button: String?
        var menu: String?
        var read: Bool?
    }

    private struct LineID: Decodable {
        var id: Int?
    }

    public static func parse(_ line: Data) -> Parsed {
        let fields: Line
        do {
            fields = try JSONDecoder().decode(Line.self, from: line)
        } catch {
            // A line whose other fields do not decode may still carry its id, so the client
            // hears why rather than waiting out its timeout.
            let id = (try? JSONDecoder().decode(LineID.self, from: line))?.id
            return .refused(id: id, reason: "the line is not a command: \(error)")
        }
        guard let id = fields.id else { return .refused(id: nil, reason: "the command has no id") }
        guard let cmd = fields.cmd, !cmd.isEmpty else {
            return .refused(id: id, reason: "the command has no cmd")
        }
        switch action(cmd, fields) {
        case .success(let a): return .command(ControlCommand(id: id, action: a))
        case .failure(let why): return .refused(id: id, reason: why.reason)
        }
    }

    private struct Refusal: Error {
        let reason: String
    }

    private static func action(_ cmd: String, _ line: Line) -> Result<Action, Refusal> {
        switch cmd {
        case "stage":
            guard let stage = line.stage else {
                return .failure(Refusal(reason: "stage needs a stage"))
            }
            do {
                try stage.validate()
            } catch {
                return .failure(Refusal(reason: "\(error)"))
            }
            return .success(.stage(stage))
        case "snapshot":
            let settle = line.settle ?? 0
            guard settle.isFinite, settle >= 0 else {
                return .failure(Refusal(reason: "settle must be zero or more seconds"))
            }
            let window = TreeWindow(rawValue: line.window ?? TreeWindow.main.rawValue)
            guard let window, window == .main || window == .settings else {
                return .failure(Refusal(reason: "a snapshot's window must be main or settings"))
            }
            return .success(.snapshot(settle: settle, window: window))
        case "state": return .success(.state)
        case "ax":
            guard let window = TreeWindow(rawValue: line.window ?? TreeWindow.main.rawValue) else {
                return .failure(Refusal(reason: "window must be main, settings, popover or sheet"))
            }
            return .success(.ax(window: window))
        case "key":
            guard let keys = line.keys else { return .failure(Refusal(reason: "key needs keys")) }
            guard let chord = KeyChord(keys) else {
                return .failure(Refusal(reason: "keys \(keys) is not a key the app can send"))
            }
            return .success(.key(chord))
        case "type":
            guard let text = line.text, !text.isEmpty else {
                return .failure(Refusal(reason: "type needs text"))
            }
            return .success(.type(text))
        case "press":
            guard let identifier = line.identifier, !identifier.isEmpty else {
                return .failure(Refusal(reason: "press needs an identifier"))
            }
            return .success(.press(identifier: identifier))
        case "pick":
            guard let identifier = line.identifier, !identifier.isEmpty, let item = line.text,
                !item.isEmpty
            else {
                return .failure(Refusal(reason: "pick needs an identifier and the item's text"))
            }
            return .success(.pick(identifier: identifier, item: item))
        case "hover", "click":
            let target: PointTarget
            switch (line.identifier, line.x, line.y) {
            case (let id?, nil, nil) where !id.isEmpty: target = .identifier(id)
            case (nil, let x?, let y?) where x.isFinite && y.isFinite: target = .point(x: x, y: y)
            default:
                return .failure(Refusal(reason: "\(cmd) needs an identifier, or x and y"))
            }
            if cmd == "hover" {
                guard line.button == nil else {
                    return .failure(Refusal(reason: "hover takes no button"))
                }
                return .success(.hover(target))
            }
            switch line.button ?? "left" {
            case "left": return .success(.click(target, right: false))
            case "right": return .success(.click(target, right: true))
            default: return .failure(Refusal(reason: "a click's button must be left or right"))
            }
        case "menu":
            guard let path = line.menu, !path.isEmpty,
                !path.split(separator: ">", omittingEmptySubsequences: false).contains("")
            else {
                return .failure(Refusal(reason: "menu needs titles joined by >"))
            }
            return .success(.menu(path: path, read: line.read ?? false))
        case "wait":
            guard let s = line.seconds, s.isFinite, s >= 0 else {
                return .failure(Refusal(reason: "wait needs seconds, zero or more"))
            }
            return .success(.wait(seconds: s))
        case "quit": return .success(.quit)
        default:
            return .failure(Refusal(reason: "unknown cmd \(cmd)"))
        }
    }
}

/// `out/<id>.json`: whether the command ran, why not, the files it wrote (relative to the
/// control directory) and its result, `{}` when it has none.
public struct ControlAnswer: Sendable, Equatable, Codable {
    public var id: Int
    public var ok: Bool
    public var error: String
    public var files: [String]
    public var result: JSONValue

    public init(
        id: Int, ok: Bool, error: String = "", files: [String] = [],
        result: JSONValue = .object([:])
    ) {
        self.id = id
        self.ok = ok
        self.error = error
        self.files = files
        self.result = result
    }

    /// The answer file's path relative to the control directory.
    public static func path(id: Int) -> String { "\(AppControl.outName)/\(id).json" }

    /// A result value from any encodable shape, through its JSON.
    public static func result<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: AppControl.encoded(value))
    }
}

/// `snapshot`'s result: the picture's scale and point size, and the regions as `regions.json`
/// gives them.
public struct ControlSnapshot: Sendable, Equatable, Encodable {
    public var scale: Double
    public var widthPt: Double
    public var heightPt: Double
    public var regions: [ShotRegion: ShotRegions.Rect]

    enum CodingKeys: String, CodingKey {
        case scale, regions
        case widthPt = "width_pt"
        case heightPt = "height_pt"
    }

    public init(
        scale: Double, widthPt: Double, heightPt: Double, regions: [ShotRegion: ShotRegions.Rect]
    ) {
        self.scale = scale
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.regions = regions
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scale, forKey: .scale)
        try c.encode(widthPt, forKey: .widthPt)
        try c.encode(heightPt, forKey: .heightPt)
        try c.encode(
            Dictionary(uniqueKeysWithValues: regions.map { ($0.key.rawValue, $0.value) }),
            forKey: .regions)
    }
}

/// `state.window`: the main window's frame in points, toolbar included, and the least the person
/// can make it.
public struct ControlWindowSize: Sendable, Equatable, Codable {
    public var width: Double
    public var height: Double
    public var minWidth: Double
    public var minHeight: Double

    enum CodingKeys: String, CodingKey {
        case width, height
        case minWidth = "min_width"
        case minHeight = "min_height"
    }

    public init(width: Double, height: Double, minWidth: Double, minHeight: Double) {
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.minHeight = minHeight
    }
}

/// `state.alert`: the sheet over a window (an alert, a confirmation): its title, its message
/// when it has one, and its buttons' titles in order.
public struct ControlAlert: Sendable, Equatable, Codable {
    public var title: String
    public var message: String?
    public var buttons: [String]

    public init(title: String, message: String? = nil, buttons: [String]) {
        self.title = title
        self.message = message
        self.buttons = buttons
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(message, forKey: .message)
        try c.encode(buttons, forKey: .buttons)
    }
}

/// `state.view_window`: the frequencies at the spectrum and waterfall's two edges, as the zoom
/// and the tuned channel put them.
public struct ControlViewWindow: Sendable, Equatable, Codable {
    public var lowHz: UInt64
    public var highHz: UInt64

    enum CodingKeys: String, CodingKey {
        case lowHz = "low_hz"
        case highHz = "high_hz"
    }

    public init(lowHz: UInt64, highHz: UInt64) {
        self.lowHz = lowHz
        self.highHz = highHz
    }
}

/// `state.assistant`: the assistant's panel while it is shown.
public struct ControlAssistant: Sendable, Equatable, Codable {
    /// One turn of the conversation, oldest first: `user` or `assistant`, and its text.
    public struct Turn: Sendable, Equatable, Codable {
        public var role: String
        public var text: String

        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// A button the panel shows (New, Stop, Decline, Allow…), by its identifier.
    public struct Button: Sendable, Equatable, Codable {
        public var id: String
        public var title: String
        public var enabled: Bool

        public init(id: String, title: String, enabled: Bool) {
            self.id = id
            self.title = title
            self.enabled = enabled
        }
    }

    public var turns: [Turn]
    /// The conversation's state as the header says it (`thinking`, `idle`, `asking`…), or nil
    /// with none.
    public var state: String?
    /// The assistant is thinking: the `thinking…` row shows under the newest turn.
    public var thinking: Bool
    /// What the panel's field holds, and whether it has the keyboard's focus.
    public var input: String
    public var inputFocused: Bool
    /// Stop shows beside the field.
    public var stopShown: Bool
    public var buttons: [Button]

    enum CodingKeys: String, CodingKey {
        case turns, state, thinking, input, buttons
        case inputFocused = "input_focused"
        case stopShown = "stop_shown"
    }

    public init(
        turns: [Turn] = [], state: String? = nil, thinking: Bool = false, input: String = "",
        inputFocused: Bool = false, stopShown: Bool = false, buttons: [Button] = []
    ) {
        self.turns = turns
        self.state = state
        self.thinking = thinking
        self.input = input
        self.inputFocused = inputFocused
        self.stopShown = stopShown
        self.buttons = buttons
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(turns, forKey: .turns)
        try c.encode(state, forKey: .state)
        try c.encode(thinking, forKey: .thinking)
        try c.encode(input, forKey: .input)
        try c.encode(inputFocused, forKey: .inputFocused)
        try c.encode(stopShown, forKey: .stopShown)
        try c.encode(buttons, forKey: .buttons)
    }
}

/// `state`'s result: the window's view state as `AppSession` holds it. Every key is written,
/// null when absent, so a check can tell "no channel" from a key it misspelled.
public struct ControlViewState: Sendable, Equatable, Codable {
    /// `radio` or `library`.
    public var place: String
    public var tunedHz: UInt64?
    /// The tuned channel's mode as `ley` spells it (`nfm`), and its bandwidth.
    public var mode: String?
    public var bandwidthHz: UInt32?
    public var channelID: String?
    public var captureID: String?
    /// The band the radio is in, by its `bands.json` id, and the bookmark tuned, by name.
    public var band: String?
    public var bookmark: String?
    /// The sidebar rows drawn open, by id: the tuned row and one opened by its chevron.
    public var openRows: [String]
    public var filterQuery: String
    public var inspectorShown: Bool
    public var assistantShown: Bool
    public var zoom: Int
    /// The key window's first responder: its accessibility identifier, else its role and label;
    /// empty when nothing holds the focus.
    public var focused: String
    /// Every message the window shows: the notice, the error, the empty-state and
    /// out-of-capture words, the assistant's notice.
    public var notices: [String]
    /// The popover open (`channels:<row id>`, `device_menu`), or empty.
    public var popover: String
    /// The Library's selected channel row and part.
    public var selectedRecordingChannel: String?
    public var selectedPart: String?
    /// The tone the tuned channel last heard, as the inspector writes it beside the bookmark's
    /// (`PL 100.0`, `DCS 023`), or nil before one is measured.
    public var heard: String?
    /// The last sweep's hits as the open row lists them, strongest first, by the name or
    /// frequency each shows.
    public var hits: [String]
    /// The transport's speaker: true when the window has no sink of its own on the channel and
    /// no other client's plays it.
    public var muted: Bool
    /// The window's own sink's volume, 0 to 1, or nil without one.
    public var volume: Double?
    /// Who plays the tuned channel: `own` (the window's sink), `other` (another client's) or
    /// `none`.
    public var sink: String
    public var window: ControlWindowSize?
    /// The insertion point in the sidebar's filter, in characters from its start, while the
    /// filter has the focus; nil otherwise.
    public var filterCaret: Int?
    public var settingsOpen: Bool
    public var alert: ControlAlert?
    public var viewWindow: ControlViewWindow?
    public var assistant: ControlAssistant?
    /// The tooltip of what the last `hover` rested on, or the charts' pointer readout while the
    /// pointer is over one; nil when neither shows.
    public var tooltip: String?

    enum CodingKeys: String, CodingKey {
        case place, mode, band, bookmark, zoom, focused, notices, popover, heard, hits
        case tunedHz = "tuned_hz"
        case bandwidthHz = "bandwidth_hz"
        case channelID = "channel_id"
        case captureID = "capture_id"
        case openRows = "open_rows"
        case filterQuery = "filter_query"
        case inspectorShown = "inspector_shown"
        case assistantShown = "assistant_shown"
        case selectedRecordingChannel = "selected_recording_channel"
        case selectedPart = "selected_part"
        case muted, volume, sink, window, alert, assistant, tooltip
        case filterCaret = "filter_caret"
        case settingsOpen = "settings_open"
        case viewWindow = "view_window"
    }

    public init(
        place: String, tunedHz: UInt64? = nil, mode: String? = nil, bandwidthHz: UInt32? = nil,
        channelID: String? = nil, captureID: String? = nil, band: String? = nil,
        bookmark: String? = nil, openRows: [String] = [], filterQuery: String = "",
        inspectorShown: Bool = false, assistantShown: Bool = false, zoom: Int = 1,
        focused: String = "", notices: [String] = [], popover: String = "",
        selectedRecordingChannel: String? = nil, selectedPart: String? = nil,
        heard: String? = nil, hits: [String] = [], muted: Bool = false, volume: Double? = nil,
        sink: String = "none", window: ControlWindowSize? = nil, filterCaret: Int? = nil,
        settingsOpen: Bool = false, alert: ControlAlert? = nil,
        viewWindow: ControlViewWindow? = nil, assistant: ControlAssistant? = nil,
        tooltip: String? = nil
    ) {
        self.place = place
        self.tunedHz = tunedHz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.channelID = channelID
        self.captureID = captureID
        self.band = band
        self.bookmark = bookmark
        self.openRows = openRows
        self.filterQuery = filterQuery
        self.inspectorShown = inspectorShown
        self.assistantShown = assistantShown
        self.zoom = zoom
        self.focused = focused
        self.notices = notices
        self.popover = popover
        self.selectedRecordingChannel = selectedRecordingChannel
        self.selectedPart = selectedPart
        self.heard = heard
        self.hits = hits
        self.muted = muted
        self.volume = volume
        self.sink = sink
        self.window = window
        self.filterCaret = filterCaret
        self.settingsOpen = settingsOpen
        self.alert = alert
        self.viewWindow = viewWindow
        self.assistant = assistant
        self.tooltip = tooltip
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // `encode` of an optional writes null for nil, where the synthesized conformance
        // would leave the key out.
        try c.encode(place, forKey: .place)
        try c.encode(tunedHz, forKey: .tunedHz)
        try c.encode(mode, forKey: .mode)
        try c.encode(bandwidthHz, forKey: .bandwidthHz)
        try c.encode(channelID, forKey: .channelID)
        try c.encode(captureID, forKey: .captureID)
        try c.encode(band, forKey: .band)
        try c.encode(bookmark, forKey: .bookmark)
        try c.encode(openRows, forKey: .openRows)
        try c.encode(filterQuery, forKey: .filterQuery)
        try c.encode(inspectorShown, forKey: .inspectorShown)
        try c.encode(assistantShown, forKey: .assistantShown)
        try c.encode(zoom, forKey: .zoom)
        try c.encode(focused, forKey: .focused)
        try c.encode(notices, forKey: .notices)
        try c.encode(popover, forKey: .popover)
        try c.encode(selectedRecordingChannel, forKey: .selectedRecordingChannel)
        try c.encode(selectedPart, forKey: .selectedPart)
        try c.encode(heard, forKey: .heard)
        try c.encode(hits, forKey: .hits)
        try c.encode(muted, forKey: .muted)
        try c.encode(volume, forKey: .volume)
        try c.encode(sink, forKey: .sink)
        try c.encode(window, forKey: .window)
        try c.encode(filterCaret, forKey: .filterCaret)
        try c.encode(settingsOpen, forKey: .settingsOpen)
        try c.encode(alert, forKey: .alert)
        try c.encode(viewWindow, forKey: .viewWindow)
        try c.encode(assistant, forKey: .assistant)
        try c.encode(tooltip, forKey: .tooltip)
    }
}

/// `commands.jsonl` as it grows: bytes appended since the last read go in, complete lines come
/// out, and a line the client has not finished writing waits for its newline.
public struct ControlLines: Sendable {
    private var pending = Data()

    public init() {}

    /// The complete lines in `appended` and what was held back before it, blank ones dropped.
    public mutating func append(_ appended: Data) -> [Data] {
        pending.append(appended)
        var lines: [Data] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            pending = Data(pending[pending.index(after: nl)...])
            let trimmed = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(Data(trimmed.utf8)) }
        }
        return lines
    }
}
