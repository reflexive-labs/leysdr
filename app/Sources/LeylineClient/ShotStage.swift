// SPDX-License-Identifier: Apache-2.0

// The stage file `leyshots` hands the app through `LEYLINE_APP_STAGE`, and the `regions.json`
// the app writes back beside it (docs/dev/app.md, "Staged runs"; docs/plans/site-shots.md, "App
// shots"). Both are plain data, kept here so the Linux tests can hold the keys to the shapes
// `go/cmd/leyshots` reads and writes; the app applies the stage and measures the regions.

import Foundation

// On macOS CGRect's geometry (minX, width…) comes from CoreGraphics; Foundation alone carries only
// the type. Linux's Foundation defines both.
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// What a staged run sets before the screenshot: the window's size, the place, the inspector,
/// the open band, the bookmark tuned, the Library part selected and a CHIRP file imported. Every
/// field but `settle` may be absent, which leaves that part of the window as a launch has it.
public struct ShotStage: Sendable, Equatable, Codable {
    /// The variable naming the stage file. With it unset the app is not staged.
    public static let environmentKey = "LEYLINE_APP_STAGE"

    public enum Place: String, Sendable, Equatable, Codable {
        case radio
        case library
    }

    /// The window's frame in points, toolbar included: the size of the image `screencapture -l`
    /// takes at 1×.
    public struct WindowSize: Sendable, Equatable, Codable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public var window: WindowSize?
    public var place: Place?
    public var inspector: Bool?
    /// A sidebar row's id as `bands.json` spells it (`2m`).
    public var expandedBand: String?
    /// A bookmark's name, tuned as a click on its sidebar row tunes it.
    public var selectBookmark: String?
    /// The Library part selected, counted from 0 down the selected channel's page as it is
    /// drawn (the recent days' rows, newest recording first). Selected, not played.
    public var selectPart: Int?
    /// An absolute path to a CHIRP CSV export, imported as File ▸ Import CHIRP… imports one.
    public var importCHIRP: String?
    /// Seconds the window draws after the stage is applied, before the regions are written.
    public var settle: Double
    /// After `settle`, the regions wait for the tuned channel's squelch to be open, so the shot
    /// shows a station on the air.
    public var onAir: Bool
    /// The spectrum and waterfall's width in Hz, centred on the tuned frequency, as the band
    /// rail's − and + set it; the app holds it between the narrowest span the spectrum's bins
    /// allow and the capture.
    public var zoom: UInt64?
    /// Presses the expanded band row's Scan band, as a click does, and waits for the sweep to end
    /// before `settle` starts; its hits then show on the row and the band rail.
    public var scanBand: Bool
    /// With `select_part`, plays that part and pauses it at once, as a click and a second click
    /// do: the Library draws only the playing row as current, not a row that is merely selected.
    public var playPart: Bool
    /// Shows or hides the assistant's panel, as its toolbar button does; drawn only while an AI
    /// provider is set up.
    public var assistant: Bool?
    /// Gives the sidebar's filter field the focus, as Go to… (⌘G) does.
    public var focusFilter: Bool
    /// Opens a sidebar row's Channels… popover, by the row's id (`gmrs`).
    public var channelsPicker: String?
    /// Opens the Settings window (true), as Leyline ▸ Settings… does, or closes it (false).
    public var settings: Bool?
    /// Leaves out the model and confidence after each over's words in the Library, so a shot
    /// made with the scripted speech engine does not show a model that never ran.
    public var hideEngineLabel: Bool

    enum CodingKeys: String, CodingKey {
        case window, place, inspector, settle, zoom
        case onAir = "on_air"
        case scanBand = "scan_band"
        case playPart = "play_part"
        case expandedBand = "expanded_band"
        case selectBookmark = "select_bookmark"
        case selectPart = "select_part"
        case importCHIRP = "import_chirp"
        case assistant
        case focusFilter = "focus_filter"
        case channelsPicker = "channels_picker"
        case settings
        case hideEngineLabel = "hide_engine_label"
    }

    public init(
        window: WindowSize? = nil, place: Place? = nil, inspector: Bool? = nil,
        expandedBand: String? = nil, selectBookmark: String? = nil, selectPart: Int? = nil,
        importCHIRP: String? = nil, settle: Double = 0, onAir: Bool = false,
        zoom: UInt64? = nil, scanBand: Bool = false, playPart: Bool = false,
        assistant: Bool? = nil, focusFilter: Bool = false, channelsPicker: String? = nil,
        settings: Bool? = nil, hideEngineLabel: Bool = false
    ) {
        self.window = window
        self.place = place
        self.inspector = inspector
        self.expandedBand = expandedBand
        self.selectBookmark = selectBookmark
        self.selectPart = selectPart
        self.importCHIRP = importCHIRP
        self.settle = settle
        self.onAir = onAir
        self.zoom = zoom
        self.scanBand = scanBand
        self.playPart = playPart
        self.assistant = assistant
        self.focusFilter = focusFilter
        self.channelsPicker = channelsPicker
        self.settings = settings
        self.hideEngineLabel = hideEngineLabel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window = try c.decodeIfPresent(WindowSize.self, forKey: .window)
        place = try c.decodeIfPresent(Place.self, forKey: .place)
        inspector = try c.decodeIfPresent(Bool.self, forKey: .inspector)
        expandedBand = try c.decodeIfPresent(String.self, forKey: .expandedBand)
        selectBookmark = try c.decodeIfPresent(String.self, forKey: .selectBookmark)
        selectPart = try c.decodeIfPresent(Int.self, forKey: .selectPart)
        importCHIRP = try c.decodeIfPresent(String.self, forKey: .importCHIRP)
        settle = try c.decodeIfPresent(Double.self, forKey: .settle) ?? 0
        onAir = try c.decodeIfPresent(Bool.self, forKey: .onAir) ?? false
        zoom = try c.decodeIfPresent(UInt64.self, forKey: .zoom)
        scanBand = try c.decodeIfPresent(Bool.self, forKey: .scanBand) ?? false
        playPart = try c.decodeIfPresent(Bool.self, forKey: .playPart) ?? false
        assistant = try c.decodeIfPresent(Bool.self, forKey: .assistant)
        focusFilter = try c.decodeIfPresent(Bool.self, forKey: .focusFilter) ?? false
        channelsPicker = try c.decodeIfPresent(String.self, forKey: .channelsPicker)
        settings = try c.decodeIfPresent(Bool.self, forKey: .settings)
        hideEngineLabel = try c.decodeIfPresent(Bool.self, forKey: .hideEngineLabel) ?? false
    }

