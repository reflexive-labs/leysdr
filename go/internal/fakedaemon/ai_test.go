// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// testSecret has a distinctive middle so a leak is found by substring, wherever it lands.
const testSecret = "sk-ant-LEAKCANARY-7f3e1234"

// retained replays every event the daemon still holds, for a test that checks all of them.
func retained(t *testing.T, c *leyline.Client) []*leylinev1.Event {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	events, _, err := c.Events(ctx, leyline.ScopeSince(nil, 0))
	if err != nil {
		t.Fatal(err)
	}
	var out []*leylinev1.Event
	for {
		select {
		case ev, ok := <-events:
			if !ok {
				return out
			}
			out = append(out, ev)
		case <-time.After(200 * time.Millisecond):
			return out
		}
	}
}

// A key is write-only: the reply, the listing, the snapshot and every event carry its last four
// characters and nothing else of it.
func TestCredentialIsWriteOnly(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	cred, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{
		Provider: "anthropic", Secret: testSecret, Label: "home",
	})
	if err != nil {
		t.Fatal(err)
	}
	if cred.LastFour != "1234" || cred.Label != "home" || cred.AddedAtNs == 0 {
		t.Errorf("credential: %v", cred)
	}
	if got := cred.GetLastCheck().GetOutcome(); got != leylinev1.CredentialCheck_ACCEPTED {
		t.Errorf("outcome = %v, want ACCEPTED", got)
	}
	if _, err := c.Credentials.CheckCredential(ctx, &leylinev1.CredentialRef{Provider: "anthropic"}); err != nil {
		t.Fatal(err)
	}
	ai, err := c.Credentials.GetAIState(ctx, &leylinev1.GetAIStateRequest{})
	if err != nil {
		t.Fatal(err)
	}
	st, err := c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.GetAi().GetCredentials()) != 1 || !proto.Equal(st.GetAi(), ai) {
		t.Errorf("GetState.ai = %v, want the GetAIState answer %v", st.GetAi(), ai)
	}
	seen := []proto.Message{cred, ai, st}
	aiEvents := 0
	for _, ev := range retained(t, c) {
		seen = append(seen, ev)
		if ev.GetAi() != nil {
			aiEvents++
		}
	}
	if aiEvents != 3 {
		t.Errorf("%d ai events, want one for the set, one for the assistant's default model and one for the check", aiEvents)
	}
	for _, m := range seen {
		if b, _ := protojson.Marshal(m); strings.Contains(string(b), "LEAKCANARY") {
			t.Errorf("the secret left the daemon: %s", b)
		}
	}
}

// A replacement key is added now and keeps the provider's last use, which a new key for the same
// account does not reset.
func TestReplacedKeyKeepsLastUse(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	first, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: "anthropic", Secret: testSecret})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Usage.ReportUsage(ctx, &leylinev1.UsageReport{Provider: "anthropic", Model: "m", Feature: "assistant", Requests: 1, AtNs: 42}); err != nil {
		t.Fatal(err)
	}
	second, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: " anthropic ", Secret: "sk-ant-other-9876"})
	if err != nil {
		t.Fatal(err)
	}
	if second.LastUsedAtNs != 42 || second.AddedAtNs <= first.AddedAtNs || second.LastFour != "9876" {
		t.Errorf("replacement: %v", second)
	}
	if _, err := c.Credentials.CheckCredential(ctx, &leylinev1.CredentialRef{Provider: " anthropic"}); err != nil {
		t.Errorf("a padded provider name: %v", err)
	}
}

// A refused key is stored and reported, not refused: SetCredential and CheckCredential both
// return it with a REJECTED outcome and the provider's words.
func TestRejectedKey(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	cred, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: "anthropic", Secret: fakedaemon.RejectedSecret})
	if err != nil {
		t.Fatal(err)
	}
	if cred.GetLastCheck().GetOutcome() != leylinev1.CredentialCheck_REJECTED || cred.GetLastCheck().GetMessage() == "" {
		t.Errorf("last_check = %v, want REJECTED with the provider's words", cred.GetLastCheck())
	}
	if cred.LastFour != "" {
		t.Errorf("a three-character key showed %q of itself", cred.LastFour)
	}
	cred, err = c.Credentials.CheckCredential(ctx, &leylinev1.CredentialRef{Provider: "anthropic"})
	if err != nil || cred.GetLastCheck().GetOutcome() != leylinev1.CredentialCheck_REJECTED ||
		cred.GetLastCheck().GetMessage() != "invalid x-api-key" {
		t.Errorf("check: %v %v, want the credential with a REJECTED outcome", cred, err)
	}
}

