// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// The assistant on the OpenAI-compatible model end to end (docs/plans/ai-features.md, AI-15):
// the real daemon, the real `ley worker assistant` and the real `ley ask`, with no
// LEY_ASSISTANT_SCRIPT, against an httptest chat completions endpoint. It covers the openai
// provider at an endpoint, a gateway under a name of its own, and the two refusals.

// chatEndpoint is a chat completions API as the worker and the check use it: GET /v1/models
// accepts the test's key; POST /v1/chat/completions checks each request as the API would and
// answers one whose last message is a user message with two tool calls, and one whose last
// message is a tool result with "Done.", each with the same usage. status other than 0 answers
// every chat request with that status and its OpenAI error body.
type chatEndpoint struct {
	t      *testing.T
	srv    *httptest.Server
	status atomic.Int32

	mu       sync.Mutex
	requests []e2eChatRequest
	problems []string
}

// e2eChatRequest is what the endpoint reads of a request.
type e2eChatRequest struct {
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

// chatUsage is on every answer: 100 of the 120 prompt tokens cached.
const chatUsage = `{"prompt_tokens":120,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":100}}`

func newChatEndpoint(t *testing.T) *chatEndpoint {
	c := &chatEndpoint{t: t}
	c.srv = httptest.NewServer(http.HandlerFunc(c.serve))
	t.Cleanup(c.srv.Close)
	return c
}

func (c *chatEndpoint) problem(format string, args ...any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.problems = append(c.problems, fmt.Sprintf(format, args...))
}

// take returns the requests and problems since the last take, and forgets them.
func (c *chatEndpoint) take() ([]e2eChatRequest, []string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	reqs, problems := c.requests, c.problems
	c.requests, c.problems = nil, nil
	return reqs, problems
}

func (c *chatEndpoint) serve(w http.ResponseWriter, req *http.Request) {
	if req.Header.Get("Authorization") != "Bearer "+openaiKey {
		c.problem("%s %s without the test's key as a bearer token", req.Method, req.URL.Path)
		http.Error(w, `{"error":{"message":"not the test's key","type":"invalid_request_error","code":"invalid_api_key"}}`, http.StatusUnauthorized)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	switch {
	case req.Method == http.MethodGet && req.URL.Path == "/v1/models":
		_, _ = w.Write([]byte(`{"object":"list","data":[]}`))
	case req.Method == http.MethodPost && req.URL.Path == "/v1/chat/completions":
		c.serveChat(w, req)
	default:
		c.problem("%s %s, which the endpoint does not serve", req.Method, req.URL.Path)
		http.NotFound(w, req)
	}
}

func (c *chatEndpoint) serveChat(w http.ResponseWriter, req *http.Request) {
	raw, _ := io.ReadAll(req.Body)
	var body e2eChatRequest
	if err := json.Unmarshal(raw, &body); err != nil {
		c.problem("a chat request the endpoint cannot read: %v\n%s", err, raw)
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if p := checkE2EChat(body); p != "" {
		c.problem("the API would refuse this request: %s\n%s", p, raw)
	}
	c.mu.Lock()
	c.requests = append(c.requests, body)
	c.mu.Unlock()

	switch int(c.status.Load()) {
	case http.StatusUnauthorized:
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}`))
		return
	case http.StatusTooManyRequests:
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}`))
		return
	}
	last := body.Messages[len(body.Messages)-1]
	if last.Role == "tool" {
		fmt.Fprintf(w, `{"id":"chatcmpl-2","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Done."},"finish_reason":"stop"}],"usage":%s}`, chatUsage)
		return
	}
	fmt.Fprintf(w, `{"id":"chatcmpl-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[`+
		`{"id":"call_a","type":"function","function":{"name":"get_state","arguments":"{}"}},`+
		`{"id":"call_b","type":"function","function":{"name":"list_bands","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":%s}`, chatUsage)
}

