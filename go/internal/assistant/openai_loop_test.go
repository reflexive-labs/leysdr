// SPDX-License-Identifier: Apache-2.0

package assistant_test

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

const chatKey = "sk-proj-loop-SECRET-4242"

// chatLine is one line of a harness script, as the chat endpoint plays it. raw_args sends a
// call's arguments as written, so a test can play arguments that are not JSON.
type chatLine struct {
	Text       string          `json:"text"`
	Tool       string          `json:"tool"`
	Args       json.RawMessage `json:"args"`
	RawArgs    *string         `json:"raw_args"`
	SleepMs    int             `json:"sleep_ms"`
	StopReason string          `json:"stop_reason"`
	Usage      *struct {
		InputTokens  uint64 `json:"input_tokens"`
		OutputTokens uint64 `json:"output_tokens"`
		CacheRead    uint64 `json:"cache_read_input_tokens"`
	} `json:"usage"`
}

// chatRequest is what the endpoint reads of a request.
type chatRequest struct {
	Model    string `json:"model"`
	Messages []struct {
		Role       string  `json:"role"`
		Content    *string `json:"content"`
		ToolCallID string  `json:"tool_call_id"`
		ToolCalls  []struct {
			ID       string `json:"id"`
			Function struct {
				Name      string `json:"name"`
				Arguments string `json:"arguments"`
			} `json:"function"`
		} `json:"tool_calls"`
	} `json:"messages"`
}

// chatScript is a chat completions endpoint that plays a harness script, one line per request,
// as the Scripted model plays it in process ("done" once the lines run out), so a loop test runs
// through the OpenAI model unchanged. It checks every request as the API would: the system prompt
// first, and every tool call answered by a tool message, in the order the calls were made, before
// anything else.
type chatScript struct {
	t     *testing.T
	srv   *httptest.Server
	mu    sync.Mutex
	lines []chatLine
	next  int
	sent  []chatRequest
	raw   []string
}

func newChatScript(t *testing.T, script []string) *chatScript {
	t.Helper()
	c := &chatScript{t: t}
	for _, l := range script {
		var cl chatLine
		if err := json.Unmarshal([]byte(l), &cl); err != nil {
			t.Fatalf("script line %s: %v", l, err)
		}
		c.lines = append(c.lines, cl)
	}
	c.srv = httptest.NewServer(http.HandlerFunc(c.serve))
	t.Cleanup(c.srv.Close)
	return c
}

func (c *chatScript) URL() string { return c.srv.URL + "/v1" }

// requests is what the endpoint was sent, in order.
func (c *chatScript) requests() ([]chatRequest, []string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]chatRequest(nil), c.sent...), append([]string(nil), c.raw...)
}

