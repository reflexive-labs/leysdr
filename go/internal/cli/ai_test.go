// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// aiSecret has a distinctive middle, so a leak into any output is found by substring.
const aiSecret = "sk-ant-api03-LEAKCANARY-x9Qz1234"

// runLey runs ley as a terminal of the given width would, in colour or not, with stdin holding
// the given text.
func runLey(t *testing.T, sock string, width int, color bool, stdin string, args ...string) (string, string, error) {
	t.Helper()
	var out, errb bytes.Buffer
	mode := "--color=never"
	if color {
		mode = "--color=always"
	}
	app := &App{
		Stdout: &out, Stderr: &errb, Stdin: strings.NewReader(stdin),
		IsTTY: func() bool { return true }, IsInTTY: func() bool { return false },
		TermWidth: func() int { return width }, ErrTermWidth: func() int { return width },
		LookupEnv: func(k string) (string, bool) {
			if k == "LANG" {
				return "en_US.UTF-8", true
			}
			return "", false
		},
	}
	err := Execute(t.Context(), app, append([]string{"--socket", sock, mode}, args...))
	return out.String(), errb.String(), err
}

// checkScreen renders a verb in colour and without at 40, 80 and 160 columns: no line is wider
// than the terminal, and colour adds ink and nothing else (docs/dev/cli-style.md, "Testing rules").
func checkScreen(t *testing.T, sock string, args ...string) map[int]string {
	t.Helper()
	screens := map[int]string{}
	for _, w := range []int{40, 80, 160} {
		plain, plainErr, err := runLey(t, sock, w, false, "", args...)
		if err != nil {
			t.Fatalf("ley %v at %d: %v", args, w, err)
		}
		inked, inkedErr, err := runLey(t, sock, w, true, "", args...)
		if err != nil {
			t.Fatalf("ley %v at %d in colour: %v", args, w, err)
		}
		if ui.Strip(inked) != plain || ui.Strip(inkedErr) != plainErr {
			t.Errorf("width %d: colour changed the words\nplain:\n%s%s\ninked, stripped:\n%s%s", w, plainErr, plain, ui.Strip(inkedErr), ui.Strip(inked))
		}
		if !strings.Contains(inked, "\x1b[") {
			t.Errorf("width %d: --color=always printed no ink", w)
		}
		for _, line := range strings.Split(strings.TrimRight(plainErr+plain, "\n"), "\n") {
			if ui.Visible(line) > w {
				t.Errorf("width %d: %d-column line %q", w, ui.Visible(line), line)
			}
		}
		screens[w] = plainErr + plain
	}
	return screens
}

func seedKeys(t *testing.T, c *leyline.Client) {
	t.Helper()
	ctx := t.Context()
	for _, r := range []*leylinev1.SetCredentialRequest{
		{Provider: "anthropic", Secret: aiSecret, Label: "work"},
		{Provider: "openai", Secret: fakedaemon.RejectedSecret, Endpoint: "http://localhost:11434"},
	} {
		if _, err := c.Credentials.SetCredential(ctx, r); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "assistant", Provider: "anthropic", Model: "claude-sonnet-5-5"}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Usage.ReportUsage(ctx, &leylinev1.UsageReport{Provider: "anthropic", Model: "claude-sonnet-5-5", Feature: "assistant", Requests: 1}); err != nil {
		t.Fatal(err)
	}
}

// `ley ai` lists the keys by their last four characters and the model each feature calls, fits
// every width, and never prints a key.
func TestAIList(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{})
	seedKeys(t, c)
	screens := checkScreen(t, sock, "ai")
	t.Logf("ley ai at 80 columns:\n%s", screens[80])
	wide := screens[160]
	for _, want := range []string{
		"PROVIDER", "anthropic", "work", "…1234", "accepted", "rejected", "http://localhost:11434",
		"FEATURE", "assistant  anthropic  claude-sonnet-5-5", "speech",
	} {
		if !strings.Contains(wide, want) {
			t.Errorf("160 columns lacks %q:\n%s", want, wide)
		}
	}
	for w, s := range screens {
		if strings.Contains(s, "LEAKCANARY") {
			t.Errorf("width %d printed the key:\n%s", w, s)
		}
		if !strings.Contains(s, "anthropic") || !strings.Contains(s, "…1234") {
			t.Errorf("width %d lost the provider or the key:\n%s", w, s)
		}
	}
}

