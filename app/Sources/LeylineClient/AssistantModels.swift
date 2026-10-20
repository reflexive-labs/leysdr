// SPDX-License-Identifier: Apache-2.0

// The assistant's conversation as the app's panel draws it: each turn, each tool call as a step
// with its arguments in one line and its result, the question the assistant is waiting on, and the
// tokens the conversation has used. Pure functions over `Leyline_V1_Conversation` and the mirror's
// usage lines, so the Linux tests read every string the panel prints. The conversation is daemon
// state (`docs/design/ai.md`, "The assistant"): the panel renders it and moves it only through the
// `Assistant` RPCs, as `ley ask` does, and the words follow `ley ask`'s (`go/internal/cli/ask.go`):
// a step is `→ tool arguments` and its result's first line, a declined call says so, and usage is
// in the provider's units, never a price (`docs/design/ai.md`, "Usage").

import Foundation
import LeylineProto

/// One conversation as the panel draws it.
public struct ConversationView: Sendable, Equatable {
    public let conversationID: String
    public let state: Leyline_V1_ConversationState
    /// "anthropic claude-sonnet-5-5", or empty when the daemon chose the worker's default.
    public let model: String
    public let turns: [TurnRow]
    /// What the assistant waits on while the conversation is `WAITING`.
    public let pending: PendingQuestion?
    /// Why a failed conversation stopped, in the daemon's words.
    public let errorText: String?

    public init(_ c: Leyline_V1_Conversation) {
        conversationID = c.conversationID
        state = c.state
        model = [c.provider, c.model].filter { !$0.isEmpty }.joined(separator: " ")
        turns = c.turns.map(TurnRow.init)
        pending =
            c.state == .conversationWaiting && c.hasPending && !c.pending.callID.isEmpty
            ? PendingQuestion(c.pending) : nil
        if c.state == .conversationFailed {
            let e = c.error
            errorText =
                e.message.isEmpty
                ? (e.code.isEmpty ? "The assistant stopped." : e.code) : e.message
        } else {
            errorText = nil
        }
    }

    /// A message can be sent only while the assistant waits for the user, which is what
    /// `SendMessage` accepts.
    public var canSend: Bool { state == .conversationIdle }
    /// The assistant is on a turn and Stop ends it.
    public var isThinking: Bool { state == .conversationThinking }
    /// Stop shows: while the assistant thinks, and while it waits on one of the app's view tools,
    /// which the person did not decide and may want to cut short. A question the person decides
    /// has Decline instead.
    public var canStop: Bool { isThinking || pending?.isViewTool == true }
    /// Ended or failed: nothing more happens in it, and the panel offers a new one.
    public var isOver: Bool { state == .conversationEnded || state == .conversationFailed }

    /// The state in one word for the panel's header.
    public var stateWord: String {
        switch state {
        case .conversationIdle: "ready"
        case .conversationThinking: "thinking"
        case .conversationWaiting: pending?.isViewTool == true ? "working" : "waiting for you"
        case .conversationEnded: "ended"
        case .conversationFailed: "failed"
        default: "starting"
        }
    }
}

/// One turn: the user's message or the assistant's reply with the tool calls it made.
public struct TurnRow: Sendable, Equatable, Identifiable {
    public enum Role: Sendable, Equatable {
        case user, assistant
    }

    public let id: String
    public let role: Role
    /// The text so far; the whole text once `done`.
    public let text: String
    public let done: Bool
    public let steps: [StepRow]

    public init(_ t: Leyline_V1_Turn) {
        id = t.turnID
        role = t.role == .user ? .user : .assistant
        text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        done = t.done
        steps = t.tools.map(StepRow.init)
    }
}

/// One tool call: a disclosure row whose line is the tool and its arguments and whose body is the
/// arguments in full and the result.
public struct StepRow: Sendable, Equatable, Identifiable {
    public var id: String { callID }
    public let callID: String
    public let tool: String
    /// The arguments on one line: `noaa`, `frequency 146.52 · mode nfm`.
    public let summary: String
    /// The arguments as indented JSON for the expanded row; the text as it came when it is not
    /// JSON.
    public let arguments: String
    public let state: Leyline_V1_ToolCallState
    public let isError: Bool
    /// The result's first line, under the step while it is closed; empty until the call is done.
    public let resultFirstLine: String
    /// The tool's prose in full.
    public let resultText: String
    /// The tool's JSON, as the tool returned it.
    public let resultJSON: String
    /// Why the call asked first, the gate's words; empty for a call that ran.
    public let reason: String