func (c *chatScript) serve(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	var req chatRequest
	if err := json.Unmarshal(raw, &req); err != nil || r.URL.Path != "/v1/chat/completions" {
		c.t.Errorf("a request to %s the endpoint cannot read: %v", r.URL.Path, err)
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if problem := checkChat(req); problem != "" {
		c.t.Errorf("the API would refuse this request: %s\n%s", problem, raw)
	}
	c.mu.Lock()
	c.sent, c.raw = append(c.sent, req), append(c.raw, string(raw))
	l := chatLine{Text: "done"}
	n := c.next
	if n < len(c.lines) {
		l = c.lines[n]
	}
	c.next++
	c.mu.Unlock()
	if l.SleepMs > 0 {
		select {
		case <-r.Context().Done():
			return
		case <-time.After(time.Duration(l.SleepMs) * time.Millisecond):
		}
	}
	_, _ = w.Write(chatReply(l, n))
}

// checkChat is what the chat API refuses in a request.
func checkChat(req chatRequest) string {
	if len(req.Messages) == 0 || req.Messages[0].Role != "system" {
		return "the system prompt is not first"
	}
	var pending []string
	for i, m := range req.Messages[1:] {
		if m.Role == "tool" {
			if len(pending) == 0 || m.ToolCallID != pending[0] {
				return fmt.Sprintf("message %d answers %q, and the next call waiting is %v", i+1, m.ToolCallID, pending)
			}
			pending = pending[1:]
			continue
		}
		if len(pending) > 0 {
			return fmt.Sprintf("message %d (%s) comes before the calls %v are answered", i+1, m.Role, pending)
		}
		for _, call := range m.ToolCalls {
			pending = append(pending, call.ID)
		}
	}
	if len(pending) > 0 {
		return fmt.Sprintf("the calls %v are never answered", pending)
	}
	return ""
}

// chatReply is a script line as a chat completions response.
func chatReply(l chatLine, n int) []byte {
	msg := map[string]any{"role": "assistant", "content": nil}
	if l.Text != "" {
		msg["content"] = l.Text
	}
	finish := "stop"
	if l.Tool != "" {
		args := string(l.Args)
		if l.RawArgs != nil {
			args = *l.RawArgs
		} else if args == "" || args == "null" {
			args = "{}"
		}
		msg["tool_calls"] = []any{map[string]any{"id": fmt.Sprintf("call_s%d", n+1), "type": "function", "function": map[string]any{"name": l.Tool, "arguments": args}}}
		finish = "tool_calls"
	}
	switch l.StopReason {
	case "":
	case "max_tokens":
		finish = "length"
	case "refusal":
		finish = "content_filter"
	default:
		finish = l.StopReason
	}
	usage := map[string]any{"prompt_tokens": 0, "completion_tokens": 0}
	if u := l.Usage; u != nil {
		usage = map[string]any{
			"prompt_tokens": u.InputTokens + u.CacheRead, "completion_tokens": u.OutputTokens,
			"prompt_tokens_details": map[string]any{"cached_tokens": u.CacheRead},
		}
	}
	out, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"message": msg, "finish_reason": finish}}, "usage": usage})
	return out
}