// A check that could not run says nothing about the key, so it is an outcome, never an error.
func TestUnavailableCheckIsNotAnError(t *testing.T) {
	t.Parallel()
	var gotEndpoint string
	c, _ := harness(t, fakedaemon.Options{CheckCredential: func(_, _, endpoint string) (leylinev1.CredentialCheck_Outcome, string) {
		gotEndpoint = endpoint
		return leylinev1.CredentialCheck_UNAVAILABLE, "no worker"
	}})
	ctx := t.Context()
	if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{
		Provider: "openai", Secret: testSecret, Endpoint: "http://gw.local:8080",
	}); err != nil {
		t.Fatal(err)
	}
	cred, err := c.Credentials.CheckCredential(ctx, &leylinev1.CredentialRef{Provider: "openai"})
	if err != nil {
		t.Fatal(err)
	}
	if cred.GetLastCheck().GetOutcome() != leylinev1.CredentialCheck_UNAVAILABLE || gotEndpoint != "http://gw.local:8080" {
		t.Errorf("last_check = %v, endpoint %q", cred.GetLastCheck(), gotEndpoint)
	}
}

// A provider with no key is CREDENTIAL_MISSING in the daemon's sentence, for a check and a delete.
func TestMissingKey(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	_, err := c.Credentials.CheckCredential(ctx, &leylinev1.CredentialRef{Provider: "deepgram"})
	if leyline.Code(err) != leyline.CodeCredentialMissing ||
		!strings.Contains(err.Error(), "no deepgram key is set; add one with ley ai add deepgram") {
		t.Errorf("check: %v", err)
	}
	_, err = c.Credentials.DeleteCredential(ctx, &leylinev1.CredentialRef{Provider: "deepgram"})
	if leyline.Code(err) != leyline.CodeCredentialMissing {
		t.Errorf("delete: %v", err)
	}
	_, err = c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: "deepgram"})
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("empty secret: %v", err)
	}
}

// A delete is a shorter list on the event plane, and the feature models ride in the same state.
func TestDeleteAndFeatureModels(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	for _, p := range []string{"anthropic", "openai"} {
		if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: p, Secret: testSecret}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "assistant", Provider: "anthropic", Model: "claude-sonnet-5-5"}); err != nil {
		t.Fatal(err)
	}
	_, err := c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "cooking", Provider: "anthropic", Model: "m"})
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("unknown feature: %v", err)
	}
	if _, err := c.Credentials.DeleteCredential(ctx, &leylinev1.CredentialRef{Provider: "anthropic"}); err != nil {
		t.Fatal(err)
	}
	evs := retained(t, c)
	last := evs[len(evs)-1].GetAi()
	if len(last.GetCredentials()) != 1 || last.GetCredentials()[0].Provider != "openai" {
		t.Errorf("after the delete the event lists %v, want openai alone", last.GetCredentials())
	}
	// The keys set the defaults: anthropic's first, so the assistant stays on it; speech from
	// openai's. A delete leaves both choices.
	if len(last.GetFeatures()) != 2 || last.GetFeatures()[0].Model != "claude-sonnet-5-5" || last.GetFeatures()[1].Model != "whisper-1" {
		t.Errorf("features: %v", last.GetFeatures())
	}
}

// A key sets every feature its provider serves that has no provider yet, and never one chosen;
// a rejected key sets none.
func TestAKeySetsTheDefaultsAndOverwritesNoChoice(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	features := func() string {
		st, err := c.Credentials.GetAIState(ctx, &leylinev1.GetAIStateRequest{})
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, f := range st.GetFeatures() {
			out = append(out, f.GetFeature()+" "+f.GetProvider()+" "+f.GetModel())
		}
		return strings.Join(out, ", ")
	}
	set := func(provider, secret string) {
		if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: provider, Secret: secret}); err != nil {
			t.Fatal(err)
		}
	}
	set("openai", fakedaemon.RejectedSecret)
	if got := features(); got != "" {
		t.Errorf("a rejected key set %q", got)
	}
	if _, err := c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "assistant", Provider: "anthropic", Model: "claude-opus-5-5"}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{
		Provider: "openai", Secret: testSecret, Endpoint: "http://localhost:11434",
	}); err != nil {
		t.Fatal(err)
	}
	if got := features(); got != "assistant anthropic claude-opus-5-5" {
		t.Errorf("a key at an endpoint set defaults: %q", got)
	}
	set("openai", testSecret)
	if got := features(); got != "assistant anthropic claude-opus-5-5, speech openai whisper-1" {
		t.Errorf("after the openai key: %q", got)
	}
}