    public init(_ c: Leyline_V1_ToolCall) {
        callID = c.callID
        tool = c.tool
        summary = AssistantWords.summary(argumentsJSON: c.argumentsJson)
        arguments = AssistantWords.pretty(json: c.argumentsJson)
        state = c.state
        isError = c.isError
        resultFirstLine = AssistantWords.firstLine(c.resultText)
        resultText = c.resultText
        resultJSON = c.resultJson
        reason = c.reason
    }

    /// `→ tune noaa`: the closed row's line, `ley ask`'s.
    public var line: String {
        summary.isEmpty ? "\u{2192} \(tool)" : "\u{2192} \(tool) \(summary)"
    }

    /// What became of the call, in one word.
    public var stateWord: String {
        let stopped = AssistantWords.firstLine(resultText) == "stopped"
        switch state {
        case .toolCallRunning: return "running"
        case .toolCallDone: return stopped ? "stopped" : isError ? "failed" : "done"
        case .toolCallAwaitingApproval: return "asks"
        case .toolCallAwaitingClient: return "in the app"
        case .toolCallRefused: return stopped ? "stopped" : "declined"
        default: return ""
        }
    }
}

/// The call the assistant waits on: a question with Allow and Decline, or a view tool the app
/// performs itself without asking.
public struct PendingQuestion: Sendable, Equatable {
    public let callID: String
    public let tool: String
    public let summary: String
    /// Why it asks, the gate's words (`docs/dev/assistant.md`, "The gate").
    public let reason: String
    /// A call to one of the app's own view tools: answered by the app, never put to the person.
    public let isViewTool: Bool
    /// The scopes the gate accepts for this call, ONCE included; the card shows a button for each.
    /// Empty for a view tool, and from a daemon that sends none, which means ONCE alone.
    public let offers: [Leyline_V1_ApprovalScope]

    public init(_ p: Leyline_V1_PendingAction) {
        callID = p.callID
        tool = p.tool
        summary = AssistantWords.summary(argumentsJSON: p.argumentsJson)
        reason = p.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        isViewTool = p.viewTool
        offers = p.offers
    }

    /// The question can be allowed for the rest of the conversation: every row the gate lists
    /// for it is granted, and later calls of that kind run without asking
    /// (`docs/dev/assistant.md`, "The gate"). A delete, and a cancel of another client's job,
    /// never offer it.
    public var offersConversation: Bool { offers.contains(.conversation) }

    /// "The assistant wants to delete_recording rec_01…", `ley ask`'s question without the
    /// letters it offers; the reason goes on a line of its own under it.
    public var question: String {
        let what = summary.isEmpty ? tool : "\(tool) \(summary)"
        return "The assistant wants to \(what)."
    }
}

/// The tokens one conversation has used so far: its usage lines summed over the days they fall on.
/// The worker reports usage with the conversation's id as the scope, after every response
/// (`docs/dev/assistant.md`, "The loop"), and the mirror carries each line.
public struct UsageSoFar: Sendable, Equatable {
    public var requests: UInt64 = 0
    public var inputTokens: UInt64 = 0
    public var outputTokens: UInt64 = 0
    public var cacheReadTokens: UInt64 = 0
    public var cacheWriteTokens: UInt64 = 0

    public init(lines: [Leyline_V1_UsageLine], conversationID: String) {
        for l in lines where l.scopeID == conversationID && !conversationID.isEmpty {
            requests += l.requests
            inputTokens += l.inputTokens
            outputTokens += l.outputTokens
            cacheReadTokens += l.cacheReadTokens
            cacheWriteTokens += l.cacheWriteTokens
        }
    }

    /// "3 requests, 1.2k in, 400 out", with ", 12k from cache" when the provider's cache served
    /// any; nil before the first request.
    public var words: String? {
        guard requests > 0 else { return nil }
        var parts = [
            requests == 1 ? "1 request" : "\(requests) requests",
            "\(AssistantWords.tokens(inputTokens)) in",
            "\(AssistantWords.tokens(outputTokens)) out",
        ]
        if cacheReadTokens > 0 {
            parts.append("\(AssistantWords.tokens(cacheReadTokens)) from cache")
        }
        return parts.joined(separator: ", ")
    }
}

/// What the panel asked the daemon to do, for the words when it could not.
public enum AssistantAction: Sendable, Equatable {
    case start, send, resolve, answerViewTool, stop, end

    public var words: String {
        switch self {
        case .start: "start"
        case .send: "take the message"
        case .resolve: "take the answer"
        case .answerViewTool: "hear what the app did"
        case .stop: "stop"
        case .end: "end the conversation"
        }
    }
}

/// Why the assistant could not start or take a message, and whether the fix is in Settings.
public struct AssistantNotice: Sendable, Equatable {
    public let text: String
    /// The panel shows an Open Settings button beside the text.
    public let pointsToSettings: Bool