// The worker on the OpenAI model: the key arrives on stdin and goes out in the bearer header
// only; parallel calls run one at a time in the order given and their results go back as tool
// messages in that order; a rejected key fails the conversation in the provider's words with the
// key cut out, and the key is never on the worker's stdout or stderr.
func TestOpenAIThroughTheLoop(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	var bodies []string
	step := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		defer mu.Unlock()
		bodies = append(bodies, string(body))
		if r.Header.Get("Authorization") != "Bearer "+chatKey {
			t.Errorf("Authorization %q", r.Header.Get("Authorization"))
		}
		step++
		switch step {
		case 1:
			_, _ = io.WriteString(w, `{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":"Checking.","tool_calls":[
				{"id":"call_1","type":"function","function":{"name":"list_devices","arguments":"{}"}},
				{"id":"call_2","type":"function","function":{"name":"get_state","arguments":"{}"}}]}}],
				"usage":{"prompt_tokens":10,"completion_tokens":5}}`)
		case 2:
			_, _ = io.WriteString(w, `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"One radio, idle."}}],"usage":{"prompt_tokens":12,"completion_tokens":4}}`)
		default:
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(w, `{"error":{"message":"Incorrect API key provided: `+chatKey+`","type":"invalid_request_error","code":"invalid_api_key"}}`)
		}
	}))
	t.Cleanup(api.Close)

	w := startWorker(t, workerConfig{provider: "openai", endpoint: api.URL, key: chatKey})
	w.say("t1", "what radios are there?")
	turn := w.doneTurn()
	if turn.GetText() != "Checking.\n\nOne radio, idle." || len(turn.GetTools()) != 2 || turn.GetTools()[0].GetTool() != "list_devices" || turn.GetTools()[1].GetTool() != "get_state" {
		t.Errorf("turn: %v", turn)
	}

	mu.Lock()
	var second chatRequest
	if err := json.Unmarshal([]byte(bodies[1]), &second); err != nil {
		t.Fatal(err)
	}
	mu.Unlock()
	if problem := checkChat(second); problem != "" {
		t.Error(problem)
	}
	n := len(second.Messages)
	first, last := second.Messages[n-2], second.Messages[n-1]
	if first.Role != "tool" || first.ToolCallID != "call_1" || !strings.Contains(*first.Content, "devices") || last.Role != "tool" || last.ToolCallID != "call_2" {
		t.Errorf("the results: %+v %+v", first, last)
	}

	w.say("t2", "again")
	var failure *leylinev1.WorkerFailure
	for failure == nil {
		failure = w.next().GetFailure()
	}
	if failure.GetError().GetCode() != leyline.CodeCredentialRejected || !strings.Contains(failure.GetError().GetMessage(), "Incorrect API key provided: …") {
		t.Errorf("failure: %v", failure.GetError())
	}
	if err := <-w.done; err == nil {
		t.Error("the worker exited 0 after a failure")
	}
	w.done <- nil // for the cleanup
	for where, text := range map[string]string{"stdout": w.raw.String(), "stderr": w.stderr.String()} {
		if strings.Contains(text, chatKey) {
			t.Errorf("the key is on the worker's %s", where)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	for _, b := range bodies {
		if strings.Contains(b, chatKey) {
			t.Error("the key is in a request body")
		}
	}
}

// openai with no model runs the default, and the ledger names it; the usage is split as the
// Messages API reports it, the cached tokens apart from the input.
func TestOpenAIDefaultModel(t *testing.T) {
	t.Parallel()
	usage := map[string]any{"input_tokens": 100, "output_tokens": 10, "cache_read_input_tokens": 4000}
	w := startWorker(t, workerConfig{via: "openai", noModel: true, script: []string{line(map[string]any{"text": "ok", "usage": usage})}})
	w.say("t1", "hello")
	if turn := w.doneTurn(); turn.GetText() != "ok" {
		t.Errorf("turn: %v", turn)
	}
	got, err := w.client.Usage.GetUsage(t.Context(), &leylinev1.GetUsageRequest{ScopeId: convID})
	if err != nil || len(got.GetLines()) != 1 {
		t.Fatalf("ledger: %v %v", got, err)
	}
	l := got.GetLines()[0]
	if l.GetProvider() != "openai" || l.GetModel() != "gpt-5" || l.GetInputTokens() != 100 || l.GetCacheReadTokens() != 4000 || l.GetOutputTokens() != 10 || l.GetCacheWriteTokens() != 0 {
		t.Errorf("ledger line: %v", l)
	}
}

// Any provider whose key names an endpoint runs on the OpenAI model, under its own name on the
// ledger; with no model it fails saying how to choose one, since only openai has a default.
func TestOpenAICompatibleProvider(t *testing.T) {
	t.Parallel()
	t.Run("with a model", func(t *testing.T) {
		t.Parallel()
		w := startWorker(t, workerConfig{via: "openai", provider: "ollama", script: []string{line(map[string]any{"text": "local"})}})
		w.say("t1", "hello")
		if turn := w.doneTurn(); turn.GetText() != "local" {
			t.Errorf("turn: %v", turn)
		}
		got, err := w.client.Usage.GetUsage(t.Context(), &leylinev1.GetUsageRequest{ScopeId: convID})
		if err != nil || len(got.GetLines()) != 1 || got.GetLines()[0].GetProvider() != "ollama" || got.GetLines()[0].GetModel() != "claude-test" {
			t.Errorf("ledger: %v %v", got, err)
		}
	})
	t.Run("without one", func(t *testing.T) {
		t.Parallel()
		w := startWorker(t, workerConfig{provider: "ollama", endpoint: "http://127.0.0.1:9/v1", key: "k", noModel: true})
		m := w.next()
		if e := m.GetFailure().GetError(); e.GetCode() != leyline.CodeFailedPrecondition || !strings.Contains(e.GetMessage(), "ley ai use assistant ollama <model>") {
			t.Errorf("got %v", m)
		}
		<-w.done
		w.done <- nil
	})
	t.Run("without a key", func(t *testing.T) {
		t.Parallel()
		w := startWorker(t, workerConfig{provider: "openai"})
		m := w.next()
		if e := m.GetFailure().GetError(); e.GetCode() != leyline.CodeCredentialMissing || !strings.Contains(e.GetMessage(), "ley ai add openai") {
			t.Errorf("got %v", m)
		}
		<-w.done
		w.done <- nil
	})
	t.Run("in the clear", func(t *testing.T) {
		t.Parallel()
		w := startWorker(t, workerConfig{provider: "ollama", endpoint: "http://gateway.example/v1", key: "k"})
		m := w.next()
		if e := m.GetFailure().GetError(); e.GetCode() != leyline.CodeProviderUnavailable || !strings.Contains(e.GetMessage(), "must be https") {
			t.Errorf("got %v", m)
		}
		<-w.done
		w.done <- nil
	})
}

// A call whose arguments are not a JSON object is refused without running, the model is told so
// against the call's id, and its arguments go back to the API as the model wrote them.
func TestOpenAIArgumentsThatAreNotAnObject(t *testing.T) {
	t.Parallel()
	bad := "frequency=146.52"
	chat := newChatScript(t, []string{
		line(map[string]any{"tool": "tune", "raw_args": bad}),
		line(map[string]any{"text": "Sorry."}),
	})
	w := startWorker(t, workerConfig{via: "openai", chat: chat})
	w.say("t1", "tune the calling frequency")
	turn := w.doneTurn()
	call := lastCall(turn)
	if call.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || !call.GetIsError() || call.GetResultText() != "the arguments are not a JSON object" || call.GetArgumentsJson() != `"`+bad+`"` {
		t.Errorf("the call: %v", call)
	}
	if len(w.state().GetChannels()) != 0 {
		t.Error("the call ran")
	}
	sent, _ := chat.requests()
	msgs := sent[1].Messages
	echoed, result := msgs[len(msgs)-2], msgs[len(msgs)-1]
	if echoed.ToolCalls[0].Function.Arguments != bad || result.ToolCallID != "call_s1" || *result.Content != "error: the arguments are not a JSON object" {
		t.Errorf("sent back: %+v then %+v", echoed, result)
	}
}

// A transcript written by a worker on the OpenAI model resumes on it: the resumed worker's first
// request carries the earlier turn, each call answered against its id, and the key is in no line.
func TestOpenAITranscriptResumes(t *testing.T) {
	t.Parallel()
	transcript := filepath.Join(t.TempDir(), "transcript.jsonl")
	chat := newChatScript(t, []string{
		toolLine("get_state", nil), line(map[string]any{"text": "one " + chatKey}),
		toolLine("list_devices", nil), line(map[string]any{"text": "two"}),
	})
	cfg := workerConfig{via: "openai", chat: chat, transcript: transcript}
	first := startWorker(t, cfg)
	first.say("t1", "first question")
	if turn := first.doneTurn(); lastCall(turn).GetCallId() != "c1" {
		t.Fatalf("the first worker's turn: %v", turn)
	}

	cfg.resume = true
	second := startWorker(t, cfg)
	second.say("t3", "second question")
	turn := second.doneTurn()
	if turn.GetText() != "two" || lastCall(turn).GetTool() != "list_devices" || lastCall(turn).GetCallId() != "c2" {
		t.Errorf("the resumed turn: %v", turn)
	}

	sent, raw := chat.requests()
	if len(sent) != 4 {
		t.Fatalf("want 4 requests, got %d", len(sent))
	}
	var said []string
	for _, m := range sent[2].Messages[1:] {
		s := m.Role
		if m.Content != nil && m.Role != "tool" {
			s += ":" + *m.Content
		}
		for _, c := range m.ToolCalls {
			s += ":" + c.ID + "=" + c.Function.Name
		}
		if m.ToolCallID != "" {
			s += ":" + m.ToolCallID
		}
		said = append(said, s)
	}
	want := "user:first question,assistant:call_s1=get_state,tool:call_s1,assistant:one [key],user:second question"
	if strings.Join(said, ",") != want {
		t.Errorf("the resumed worker's first request carried\n%s\nwant\n%s", strings.Join(said, ","), want)
	}
	kept, _ := os.ReadFile(transcript)
	if strings.Contains(string(kept), chatKey) || strings.Contains(raw[2], chatKey) {
		t.Errorf("the key is in the transcript or a request: %s", kept)
	}
}
