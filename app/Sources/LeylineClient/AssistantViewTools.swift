// SPDX-License-Identifier: Apache-2.0

// The view tools the app declares when it starts a conversation: moving the waterfall's view to a
// band, opening the Library on a recording, and showing one of the window's two places. The
// assistant calls them like its other tools, the daemon routes each call to this client as a call
// awaiting the client, and the app performs it and answers (`docs/design/ai.md`, "The assistant").
// View state stays in the client, and a view tool never moves the radio: the waterfall's view
// moves only inside the span the radio is capturing, and the answer says to tune when the band is
// outside it, because retuning goes only through the radio tools and their don't-disturb check
// (`docs/design/ai.md`, "The assistant"). The names follow the worker's rule for a view tool, 1
// to 64 letters, digits, `_` or `-` and no radio tool's name (`docs/dev/assistant.md`, "The
// tools"). Every input is parsed here, so a malformed call is answered as an error and never
// reaches the window.

import Foundation
import LeylineProto

/// What the app answers a view tool with: the prose and JSON the model reads, and whether the
/// call failed.
public struct ViewToolAnswer: Sendable, Equatable {
    public var text: String
    public var json: String
    public var isError: Bool

    public init(text: String, json: String = "", isError: Bool = false) {
        self.text = text
        self.json = json
        self.isError = isError
    }

    static func error(_ text: String) -> ViewToolAnswer {
        ViewToolAnswer(text: text, json: "", isError: true)
    }