// An empty daemon says how to add a key and choose a model.
func TestAIListEmpty(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{})
	out := checkScreen(t, sock, "ai")[80]
	if !strings.Contains(out, "ley ai add anthropic") || !strings.Contains(out, "ley ai use assistant") {
		t.Errorf("empty state names no next command:\n%s", out)
	}
}

// --json is the AIState the daemon holds, unstyled, and holds no key.
func TestAIJSON(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{})
	seedKeys(t, c)
	out, _, err := runLey(t, sock, 80, true, "", "--json", "ai")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "\x1b") || strings.Contains(out, "LEAKCANARY") {
		t.Fatalf("--json carries ink or the key: %q", out)
	}
	var got leylinev1.AIState
	if err := protojson.Unmarshal([]byte(out), &got); err != nil {
		t.Fatal(err)
	}
	want, err := c.Credentials.GetAIState(t.Context(), &leylinev1.GetAIStateRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(&got, want) {
		t.Errorf("ley ai --json = %v, want %v", &got, want)
	}
}

// add reads the key from stdin and reports what the provider said; a refused key is stored, so
// the exit status is 0 and the line ends with the command that fixes it.
func TestAIAdd(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name, key string
		check     fakedaemon.CheckFunc
		want      []string
	}{
		{"accepted", aiSecret + "\n", nil, []string{"anthropic key …1234 added; the provider accepted it"}},
		{"rejected", fakedaemon.RejectedSecret + "\n", nil, []string{
			"anthropic key added; the provider rejected it: invalid x-api-key. Paste a working key with: ley ai add anthropic",
		}},
		{"unavailable", "  " + aiSecret + "  \n", func(_, _, _ string) (leylinev1.CredentialCheck_Outcome, string) {
			return leylinev1.CredentialCheck_UNAVAILABLE, "api.anthropic.com could not be reached"
		}, []string{"added; the check could not run: api.anthropic.com could not be reached. Try it again with: ley ai check anthropic"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			sock, c := harness(t, fakedaemon.Options{CheckCredential: tc.check})
			out, errOut, err := runLey(t, sock, 80, false, tc.key, "ai", "add", "anthropic", "--label", "work")
			if err != nil {
				t.Fatalf("exit %d: %v", exitCode(err), err)
			}
			for _, w := range tc.want {
				if !strings.Contains(errOut, w) {
					t.Errorf("stderr %q lacks %q", errOut, w)
				}
			}
			if strings.Contains(out+errOut, "LEAKCANARY") {
				t.Errorf("the key was printed:\n%s%s", out, errOut)
			}
			st, _ := c.Credentials.GetAIState(t.Context(), &leylinev1.GetAIStateRequest{})
			if len(st.GetCredentials()) != 1 || st.GetCredentials()[0].GetLabel() != "work" {
				t.Errorf("stored: %v", st.GetCredentials())
			}
		})
	}
}

