// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"fmt"
	"slices"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// The providers Leyline knows by name, the features each serves, and the model a feature gets
// when it has none (docs/dev/engine-internals.md, "Credentials and usage"). The daemon keeps the
// same table in engine/Sources/LeylineServer/AI/ProviderDefaults.swift and the app in its
// provider catalogue; TestProviderTablesAgree reads both. The model names are placeholders until
// the assistant evals and the speech spike confirm them (docs/plans/ai-features.md).

// ProviderDefault is one provider in the table: the default model of every feature it serves.
type ProviderDefault struct {
	Provider string
	Models   map[string]string // by feature
}

// ProviderDefaults is the table, in the order a hint offers the providers.
var ProviderDefaults = []ProviderDefault{
	{Provider: "openai", Models: map[string]string{"assistant": "gpt-5", "speech": "whisper-1"}},
	{Provider: "anthropic", Models: map[string]string{"assistant": "claude-sonnet-5-5"}},
}

// AIFeatures are the features a model can be chosen for, in the order `ley ai` lists them.
var AIFeatures = []string{"assistant", "speech"}

// IsAIFeature reports whether f is one of AIFeatures.
func IsAIFeature(f string) bool { return slices.Contains(AIFeatures, f) }

func providerDefault(provider string) (ProviderDefault, bool) {
	for _, p := range ProviderDefaults {
		if p.Provider == provider {
			return p, true
		}
	}
	return ProviderDefault{}, false
}

// DefaultModel is the model feature gets on provider when nobody named one; empty when the
// table has none, which is every provider it does not list.
func DefaultModel(provider, feature string) string {
	p, _ := providerDefault(provider)
	return p.Models[feature]
}

// IsKnownProvider reports whether the table lists provider.
func IsKnownProvider(provider string) bool {
	_, known := providerDefault(provider)
	return known
}

// TableFeatures are the features the table gives provider a default model for, in AIFeatures
// order; none for a provider it does not list.
func TableFeatures(provider string) []string {
	p, _ := providerDefault(provider)
	var out []string
	for _, f := range AIFeatures {
		if p.Models[f] != "" {
			out = append(out, f)
		}
	}
	return out
}

// FeatureProviders are the providers that serve feature: the table's in its order, then for
// speech every provider an installed speech decoder calls (a SEGMENTED decoder whose manifest
// names a credential provider), which serves speech on that provider's key whatever the table
// says.
func FeatureProviders(feature string, decoders []*leylinev1.DecoderManifest) []string {
	var out []string
	for _, p := range ProviderDefaults {
		if p.Models[feature] != "" {
			out = append(out, p.Provider)
		}
	}
	if feature != "speech" {
		return out
	}
	for _, m := range decoders {
		p := m.GetCredentialProvider()
		if p != "" && m.GetInput().GetMode() == leylinev1.InputMode_SEGMENTED && !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	return out
}

// FeatureRefusal is why feature cannot be set to provider, or "" when it can; the daemon's
// SetFeatureModel answers INVALID_ARGUMENT with it. key is the provider's stored key, nil when
// none is set yet. A provider the table does not list serves the assistant at an endpoint, so
// its key must name one; with no key yet the choice is allowed, as any choice is before its key.
func FeatureRefusal(feature, provider string, key *leylinev1.Credential, decoders []*leylinev1.DecoderManifest) string {
	can := FeatureProviders(feature, decoders)
	if slices.Contains(can, provider) {
		return ""
	}
	if feature == "assistant" && !IsKnownProvider(provider) {
		if key != nil && key.GetEndpoint() == "" {
			return fmt.Sprintf("%s serves the assistant only as an OpenAI-compatible server, and its key names no endpoint; "+
				"add it again with ley ai add %s --endpoint <url>", provider, provider)
		}
		return ""
	}
	if len(can) == 0 {
		return fmt.Sprintf("%s does not serve %s, and no provider does", provider, FeatureWords(feature))
	}
	verb := "does"
	if len(can) > 1 {
		verb = "do"
	}
	return fmt.Sprintf("%s does not serve %s; %s %s: ley ai use %s %s",
		provider, FeatureWords(feature), joinAnd(can), verb, feature, can[0])
}

// FeatureWords names a feature in a sentence: "the assistant", "speech".
func FeatureWords(feature string) string {
	if feature == "assistant" {
		return "the assistant"
	}
	return feature
}

// ChooseCommand is the command that gives feature a model, built from the keys that exist:
// `ley ai use <feature> <provider>` for the first provider in the table with a key and a default
// model for the feature, `ley ai use assistant <provider> <model>` for an OpenAI-compatible
// server's key, else the `ley ai add` that would make one possible.
func ChooseCommand(feature string, keys []*leylinev1.Credential) string {
	for _, p := range ProviderDefaults {
		if p.Models[feature] == "" {
			continue
		}
		for _, k := range keys {
			if k.GetProvider() == p.Provider {
				return "ley ai use " + feature + " " + p.Provider
			}
		}
	}
	if feature == "assistant" {
		for _, k := range keys {
			if !IsKnownProvider(k.GetProvider()) && k.GetEndpoint() != "" {
				return "ley ai use assistant " + k.GetProvider() + " <model>"
			}
		}
	}
	return AddCommand(feature)
}

// AddCommand is the `ley ai add` for the table's first provider that serves feature, naming the
// others in brackets: "ley ai add openai (or anthropic)".
func AddCommand(feature string) string {
	can := FeatureProviders(feature, nil)
	if len(can) == 0 {
		return "ley ai add <provider>"
	}
	cmd := "ley ai add " + can[0]
	if len(can) > 1 {
		cmd += " (or " + strings.Join(can[1:], ", or ") + ")"
	}
	return cmd
}

// MissingModelMessage is the daemon's FAILED_PRECONDITION when a feature runs with no model
// chosen, ending with the command ChooseCommand builds.
func MissingModelMessage(feature string, keys []*leylinev1.Credential) string {
	cmd := ChooseCommand(feature, keys)
	if strings.HasPrefix(cmd, "ley ai use ") {
		return fmt.Sprintf("no model is chosen for %s; choose one with %s", FeatureWords(feature), cmd)
	}
	return fmt.Sprintf("no model is chosen for %s, and no key is set for a provider that serves it; add one with %s",
		FeatureWords(feature), cmd)
}

// joinAnd lists words as a sentence does: "a", "a and b", "a, b and c".
func joinAnd(words []string) string {
	if len(words) < 2 {
		return strings.Join(words, "")
	}
	return strings.Join(words[:len(words)-1], ", ") + " and " + words[len(words)-1]
}