    public init(text: String, pointsToSettings: Bool = false) {
        self.text = text
        self.pointsToSettings = pointsToSettings
    }
}

/// The panel's words.
public enum AssistantWords {
    /// Where keys and models are set, as the menu names it.
    public static let settingsPlace = "Settings (\u{2318},), under AI"

    /// The empty panel: what the assistant can do, and that it acts through the same tools and
    /// guards as `ley mcp`, so it asks before it takes a radio or deletes anything.
    public static let whatItDoes =
        "Ask in plain words: \u{201C}put on the weather radio\u{201D}, \u{201C}what\u{2019}s active on 2 m?\u{201D}, \u{201C}show me airband\u{201D}. The assistant tunes, scans, records and explains, and asks before it takes over a radio, deletes a recording or starts paid transcription."

    /// The daemon answered that it does not know the conversation: another client deleted it, or
    /// it fell out of what the daemon keeps (`docs/design/ai.md`, "The assistant").
    public static let forgotten =
        "The daemon no longer has this conversation; it was deleted. Start a new one to go on."

    /// The empty panel with no model chosen yet.
    public static let noModel =
        "The assistant needs a provider and a model. Choose them in \(settingsPlace)."

    /// The words for a call the daemon refused or never received (`docs/dev/engine-internals.md`,
    /// "Assistant"). No key, a rejected key and no model point to Settings, where each is fixed.
    public static func failed(_ action: AssistantAction, _ e: LeylineError) -> AssistantNotice {
        switch e.code {
        case "CREDENTIAL_MISSING":
            return AssistantNotice(
                text: "The assistant has no key to call with. Add one in \(settingsPlace).",
                pointsToSettings: true)
        case "CREDENTIAL_REJECTED":
            let said = e.message.isEmpty ? "" : ": \(e.message)"
            return AssistantNotice(
                text:
                    "The provider rejected the assistant\u{2019}s key\(said). Check it in \(settingsPlace).",
                pointsToSettings: true)
        case "FAILED_PRECONDITION" where action == .start:
            return AssistantNotice(text: noModel, pointsToSettings: true)
        default:
            if e.daemonUnreachable {
                return AssistantNotice(
                    text: "The daemon is not running, so the assistant could not \(action.words).")
            }
            return AssistantNotice(
                text:
                    "The assistant could not \(action.words): \(e.message.isEmpty ? e.code : e.message)"
            )
        }
    }

    /// A call's arguments on one line. A single scalar argument is its value alone (`noaa`);
    /// several are `name value` pairs in name order, joined by ` · `; a nested value is compact
    /// JSON. Text that is not a JSON object is shown with its whitespace collapsed. Cut at
    /// `summaryLimit` characters.
    public static func summary(argumentsJSON: String) -> String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let object = jsonObject(trimmed) else {
            return cut(trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        let keys = object.keys.sorted()
        if keys.count == 1, let only = object[keys[0]], let v = scalar(only) {
            return cut(v)
        }
        let pairs = keys.map { k in "\(k) \(object[k].map(inline) ?? "")" }
        return cut(pairs.joined(separator: " \u{00B7} "))
    }

    /// The closed row's summary is cut here, so a long URL or a list of bookmarks keeps the row
    /// to one line; the expanded row shows the arguments whole.
    public static let summaryLimit = 80

    /// The arguments as indented JSON with sorted keys, or the text as it came.
    public static func pretty(json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return trimmed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let out = try? encoder.encode(value), let s = String(data: out, encoding: .utf8)
        else { return trimmed }
        return s
    }

    /// The first non-empty line of a result, trimmed.
    public static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// A token count in a few characters: `400`, `1.2k`, `12k`, `3.4M`.
    public static func tokens(_ n: UInt64) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<10_000: return trimmedOne(Double(n) / 1e3) + "k"
        case ..<1_000_000: return "\((n + 500) / 1_000)k"
        default: return trimmedOne(Double(n) / 1e6) + "M"
        }
    }

    /// One decimal, without a trailing `.0`.
    private static func trimmedOne(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    static func jsonObject(_ text: String) -> [String: JSONValue]? {
        guard let data = text.data(using: .utf8),
            case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return o
    }

    /// A string, number or boolean as it reads in a sentence; nil for anything else.
    static func scalar(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .null: return "null"
        case .array, .object: return nil
        }
    }

    static func inline(_ v: JSONValue) -> String {
        if let s = scalar(v) { return s }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(v), let s = String(data: data, encoding: .utf8)
        else { return "" }
        return s
    }

    static func cut(_ s: String) -> String {
        guard s.count > summaryLimit else { return s }
        return String(s.prefix(summaryLimit - 1)) + "\u{2026}"
    }
}
