// SPDX-License-Identifier: Apache-2.0

// Settings, AI as words: the keys the daemon holds, the provider and model each feature calls with
// what that choice sends off the Mac and to which host, and the usage ledger summed by day or
// month. Pure functions over the mirror's `ai` and `usage`, so the Linux tests read every string
// the pane prints. The rules are `docs/design/ai.md`'s: the daemon never returns a key, so a row
// shows its last four characters; usage is in the provider's units and never a price; days are
// UTC, as the providers' consoles count them (`ley ai usage`, `go/internal/cli/ai_usage.go`, sums
// the same way); and no AI control shows anywhere but Settings until a key or an on-device engine
// is set (`docs/design/ai.md`, "Context").

import Foundation
import LeylineProto

/// A provider the pane offers: a kind of endpoint, the features it can serve, the models it
/// offers, and where its calls go.
public struct AIProvider: Equatable, Sendable, Identifiable {
    /// Where a provider's calls go: a host on the internet, or nowhere off the Mac.
    public enum Reach: Equatable, Sendable {
        case cloud(host: String)
        case onDevice
    }

    /// The contract's spelling (`Credential.provider`): lower case, as `ley ai add` takes it.
    public let id: String
    public let name: String
    public let features: [String]
    /// The model each feature gets when this provider's key is added and the feature has none.
    /// The daemon sets it from its own table (`ProviderDefaults.swift`), and the pane shows the
    /// result; it is here so the catalogue cannot drift from that table unnoticed (Go's
    /// `TestProviderTablesAgree` reads both and `go/pkg/leyline/providers.go`).
    public let defaultModels: [String: String]
    /// The models the pane lists; empty means the model is typed, as `ley ai use` takes it.
    public let models: [String]
    public let reach: Reach
    /// Whether the Add form shows an endpoint field: a server that speaks the provider's API at
    /// an address of its own.
    public let takesEndpoint: Bool

    public init(
        id: String, name: String, features: [String], defaultModels: [String: String] = [:],
        models: [String], reach: Reach, takesEndpoint: Bool
    ) {
        self.id = id
        self.name = name
        self.features = features
        self.defaultModels = defaultModels
        self.models = models
        self.reach = reach
        self.takesEndpoint = takesEndpoint
    }

    public var needsKey: Bool { reach != .onDevice }
}

/// The providers the pane offers. The speech providers are chosen by measuring each candidate on
/// real receiver audio (`docs/design/ai.md`, "Providers"), and none is listed until that is done.
public enum ProviderCatalog {
    public static let anthropic = AIProvider(
        id: "anthropic", name: "Anthropic", features: ["assistant"],
        defaultModels: ["assistant": "claude-sonnet-5-5"],
        models: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
        reach: .cloud(host: "api.anthropic.com"), takesEndpoint: false)
    /// OpenAI's API, or any server that speaks it when its key is added with an endpoint (then
    /// the key reads "OpenAI-compatible", `name(_:endpoint:in:)`). Its key serves speech too,
    /// through the bundled `speech` decoder.
    public static let openAI = AIProvider(
        id: "openai", name: "OpenAI", features: ["assistant", "speech"],
        defaultModels: ["assistant": "gpt-5", "speech": "whisper-1"], models: [],
        reach: .cloud(host: "api.openai.com"), takesEndpoint: true)
    /// Providers for speech alone. None yet: a dedicated speech engine is chosen by measurement,
    /// so none is offered before it.
    public static let speech: [AIProvider] = []

    public static let all: [AIProvider] = [anthropic, openAI] + speech

    /// The features a model can be chosen for, in the order `ley ai` lists them.
    public static let features = ["assistant", "speech"]

    public static func provider(_ id: String, in providers: [AIProvider] = all) -> AIProvider? {
        providers.first { $0.id == id }
    }

