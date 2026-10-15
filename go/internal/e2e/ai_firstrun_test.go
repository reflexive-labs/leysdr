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

// The first run (docs/plans/ai-features.md): on a fresh daemon, one `ley ai add openai` is all
// the setup `ley ask` and `ley transcribe` need, with no `ley ai use` in between. The defaults
// come only from a key with no endpoint, the provider's own API, which a hermetic test cannot
// call: the daemon's `--ley` is a wrapper that answers the check of such a key itself and runs
// the real ley for everything else, so the assistant's worker is the real one playing
// LEY_ASSISTANT_SCRIPT. To transcribe, the same key is added again at the OpenAI stand-in, which
// sets nothing and keeps the choices the first add made; the real `ley worker check` then tries
// it there, and the bundled speech decoder sends each over to it.
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
	wrapper := filepath.Join(dir, "ley")
	if err := os.WriteFile(wrapper, []byte(`#!/bin/sh
if [ "$1" = worker ] && [ "$2" = check ]; then
  case " $* " in
    *" --endpoint "*) ;;
    *) read -r key
       if [ "$key" = "`+openaiKey+`" ]; then echo '{"outcome":"accepted","message":""}'
       else echo '{"outcome":"rejected","message":"not the test key"}'; fi
       exit 0 ;;
  esac
fi
exec "`+leyBin+`" "$@"
`), 0o755); err != nil {
		t.Fatal(err)
	}

	ar := &aiRig{
		t: t, dir: dir, data: filepath.Join(dir, "data"), store: filepath.Join(dir, "store"),
		logFile: filepath.Join(dir, "leylined.log"), workerBin: wrapper,
	}
	ar.daemonArgs = []string{
		"--no-hardware", "--data", ar.data, "--store", ar.store, "--ley", wrapper, "--log-file", ar.logFile,
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
	const both = "assistant openai gpt-5, speech openai whisper-1"

	_, errOut := r.mustLey(openaiKey+"\n", "ai", "add", "openai")
	banner := "openai key ...0099 added; the provider accepted it. The assistant and speech now use openai " +
		"(gpt-5, whisper-1); change one with ley ai use <feature> <provider> [<model>]"
	if strings.TrimSpace(errOut) != banner {
		t.Errorf("ley ai add said\n%q\nwant\n%q", errOut, banner)
	}
	if got := r.features(); got != both {
		t.Fatalf("ley ai --json features after the add: %q", got)
	}

	out, errOut, code := r.callWithin(20*time.Second, "ask", "hi", "--yes")
	if code != 0 || !strings.Contains(out, "Hello from the first run.") {
		t.Fatalf("ley ask: exit %d\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	shown, _ := r.mustLey("", "ask", "--list", "--json")
	if !strings.Contains(shown, `"provider":"openai"`) || !strings.Contains(shown, `"model":"gpt-5"`) {
		t.Errorf("the conversation does not call openai gpt-5: %s", shown)
	}

	provider := newOpenAIStandIn(t)
	_, errOut = r.mustLey(openaiKey+"\n", "ai", "add", "openai", "--endpoint", provider.URL)
	banner = "openai key ...0099 added; the provider accepted it. It names an endpoint, so no model was set; " +
		"choose the server's with ley ai use assistant openai <model>"
	if strings.TrimSpace(errOut) != banner {
		t.Errorf("ley ai add --endpoint said\n%q\nwant\n%q", errOut, banner)
	}
	if got := r.features(); got != both {
		t.Fatalf("a key at an endpoint changed the features: %q", got)
	}

	out, errOut, code = r.callWithin(30*time.Second, "transcribe", r.recordingID, "--yes", "--json")
	if code != 0 {
		t.Fatalf("ley transcribe: exit %d\n%s", code, errOut)
	}
	r.checkOpenAITranscript(t, provider, out)
	r.assertNoCanary()
}

// features is `ley ai --json`'s feature models as "feature provider model", comma-separated.
func (r *aiRig) features() string {
	var out []string
	for _, f := range list(r.aiState(), "features") {
		m := f.(map[string]any)
		out = append(out, m["feature"].(string)+" "+m["provider"].(string)+" "+m["model"].(string))
	}
	return strings.Join(out, ", ")
}