    /// The stage file's path from the environment, or nil when the run is not staged.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let p = environment[environmentKey], !p.isEmpty else { return nil }
        return p
    }

    /// Reads and decodes a stage file, refused as `validate()` refuses it.
    public static func read(at url: URL) throws -> ShotStage {
        let stage = try JSONDecoder().decode(ShotStage.self, from: Data(contentsOf: url))
        try stage.validate()
        return stage
    }

    /// Refuses a negative or non-finite `settle`, a window without a positive size, a negative
    /// part and a zoom under a kilohertz, which would be the factor `zoom` once took (1 to 8), so
    /// the app never sleeps or sizes on a value it cannot use.
    public func validate() throws {
        guard settle.isFinite, settle >= 0 else {
            throw ShotStageError.invalid("settle must be zero or more seconds")
        }
        if let w = window,
            !(w.width.isFinite && w.height.isFinite && w.width > 0 && w.height > 0)
        {
            throw ShotStageError.invalid("window needs a positive width and height")
        }
        if let p = selectPart, p < 0 {
            throw ShotStageError.invalid("select_part must be 0 or more")
        }
        if let z = zoom, z < Self.leastZoomHz {
            throw ShotStageError.invalid(
                "zoom is the span shown in Hz, at least \(Self.leastZoomHz)")
        }
    }

    /// The least `zoom` a stage may ask for, in Hz.
    public static let leastZoomHz: UInt64 = 1_000

    /// Where `regions.json` goes: beside the stage file.
    public static func regionsURL(besideStage url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("regions.json")
    }

    /// Where the window's own picture goes: beside the stage file, with `regions.json`.
    public static func pictureURL(besideStage url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("window.png")
    }
}

public enum ShotStageError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let why): "stage file refused: \(why)"
        }
    }
}

/// The parts of the window `leyshots` crops to, by the names `scenes.yaml` uses.
public enum ShotRegion: String, Sendable, CaseIterable, Codable {
    case window, sidebar, inspector, toolbar, spectrum, waterfall, library
    /// The one-line notice over the bottom of the waterfall (a CHIRP import's counts), when shown.
    case notice
    /// The Library's page of the selected channel: its day strip and its parts.
    case parts
    /// The inspector's live readings: the Signal, Tuning, Deviation and On air rows and the audio
    /// ladder, which change from one frame to the next while the radio plays. A check masks it.
    case readings
    /// The rows of the inspector's transmissions log, which gain a row whenever an over starts or
    /// ends. A check masks it.
    case transmissions
    /// The tone the tuned channel last heard, beside the bookmark's Tone (`heard PL 100.0`),
    /// which appears once the decoder has measured one. A check masks it.
    case heard
    /// The day over the transmissions log (`today`), blank until the first over. A check masks
    /// it.
    case logDay = "log_day"
    /// The squelch's words and the level in its track, under the waterfall, which follow the
    /// noise between overs. A check masks it.
    case squelch
}

/// `regions.json`: the window's number for `screencapture -l`, its backing scale (pixels per
/// point in `window.png`), and each region on screen as a rectangle in points from the top-left
/// corner of the window's frame, toolbar included, which is the image `screencapture -l` takes.
public struct ShotRegions: Sendable, Equatable, Encodable {
    public struct Rect: Sendable, Equatable, Codable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// A rectangle in AppKit's window coordinates, which run up from the frame's bottom-left
        /// corner, measured from the top-left instead; nil when it is empty or not finite.
        public init?(windowRect r: CGRect, windowHeight: Double) {
            let x = Double(r.minX)
            let y = windowHeight - Double(r.maxY)
            let w = Double(r.width)
            let h = Double(r.height)
            guard [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
            self.init(x: x, y: y, width: w, height: h)
        }
    }

    public var windowNumber: Int
    public var scale: Double
    public var regions: [ShotRegion: Rect]

    public init(windowNumber: Int, scale: Double, regions: [ShotRegion: Rect]) {
        self.windowNumber = windowNumber
        self.scale = scale
        self.regions = regions
    }

    enum CodingKeys: String, CodingKey {
        case windowNumber = "window_number"
        case scale, regions
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(windowNumber, forKey: .windowNumber)
        try c.encode(scale, forKey: .scale)
        // Keyed by the region's name: a dictionary keyed by an enum encodes as an array.
        try c.encode(
            Dictionary(uniqueKeysWithValues: regions.map { ($0.key.rawValue, $0.value) }),
            forKey: .regions)
    }

    /// The file's bytes, keys sorted so two runs of one scene give the same file.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Writes the file the way `BookmarkStore.save()` writes bookmarks: a temp file beside it,
    /// then rename(2), so `leyshots`, which waits for the file to appear, never reads half of it.
    public func write(to url: URL) throws {
        try AppControl.writeReplacing(encoded(), to: url)
    }
}