    /// The answer's JSON from a dictionary, keys sorted so the same answer is the same bytes.
    static func json(_ fields: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(fields)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The window's two places, as `show_place` names them.
public enum ViewPlace: String, Sendable, CaseIterable {
    case radio, library
}

/// The app's view tools: their declarations and their input.
public enum AppViewTools {
    public static let showBand = "show_band"
    public static let selectRecording = "select_recording"
    public static let showPlace = "show_place"

    /// A view tool call, parsed.
    public enum Request: Sendable, Equatable {
        /// Show `lowHz` to `highHz` on the waterfall; `label` names it in the answer
        /// ("2 m", "145.000 MHz to 146.000 MHz").
        case showRange(lowHz: UInt64, highHz: UInt64, label: String)
        /// Open the Library on the recording with this job id, at this part when one is given.
        case selectRecording(id: String, part: Int?)
        case showPlace(ViewPlace)
    }

    /// What `StartConversation` declares, in the order the model is offered them.
    public static let declarations: [Leyline_V1_ViewTool] = [
        tool(
            showBand,
            "Moves the app's waterfall to show a band or a range of frequencies, without retuning the radio. Only what the radio is capturing can be shown; for a band outside it, use tune, which asks first when someone else is using the radio.",
            #"{"type":"object","properties":{"band":{"type":"string","description":"a band's name or alias, as list_bands gives it, such as 2m or airband"},"from_hz":{"type":"integer","description":"the lowest frequency to show, in Hz"},"to_hz":{"type":"integer","description":"the highest frequency to show, in Hz"}},"additionalProperties":false}"#
        ),
        tool(
            selectRecording,
            "Opens the app's Library on a recording, and on one of its parts when part is given, so the person can play it.",
            #"{"type":"object","properties":{"recording":{"type":"string","description":"the recording's id or ley://recordings/ URI, as find_recordings gives it"},"part":{"type":"integer","minimum":1,"description":"the part's number, as get_recording lists it"}},"required":["recording"],"additionalProperties":false}"#
        ),
        tool(
            showPlace,
            "Shows one of the app window's two places: radio (the live waterfall) or library (what has been recorded).",
            #"{"type":"object","properties":{"place":{"type":"string","enum":["radio","library"]}},"required":["place"],"additionalProperties":false}"#
        ),
    ]

    private static func tool(_ name: String, _ description: String, _ schema: String)
        -> Leyline_V1_ViewTool
    {
        var t = Leyline_V1_ViewTool()
        t.name = name
        t.description_p = description
        t.inputSchemaJson = schema
        return t
    }

    /// Parses a call to one of the app's view tools. A failure is the error answer the model
    /// reads, saying what was wrong with the input, so it can call again.
    public static func parse(tool: String, argumentsJSON: String) -> Result<Request, ViewToolError>
    {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let args: [String: JSONValue]
        if trimmed.isEmpty {
            args = [:]
        } else if let o = AssistantWords.jsonObject(trimmed) {
            args = o
        } else {
            return .failure(ViewToolError("the arguments to \(tool) are not a JSON object"))
        }
        switch tool {
        case showBand: return parseShowBand(args)
        case selectRecording: return parseSelectRecording(args)
        case showPlace:
            guard case .string(let s)? = args["place"],
                let place = ViewPlace(rawValue: s.lowercased())
            else { return .failure(ViewToolError("place must be radio or library")) }
            return .success(.showPlace(place))
        default:
            return .failure(ViewToolError("the app has no view tool named \(tool)"))
        }
    }

    private static func parseShowBand(_ args: [String: JSONValue]) -> Result<Request, ViewToolError>
    {
        if case .string(let name)? = args["band"] {
            guard args["from_hz"] == nil, args["to_hz"] == nil else {
                return .failure(ViewToolError("give a band or from_hz and to_hz, not both"))
            }
            guard let band = Bands.resolve(name) else {
                return .failure(
                    ViewToolError("no band is named \(name); list_bands gives the names"))
            }
            return .success(.showRange(lowHz: band.minHz, highHz: band.maxHz, label: band.name))
        }
        guard args["band"] == nil else { return .failure(ViewToolError("band must be a string")) }
        guard let low = hz(args["from_hz"]), let high = hz(args["to_hz"]) else {
            return .failure(
                ViewToolError("give a band, or from_hz and to_hz as whole numbers of Hz"))
        }
        guard low < high else {
            return .failure(ViewToolError("from_hz must be below to_hz"))
        }
        let label =
            "\(BookmarkNaming.frequencyWords(low)) to \(BookmarkNaming.frequencyWords(high))"
        return .success(.showRange(lowHz: low, highHz: high, label: label))
    }

    private static func parseSelectRecording(_ args: [String: JSONValue])
        -> Result<Request, ViewToolError>
    {
        guard case .string(let raw)? = args["recording"] else {
            return .failure(ViewToolError("recording must be the recording's id"))
        }
        var id = raw.trimmingCharacters(in: .whitespaces)
        var part: Int?
        // A part's URI names both: ley://recordings/<id>/<part>.
        if let ref = RecordingPartRef(uri: id) {
            id = ref.jobID
            part = ref.part
        } else if id.hasPrefix(recordingsPrefix) {
            id = String(id.dropFirst(recordingsPrefix.count))
        }
        guard !id.isEmpty, !id.contains("/") else {
            return .failure(ViewToolError("\(raw) is not a recording's id"))
        }
        if let p = args["part"] {
            guard case .number(let n) = p, n.isFinite, n == n.rounded(), n >= 1, n < 1e9 else {
                return .failure(ViewToolError("part must be a whole number from 1"))
            }
            part = Int(n)
        }
        return .success(.selectRecording(id: id, part: part))
    }

    private static let recordingsPrefix = "ley://recordings/"

    /// A whole, non-negative number of Hz that fits the contract's `uint64`; nil otherwise.
    private static func hz(_ v: JSONValue?) -> UInt64? {
        guard case .number(let n)? = v, n.isFinite, n >= 0, n == n.rounded(), n < 1e15 else {
            return nil
        }
        return UInt64(n)
    }

    // MARK: Answers

    /// The answer to `show_band` and the view to apply: the waterfall moved to the part of the
    /// range the radio captures, or an error when the radio captures none of it. `centerHz` and
    /// `sampleRate` are the capture's, nil with no radio open.
    public static func showRange(
        lowHz: UInt64, highHz: UInt64, label: String, centerHz: UInt64?, sampleRate: UInt64
    ) -> (answer: ViewToolAnswer, fit: ViewWindow.Fit?) {
        let asked = "\(label) (\(rangeWords(lowHz...highHz)))"
        let named = label.contains(" to ") ? label : asked
        guard let centerHz, sampleRate > 0 else {
            return (
                .error(
                    "No radio is open, so there is no waterfall to move; tune opens one on \(named)."
                ), nil
            )
        }
        let span = ViewWindow.span(centerHz: centerHz, sampleRate: sampleRate)
        guard
            let fit = ViewWindow.fit(
                lowHz: lowHz, highHz: highHz, centerHz: centerHz, sampleRate: sampleRate)
        else {
            return (
                .error(
                    "\(named) is outside what the radio is capturing (\(rangeWords(span))), and the waterfall shows only that. Tune the radio there to see it; tune asks first when someone else is using the radio."
                ), nil
            )
        }
        var text = "The waterfall shows \(rangeWords(fit.shown))."
        if !fit.whole {
            text +=
                " The radio captures \(rangeWords(span)), so that is all of \(named) it can show without a retune."
        }
        let json = ViewToolAnswer.json([
            "place": .string(ViewPlace.radio.rawValue),
            "from_hz": .number(Double(fit.shown.lowerBound)),
            "to_hz": .number(Double(fit.shown.upperBound)),
            "zoom": .number(Double(fit.zoom)),
            "whole": .bool(fit.whole),
        ])
        return (ViewToolAnswer(text: text, json: json), fit)
    }

    /// The answer once the Library shows the recording.
    public static func selected(recording id: String, part: Int?, title: String) -> ViewToolAnswer {
        var fields: [String: JSONValue] = [
            "place": .string(ViewPlace.library.rawValue), "recording": .string(id),
        ]
        if let part { fields["part"] = .number(Double(part)) }
        let what = part.map { "part \($0) of the recording" } ?? "the recording"
        return ViewToolAnswer(
            text: "The Library shows \(what) on \(title).", json: ViewToolAnswer.json(fields))
    }

    /// The answer when the daemon's listing has no such recording, or the recording no such part.
    public static func unknownRecording(_ id: String, part: Int? = nil) -> ViewToolAnswer {
        if let part {
            return .error("Recording \(id) has no part \(part); get_recording lists its parts.")
        }
        return .error("No recording \(id) is in the Library; find_recordings lists them.")
    }

    public static func shown(_ place: ViewPlace) -> ViewToolAnswer {
        ViewToolAnswer(
            text: place == .radio ? "The window shows the radio." : "The window shows the Library.",
            json: ViewToolAnswer.json(["place": .string(place.rawValue)]))
    }

    /// "144.000 MHz to 148.000 MHz".
    static func rangeWords(_ r: ClosedRange<UInt64>) -> String {
        "\(BookmarkNaming.frequencyWords(r.lowerBound)) to \(BookmarkNaming.frequencyWords(r.upperBound))"
    }
}

/// A view tool's input the app could not use, worded for the model.
public struct ViewToolError: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }

    public var answer: ViewToolAnswer { .error(message) }
}

/// Which frequencies the spectrum and waterfall show: the capture's span at zoom 1, and at a
/// higher zoom a window of it, centred on the tuned frequency or on where a view tool put it.
/// Presentation only: the radio is not moved.
public enum ViewWindow {
    /// The zooms the View menu steps through, ⌘= and ⌘-.
    public static let zooms = [1, 2, 4, 8]

    /// The capture's span, its lower edge held at 0 Hz.
    public static func span(centerHz: UInt64, sampleRate: UInt64) -> ClosedRange<UInt64> {
        let lo = centerHz > sampleRate / 2 ? centerHz - sampleRate / 2 : 0
        return lo...(centerHz + sampleRate / 2)
    }

    /// The span at `zoom` 1; otherwise a window `zoom` times narrower centred on `focusHz`, kept
    /// inside the span.
    public static func visible(centerHz: UInt64, sampleRate: UInt64, zoom: Int, focusHz: UInt64)
        -> ClosedRange<UInt64>?
    {
        guard sampleRate > 0 else { return nil }
        let full = span(centerHz: centerHz, sampleRate: sampleRate)
        guard zoom > 1 else { return full }
        let width = sampleRate / UInt64(zoom)
        let centre = min(
            max(focusHz, full.lowerBound + width / 2), full.upperBound - width / 2)
        return (centre - width / 2)...(centre + width / 2)
    }

    /// How a range is shown: the zoom, the frequency the window centres on, what it then shows,
    /// and whether that holds the whole range asked for.
    public struct Fit: Sendable, Equatable {
        public let zoom: Int
        public let focusHz: UInt64
        public let shown: ClosedRange<UInt64>
        public let whole: Bool
    }

    /// The closest view of `lowHz` to `highHz`: the part of it inside the span, at the highest
    /// zoom whose window still holds that part, centred on it. Nil when the span holds none of it.
    public static func fit(lowHz: UInt64, highHz: UInt64, centerHz: UInt64, sampleRate: UInt64)
        -> Fit?
    {
        guard sampleRate > 0, lowHz < highHz else { return nil }
        let full = span(centerHz: centerHz, sampleRate: sampleRate)
        let lo = max(lowHz, full.lowerBound)
        let hi = min(highHz, full.upperBound)
        guard lo < hi else { return nil }
        let need = hi - lo
        let zoom = zooms.last { sampleRate / UInt64($0) >= need } ?? 1
        let focus = lo + need / 2
        guard
            let shown = visible(
                centerHz: centerHz, sampleRate: sampleRate, zoom: zoom, focusHz: focus)
        else { return nil }
        return Fit(
            zoom: zoom, focusHz: focus, shown: shown,
            whole: lowHz >= full.lowerBound && highHz <= full.upperBound)
    }
}

/// Where a view tool centred the zoomed window, held only while the radio stays tuned where it was
/// then and the view is zoomed: a tune, from this window or any client, puts the window back on the
/// tuned frequency, and so does zooming back out to the whole span.
public struct ViewFocus: Sendable, Equatable {
    public let hz: UInt64
    public let tunedHz: UInt64?

    public init(hz: UInt64, tunedHz: UInt64?) {
        self.hz = hz
        self.tunedHz = tunedHz
    }

    /// The centre the zoomed window takes now: the focus while the tuned frequency is the one it
    /// was set against, else nil.
    public func centre(tunedHz now: UInt64?) -> UInt64? {
        now == tunedHz ? hz : nil
    }

    /// The focus the session keeps after a mirror change or a zoom: `focus` while the radio is
    /// tuned where it was set and the view is zoomed in, else nil, so it is cleared rather than
    /// left to come back the next time the frequency or the zoom returns.
    public static func kept(_ focus: ViewFocus?, tunedHz: UInt64?, zoom: Int) -> ViewFocus? {
        guard let focus, zoom > 1, focus.tunedHz == tunedHz else { return nil }
        return focus
    }
}