// A provider that cannot serve a feature is refused when it is chosen, naming those that can.
func TestAFeatureItsProviderCannotServeIsRefused(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	_, err := c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "speech", Provider: "anthropic", Model: "nova-3"})
	if leyline.Code(err) != leyline.CodeInvalidArgument || !strings.Contains(err.Error(), "anthropic does not serve speech; openai does: ley ai use speech openai") {
		t.Errorf("speech on anthropic: %v", err)
	}
	// A choice with no model names the feature's own providers.
	_, err = c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "speech", Provider: "openai"})
	if leyline.Code(err) != leyline.CodeInvalidArgument || !strings.Contains(err.Error(), "ley ai use speech openai <model>") ||
		strings.Contains(err.Error(), "anthropic") {
		t.Errorf("speech with no model: %v", err)
	}
	// A speech decoder installed for a provider makes it a speech provider.
	c, _ = harness(t, fakedaemon.Options{SpeechProvider: "deepgram"})
	if _, err := c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "speech", Provider: "deepgram", Model: "nova-3"}); err != nil {
		t.Errorf("speech on the installed decoder's provider: %v", err)
	}
	if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: "ollama", Secret: testSecret}); err != nil {
		t.Fatal(err)
	}
	_, err = c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "assistant", Provider: "ollama", Model: "llama3"})
	if leyline.Code(err) != leyline.CodeInvalidArgument || !strings.Contains(err.Error(), "ley ai add ollama --endpoint <url>") {
		t.Errorf("an unknown provider's key with no endpoint: %v", err)
	}
}

// Reports fold by provider, model, feature, scope and UTC day; each one sends the whole line and
// marks the key used; GetUsage filters, and a seeded ledger is there from the start.
func TestUsageLedger(t *testing.T) {
	t.Parallel()
	day1 := time.Date(2026, 10, 13, 23, 30, 0, 0, time.UTC).UnixNano()
	day2 := time.Date(2026, 10, 14, 0, 30, 0, 0, time.UTC).UnixNano()
	c, _ := harness(t, fakedaemon.Options{Usage: []*leylinev1.UsageReport{
		{Provider: "deepgram", Model: "nova-3", Feature: "speech", JobId: "job_1", Requests: 1, AudioSeconds: 90, AtNs: day1},
	}})
	ctx := t.Context()
	if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: "anthropic", Secret: testSecret}); err != nil {
		t.Fatal(err)
	}
	for _, r := range []*leylinev1.UsageReport{
		{Provider: "anthropic", Model: "claude-sonnet-5-5", Feature: "assistant", ConversationId: "conv_1", Requests: 1, InputTokens: 100, OutputTokens: 10, AtNs: day1},
		{Provider: "anthropic", Model: "claude-sonnet-5-5", Feature: "assistant", ConversationId: "conv_1", Requests: 1, InputTokens: 50, CacheReadTokens: 7, AtNs: day1 + 1},
		{Provider: "anthropic", Model: "claude-sonnet-5-5", Feature: "assistant", ConversationId: "conv_1", Requests: 1, InputTokens: 1, AtNs: day2},
	} {
		if _, err := c.Usage.ReportUsage(ctx, r); err != nil {
			t.Fatal(err)
		}
	}
	_, err := c.Usage.ReportUsage(ctx, &leylinev1.UsageReport{Provider: "anthropic", Model: "m", Feature: "cooking"})
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("unknown feature: %v", err)
	}
	all, err := c.Usage.GetUsage(ctx, &leylinev1.GetUsageRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if len(all.Lines) != 3 {
		t.Fatalf("lines: %v", all.Lines)
	}
	first := all.Lines[0] // day 1 sorts anthropic before deepgram
	if first.Day != "2026-10-13" || first.Requests != 2 || first.InputTokens != 150 || first.CacheReadTokens != 7 || first.ScopeId != "conv_1" {
		t.Errorf("folded line: %v", first)
	}
	if all.Lines[1].Provider != "deepgram" || all.Lines[2].Day != "2026-10-14" {
		t.Errorf("order: %v", all.Lines)
	}
	since, _ := c.Usage.GetUsage(ctx, &leylinev1.GetUsageRequest{SinceNs: day2})
	byFeature, _ := c.Usage.GetUsage(ctx, &leylinev1.GetUsageRequest{Feature: "speech"})
	byScope, _ := c.Usage.GetUsage(ctx, &leylinev1.GetUsageRequest{ScopeId: "job_1", Provider: "deepgram"})
	if len(since.GetLines()) != 1 || len(byFeature.GetLines()) != 1 || len(byScope.GetLines()) != 1 {
		t.Errorf("filters: since %d, feature %d, scope %d lines", len(since.GetLines()), len(byFeature.GetLines()), len(byScope.GetLines()))
	}
	st, err := c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Usage) != 3 || st.GetAi().GetCredentials()[0].LastUsedAtNs != day2 {
		t.Errorf("state: %d usage lines, last used %d", len(st.Usage), st.GetAi().GetCredentials()[0].LastUsedAtNs)
	}
	var usageEvents []*leylinev1.UsageLine
	for _, ev := range retained(t, c) {
		if u := ev.GetUsage(); u != nil {
			usageEvents = append(usageEvents, u)
		}
	}
	if len(usageEvents) != 3 || usageEvents[1].Requests != 2 {
		t.Errorf("usage events carry the whole line: %v", usageEvents)
	}
}
