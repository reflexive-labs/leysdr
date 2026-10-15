// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/assistant"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The assistant end to end (docs/plans/ai-features.md, AI-9 and AI-10): the real daemon spawns
// the real `ley worker assistant` for each conversation, with the key on its stdin, and the real
// `ley ask` drives it. The worker plays LEY_ASSISTANT_SCRIPT, which the daemon's environment
// hands it, so the model's answers are fixed and no provider is called; the tools it calls are
// the real `ley mcp` tools against the daemon. The key is the aiRig's canary key, checked
// against an httptest provider, so a leak anywhere is found by substring.

// askRig is an aiRig whose `--ley` is the real ley, with a looping fixture as an idle radio, a
// recordings directory, and a provider endpoint the key is checked (and, unscripted, called) at.
type askRig struct {
	*aiRig
	script   string
	provider *httptest.Server
	// messagesStatus is what the provider answers POST /v1/messages with; 0 is a Messages reply.
	messagesStatus atomic.Int32
	// sawKey is set when a request to the provider carried the test's key.
	sawKey atomic.Bool
}

// newAskRig starts the daemon. scripted sets LEY_ASSISTANT_SCRIPT in the daemon's environment,
// which every worker it spawns inherits; unscripted it is empty, so the worker calls the provider.
func newAskRig(t *testing.T, scripted bool) *askRig {
	t.Helper()
	r := &askRig{}
	r.provider = httptest.NewServer(http.HandlerFunc(r.serveProvider))
	t.Cleanup(r.provider.Close)
	r.aiRig = startAskDaemon(t, scripted)
	r.script = askScriptPath(r.aiRig)

	// The check is the real `ley worker check`, against the test's provider.
	_, errOut := r.mustLey(anthropicKey+"\n", "ai", "add", "anthropic", "--endpoint", r.provider.URL)
	if !strings.Contains(errOut, "the provider accepted it") {
		t.Fatalf("ley ai add said %q", errOut)
	}
	return r
}

// startAskDaemon starts a daemon whose `--ley` is the real ley, with no key added. scripted sets
// LEY_ASSISTANT_SCRIPT to askScriptPath in its environment; unscripted it is empty.
func startAskDaemon(t *testing.T, scripted bool) *aiRig {
	t.Helper()
	leyBin := os.Getenv("LEY_BIN")
	if leyBin == "" || os.Getenv("LEYLINED_BIN") == "" {
		t.Skip("set LEYLINED_BIN and LEY_BIN to run the cross-language e2e")
	}
	dir := t.TempDir()
	ar := &aiRig{
		t: t, dir: dir, data: filepath.Join(dir, "data"), store: filepath.Join(dir, "store"),
		logFile: filepath.Join(dir, "leylined.log"), workerBin: leyBin,
	}
	if scripted {
		t.Setenv(assistant.ScriptEnv, askScriptPath(ar))
	} else {
		t.Setenv(assistant.ScriptEnv, "")
	}
	ar.daemonArgs = []string{
		"--no-hardware", "--data", ar.data, "--store", ar.store, "--ley", leyBin, "--log-file", ar.logFile,
		"--recordings", filepath.Join(dir, "recordings"),
	}
	t.Cleanup(func() {
		if t.Failed() {
			b, _ := os.ReadFile(ar.logFile)
			t.Logf("leylined log file:\n%s\nley transcript:\n%s", b, ar.transcript.String())
		}
	})
	ar.start()
	return ar
}

// askScriptPath is the file a scripted daemon's workers play.
func askScriptPath(r *aiRig) string { return filepath.Join(r.dir, "assistant-script.jsonl") }

