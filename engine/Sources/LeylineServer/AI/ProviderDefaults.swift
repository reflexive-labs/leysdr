// SPDX-License-Identifier: GPL-3.0-or-later

// The providers Leyline knows by name, the features each serves, and the model a feature gets
// when it has none (docs/dev/engine-internals.md, "Credentials and usage"). `ley` and the fake
// daemon keep the same table in go/pkg/leyline/providers.go, and the app in its provider
// catalogue; Go's TestProviderTablesAgree reads this file as text, so `table` stays one literal
// with one provider per line. The model names are placeholders until the AI-12 run and the
// speech spike confirm them (docs/plans/ai-features.md, AI-16).

import LeylineProto

enum ProviderDefaults {
    /// Each provider's default model by feature, in the order a hint offers the providers.
    static let table: [(provider: String, models: [String: String])] = [
        ("openai", ["assistant": "gpt-5", "speech": "whisper-1"]),
        ("anthropic", ["assistant": "claude-sonnet-5-5"]),
    ]

    /// The features a model can be chosen for, in the order `ley ai` lists them.
    static let features = ["assistant", "speech"]

    static func isKnown(_ provider: String) -> Bool {
        table.contains { $0.provider == provider }
    }

    /// The model `feature` gets on `provider` when nobody named one; nil when the table has none.
    static func defaultModel(_ provider: String, _ feature: String) -> String? {
        table.first { $0.provider == provider }?.models[feature]
    }

    /// The features the table says `provider` serves, in `features` order. A provider the table
    /// does not list gets no defaults, so it has none here.
    static func tableFeatures(_ provider: String) -> [String] {
        guard let models = table.first(where: { $0.provider == provider })?.models else { return [] }
        return features.filter { models[$0] != nil }
    }

    /// The providers that serve `feature`: the table's in its order, then for speech every
    /// provider an installed speech decoder calls (a SEGMENTED decoder whose manifest names a
    /// credential provider), which serves speech on that provider's key whatever the table says.
    static func providers(for feature: String, decoders: [Leyline_V1_DecoderManifest]) -> [String] {
        var out = table.filter { $0.models[feature] != nil }.map(\.provider)
        guard feature == "speech" else { return out }
        for m in decoders where !m.credentialProvider.isEmpty && m.input.mode == .segmented {
            if !out.contains(m.credentialProvider) { out.append(m.credentialProvider) }
        }
        return out
    }

    /// Why `feature` cannot be set to `provider`, or nil when it can. `key` is the provider's
    /// stored key, nil when none is set yet. A provider the table does not list serves the
    /// assistant as an OpenAI-compatible server, so its key must name an endpoint; with no key
    /// yet the choice is allowed, as any choice is before its key.
    static func refusal(feature: String, provider: String, key: Leyline_V1_Credential?,
                        decoders: [Leyline_V1_DecoderManifest]) -> String?
    {
        let can = providers(for: feature, decoders: decoders)
        if can.contains(provider) { return nil }
        if feature == "assistant", !isKnown(provider) {
            guard let key, key.endpoint.isEmpty else { return nil }
            return "\(provider) serves the assistant only as an OpenAI-compatible server, and its key names no endpoint; "
                + "add it again with ley ai add \(provider) --endpoint <url>"
        }
        guard let first = can.first else {
            return "\(provider) does not serve \(words(feature)), and no provider does"
        }
        let verb = can.count > 1 ? "do" : "does"
        return "\(provider) does not serve \(words(feature)); \(joinAnd(can)) \(verb): ley ai use \(feature) \(first)"
    }

    /// A feature in a sentence: "the assistant", "speech".
    static func words(_ feature: String) -> String {
        feature == "assistant" ? "the assistant" : feature
    }

    /// The command that gives `feature` a model, built from the keys that exist: `ley ai use
    /// <feature> <provider>` for the first provider in the table with a key and a default model
    /// for the feature, `ley ai use assistant <provider> <model>` for an OpenAI-compatible
    /// server's key, else the `ley ai add` that would make one possible.
    static func chooseCommand(_ feature: String, keys: [Leyline_V1_Credential]) -> String {
        for entry in table where entry.models[feature] != nil {
            if keys.contains(where: { $0.provider == entry.provider }) {
                return "ley ai use \(feature) \(entry.provider)"
            }
        }
        if feature == "assistant",
           let server = keys.first(where: { !isKnown($0.provider) && !$0.endpoint.isEmpty })
        {
            return "ley ai use assistant \(server.provider) <model>"
        }
        return addCommand(feature)
    }

    /// The `ley ai add` for the table's first provider that serves `feature`, naming the others in
    /// brackets: "ley ai add openai (or anthropic)".
    static func addCommand(_ feature: String) -> String {
        let can = providers(for: feature, decoders: [])
        guard let first = can.first else { return "ley ai add <provider>" }
        let others = can.dropFirst()
        return "ley ai add \(first)" + (others.isEmpty ? "" : " (or " + others.joined(separator: ", or ") + ")")
    }

    /// The FAILED_PRECONDITION a feature run with no model chosen gets, ending with the command
    /// `chooseCommand` builds.
    static func missingModelMessage(_ feature: String, keys: [Leyline_V1_Credential]) -> String {
        let command = chooseCommand(feature, keys: keys)
        if command.hasPrefix("ley ai use ") {
            return "no model is chosen for \(words(feature)); choose one with \(command)"
        }
        return "no model is chosen for \(words(feature)), and no key is set for a provider that serves it; add one with \(command)"
    }

    /// Words as a sentence lists them: "a", "a and b", "a, b and c".
    private static func joinAnd(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.joined() }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
