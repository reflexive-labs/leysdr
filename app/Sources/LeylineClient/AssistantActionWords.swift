// SPDX-License-Identifier: Apache-2.0

// What a call the assistant asks about would do, in words, for the question card's sentence
// (`docs/plans/app.md`, MC-2: "The assistant wants to remove the APRS bookmark."). The daemon's
// question carries the tool's name, its arguments and the gate's reason, and no sentence of its
// own; the reason says why it asks (`docs/dev/assistant.md`, "The gate"), and may list several
// rows, so the sentence is built here from the name and the arguments. A tool this table does
// not know reads as `use the list presets tool`, and no tool name or object id is ever printed
// as it came: an id is a word for what it names (`a recording`).

import Foundation

extension AssistantWords {
    /// What the call would do, as the rest of "The assistant wants to …": `remove the APRS
    /// bookmark`, `tune to 146.94`, `delete a recording`.
    public static func action(tool: String, argumentsJSON: String) -> String {
        let args = jsonObject(argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)) ?? [:]
        func word(_ key: String) -> String? {
            guard let v = args[key], let s = scalar(v)?.trimmingCharacters(in: .whitespaces),
                !s.isEmpty, s != "null", !isID(s)
            else { return nil }
            return s
        }
        func flag(_ key: String) -> Bool {
            if case .bool(true)? = args[key] { return true }
            return false
        }
        let at = word("frequency").map { " on \($0)" } ?? ""
        switch tool {
        case "remove_bookmark":
            return word("bookmark").map { "remove the \($0) bookmark" } ?? "remove a bookmark"
        case "add_bookmark":
            let what = word("frequency").map { "bookmark \($0)" } ?? "add a bookmark"
            return what + (word("name").map { " as \($0)" } ?? "")
        case "import_chirp":
            let file = word("path").map { " in \(fileName($0))" } ?? " in a CHIRP file"
            return "import the channels\(file) into your bookmarks"
        case "delete_recording": return "delete a recording"
        case "cancel_job": return "cancel a job"
        case "tune": return word("frequency").map { "tune to \($0)" } ?? "tune the radio"
        case "scan": return word("range").map { "scan \($0)" } ?? "scan the band"
        case "record":
            let what = word("target").map { "record \($0)" } ?? "record a channel"
            return what + (word("duration_s").map { " for \($0) s" } ?? "")
        case "listen_summary":
            let what = word("target").map { "listen to \($0)" } ?? "listen to a channel"
            return what + (word("duration_s").map { " for \($0) s" } ?? "")
        case "snapshot":
            let place = word("band").map { " of \($0)" } ?? at
            return "take a snapshot of the spectrum\(place)"
        case "start_decode_job":
            let decoder = word("decoder").map { "the \($0) decoder" } ?? "a decoder"
            return "run \(decoder)\(at)"
        case "watch":
            let decoder = word("decoder").map { "\($0) " } ?? ""
            return "watch for \(decoder)records\(at)"
        case "set":
            guard let param = word("param") else { return "change a setting" }
            let name = param.replacingOccurrences(of: "_", with: " ")
            return word("value").map { "set the \(name) to \($0)" } ?? "set the \(name)"
        case "stop": return flag("all") ? "stop every channel" : "stop a channel"
        case "attach_device":
            let file = word("path").map { " from \(fileName($0))" } ?? ""
            return "attach a radio\(file)"
        default:
            let name = tool.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "use a tool" : "use the \(name) tool"
        }
    }

    /// The line under the card's sentence: what the gate's reason says that the sentence does
    /// not, in words, or empty when it says nothing more (`docs/plans/app.md`, MC-4). The reason
    /// is the daemon's, one clause per policy row joined by `; ` (`go/internal/assistant`,
    /// `policy.go`), and is written for the model as much as for a person, so it names arguments
    /// (`take_over`, `dry_run`) and ids. A clause that restates the action (`remove the bookmark
    /// "APRS" from your bookmarks`) goes, a take-over says whom it takes the radio from, and a
    /// clause this table does not know is kept as the daemon wrote it.
    public static func cardReason(_ reason: String) -> String {
        var clauses: [String] = []
        for part in reason.components(separatedBy: "; ") {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if clauses.isEmpty || reasonRows.contains(where: { p.hasPrefix($0) }) {
                clauses.append(p)
            } else {
                // Inside one row's own words: `and its files; this cannot be undone`.
                clauses[clauses.count - 1] += "; " + p
            }
        }
        var out: [String] = []
        for c in clauses {
            let words = clauseWords(c)
            if !words.isEmpty, !out.contains(words) { out.append(words) }
        }
        return out.joined(separator: " ")
    }

    /// How each policy row's reason begins, in the gate's order.
    static let reasonRows = [
        takeOverStart, "start a kept ", "add a webhook notifier: ", "delete the recording ",
        "remove the bookmark ", "cancel ", "import every channel in ",
        "a third bookmark change this turn", "the assistant could not check whether ",
        "start paid transcription", "the assistant read text received over the air",
    ]
    static let takeOverStart = "another channel or client is using the radio"

    /// One clause of the reason as a sentence for the card, or empty when the card's sentence
    /// already says it.
    static func clauseWords(_ c: String) -> String {
        if c.hasPrefix(takeOverStart) { return takeOverWords(c) }
        if c.hasPrefix("start a kept ") {
            return "It keeps running after this conversation ends, until it is cancelled."
        }
        if c.hasPrefix("add a webhook notifier: ") {
            return sentence(String(c.dropFirst("add a webhook notifier: ".count)))
        }
        if c.hasPrefix("delete the recording ") {
            return "Its files go with it, and this cannot be undone."
        }
        if c.hasPrefix("remove the bookmark ") || c.hasPrefix("import every channel in ") {
            return ""
        }
        if c.hasPrefix("cancel "), c.hasSuffix("a job the assistant did not start") {
            return "The assistant did not start this job."
        }
        if c.hasPrefix("a third bookmark change this turn") {
            return "It is the third bookmark change this turn."
        }
        if c.hasPrefix("start paid transcription"), let colon = c.firstIndex(of: ":") {
            let rest = c[c.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return sentence("it is paid transcription: \(rest)")
        }
        return sentence(c)
    }

    /// "It takes the radio from the window.": whom a take-over takes the radio from, by the kind
    /// of client the daemon's refusal names in each channel's parentheses (`chan_X (146.520 MHz,
    /// app:Leyline)`), never the `take_over` argument. With no refusal before it, who is
    /// listening is not known.
    static func takeOverWords(_ c: String) -> String {
        var who: [String] = []
        var rest = Substring(c)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let inside = rest[rest.index(after: open)..<close]
            if let owner = inside.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
                let colon = owner.firstIndex(of: ":")
            {
                let name: String
                switch owner[..<colon] {
                case "app": name = "the window"
                case "cli": name = "a ley command"
                case "mcp": name = "another assistant"
                case "job": name = "a job"
                default: name = "another client"
                }
                if !who.contains(name) { who.append(name) }
            }
            rest = rest[rest.index(after: close)...]
        }
        guard let last = who.last else { return "It takes the radio from whoever is using it." }
        let list = who.count == 1 ? last : who.dropLast().joined(separator: ", ") + " and " + last
        return "It takes the radio from \(list)."
    }

    /// The clause with a capital and a full stop.
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let first = t.first, let end = t.last else { return "" }
        let body = first.uppercased() + t.dropFirst()
        return ".!?".contains(end) ? body : body + "."
    }

    /// An object id or a resource URI, which the sentence names by kind instead: `cap_`, `chan_`,
    /// `job_`, `rec_`, `dev_`, `conv_`, `sink_` and `ley://`.
    static func isID(_ s: String) -> Bool {
        if s.hasPrefix("ley://") { return true }
        let prefixes = ["cap_", "chan_", "job_", "rec_", "dev_", "conv_", "sink_"]
        return prefixes.contains { s.hasPrefix($0) } && !s.contains(" ")
    }

    /// The last part of a path: `club.csv` for `/Users/me/club.csv`.
    static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