// serveProvider is the Messages API as far as the worker and the check use it: GET /v1/models
// accepts the test's key; POST /v1/messages answers messagesStatus with Anthropic's error shape.
func (r *askRig) serveProvider(w http.ResponseWriter, req *http.Request) {
	if req.Header.Get("x-api-key") != anthropicKey {
		http.Error(w, `{"type":"error","error":{"type":"authentication_error","message":"not the test's key"}}`, http.StatusUnauthorized)
		return
	}
	r.sawKey.Store(true)
	w.Header().Set("Content-Type", "application/json")
	switch {
	case req.Method == http.MethodGet && req.URL.Path == "/v1/models":
		_, _ = w.Write([]byte(`{"data":[]}`))
	case req.Method == http.MethodPost && req.URL.Path == "/v1/messages":
		switch status := int(r.messagesStatus.Load()); status {
		case http.StatusUnauthorized:
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`))
		case http.StatusTooManyRequests:
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"type":"error","error":{"type":"rate_limit_error","message":"rate limit reached for requests"}}`))
		default:
			_, _ = w.Write([]byte(`{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}`))
		}
	default:
		http.NotFound(w, req)
	}
}

// setScript writes the responses the next conversation's worker plays: it loads the file when it
// starts, so a conversation carried on with --continue plays on through the same lines.
func (r *askRig) setScript(lines ...string) {
	r.t.Helper()
	if err := os.WriteFile(r.script, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		r.t.Fatal(err)
	}
}

// ask runs `ley ask` with stdin not a terminal, under a deadline.
func (r *askRig) ask(args ...string) (stdout, stderr string, code int) {
	r.t.Helper()
	return r.callWithin(20*time.Second, append([]string{"ask"}, args...)...)
}

// conversations is ListConversations through the Go client, newest first.
func (r *askRig) conversations() []*leylinev1.Conversation {
	r.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := leyline.Dial(ctx, r.socket, leyline.WithLabel("e2e"))
	if err != nil {
		r.t.Fatal(err)
	}
	defer c.Close()
	resp, err := c.Assistant.ListConversations(ctx, &leylinev1.ListConversationsRequest{})
	if err != nil {
		r.t.Fatalf("ListConversations: %v", err)
	}
	return resp.GetConversations()
}

// conversation is the one with id, failing the test when the daemon does not list it.
func (r *askRig) conversation(id string) *leylinev1.Conversation {
	r.t.Helper()
	for _, cv := range r.conversations() {
		if cv.GetConversationId() == id {
			return cv
		}
	}
	r.t.Fatalf("the daemon does not list conversation %s", id)
	return nil
}

// newest is the conversation the last `ley ask` started.
func (r *askRig) newest() *leylinev1.Conversation {
	r.t.Helper()
	list := r.conversations()
	if len(list) == 0 {
		r.t.Fatal("the daemon lists no conversation")
	}
	return list[0]
}

// calls is every tool call of the conversation's assistant turns, in order.
func calls(cv *leylinev1.Conversation) []*leylinev1.ToolCall {
	var out []*leylinev1.ToolCall
	for _, t := range cv.GetTurns() {
		out = append(out, t.GetTools()...)
	}
	return out
}

// oneLine is text with its line breaks and runs of spaces as single spaces, so a sentence ley
// wrapped to the terminal is matched whole.
func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

// toolLine reports whether stderr holds the start line of a call to tool, in either glyph.
func toolLine(stderr, tool string) bool {
	for _, l := range strings.Split(stderr, "\n") {
		if strings.HasPrefix(l, "→ "+tool) || strings.HasPrefix(l, "-> "+tool) {
			return true
		}
	}
	return false
}

func atoi(t *testing.T, v any) int64 {
	t.Helper()
	switch x := v.(type) {
	case string:
		n, err := strconv.ParseInt(x, 10, 64)
		if err != nil {
			t.Fatalf("not a number: %q", x)
		}
		return n
	case float64:
		return int64(x)
	case nil:
		return 0
	}
	t.Fatalf("not a number: %v", v)
	return 0
}

// assistantChannels is every channel in `ley state --json` the assistant owns, with its frequency
// (the capture's centre plus the channel's offset).
func (r *askRig) assistantChannels() map[string]int64 {
	r.t.Helper()
	st := r.state()
	centres := map[string]int64{}
	for _, c := range list(st, "captures") {
		m := c.(map[string]any)
		centres[m["captureId"].(string)] = atoi(r.t, m["centerHz"])
	}
	out := map[string]int64{}
	for _, c := range list(st, "channels") {
		m := c.(map[string]any)
		owner, _ := m["owner"].(map[string]any)
		if owner["kind"] != "mcp" || owner["label"] != "assistant" {
			continue
		}
		capID, _ := m["captureId"].(string)
		out[m["channelId"].(string)] = centres[capID] + atoi(r.t, m["offsetHz"])
	}
	return out
}