// One added key is enough to start: the daemon gives the features its provider serves their
// default models, the banner says so with the command that changes them, a choice already made
// is kept, and a rejected key sets nothing. --json is still the Credential alone.
func TestAIAddSetsTheDefaults(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{})
	_, errOut, err := runLey(t, sock, 80, false, "sk-oa-0042\n", "ai", "add", "openai")
	want := "openai key …0042 added; the provider accepted it. The assistant and speech now use openai " +
		"(gpt-5, whisper-1); change one with ley ai use <feature> <provider> [<model>]\n"
	if err != nil || errOut != want {
		t.Errorf("first key: %v\ngot  %q\nwant %q", err, errOut, want)
	}
	_, errOut, err = runLey(t, sock, 80, false, "sk-ant-0042\n", "ai", "add", "anthropic")
	if err != nil || errOut != "anthropic key …0042 added; the provider accepted it\n" {
		t.Errorf("second key, nothing left to set: %v %q", err, errOut)
	}
	st, _ := c.Credentials.GetAIState(t.Context(), &leylinev1.GetAIStateRequest{})
	got := []string{}
	for _, f := range st.GetFeatures() {
		got = append(got, f.GetFeature()+" "+f.GetProvider()+" "+f.GetModel())
	}
	if strings.Join(got, ", ") != "assistant openai gpt-5, speech openai whisper-1" {
		t.Errorf("features: %v", got)
	}

	// One feature set reads in the singular; --json prints the Credential only.
	sock, _ = harness(t, fakedaemon.Options{})
	out, errOut, err := runLey(t, sock, 80, false, "sk-ant-0042\n", "--json", "ai", "add", "anthropic")
	if err != nil || !strings.HasSuffix(errOut, ". The assistant now uses anthropic (claude-sonnet-5-5); "+
		"change it with ley ai use assistant <provider> [<model>]\n") {
		t.Errorf("anthropic first: %v %q", err, errOut)
	}
	var cred leylinev1.Credential
	if err := protojson.Unmarshal([]byte(out), &cred); err != nil || cred.GetProvider() != "anthropic" {
		t.Errorf("--json: %v %q", err, out)
	}

	sock, c = harness(t, fakedaemon.Options{})
	if _, _, err := runLey(t, sock, 80, false, fakedaemon.RejectedSecret+"\n", "ai", "add", "openai"); err != nil {
		t.Fatal(err)
	}
	if st, _ := c.Credentials.GetAIState(t.Context(), &leylinev1.GetAIStateRequest{}); len(st.GetFeatures()) != 0 {
		t.Errorf("a rejected key set %v", st.GetFeatures())
	}
}

// A key is trimmed of spaces and the newline, never taken empty, and asked for on a terminal.
func TestAIAddReadsStdin(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{})
	_, _, err := runLey(t, sock, 80, false, " \n", "ai", "add", "anthropic")
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "stdin held no key") {
		t.Errorf("empty stdin: exit %d (%v)", exitCode(err), err)
	}
	_, _, err = runLey(t, sock, 80, false, aiSecret, "ai", "add", "Anthropic")
	if exitCode(err) != ExitUsage {
		t.Errorf("capitalised provider: exit %d (%v)", exitCode(err), err)
	}
	var out, errb bytes.Buffer
	echoed := false
	app := &App{
		Stdout: &out, Stderr: &errb, Stdin: strings.NewReader(aiSecret), IsInTTY: func() bool { return true },
		echoOff: func(io.Reader) (func(), error) { return func() { echoed = true }, nil },
	}
	if err := Execute(t.Context(), app, []string{"--socket", sock, "ai", "add", "openai"}); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(errb.String(), "Paste the openai key and press Enter: \n") || !echoed {
		t.Errorf("terminal prompt: %q, echo restored %v", errb.String(), echoed)
	}
	app.Stdin = strings.NewReader("\n")
	err = Execute(t.Context(), app, []string{"--socket", sock, "ai", "add", "openai"})
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "paste the key at the prompt") {
		t.Errorf("nothing typed at the prompt: exit %d (%v)", exitCode(err), err)
	}
	// A terminal that keeps echo on is refused before the key is asked for.
	app.Stdin = strings.NewReader(aiSecret)
	app.echoOff = func(io.Reader) (func(), error) { return nil, errors.New("no termios") }
	errb.Reset()
	err = Execute(t.Context(), app, []string{"--socket", sock, "ai", "add", "openai"})
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "pbpaste | ley ai add openai") || strings.Contains(errb.String(), "Paste the") {
		t.Errorf("echo stays on: exit %d (%v), stderr %q", exitCode(err), err, errb.String())
	}
}

// Neither add nor check under --json, nor their prose, carries the key's text.
func TestAIKeyNeverPrinted(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{})
	var seen strings.Builder
	for _, args := range [][]string{
		{"--json", "ai", "add", "anthropic"},
		{"ai", "add", "anthropic"},
		{"--json", "ai", "check", "anthropic"},
		{"ai", "check", "anthropic"},
	} {
		out, errOut, err := runLey(t, sock, 80, false, aiSecret+"\n", args...)
		if err != nil {
			t.Fatalf("ley %v: %v", args, err)
		}
		seen.WriteString(out + errOut)
	}
	if strings.Contains(seen.String(), "LEAKCANARY") || !strings.Contains(seen.String(), `"lastFour":"1234"`) {
		t.Errorf("output:\n%s", seen.String())
	}
}

