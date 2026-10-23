// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"os"
	"reflect"
	"regexp"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// swiftTable reads provider-to-model literals out of a Swift source with re, whose first group
// is the provider and second the body of a [feature: model] dictionary literal.
func swiftTable(t *testing.T, path string, re *regexp.Regexp) ([]string, map[string]map[string]string) {
	t.Helper()
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	pair := regexp.MustCompile(`"([a-z]+)":\s*"([^"]+)"`)
	var order []string
	table := map[string]map[string]string{}
	for _, m := range re.FindAllStringSubmatch(string(src), -1) {
		models := map[string]string{}
		for _, p := range pair.FindAllStringSubmatch(m[2], -1) {
			models[p[1]] = p[2]
		}
		order = append(order, m[1])
		table[m[1]] = models
	}
	if len(order) == 0 {
		t.Fatalf("%s holds no table %s matches", path, re)
	}
	return order, table
}

// The default table is written three times, once per language and once in the app's catalogue,
// and read here from each source: the daemon's ProviderDefaults.table (in order, since the
// order picks the provider a hint names) and the app's catalogue, whose defaultModels must also
// be exactly the features it says the provider serves.
func TestProviderTablesAgree(t *testing.T) {
	var order []string
	want := map[string]map[string]string{}
	for _, p := range ProviderDefaults {
		order = append(order, p.Provider)
		want[p.Provider] = p.Models
	}

	daemonOrder, daemon := swiftTable(t, "../../../engine/Sources/LeylineServer/AI/ProviderDefaults.swift",
		regexp.MustCompile(`\("([a-z0-9._-]+)", \[([^\]]*)\]\),`))
	if !reflect.DeepEqual(daemonOrder, order) || !reflect.DeepEqual(daemon, want) {
		t.Errorf("the daemon's table is %v %v, ley's %v %v", daemonOrder, daemon, order, want)
	}

	_, app := swiftTable(t, "../../../app/Sources/LeylineClient/AISettings.swift",
		regexp.MustCompile(`(?s)id: "([a-z0-9._-]+)",[^)]*?defaultModels: \[([^\]]*)\]`))
	if !reflect.DeepEqual(app, want) {
		t.Errorf("the app's catalogue has %v, ley's table %v", app, want)
	}
}

func TestFeatureRefusal(t *testing.T) {
	scripted := &leylinev1.DecoderManifest{
		Name: "speechpaid", CredentialProvider: "deepgram",
		Input: &leylinev1.DecoderInput{Mode: leylinev1.InputMode_SEGMENTED},
	}
	aprs := &leylinev1.DecoderManifest{
		Name: "aprs", CredentialProvider: "mapco",
		Input: &leylinev1.DecoderInput{Mode: leylinev1.InputMode_CONTINUOUS},
	}
	cases := []struct {
		feature, provider string
		key               *leylinev1.Credential
		decoders          []*leylinev1.DecoderManifest
		want              string
	}{
		{"assistant", "openai", nil, nil, ""},
		{"speech", "openai", nil, nil, ""},
		{"assistant", "anthropic", nil, nil, ""},
		{"speech", "anthropic", nil, nil, "anthropic does not serve speech; openai does: ley ai use speech openai"},
		{"speech", "deepgram", nil, []*leylinev1.DecoderManifest{scripted}, ""},
		{
			"speech", "mapco", nil,
			[]*leylinev1.DecoderManifest{scripted, aprs},
			"mapco does not serve speech; openai and deepgram do: ley ai use speech openai",
		},
		{"assistant", "ollama", nil, nil, ""},
		{"assistant", "ollama", &leylinev1.Credential{Endpoint: "http://localhost:11434"}, nil, ""},
		{
			"assistant", "ollama", &leylinev1.Credential{}, nil,
			"ollama serves the assistant only as an OpenAI-compatible server, and its key names no endpoint; " +
				"add it again with ley ai add ollama --endpoint <url>",
		},
	}
	for _, tc := range cases {
		if got := FeatureRefusal(tc.feature, tc.provider, tc.key, tc.decoders); got != tc.want {
			t.Errorf("%s on %s: %q, want %q", tc.feature, tc.provider, got, tc.want)
		}
	}
}

func TestMissingModelMessageNamesAPasteableCommand(t *testing.T) {
	key := func(p, endpoint string) *leylinev1.Credential {
		return &leylinev1.Credential{Provider: p, Endpoint: endpoint}
	}
	cases := []struct {
		keys []*leylinev1.Credential
		want string
	}{
		{nil, "no model is chosen for the assistant, and no key is set for a provider that serves it; " +
			"add one with ley ai add openai (or anthropic)"},
		{[]*leylinev1.Credential{key("anthropic", "")}, "no model is chosen for the assistant; choose one with ley ai use assistant anthropic"},
		{
			[]*leylinev1.Credential{key("anthropic", ""), key("openai", "")},
			"no model is chosen for the assistant; choose one with ley ai use assistant openai",
		},
		{
			[]*leylinev1.Credential{key("ollama", "http://localhost:11434")},
			"no model is chosen for the assistant; choose one with ley ai use assistant ollama <model>",
		},
	}
	for _, tc := range cases {
		if got := MissingModelMessage("assistant", tc.keys); got != tc.want {
			t.Errorf("keys %v: %q, want %q", tc.keys, got, tc.want)
		}
	}
	if got := ChooseCommand("speech", []*leylinev1.Credential{key("anthropic", "")}); got != "ley ai add openai" {
		t.Errorf("speech with an anthropic key: %q", got)
	}
}
