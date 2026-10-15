// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/reflexive-labs/leysdr/go/internal/assistant"
)

// The first run (docs/plans/ai-features.md, AI-16): on a fresh daemon, one `ley ai add openai`
// is all the setup `ley ask` and `ley transcribe` need, with no `ley ai use` in between. The
// daemon's `--ley` is the real ley, so the key check is the real `ley worker check` against the
// OpenAI stand-in, the assistant's worker plays LEY_ASSISTANT_SCRIPT, and the bundled speech
// decoder sends each over to the same stand-in.
func TestFirstRunAgainstRealDaemon(t *testing.T) {
	leyBin, decoders := os.Getenv("LEY_BIN"), os.Getenv("LEYLINE_DECODERS")
	if leyBin == "" || os.Getenv("LEYLINED_BIN") == "" || decoders == "" {
		t.Skip("set LEYLINED_BIN, LEY_BIN and LEYLINE_DECODERS to run the cross-language e2e (make e2e does)")
	}
	fixture, err := filepath.Abs("../../../fixtures/nfm_keyed.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "assistant-script.jsonl")
	if err := os.WriteFile(script, []byte(`{"text":"Hello from the first run.","usage":{"input_tokens":3,"output_tokens":5}}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// The daemon's environment is every worker's, so the assistant plays the script.
	t.Setenv(assistant.ScriptEnv, script)

	ar := &aiRig{
		t: t, dir: dir, data: filepath.Join(dir, "data"), store: filepath.Join(dir, "store"),
		logFile: filepath.Join(dir, "leylined.log"), workerBin: leyBin,
	}
	ar.daemonArgs = []string{
		"--no-hardware", "--data", ar.data, "--store", ar.store, "--ley", leyBin, "--log-file", ar.logFile,
		"--recordings", filepath.Join(dir, "recordings"), "--decoders", decoders,
	}
	t.Cleanup(func() {
		if t.Failed() {
			b, _ := os.ReadFile(ar.logFile)
			t.Logf("leylined log file:\n%s\nley transcript:\n%s", b, ar.transcript.String())
		}
	})
	ar.start()
	r := &transcribeRig{aiRig: ar}
	r.record(fixture)
	provider := newOpenAIStandIn(t)

	_, errOut := r.mustLey(openaiKey+"\n", "ai", "add", "openai", "--endpoint", provider.URL)
	banner := "openai key ...0099 added; the provider accepted it. The assistant and speech now use openai " +
		"(gpt-5, whisper-1); change one with ley ai use <feature> <provider> [<model>]"
	if strings.TrimSpace(errOut) != banner {
		t.Errorf("ley ai add said\n%q\nwant\n%q", errOut, banner)
	}
	var features []string
	for _, f := range list(r.aiState(), "features") {
		m := f.(map[string]any)
		features = append(features, m["feature"].(string)+" "+m["provider"].(string)+" "+m["model"].(string))
	}
	if strings.Join(features, ", ") != "assistant openai gpt-5, speech openai whisper-1" {
		t.Fatalf("ley ai --json features after the add: %v", features)
	}

	out, errOut, code := r.callWithin(20*time.Second, "ask", "hi", "--yes")
	if code != 0 || !strings.Contains(out, "Hello from the first run.") {
		t.Fatalf("ley ask: exit %d\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	shown, _ := r.mustLey("", "ask", "--list", "--json")
	if !strings.Contains(shown, `"provider":"openai"`) || !strings.Contains(shown, `"model":"gpt-5"`) {
		t.Errorf("the conversation does not call openai gpt-5: %s", shown)
	}

	out, errOut, code = r.callWithin(30*time.Second, "transcribe", r.recordingID, "--yes", "--json")
	if code != 0 {
		t.Fatalf("ley transcribe: exit %d\n%s", code, errOut)
	}
	r.checkOpenAITranscript(t, provider, out)
	r.assertNoCanary()
}