    /// The name the pane gives a provider, `Anthropic` for `anthropic`, so its sentences read as
    /// its rows do; the id itself for one the catalog does not list. `ley ai` keeps the ids,
    /// which are what `ley ai add` and `ley ai use` take.
    public static func name(_ id: String, in providers: [AIProvider] = all) -> String {
        provider(id, in: providers)?.name ?? id
    }

    /// What a key added with an endpoint is called: a server of its own that speaks OpenAI's API.
    public static let openAICompatibleName = "OpenAI-compatible"

    /// The name for a key, which knows its endpoint: `openai` at an endpoint, or a provider the
    /// catalog does not list at one, is an OpenAI-compatible server (as `ley ai use` and the
    /// assistant's worker treat it), not OpenAI; any other key reads as `name(_:in:)`.
    public static func name(_ id: String, endpoint: String, in providers: [AIProvider] = all)
        -> String
    {
        guard !endpoint.isEmpty, id == openAI.id || provider(id, in: providers) == nil else {
            return name(id, in: providers)
        }
        return openAICompatibleName
    }
}

/// How the last check of a key came out, as `ley ai` words it.
public enum KeyOutcome: Equatable, Sendable {
    case accepted, rejected, unavailable, unchecked

    public init(_ check: Leyline_V1_CredentialCheck) {
        guard check.atNs != 0 else {
            self = .unchecked
            return
        }
        switch check.outcome {
        case .accepted: self = .accepted
        case .rejected: self = .rejected
        case .unavailable: self = .unavailable
        default: self = .unchecked
        }
    }

    public var word: String {
        switch self {
        case .accepted: "accepted"
        case .rejected: "rejected"
        case .unavailable: "unavailable"
        case .unchecked: "not checked"
        }
    }
}

/// One stored key as the pane lists it. It never holds the key, because the daemon never sends
/// it: `maskedKey` is the last four characters behind an ellipsis.
public struct KeyRow: Equatable, Sendable, Identifiable {
    public var id: String { provider }
    public let provider: String
    public let providerName: String
    public let label: String
    public let maskedKey: String
    public let endpoint: String
    public let added: String
    public let lastUsed: String
    public let lastChecked: String
    public let outcome: KeyOutcome
    /// The provider's words from the last check, on one line; empty when it said nothing.
    public let message: String

    public init(
        _ c: Leyline_V1_Credential, now: Date, providers: [AIProvider] = ProviderCatalog.all
    ) {
        provider = c.provider
        providerName = ProviderCatalog.name(c.provider, endpoint: c.endpoint, in: providers)
        label = c.label
        maskedKey = AISettings.maskedKey(c.lastFour)
        endpoint = c.endpoint
        added = AISettings.ago(ns: c.addedAtNs, now: now)
        lastUsed = AISettings.ago(ns: c.lastUsedAtNs, now: now)
        outcome = KeyOutcome(c.lastCheck)
        lastChecked = AISettings.ago(ns: c.lastCheck.atNs, now: now)
        message = AISettings.oneLine(c.lastCheck.message)
    }
}

/// One feature as the pane lists it: what it does, the provider and model it calls, and what
/// that choice sends off the Mac and to which host. `choices` are the providers that can serve
/// it, each with its own sentence, so a person reads what a choice sends before making it.
public struct FeatureRow: Equatable, Sendable, Identifiable {
    public var id: String { feature }
    public let feature: String
    public let title: String
    public let does: String
    /// Empty when no provider was chosen.
    public let provider: String
    public let model: String
    public let privacy: String
    /// The chosen provider needs a key and none is set; nil otherwise.
    public let missingKey: String?
    public let choices: [Choice]

    public struct Choice: Equatable, Sendable, Identifiable {
        public var id: String { provider.id }
        public let provider: AIProvider
        public let privacy: String
    }
}

