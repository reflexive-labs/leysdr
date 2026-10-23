// SPDX-License-Identifier: Apache-2.0

// An opened step as the assistant's panel lays it out (`docs/plans/app.md`, MC-2): the call's
// arguments as `key value` lines, and its result as a small table when the result's JSON is rows,
// else as compact text; the raw JSON stays one toggle away. Pure functions over the call's
// strings, so the Linux tests read every line the panel prints.

import Foundation

/// One tool call, opened.
public struct StepDetail: Sendable, Equatable {
    /// One argument: its name and its value as it reads in a line, a nested value as compact
    /// JSON. Arguments that are not a JSON object are one line with no key.
    public struct Argument: Sendable, Equatable {
        public let key: String
        public let value: String
    }

    /// Rows of a result: at most `StepDetail.columnLimit` columns, the first
    /// `StepDetail.rowLimit` rows, and how many more the result holds.
    public struct Table: Sendable, Equatable {
        public let columns: [String]
        public let rows: [[String]]
        public let more: Int

        /// `… 18 more`, or nil when every row is shown.
        public var moreWords: String? { more > 0 ? "\u{2026} \(more) more" : nil }
    }

    public enum Result: Sendable, Equatable {
        case none
        case text(String)
        case table(Table)
    }

    public let arguments: [Argument]
    public let result: Result
    /// The arguments' and the result's JSON, indented, for the JSON toggle; empty when the call
    /// carried none.
    public let argumentsJSON: String
    public let resultJSON: String

    /// The JSON toggle shows: there is JSON that the readable lines do not already say whole.
    public var hasJSON: Bool { !resultJSON.isEmpty || !argumentsJSON.isEmpty }

    /// The rows a table shows before `… N more`: with its column head and that line, about ten
    /// lines, inside the opened step's twelve.
    public static let rowLimit = 8
    /// The columns a table shows: as many as fit the 320 pt column in `Font.valueSmall`.
    public static let columnLimit = 3

    public init(argumentsJSON args: String, resultText: String, resultJSON: String) {
        arguments = Self.arguments(args)
        let raw = resultJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if let table = Self.table(raw) {
            result = .table(table)
        } else {
            let text = Self.compact(resultText)
            if !text.isEmpty {
                result = .text(text)
            } else if !raw.isEmpty {
                result = .text(AssistantWords.inlineJSON(raw))
            } else {
                result = .none
            }
        }
        let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        argumentsJSON =
            trimmedArgs.isEmpty || trimmedArgs == "{}"
            ? "" : AssistantWords.pretty(json: trimmedArgs)
        self.resultJSON = raw.isEmpty ? "" : AssistantWords.pretty(json: raw)
    }

    /// The arguments in name order, each `name value`; nothing for no arguments or `{}`.
    static func arguments(_ json: String) -> [Argument] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let object = AssistantWords.jsonObject(trimmed) else {
            let flat = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return [Argument(key: "", value: flat)]
        }
        return object.keys.sorted().map { k in
            Argument(key: k, value: object[k].map(AssistantWords.inline) ?? "")
        }
    }

    /// The result's text with each line's trailing spaces gone, the blank lines at its ends gone
    /// and a run of blank lines inside it made one.
    static func compact(_ text: String) -> String {
        var out: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var l = line
            while let last = l.last, last == " " || last == "\t" || last == "\r" { l.removeLast() }
            if l.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(l)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// A table when the JSON is rows: an array of objects, or an object whose one key holds one
    /// (`{"recordings": [...]}`). Nil for anything else, and for rows with no column to show.
    static func table(_ json: String) -> Table? {
        guard !json.isEmpty, let data = json.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        let items: [JSONValue]
        switch value {
        case .array(let a): items = a
        case .object(let o) where o.count == 1:
            guard case .array(let a)? = o.values.first else { return nil }
            items = a
        default: return nil
        }
        let rows = items.compactMap { item -> [String: JSONValue]? in
            if case .object(let o) = item { return o }
            return nil
        }
        guard !rows.isEmpty, rows.count == items.count else { return nil }
        let picked = columns(rows)
        guard !picked.isEmpty else { return nil }
        let shown = rows.prefix(rowLimit).map { row in
            picked.map { c in row[c.key].map { cell($0, frequency: c.isFrequency) } ?? "" }
        }
        return Table(
            columns: picked.map(\.title), rows: Array(shown), more: rows.count - shown.count)
    }

    /// A column the table shows: the key it reads, the head it prints, and whether its numbers
    /// are hertz.
    struct Column: Equatable {
        let key: String
        let title: String
        let isFrequency: Bool
    }

    /// The keys that name a row, first found wins.
    static let nameKeys = ["name", "label", "title", "id"]
    /// The keys that hold a row's frequency, first found wins; the column is `frequency`.
    static let frequencyKeys = ["frequency_hz", "hz", "center_hz", "frequency"]
    /// Prose that does not fit a cell: left out unless nothing else is there.
    static let proseKeys: Set<String> = ["description", "note", "summary", "text"]

    /// The most useful columns, up to `columnLimit`: the row's name, its frequency and its mode,
    /// as the owner's `name frequency mode`, then the other keys whose values are scalars in
    /// every row, in name order, prose last.
    static func columns(_ rows: [[String: JSONValue]]) -> [Column] {
        let scalarKeys = Set(rows[0].keys).filter { k in
            rows.allSatisfy { row in row[k].map { AssistantWords.scalar($0) != nil } ?? true }
        }
        var out: [Column] = []
        if let k = nameKeys.first(where: scalarKeys.contains) {
            out.append(Column(key: k, title: k, isFrequency: false))
        }
        if let k = frequencyKeys.first(where: scalarKeys.contains) {
            out.append(Column(key: k, title: "frequency", isFrequency: true))
        }
        if scalarKeys.contains("mode") {
            out.append(Column(key: "mode", title: "mode", isFrequency: false))
        }
        let taken = Set(out.map(\.key)).union(frequencyKeys).union(nameKeys)
        let rest = scalarKeys.subtracting(taken).sorted { a, b in
            let pa = proseKeys.contains(a)
            let pb = proseKeys.contains(b)
            return pa == pb ? a < b : !pa
        }
        for k in rest where out.count < columnLimit {
            out.append(
                Column(
                    key: k, title: k.replacingOccurrences(of: "_", with: " "), isFrequency: false))
        }
        return Array(out.prefix(columnLimit))
    }

    /// A cell: a frequency in hertz as `146.520 MHz`, anything else as it reads in a line.
    static func cell(_ v: JSONValue, frequency: Bool) -> String {
        if frequency, case .number(let n) = v, n.isFinite, n >= 0, n < 1e15 {
            return BookmarkNaming.frequencyWords(UInt64(n))
        }
        return AssistantWords.inline(v)
    }
}

extension StepRow {
    /// The step opened: its arguments, its result, and the JSON behind them.
    public var detail: StepDetail {
        StepDetail(argumentsJSON: argumentsJSON, resultText: resultText, resultJSON: resultJSON)
    }
}

extension AssistantWords {
    /// JSON on one line with sorted keys; the text as it came when it is not JSON.
    static func inlineJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return json }
        return inline(value)
    }
}