// check exits 0 only for a key the provider accepted.
func TestAICheck(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{})
	_, _, err := runLey(t, sock, 80, false, "", "ai", "check", "anthropic")
	if exitCode(err) != 1 || leyline.Code(err) != leyline.CodeCredentialMissing || !strings.Contains(err.Error(), "ley ai add anthropic") {
		t.Errorf("no key: exit %d (%v)", exitCode(err), err)
	}
	seedKeys(t, c)
	_, errOut, err := runLey(t, sock, 80, false, "", "ai", "check", "anthropic")
	if err != nil || !strings.Contains(errOut, "anthropic key …1234: the provider accepted it") {
		t.Errorf("accepted: %v %q", err, errOut)
	}
	_, _, err = runLey(t, sock, 80, false, "", "ai", "check", "openai")
	if exitCode(err) != 1 || err.Error() != "the provider rejected the openai key: invalid x-api-key. Paste a working key with: ley ai add openai" {
		t.Errorf("rejected: exit %d (%v)", exitCode(err), err)
	}
	out, _, err := runLey(t, sock, 80, false, "", "--json", "ai", "check", "openai")
	if exitCode(err) != 1 || !strings.Contains(out, `"outcome":"REJECTED"`) {
		t.Errorf("rejected --json: exit %d, stdout %q", exitCode(err), out)
	}
}

// A check that could not run is exit 1 with the reason and the command to try again.
func TestAICheckUnavailable(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{CheckCredential: func(_, _, _ string) (leylinev1.CredentialCheck_Outcome, string) {
		return leylinev1.CredentialCheck_UNAVAILABLE, "no worker"
	}})
	seedKeys(t, c)
	out, _, err := runLey(t, sock, 80, false, "", "--json", "ai", "check", "anthropic")
	if exitCode(err) != 1 || err.Error() != "could not check the anthropic key …1234: no worker. Run: ley ai check anthropic" {
		t.Errorf("exit %d (%v)", exitCode(err), err)
	}
	if !strings.Contains(out, `"outcome":"UNAVAILABLE"`) {
		t.Errorf("--json still prints the credential: %q", out)
	}
}

// remove deletes the key; use chooses a model and says when its provider has no key yet.
func TestAIRemoveAndUse(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{})
	seedKeys(t, c)
	if _, errOut, err := runLey(t, sock, 80, false, "", "ai", "remove", "anthropic"); err != nil || !strings.Contains(errOut, "Removed the anthropic key") {
		t.Fatalf("remove: %v %q", err, errOut)
	}
	_, _, err := runLey(t, sock, 80, false, "", "ai", "remove", "anthropic")
	if leyline.Code(err) != leyline.CodeCredentialMissing {
		t.Errorf("second remove: %v", err)
	}
	_, errOut, err := runLey(t, sock, 80, false, "", "ai", "use", "speech", "deepgram", "nova-3")
	if err != nil || !strings.Contains(errOut, "speech now calls deepgram nova-3") || !strings.Contains(errOut, "ley ai add deepgram") {
		t.Errorf("use: %v %q", err, errOut)
	}
	_, _, err = runLey(t, sock, 80, false, "", "ai", "use", "cooking", "deepgram", "nova-3")
	if exitCode(err) != ExitUsage {
		t.Errorf("unknown feature: exit %d (%v)", exitCode(err), err)
	}
	st, _ := c.Credentials.GetAIState(t.Context(), &leylinev1.GetAIStateRequest{})
	if len(st.GetCredentials()) != 1 || len(st.GetFeatures()) != 2 {
		t.Errorf("state: %v", st)
	}
}