/// One row of the usage table: the ledger's lines summed over scope, and over a month's days in
/// the month view.
public struct UsageRow: Equatable, Sendable, Identifiable {
    public var id: String { [period, provider, model, feature].joined(separator: "\u{0}") }
    public var period: String
    public var provider: String
    public var model: String
    public var feature: String
    public var requests: UInt64 = 0
    public var inputTokens: UInt64 = 0
    public var outputTokens: UInt64 = 0
    public var cacheReadTokens: UInt64 = 0
    public var cacheWriteTokens: UInt64 = 0
    public var audioSeconds: Double = 0

    mutating func add(_ l: Leyline_V1_UsageLine) {
        requests += l.requests
        inputTokens += l.inputTokens
        outputTokens += l.outputTokens
        cacheReadTokens += l.cacheReadTokens
        cacheWriteTokens += l.cacheWriteTokens
        audioSeconds += l.audioSeconds
    }

    mutating func add(_ r: UsageRow) {
        requests += r.requests
        inputTokens += r.inputTokens
        outputTokens += r.outputTokens
        cacheReadTokens += r.cacheReadTokens
        cacheWriteTokens += r.cacheWriteTokens
        audioSeconds += r.audioSeconds
    }
}

/// The usage table: one row per period, provider, model and feature, newest period first, and the
/// total. The periods are the ledger's UTC days, or their first seven characters for a month, so
/// the rows match the provider's console and `ley ai usage --by month`.
public struct UsageFold: Equatable, Sendable {
    public enum Period: String, CaseIterable, Sendable {
        case day, month
    }

    public let rows: [UsageRow]
    public let total: UsageRow

    /// The line under the table, `ley ai usage`'s header in the pane's words.
    public static let note =
        "Days are UTC, as the providers count them. The numbers are what the workers reported; the provider's console shows what they cost."
    /// The day view's reach, `ley ai usage`'s default.
    public static let dayViewDays = 30

    /// Folds `lines` by `period`, keeping the days on or after `sinceDay` (`yyyy-MM-dd`) when
    /// it is given.
    public init(lines: [Leyline_V1_UsageLine], by period: Period, sinceDay: String? = nil) {
        var byKey: [String: UsageRow] = [:]
        for l in lines {
            if let sinceDay, l.day < sinceDay { continue }
            let p = period == .month ? String(l.day.prefix(7)) : l.day
            let key = [p, l.provider, l.model, l.feature].joined(separator: "\u{0}")
            var row =
                byKey[key]
                ?? UsageRow(period: p, provider: l.provider, model: l.model, feature: l.feature)
            row.add(l)
            byKey[key] = row
        }
        rows = byKey.values.sorted { a, b in
            if a.period != b.period { return a.period > b.period }
            return (a.provider, a.model, a.feature) < (b.provider, b.model, b.feature)
        }
        var total = UsageRow(period: "total", provider: "", model: "", feature: "")
        for r in rows { total.add(r) }
        self.total = total
    }

    /// The first UTC day the day view shows: the day `days` days before `now` falls in, which
    /// is how `ley ai usage --since 30d` counts (`now - 30d`, whole UTC days, that day included).
    public static func sinceDay(now: Date, days: Int = dayViewDays) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        let f = DateFormatter()
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: start)
    }

    /// A numeric column of the table. Requests always shows; every other column shows only when
    /// some row has a value in it, as `ley ai usage` leaves an empty column out.
    public enum Column: CaseIterable, Sendable {
        case requests, input, output, cacheRead, cacheWrite, audio

        public var head: String {
            switch self {
            case .requests: "REQUESTS"
            case .input: "IN"
            case .output: "OUT"
            case .cacheRead: "CACHE RD"
            case .cacheWrite: "CACHE WR"
            case .audio: "AUDIO MIN"
            }
        }

        public func value(_ r: UsageRow) -> String {
            switch self {
            case .requests: UsageFold.count(r.requests)
            case .input: UsageFold.count(r.inputTokens)
            case .output: UsageFold.count(r.outputTokens)
            case .cacheRead: UsageFold.count(r.cacheReadTokens)
            case .cacheWrite: UsageFold.count(r.cacheWriteTokens)
            case .audio: UsageFold.minutes(r.audioSeconds)
            }
        }

        func has(_ r: UsageRow) -> Bool {
            switch self {
            case .requests: true
            case .input: r.inputTokens > 0
            case .output: r.outputTokens > 0
            case .cacheRead: r.cacheReadTokens > 0
            case .cacheWrite: r.cacheWriteTokens > 0
            case .audio: r.audioSeconds > 0
            }
        }
    }

    /// The numeric columns this fold's table shows.
    public var columns: [Column] {
        Column.allCases.filter { c in c == .requests || rows.contains { c.has($0) } }
    }

    /// A count as the table prints it: thousands grouped with commas, a dash for none.
    public static func count(_ n: UInt64) -> String {
        guard n > 0 else { return Reading.absent }
        var s = String(n)
        var i = s.count - 3
        while i > 0 {
            s.insert(",", at: s.index(s.startIndex, offsetBy: i))
            i -= 3
        }
        return s
    }

    /// Audio as minutes to one decimal, a dash for none.
    public static func minutes(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return Reading.absent }
        return String(format: "%.1f", seconds / 60)
    }
}

