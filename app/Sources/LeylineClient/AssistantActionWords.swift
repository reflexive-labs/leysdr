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