// checkE2EChat is what the chat API refuses in a request: the system prompt not first, or a tool
// message that does not answer the next call waiting, or a call never answered.
func checkE2EChat(req e2eChatRequest) string {
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

// newAskOpenAIRig starts an unscripted daemon and adds the openai key and the acme gateway's key
// (the same canary key), both at the endpoint, each checked by the real `ley worker check`.
func newAskOpenAIRig(t *testing.T) (*askRig, *chatEndpoint) {
	t.Helper()
	chat := newChatEndpoint(t)
	r := &askRig{aiRig: startAskDaemon(t, false)}
	for _, provider := range []string{"openai", "acme"} {
		_, errOut := r.mustLey(openaiKey+"\n", "ai", "add", provider, "--endpoint", chat.srv.URL)
		if !strings.Contains(errOut, "the provider accepted it") {
			t.Fatalf("ley ai add %s said %q", provider, errOut)
		}
	}
	if _, problems := chat.take(); len(problems) > 0 {
		t.Fatalf("the checks: %v", problems)
	}
	return r, chat
}

// Both tool calls of one response run in order and go back as tool messages in that order, and
// the ledger counts the uncached prompt tokens as input and the cached ones as cache read, on the
// openai provider and on a gateway under its own name.
func TestAskOpenAIAgainstRealDaemon(t *testing.T) {
	r, chat := newAskOpenAIRig(t)
	for _, provider := range []string{"openai", "acme"} {
		t.Run(provider, func(t *testing.T) { checkAskOpenAI(t, r, chat, provider) })
	}
	r.assertNoCanary()
	checkConversationFilesHoldNoKey(t, r)
}

func checkAskOpenAI(t *testing.T, r *askRig, chat *chatEndpoint, provider string) {
	r.mustLey("", "ai", "use", "assistant", provider, "gpt-test")
	out, errOut, code := r.ask("what's the state", "--yes", "--json")
	reqs, problems := chat.take()
	for _, p := range problems {
		t.Error(p)
	}
	if code != 0 {
		t.Fatalf("ley ask: exit %d\nstdout: %s\nstderr: %s", code, out, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	cv := &leylinev1.Conversation{}
	unmarshalProto(t, lines[len(lines)-1], cv)
	if cv.GetState() != leylinev1.ConversationState_CONVERSATION_IDLE || cv.GetProvider() != provider || cv.GetModel() != "gpt-test" {
		t.Errorf("the conversation's last state: %s", lines[len(lines)-1])
	}
	var got []string
	for _, c := range calls(cv) {
		got = append(got, fmt.Sprintf("%s %v %v", c.GetTool(), c.GetState(), c.GetIsError()))
	}
	want := "get_state TOOL_CALL_DONE false|list_bands TOOL_CALL_DONE false"
	if strings.Join(got, "|") != want {
		t.Errorf("the calls: %s, want %s", strings.Join(got, "|"), want)
	}

	if len(reqs) != 2 {
		t.Fatalf("want two chat requests, got %d", len(reqs))
	}
	for i, req := range reqs {
		if req.Model != "gpt-test" {
			t.Errorf("request %d names the model %q", i+1, req.Model)
		}
	}
	var answered []string
	for _, m := range reqs[1].Messages {
		if m.Role == "tool" {
			answered = append(answered, m.ToolCallID)
		}
	}
	if strings.Join(answered, ",") != "call_a,call_b" {
		t.Errorf("the second request's tool messages answer %v, want call_a, call_b", answered)
	}

	l := r.assistantUsage(cv.GetConversationId())
	if l == nil || l.GetProvider() != provider || l.GetModel() != "gpt-test" || l.GetRequests() != 2 ||
		l.GetInputTokens() != 40 || l.GetOutputTokens() != 20 || l.GetCacheReadTokens() != 200 {
		t.Errorf("the ledger's assistant line: %v", l)
	}
}

// A 401 fails the conversation CREDENTIAL_REJECTED and a 429 insufficient_quota fails it
// PROVIDER_REFUSED; ley ask exits 1 with the code either way.
func TestAskOpenAIProviderFailuresAgainstRealDaemon(t *testing.T) {
	r, chat := newAskOpenAIRig(t)
	r.mustLey("", "ai", "use", "assistant", "openai", "gpt-test")
	for _, c := range []struct {
		status int
		code   string
	}{
		{http.StatusTooManyRequests, "PROVIDER_REFUSED"},
		{http.StatusUnauthorized, "CREDENTIAL_REJECTED"},
	} {
		chat.status.Store(int32(c.status))
		out, errOut, code := r.ask("hi")
		reqs, problems := chat.take()
		for _, p := range problems {
			t.Error(p)
		}
		if code != 1 || !strings.Contains(errOut, "["+c.code+"]") {
			t.Errorf("ley ask against a %d: exit %d\nstdout: %s\nstderr: %s", c.status, code, out, errOut)
		}
		if len(reqs) == 0 {
			t.Errorf("the worker never reached the endpoint (status %d)", c.status)
		}
		cv := r.newest()
		if cv.GetState() != leylinev1.ConversationState_CONVERSATION_FAILED || cv.GetError().GetCode() != c.code {
			b, _ := json.Marshal(cv.GetError())
			t.Errorf("the conversation against a %d: %v, error %s", c.status, cv.GetState(), b)
		}
	}
	r.assertNoCanary()
	checkConversationFilesHoldNoKey(t, r)
}

// checkConversationFilesHoldNoKey: assertNoCanary walks the data directory; this also fails when
// there are no conversation files to walk, so a run that wrote none is not a pass.
func checkConversationFilesHoldNoKey(t *testing.T, r *askRig) {
	t.Helper()
	files, _ := filepath.Glob(filepath.Join(r.data, "conversations", "*", "*"))
	if len(files) == 0 {
		t.Fatalf("no conversation files under %s", filepath.Join(r.data, "conversations"))
	}
	for _, f := range files {
		if b, err := os.ReadFile(f); err != nil || bytes.Contains(b, []byte(aiCanary)) {
			t.Errorf("%s holds the key (%v)", f, err)
		}
	}
}