// usageLedger is three days of calls on two providers, the last two in one month.
func usageLedger(now time.Time) []*leylinev1.UsageReport {
	day := func(n int) int64 { return now.AddDate(0, 0, -n).UnixNano() }
	return []*leylinev1.UsageReport{
		{Provider: "anthropic", Model: "claude-sonnet-5-5", Feature: "assistant", ConversationId: "conv_a", Requests: 12, InputTokens: 48_210, OutputTokens: 3_904, CacheReadTokens: 120_000, CacheWriteTokens: 9_800, AtNs: day(0)},
		{Provider: "anthropic", Model: "claude-sonnet-5-5", Feature: "assistant", ConversationId: "conv_b", Requests: 3, InputTokens: 1_000, OutputTokens: 200, AtNs: day(0)},
		{Provider: "anthropic", Model: "/v1/models", Feature: "check", Requests: 1, AtNs: day(1)},
		{Provider: "deepgram", Model: "nova-3", Feature: "speech", JobId: "job_1", Requests: 40, AudioSeconds: 1_234, AtNs: day(1)},
		{Provider: "deepgram", Model: "nova-3", Feature: "speech", JobId: "job_1", Requests: 5, AudioSeconds: 66, AtNs: day(60)},
	}
}

// usage sums the lines over scope, by day or month, with a total, a header that says what a day
// is, and every width fitted.
func TestAIUsage(t *testing.T) {
	t.Parallel()
	now := time.Now()
	sock, _ := harness(t, fakedaemon.Options{Usage: usageLedger(now)})
	screens := checkScreen(t, sock, "ai", "usage")
	t.Logf("ley ai usage at 80 columns:\n%s", screens[80])
	wide := screens[160]
	for _, want := range []string{
		"Days are UTC", "what the workers reported", "DAY", "REQUESTS", "CACHE RD", "AUDIO (min)",
		"claude-sonnet-5-5", "49,210", "20.6", "total",
	} {
		if !strings.Contains(wide, want) {
			t.Errorf("160 columns lacks %q:\n%s", want, wide)
		}
	}
	// Two conversations on one day are one row; the 60-day-old line is outside the 30 days.
	if n := strings.Count(wide, "assistant"); n != 1 {
		t.Errorf("assistant rows = %d, want 1:\n%s", n, wide)
	}
	if strings.Contains(wide, "21.7") || !strings.Contains(wide, " 56 ") {
		t.Errorf("--since 30d kept the old line or lost a row:\n%s", wide)
	}
	all, _, err := runLey(t, sock, 160, false, "", "ai", "usage", "--since", "0", "--by", "month")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(all, "MONTH") || !strings.Contains(all, "21.7") {
		t.Errorf("--since 0 --by month:\n%s", all)
	}
	if _, _, err := runLey(t, sock, 80, false, "", "ai", "usage", "--by", "week"); exitCode(err) != ExitUsage {
		t.Errorf("--by week: exit %d", exitCode(err))
	}
}

// --json is the daemon's own lines, one per scope and day, unsummed and unstyled.
func TestAIUsageJSON(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{Usage: usageLedger(time.Now())})
	out, errOut, err := runLey(t, sock, 80, true, "", "--json", "ai", "usage", "--since", "0")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "\x1b") || errOut != "" {
		t.Fatalf("--json: ink or prose: %q %q", out, errOut)
	}
	var got leylinev1.GetUsageResponse
	if err := protojson.Unmarshal([]byte(out), &got); err != nil {
		t.Fatal(err)
	}
	want, err := c.Usage.GetUsage(t.Context(), &leylinev1.GetUsageRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(&got, want) || len(got.Lines) != 5 {
		t.Errorf("--json = %v, want the fake's %v", &got, want)
	}
}

// An empty ledger keeps the headers and says what will be counted.
func TestAIUsageEmpty(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{})
	out := checkScreen(t, sock, "ai", "usage")[80]
	if !strings.Contains(out, "REQUESTS") || !strings.Contains(out, "no usage reported") {
		t.Errorf("empty ledger:\n%s", out)
	}
}

func TestGroupDigits(t *testing.T) {
	for n, want := range map[uint64]string{0: "0", 999: "999", 1000: "1,000", 1234567: "1,234,567"} {
		if got := groupDigits(n); got != want {
			t.Errorf("groupDigits(%d) = %q, want %q", n, got, want)
		}
	}
}