/// The pane's derived rows and words.
public enum AISettings {
    /// Whether any AI feature can run, which is when a key is set or a feature names a
    /// provider that runs on the Mac. While false, the pane shows what each feature does and the
    /// Add form only, and no other screen shows an AI control.
    public static func hasAnyAI(
        _ ai: Leyline_V1_AIState, providers: [AIProvider] = ProviderCatalog.all
    )
        -> Bool
    {
        if !ai.credentials.isEmpty { return true }
        return ai.features.contains {
            ProviderCatalog.provider($0.provider, in: providers)?.reach == .onDevice
        }
    }

    public static func keyRows(
        _ ai: Leyline_V1_AIState, now: Date, providers: [AIProvider] = ProviderCatalog.all
    ) -> [KeyRow] {
        ai.credentials.sorted { $0.provider < $1.provider }.map {
            KeyRow($0, now: now, providers: providers)
        }
    }

    /// Every feature, chosen or not, in `ley ai`'s order, so the pane shows what can be set.
    public static func featureRows(
        _ ai: Leyline_V1_AIState, providers: [AIProvider] = ProviderCatalog.all
    ) -> [FeatureRow] {
        ProviderCatalog.features.map { feature in
            let chosen = ai.features.first { $0.feature == feature }
            let provider = chosen?.provider ?? ""
            let key = ai.credentials.first { $0.provider == provider }
            let known = ProviderCatalog.provider(provider, in: providers)
            let missing =
                !provider.isEmpty && key == nil && (known?.needsKey ?? true)
                ? "No \(ProviderCatalog.name(provider, in: providers)) key is set yet; add one under Keys."
                : nil
            let choices = providers.filter { $0.features.contains(feature) }.map { p in
                let endpoint = ai.credentials.first { $0.provider == p.id }?.endpoint ?? ""
                return FeatureRow.Choice(
                    provider: p,
                    privacy: privacy(
                        feature: feature, provider: p.id, endpoint: endpoint, providers: providers)
                )
            }
            return FeatureRow(
                feature: feature, title: title(feature), does: does(feature), provider: provider,
                model: chosen?.model ?? "",
                privacy: privacy(
                    feature: feature, provider: provider, endpoint: key?.endpoint ?? "",
                    providers: providers),
                missingKey: missing, choices: choices)
        }
    }

    public static func title(_ feature: String) -> String {
        switch feature {
        case "assistant": "Assistant"
        case "speech": "Speech to text"
        default: feature
        }
    }

    /// What a feature does, in one sentence, for the person deciding whether to set it up.
    public static func does(_ feature: String) -> String {
        switch feature {
        case "assistant":
            "Runs the radio from plain requests in the Assistant panel."
        case "speech":
            "Writes down what is said on received audio, one record per over."
        default: ""
        }
    }