// assistantUsage is the ledger's assistant line for the conversation, or nil.
func (r *askRig) assistantUsage(convID string) *leylinev1.UsageLine {
	r.t.Helper()
	out, _ := r.mustLey("", "ai", "usage", "--json")
	resp := &leylinev1.GetUsageResponse{}
	unmarshalProto(r.t, out, resp)
	for _, l := range resp.GetLines() {
		if l.GetFeature() == "assistant" && l.GetScopeId() == convID {
			return l
		}
	}
	return nil
}

func (r *askRig) recordingURIs() []string {
	r.t.Helper()
	out, _ := r.mustLey("", "recordings", "--json")
	var uris []string
	for _, res := range list(parseJSON(r.t, out), "resources") {
		uris = append(uris, res.(map[string]any)["uri"].(string))
	}
	return uris
}

// makeRadio plays the looping tone fixture as a radio, centred on 146.52 MHz, and leaves it idle.
func (r *askRig) makeRadio() {
	r.t.Helper()
	r.mustLey("", "play", r.fixture, "--no-audio", "--loop", "--persistent", "--json")
	r.mustLey("", "stop", "all")
	deadline := time.Now().Add(5 * time.Second)
	for {
		st := r.state()
		if len(list(st, "channels")) == 0 && len(list(st, "devices")) > 0 {
			return
		}
		if time.Now().After(deadline) {
			r.t.Fatalf("the fixture never became an idle radio: %v", st)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestAskAgainstRealDaemon(t *testing.T) {
	r := newAskRig(t, true)
	r.mustLey("", "ai", "use", "assistant", "anthropic", "claude-sonnet-5-5")
	r.makeRadio()
	// A recording to not delete.
	r.mustLey("", "record", "146.52", "--for", "1s")
	r.mustLey("", "stop", "all")
	recordings := r.recordingURIs()
	if len(recordings) != 1 {
		t.Fatalf("want one recording before the assistant runs, got %v", recordings)
	}

	var tuneConv string
	t.Run("tune", func(t *testing.T) { tuneConv = checkAskTune(t, r) })
	t.Run("continue", func(t *testing.T) { checkAskContinue(t, r, tuneConv) })
	t.Run("delete asks", func(t *testing.T) { checkAskDelete(t, r, recordings) })
	t.Run("received text", func(t *testing.T) { checkAskReceivedText(t, r) })
	t.Run("stop turn and the worker's argv and environment", func(t *testing.T) { checkAskStopTurn(t, r) })

	// No conversation the daemon holds carries the key.
	for _, cv := range r.conversations() {
		if b, _ := protojson.Marshal(cv); bytes.Contains(b, []byte(aiCanary)) {
			t.Errorf("a conversation carries the key: %s", b)
		}
	}

	t.Run("restart", func(t *testing.T) {
		var before []string
		for _, cv := range r.conversations() {
			before = append(before, cv.GetConversationId())
		}
		r.restart()
		var after []string
		for _, cv := range r.conversations() {
			after = append(after, cv.GetConversationId())
		}
		if strings.Join(after, ",") != strings.Join(before, ",") {
			t.Errorf("before the restart the daemon kept %v, after it %v", before, after)
		}
		if l := r.assistantUsage(tuneConv); l == nil || l.GetRequests() < 4 {
			t.Errorf("after a restart the ledger's assistant line for %s is %v", tuneConv, l)
		}
	})
	r.assertNoCanary()
}

// checkAskTune: the assistant says something, tunes, and says how to stop it; the channel is the
// assistant's, persistent, and the ledger has the conversation's usage. It returns the
// conversation's id.
func checkAskTune(t *testing.T, r *askRig) string {
	r.setScript(
		`{"text":"Tuning to the tone.","tool":"tune","args":{"frequency":"146.52M","mode":"nfm"},"usage":{"input_tokens":20,"output_tokens":5}}`,
		`{"text":"Tuned. ley stop ends it.","usage":{"input_tokens":30,"output_tokens":7,"cache_read_input_tokens":1000}}`,
		// --continue plays on from here.
		`{"tool":"stop","args":{}}`,
		`{"text":"Stopped."}`,
	)
	out, errOut, code := r.ask("tune to 146.52", "--yes")
	if code != 0 {
		t.Fatalf("ley ask: exit %d\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	if !strings.Contains(out, "Tuning to the tone.") || !strings.Contains(out, "Tuned. ley stop ends it.") {
		t.Errorf("ley ask stdout lacks the assistant's text: %q", out)
	}
	if strings.Contains(out, "tune {") {
		t.Errorf("a tool line reached stdout: %q", out)
	}
	// The worker keeps a channel it tunes, since the conversation's connection ends with it.
	if !toolLine(errOut, `tune {"frequency":"146.52M","keep":true,"mode":"nfm"}`) {
		t.Errorf("ley ask stderr lacks the tune line: %q", errOut)
	}
	if !strings.Contains(errOut, "\n  ") || strings.Contains(errOut, "✗") {
		t.Errorf("ley ask stderr lacks the tune's result line, or shows an error: %q", errOut)
	}

	cvs := r.conversations()
	if len(cvs) != 1 {
		t.Fatalf("want one conversation, got %d", len(cvs))
	}
	cv := cvs[0]
	if cv.GetState() != leylinev1.ConversationState_CONVERSATION_IDLE || len(cv.GetTurns()) != 2 ||
		cv.GetProvider() != "anthropic" || cv.GetModel() != "claude-sonnet-5-5" {
		t.Errorf("the conversation after ley ask: %v", cv)
	}
	if cs := calls(cv); len(cs) != 1 || cs[0].GetTool() != "tune" || cs[0].GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || cs[0].GetIsError() {
		t.Errorf("the tune call: %v", cs)
	}

	// A15: the channel is attributed to the assistant, and outlives the call.
	chans := r.assistantChannels()
	if len(chans) != 1 {
		t.Fatalf("want one assistant channel, got %v", chans)
	}
	for id, hz := range chans {
		if hz != 146_520_000 {
			t.Errorf("the assistant's channel %s is at %d Hz, want 146520000", id, hz)
		}
	}

	l := r.assistantUsage(cv.GetConversationId())
	if l == nil || l.GetProvider() != "anthropic" || l.GetModel() != "claude-sonnet-5-5" || l.GetRequests() != 2 ||
		l.GetInputTokens() != 50 || l.GetOutputTokens() != 12 || l.GetCacheReadTokens() != 1000 {
		t.Errorf("the ledger's assistant line: %v", l)
	}
	return cv.GetConversationId()
}

// checkAskContinue: --continue carries on the same conversation, and its stop ends the channel.
func checkAskContinue(t *testing.T, r *askRig, convID string) {
	out, errOut, code := r.ask("--continue", "and now stop it", "--yes")
	if code != 0 || !strings.Contains(out, "Stopped.") || !toolLine(errOut, "stop") {
		t.Fatalf("ley ask --continue: exit %d\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	if !strings.Contains(errOut, "Continuing the conversation") {
		t.Errorf("ley ask --continue did not say it continues: %q", errOut)
	}
	cvs := r.conversations()
	if len(cvs) != 1 || cvs[0].GetConversationId() != convID {
		t.Fatalf("--continue did not carry on %s: %v", convID, cvs)
	}
	var ids []string
	for _, turn := range cvs[0].GetTurns() {
		ids = append(ids, turn.GetTurnId())
	}
	if strings.Join(ids, ",") != "t1,t2,t3,t4" {
		t.Errorf("turns %v, want t1..t4", ids)
	}
	if chans := r.assistantChannels(); len(chans) != 0 {
		t.Errorf("the assistant's stop left channels: %v", chans)
	}
}

// checkAskDelete: deleting a recording asks every time. Off a terminal and without --yes ask
// declines; with --yes the call runs and the daemon refuses an id it does not have. Nothing is
// deleted either way.
func checkAskDelete(t *testing.T, r *askRig, recordings []string) {
	script := []string{`{"tool":"delete_recording","args":{"recording":"job_nonexistent"}}`, `{"text":"ok"}`}
	r.setScript(script...)
	out, errOut, code := r.ask("delete it")
	if code != 0 || !strings.Contains(out, "ok") {
		t.Fatalf("ley ask (declined): exit %d\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	const declined = "Declined: stdin is not a terminal, so nobody can answer. Pass --yes to allow what the assistant asks."
	if s := oneLine(errOut); !strings.Contains(s, `The assistant wants to delete_recording {"recording":"job_nonexistent"}: `) ||
		!strings.Contains(s, declined) || !strings.Contains(s, "declined") {
		t.Errorf("ley ask stderr lacks the question and the decline: %q", errOut)
	}
	cv := r.newest()
	cs := calls(cv)
	if cv.GetState() != leylinev1.ConversationState_CONVERSATION_IDLE || len(cs) != 1 ||
		cs[0].GetState() != leylinev1.ToolCallState_TOOL_CALL_REFUSED || cs[0].GetReason() == "" {
		t.Errorf("the declined conversation: %v", cv)
	}

	r.setScript(script...)
	out, errOut, code = r.ask("delete it", "--yes", "--json")
	if code != 0 {
		t.Fatalf("ley ask --yes --json: exit %d\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	last := &leylinev1.Conversation{}
	unmarshalProto(t, lines[len(lines)-1], last)
	cs = calls(last)
	if last.GetState() != leylinev1.ConversationState_CONVERSATION_IDLE || len(cs) != 1 ||
		cs[0].GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || !cs[0].GetIsError() {
		t.Errorf("the allowed delete's last state: %s", lines[len(lines)-1])
	}
	// --json prints no prose: an allowed call is in the JSON, not on stderr.
	if errOut != "" {
		t.Errorf("ley ask --yes --json wrote on stderr: %q", errOut)
	}
	if now := r.recordingURIs(); strings.Join(now, ",") != strings.Join(recordings, ",") {
		t.Errorf("recordings were %v and are now %v", recordings, now)
	}
}

// checkAskReceivedText: once the conversation has read records, a tune asks first, with the
// received-text reason, even though a tune alone runs.
func checkAskReceivedText(t *testing.T, r *askRig) {
	r.setScript(
		`{"tool":"query_records","args":{"protocol":"aprs","limit":5}}`,
		`{"tool":"tune","args":{"frequency":"146.52M"}}`,
		`{"text":"done"}`,
	)
	out, errOut, code := r.ask("what's on aprs, then tune", "--yes")
	if code != 0 {
		t.Fatalf("ley ask: exit %d\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	if s := oneLine(errOut); !strings.Contains(s, "The assistant wants to tune") || !strings.Contains(s, "Allowed by --yes") {
		t.Errorf("ley ask stderr lacks the tune's question: %q", errOut)
	}
	cs := calls(r.newest())
	if len(cs) != 2 || cs[0].GetTool() != "query_records" || cs[1].GetTool() != "tune" {
		t.Fatalf("calls: %v", cs)
	}
	if q := cs[0]; q.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || q.GetReason() != "" ||
		strings.HasPrefix(q.GetResultText(), "Received over the air") {
		// The quoting is for the model only; a client sees the result as the tool returned it.
		t.Errorf("query_records: %v", q)
	}
	if tune := cs[1]; tune.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || tune.GetIsError() ||
		!strings.Contains(tune.GetReason(), "received over the air") {
		t.Errorf("tune after reading records: %v", tune)
	}
	r.mustLey("", "stop", "all")
}

// checkAskStopTurn: Ctrl-C during a slow response stops the turn and ask exits 0 with the
// conversation IDLE; --continue then carries it on. While the worker is on the turn, no
// assistant worker's argv or environment holds the key.
func checkAskStopTurn(t *testing.T, r *askRig) {
	r.setScript(`{"sleep_ms":5000,"text":"slow"}`)
	cmd := exec.Command(r.ley, "--socket", r.socket, "ask", "slow")
	var out, errOut syncBuffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	started := time.Now()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	defer func() {
		r.mu.Lock()
		r.transcript.WriteString("$ ley ask slow\n" + out.String() + errOut.String())
		r.mu.Unlock()
	}()

	var cv *leylinev1.Conversation
	for deadline := time.Now().Add(3 * time.Second); ; time.Sleep(50 * time.Millisecond) {
		if list := r.conversations(); len(list) > 0 && list[0].GetState() == leylinev1.ConversationState_CONVERSATION_THINKING {
			cv = list[0]
			break
		}
		if time.Now().After(deadline) {
			_ = cmd.Process.Kill()
			t.Fatalf("the conversation never started thinking\nstderr: %s", errOut.String())
		}
	}
	checkWorkersHoldNoKey(t, cv.GetConversationId())

	time.Sleep(time.Until(started.Add(500 * time.Millisecond)))
	interrupted := time.Now()
	_ = cmd.Process.Signal(syscall.SIGINT)
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("ley ask after Ctrl-C: %v\nstderr: %s", err, errOut.String())
		}
		if d := time.Since(interrupted); d > 3*time.Second {
			t.Errorf("ley ask took %v to leave after Ctrl-C", d)
		}
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatalf("ley ask did not leave after Ctrl-C\nstderr: %s", errOut.String())
	}
	cv = r.conversation(cv.GetConversationId())
	turns := cv.GetTurns()
	if cv.GetState() != leylinev1.ConversationState_CONVERSATION_IDLE || len(turns) != 2 || !turns[1].GetDone() {
		t.Errorf("the stopped conversation: %v", cv)
	}

	stdout, stderr, code := r.ask("--continue", "again", "--yes")
	if code != 0 || !strings.Contains(stdout, "done") {
		t.Fatalf("ley ask --continue after a stop: exit %d\nstdout: %s\nstderr: %s", code, stdout, stderr)
	}
	if again := r.conversation(cv.GetConversationId()); len(again.GetTurns()) != 4 || again.GetState() != leylinev1.ConversationState_CONVERSATION_IDLE {
		t.Errorf("--continue did not carry on the stopped conversation: %v", again)
	}
}

// checkWorkersHoldNoKey reads the command line and environment of every `ley worker assistant`
// running, the one on conversation convID among them, and fails on the key in either.
func checkWorkersHoldNoKey(t *testing.T, convID string) {
	t.Helper()
	procs, _ := filepath.Glob("/proc/[0-9]*/cmdline")
	found := false
	for _, p := range procs {
		cmdline, err := os.ReadFile(p)
		if err != nil || !bytes.Contains(cmdline, []byte("worker\x00assistant\x00--conversation\x00")) {
			continue
		}
		environ, err := os.ReadFile(filepath.Join(filepath.Dir(p), "environ"))
		if err != nil {
			t.Errorf("read the environment of %s: %v", filepath.Dir(p), err)
			continue
		}
		if bytes.Contains(cmdline, []byte(aiCanary)) || bytes.Contains(environ, []byte(aiCanary)) {
			t.Errorf("%s carries the key in its argv or environment", filepath.Dir(p))
		}
		if !bytes.Contains(environ, []byte("LEYLINE_KEY_ON_STDIN=1")) {
			t.Errorf("%s lacks LEYLINE_KEY_ON_STDIN=1, so this is not the environment the daemon gave it", filepath.Dir(p))
		}
		if bytes.Contains(cmdline, []byte(convID)) {
			found = true
		}
	}
	if !found {
		t.Errorf("no running ley worker assistant --conversation %s", convID)
	}
}

// The worker on the real Messages client: a provider that refuses the request fails the
// conversation with the code that says why, and ley ask exits 1 with it.
func TestAskProviderFailuresAgainstRealDaemon(t *testing.T) {
	r := newAskRig(t, false)
	for _, c := range []struct {
		status int
		code   string
	}{
		{http.StatusTooManyRequests, "PROVIDER_REFUSED"},
		{http.StatusUnauthorized, "CREDENTIAL_REJECTED"},
	} {
		r.messagesStatus.Store(int32(c.status))
		r.sawKey.Store(false)
		out, errOut, code := r.ask("--provider", "anthropic", "--model", "x", "hi")
		if code != 1 || !strings.Contains(errOut, "["+c.code+"]") {
			t.Errorf("ley ask against a %d: exit %d\nstdout: %s\nstderr: %s", c.status, code, out, errOut)
		}
		if !r.sawKey.Load() {
			t.Errorf("the worker never reached the provider with the key (status %d)", c.status)
		}
		cv := r.newest()
		if cv.GetState() != leylinev1.ConversationState_CONVERSATION_FAILED || cv.GetError().GetCode() != c.code || cv.GetModel() != "x" {
			b, _ := json.Marshal(cv.GetError())
			t.Errorf("the conversation against a %d: %v, error %s", c.status, cv.GetState(), b)
		}
	}
	r.assertNoCanary()
}

// A conversation with a tool call outlives a daemon restart: ley ask --list shows it, --continue
// carries it on in a worker started to resume it (same id, turns t1..t4), and the model's first
// call in that worker carries the turns before the restart; ley ask --delete then removes it and
// its files.
func TestAskConversationSurvivesARestart(t *testing.T) {
	record := filepath.Join(t.TempDir(), "record.jsonl")
	// Every worker the daemon starts inherits it, so the scripted model records each call.
	t.Setenv(assistant.RecordEnv, record)
	r := newAskRig(t, true)
	r.mustLey("", "ai", "use", "assistant", "anthropic", "claude-sonnet-5-5")
	r.setScript(
		`{"text":"Looking.","tool":"list_devices","args":{}}`,
		`{"text":"That is every radio."}`,
		`{"text":"Still every radio."}`,
	)
	if out, errOut, code := r.ask("what radios are there", "--yes"); code != 0 || !strings.Contains(out, "That is every radio.") {
		t.Fatalf("ley ask: exit %d\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	cv := r.newest()
	id := cv.GetConversationId()
	if len(cv.GetTurns()) != 2 || len(calls(cv)) != 1 {
		t.Fatalf("the conversation before the restart: %v", cv)
	}

	r.restart()
	list, _ := r.mustLey("", "ask", "--list")
	if !strings.Contains(list, id) || !strings.Contains(list, "what radios are there") || !strings.Contains(list, "idle") {
		t.Errorf("ley ask --list after the restart:\n%s", list)
	}
	if kept := r.conversation(id); kept.GetSeq() != cv.GetSeq() {
		t.Errorf("seq %d after the restart, %d before", kept.GetSeq(), cv.GetSeq())
	}

	out, errOut, code := r.ask("--continue", "again", "--yes")
	if code != 0 || !strings.Contains(out, "Still every radio.") || !strings.Contains(errOut, "Continuing the conversation") {
		t.Fatalf("ley ask --continue after the restart: exit %d\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	var ids []string
	for _, turn := range r.conversation(id).GetTurns() {
		ids = append(ids, turn.GetTurnId())
	}
	if strings.Join(ids, ",") != "t1,t2,t3,t4" {
		t.Errorf("turns %v, want t1..t4 in %s", ids, id)
	}

	raw, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	sent := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(sent) != 3 {
		t.Fatalf("want three model calls recorded, got %d:\n%s", len(sent), raw)
	}
	var third []assistant.Message
	if err := json.Unmarshal([]byte(sent[2]), &third); err != nil {
		t.Fatal(err)
	}
	var said []string
	for _, m := range third {
		for _, b := range m.Content {
			said = append(said, m.Role+" "+b.Type+" "+b.Text+b.Name)
		}
	}
	want := "user text what radios are there|assistant text Looking.|assistant tool_use list_devices|" +
		"user tool_result |assistant text That is every radio.|user text again"
	if strings.Join(said, "|") != want {
		t.Errorf("the third call after the restart carried\n%s\nwant\n%s", strings.Join(said, "|"), want)
	}

	dir := filepath.Join(r.data, "conversations", id)
	for _, f := range []string{"conversation.json", "transcript.jsonl"} {
		if fi, err := os.Stat(filepath.Join(dir, f)); err != nil || fi.Mode().Perm() != 0o600 {
			t.Errorf("%s: %v %v", f, fi, err)
		}
	}
	if _, errOut := r.mustLey("", "ask", "--delete", id, "--yes"); !strings.Contains(errOut, "Deleted "+id) {
		t.Errorf("ley ask --delete said %q", errOut)
	}
	if list := r.conversations(); len(list) != 0 {
		t.Errorf("listed after the delete: %v", list)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("%s is still there (%v)", dir, err)
	}
	r.assertNoCanary()
}