    /// What a feature sends to its provider, without the host.
    static func sends(_ feature: String) -> String {
        switch feature {
        case "assistant":
            "the conversation and the tool results, which include frequencies, decoded records and speech text,"
        case "speech": "squelch-open audio"
        default: "its requests"
        }
    }

    /// What a feature set to `provider` sends off the Mac and to which host
    /// (`docs/design/ai.md`, "Privacy and the law"). A key's endpoint replaces the provider's own
    /// host; a provider the catalog does not know is named rather than given a host it may not
    /// use.
    public static func privacy(
        feature: String, provider: String, endpoint: String = "",
        providers: [AIProvider] = ProviderCatalog.all
    ) -> String {
        guard !provider.isEmpty else { return "Sends nothing until a provider is chosen." }
        let known = ProviderCatalog.provider(provider, in: providers)
        if known?.reach == .onDevice { return "Runs on this Mac; nothing leaves the Mac." }
        let host: String
        if !endpoint.isEmpty {
            host = URL(string: endpoint)?.host ?? endpoint
        } else if case .cloud(let h) = known?.reach {
            host = h
        } else {
            host = "\(provider)'s servers"
        }
        return "Sends \(sends(feature)) to \(host)."
    }

    /// "…1234", or a dash when the key was too short to show any of itself.
    public static func maskedKey(_ lastFour: String) -> String {
        lastFour.isEmpty ? Reading.absent : "\u{2026}" + lastFour
    }

    /// A time before `now` in words coarse enough not to change while the pane is read: "just
    /// now" under a minute, then minutes, hours, "yesterday" and days. Zero is "never", which is
    /// how the contract says a key was never used.
    public static func ago(ns: Int64, now: Date) -> String {
        guard ns > 0 else { return "never" }
        let then = Date(timeIntervalSince1970: Double(ns) / 1e9)
        let s = now.timeIntervalSince(then)
        guard s.isFinite, s >= 60 else { return "just now" }
        let whole = Int(s)
        if whole < 3600 { return "\(whole / 60) min ago" }
        if whole < 86_400 { return "\(whole / 3600) h ago" }
        if whole < 2 * 86_400 { return "yesterday" }
        return "\(whole / 86_400) days ago"
    }

    /// A provider's message on one line, its whitespace collapsed.
    static func oneLine(_ message: String) -> String {
        message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The pane's line after Add, `ley ai add`'s in the pane's words: the key, what the provider
    /// said, and the next step when the key does not work yet.
    public static func addedWords(_ c: Leyline_V1_Credential) -> String {
        "\(keyWords(c)) added; " + outcomeWords(c)
    }

    /// The pane's line after Check.
    public static func checkedWords(_ c: Leyline_V1_Credential) -> String {
        "\(keyWords(c)): " + outcomeWords(c)
    }

    /// "Anthropic key …1234", or "Anthropic key" when no characters are shown: the provider by
    /// the name its row shows (`ProviderCatalog.name`).
    public static func keyWords(_ c: Leyline_V1_Credential) -> String {
        let key = "\(ProviderCatalog.name(c.provider, endpoint: c.endpoint)) key"
        return c.lastFour.isEmpty ? key : "\(key) \(maskedKey(c.lastFour))"
    }

    /// "Assistant now calls Anthropic claude-opus-5-5.": the line after a feature's provider or
    /// model is chosen.
    public static func nowCallsWords(_ fm: Leyline_V1_FeatureModel) -> String {
        "\(title(fm.feature)) now calls \(ProviderCatalog.name(fm.provider)) \(fm.model)."
    }

    static func outcomeWords(_ c: Leyline_V1_Credential) -> String {
        let said = oneLine(c.lastCheck.message)
        let reason = said.isEmpty ? "no reason given" : said
        switch KeyOutcome(c.lastCheck) {
        case .accepted: return "the provider accepted it."
        case .rejected: return "the provider rejected it: \(reason). Paste a working key."
        case .unavailable, .unchecked:
            return "the check could not run: \(reason). Press Check to try it again."
        }
    }
}
