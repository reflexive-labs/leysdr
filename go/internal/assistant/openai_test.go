// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

const openaiTestKey = "sk-proj-test-0123456789abcdef"

// chatBody is a chat completions request as a test reads it.
type chatBody struct {
	Model               string `json:"model"`
	MaxCompletionTokens *int   `json:"max_completion_tokens"`
	MaxTokens           *int   `json:"max_tokens"`
	Stream              *bool  `json:"stream"`
	ToolChoice          string `json:"tool_choice"`
	Tools               []struct {
		Type     string `json:"type"`
		Function struct {
			Name        string          `json:"name"`
			Description string          `json:"description"`
			Parameters  json.RawMessage `json:"parameters"`
		} `json:"function"`
	} `json:"tools"`
	Messages []struct {
		Role       string  `json:"role"`
		Content    *string `json:"content"`
		ToolCallID string  `json:"tool_call_id"`
		ToolCalls  []struct {
			ID       string `json:"id"`
			Type     string `json:"type"`
			Function struct {
				Name      string `json:"name"`
				Arguments string `json:"arguments"`
			} `json:"function"`
		} `json:"tool_calls"`
	} `json:"messages"`
}

// chatServer answers every request with reply and keeps what it was sent.
func chatServer(t *testing.T, reply string) (srv *httptest.Server, sent func() (path string, header http.Header, body []byte)) {
	t.Helper()
	var mu sync.Mutex
	var path string
	var header http.Header
	var body []byte
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		path, header, body = r.URL.Path, r.Header.Clone(), b
		mu.Unlock()
		_, _ = io.WriteString(w, reply)
	}))
	t.Cleanup(srv.Close)
	return srv, func() (string, http.Header, []byte) {
		mu.Lock()
		defer mu.Unlock()
		return path, header, body
	}
}

// The request is chat completions': the key in the bearer header and nowhere else, the system
// prompt first, the tools as functions, a tool_use as an assistant tool call and each tool_result
// as a tool message naming its call, in the order the calls were made, with is_error in the text.
// Parallel calls in the response come back as tool_use blocks in the order given.
func TestOpenAIRequestShape(t *testing.T) {
	t.Parallel()
	srv, sent := chatServer(t, `{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":"Looking.","tool_calls":[
		{"id":"call_2","type":"function","function":{"name":"list_devices","arguments":"{}"}},
		{"id":"call_3","type":"function","function":{"name":"tune","arguments":"{\"frequency\":\"noaa\"}"}}]}}],
		"usage":{"prompt_tokens":5000,"completion_tokens":30,"prompt_tokens_details":{"cached_tokens":4000}}}`)
	o := &OpenAI{Key: openaiTestKey, Endpoint: srv.URL + "/v1/", Model: "gpt-test"}
	tools := []ToolDef{
		{Name: "get_state", Description: "the state", InputSchema: json.RawMessage(`{"type":"object"}`)},
		{Name: "tune", Description: "tune", InputSchema: json.RawMessage(`{"type":"object","properties":{"frequency":{"type":"string"}}}`)},
	}
	msgs := []Message{
		{Role: "user", Content: []Block{{Type: "text", Text: "what is on?"}}},
		{Role: "assistant", Content: []Block{
			{Type: "text", Text: "Checking."},
			{Type: "tool_use", ID: "call_a", Name: "get_state", Input: json.RawMessage(`{}`)},
			{Type: "tool_use", ID: "call_b", Name: "tune", Input: json.RawMessage(`{"frequency":"noaa"}`)},
		}},
		{Role: "user", Content: []Block{
			{Type: "tool_result", ToolUseID: "call_a", Content: "state"},
			{Type: "tool_result", ToolUseID: "call_b", Content: "the user declined", IsError: true},
			{Type: "text", Text: "never mind, what now?"},
		}},
	}
	resp, err := o.Respond(t.Context(), "the system prompt", tools, msgs)
	if err != nil {
		t.Fatal(err)
	}
	path, header, body := sent()
	if path != "/v1/chat/completions" {
		t.Errorf("path %q: an endpoint written with /v1 must not double it", path)
	}
	if header.Get("Authorization") != "Bearer "+openaiTestKey || header.Get("x-api-key") != "" {
		t.Errorf("headers: %v", header)
	}
	if strings.Contains(string(body), openaiTestKey) {
		t.Error("the key is in the body")
	}
	var req chatBody
	if err := json.Unmarshal(body, &req); err != nil {
		t.Fatalf("%v: %s", err, body)
	}
	if req.Model != "gpt-test" || req.MaxCompletionTokens == nil || *req.MaxCompletionTokens <= 0 || req.MaxTokens != nil ||
		req.Stream == nil || *req.Stream || req.ToolChoice != "auto" {
		t.Errorf("model, token bound, stream or tool_choice: %s", body)
	}
	if strings.Contains(string(body), "cache_control") {
		t.Errorf("the chat API caches by itself; nothing is marked: %s", body)
	}
	if len(req.Tools) != 2 || req.Tools[0].Type != "function" || req.Tools[0].Function.Name != "get_state" || req.Tools[0].Function.Description != "the state" ||
		string(req.Tools[1].Function.Parameters) != `{"type":"object","properties":{"frequency":{"type":"string"}}}` {
		t.Errorf("tools: %s", body)
	}
	var roles []string
	for _, m := range req.Messages {
		roles = append(roles, m.Role)
	}
	if strings.Join(roles, ",") != "system,user,assistant,tool,tool,user" {
		t.Fatalf("roles %v: %s", roles, body)
	}
	if m := req.Messages[0]; *m.Content != "the system prompt" {
		t.Errorf("system: %v", m)
	}
	a := req.Messages[2]
	if a.Content == nil || *a.Content != "Checking." || len(a.ToolCalls) != 2 || a.ToolCalls[0].ID != "call_a" || a.ToolCalls[0].Type != "function" ||
		a.ToolCalls[0].Function.Name != "get_state" || a.ToolCalls[0].Function.Arguments != "{}" ||
		a.ToolCalls[1].ID != "call_b" || a.ToolCalls[1].Function.Arguments != `{"frequency":"noaa"}` {
		t.Errorf("the assistant message: %+v", a)
	}
	if r := req.Messages[3]; r.ToolCallID != "call_a" || *r.Content != "state" {
		t.Errorf("the first result: %+v", r)
	}
	if r := req.Messages[4]; r.ToolCallID != "call_b" || *r.Content != "error: the user declined" {
		t.Errorf("the second result: %+v", r)
	}
	if u := req.Messages[5]; *u.Content != "never mind, what now?" {
		t.Errorf("the user's text: %+v", u)
	}

	uses := resp.ToolUses()
	if resp.StopReason != "tool_use" || resp.Text() != "Looking." || len(uses) != 2 ||
		uses[0].ID != "call_2" || uses[0].Name != "list_devices" || string(uses[0].Input) != "{}" ||
		uses[1].ID != "call_3" || uses[1].Name != "tune" || string(uses[1].Input) != `{"frequency":"noaa"}` {
		t.Errorf("response: %+v", resp)
	}
	if u := resp.Usage; u.InputTokens != 1000 || u.CacheReadInputTokens != 4000 || u.OutputTokens != 30 || u.CacheCreationInputTokens != 0 {
		t.Errorf("usage %+v: prompt_tokens counts the cached ones, and input is the rest", u)
	}
}

// An assistant message with tool calls and no text sends content null, which the API wants.
func TestOpenAIToolCallsWithoutText(t *testing.T) {
	t.Parallel()
	srv, sent := chatServer(t, `{"choices":[{"finish_reason":"stop","message":{"content":"ok"}}]}`)
	o := &OpenAI{Key: openaiTestKey, Endpoint: srv.URL, Model: "m"}
	msgs := []Message{
		{Role: "user", Content: []Block{{Type: "text", Text: "hi"}}},
		{Role: "assistant", Content: []Block{{Type: "tool_use", ID: "c", Name: "get_state"}}},
		{Role: "user", Content: []Block{{Type: "tool_result", ToolUseID: "c", Content: "x"}}},
	}
	if _, err := o.Respond(t.Context(), "s", nil, msgs); err != nil {
		t.Fatal(err)
	}
	_, _, body := sent()
	if !strings.Contains(string(body), `{"role":"assistant","content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"get_state","arguments":"{}"}}]}`) {
		t.Errorf("the assistant message: %s", body)
	}
	if strings.Contains(string(body), `"tools"`) || strings.Contains(string(body), `"tool_choice"`) {
		t.Errorf("no tools offered, so neither field is sent: %s", body)
	}
}

// Each finish reason becomes the loop's stop reason, and what a compatible server may send
// differently still reads.
func TestOpenAIResponses(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name, reply string
		check       func(t *testing.T, r Response)
	}{
		{"stop", `{"choices":[{"finish_reason":"stop","message":{"content":"Done."}}]}`, func(t *testing.T, r Response) {
			if r.StopReason != "end_turn" || r.Text() != "Done." {
				t.Errorf("%+v", r)
			}
		}},
		{"length", `{"choices":[{"finish_reason":"length","message":{"content":"Half","tool_calls":[{"id":"c","type":"function","function":{"name":"tune","arguments":"{\"freq"}}]}}]}`, func(t *testing.T, r Response) {
			if r.StopReason != "max_tokens" || r.Text() != "Half" {
				t.Errorf("%+v", r)
			}
		}},
		{"content filter", `{"choices":[{"finish_reason":"content_filter","message":{"content":null}}]}`, func(t *testing.T, r Response) {
			if r.StopReason != "refusal" {
				t.Errorf("%+v", r)
			}
		}},
		{"refusal field", `{"choices":[{"finish_reason":"stop","message":{"content":null,"refusal":"I can't help with that."}}]}`, func(t *testing.T, r Response) {
			if r.StopReason != "refusal" || r.Text() != "I can't help with that." {
				t.Errorf("%+v", r)
			}
		}},
		{"tool calls finished as stop", `{"choices":[{"finish_reason":"stop","message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_state","arguments":""}}]}}]}`, func(t *testing.T, r Response) {
			if r.StopReason != "tool_use" || len(r.ToolUses()) != 1 || string(r.ToolUses()[0].Input) != "{}" {
				t.Errorf("%+v", r)
			}
		}},
		{"content as parts", `{"choices":[{"finish_reason":"stop","message":{"content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}}]}`, func(t *testing.T, r Response) {
			if r.Text() != "one\n\ntwo" {
				t.Errorf("%+v", r)
			}
		}},
		{"a call with no id", `{"choices":[{"finish_reason":"tool_calls","message":{"tool_calls":[{"type":"function","function":{"name":"get_state","arguments":"{}"}},{"function":{"name":"help","arguments":"{}"}}]}}]}`, func(t *testing.T, r Response) {
			uses := r.ToolUses()
			if len(uses) != 2 || !strings.HasPrefix(uses[0].ID, "call_") || uses[0].ID == uses[1].ID {
				t.Errorf("every call needs an id of its own: %+v", uses)
			}
		}},
		{"arguments that are not an object", `{"choices":[{"finish_reason":"tool_calls","message":{"tool_calls":[{"id":"c","type":"function","function":{"name":"tune","arguments":"146.52 please"}}]}}]}`, func(t *testing.T, r Response) {
			use := r.ToolUses()[0]
			if string(use.Input) != `"146.52 please"` {
				t.Errorf("input %s: kept as a JSON string, so the transcript stays JSON", use.Input)
			}
			if got := arguments(use.Input); got != "146.52 please" {
				t.Errorf("sent back as %q, not as the model wrote it", got)
			}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			srv, _ := chatServer(t, tc.reply)
			r, err := (&OpenAI{Key: openaiTestKey, Endpoint: srv.URL, Model: "m"}).Respond(t.Context(), "s", nil, nil)
			if err != nil {
				t.Fatal(err)
			}
			tc.check(t, r)
		})
	}
}

// An endpoint that refuses max_completion_tokens is asked again with max_tokens, and the rest of
// the conversation sends max_tokens first.
func TestOpenAIMaxCompletionTokensFallback(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	var sentFields []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body chatBody
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		mu.Lock()
		defer mu.Unlock()
		if body.MaxCompletionTokens != nil {
			sentFields = append(sentFields, "max_completion_tokens")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `{"error":{"message":"Unrecognized request argument supplied: max_completion_tokens","type":"invalid_request_error","param":null,"code":null}}`)
			return
		}
		if body.MaxTokens != nil && *body.MaxTokens > 0 {
			sentFields = append(sentFields, "max_tokens")
		}
		_, _ = io.WriteString(w, `{"choices":[{"finish_reason":"stop","message":{"content":"ok"}}]}`)
	}))
	t.Cleanup(srv.Close)
	o := &OpenAI{Key: openaiTestKey, Endpoint: srv.URL, Model: "m"}
	for range 2 {
		if r, err := o.Respond(t.Context(), "s", nil, nil); err != nil || r.Text() != "ok" {
			t.Fatalf("%+v %v", r, err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if strings.Join(sentFields, ",") != "max_completion_tokens,max_tokens,max_tokens" {
		t.Errorf("sent %v", sentFields)
	}
}

// Each refusal maps onto the conversation's codes in the provider's words, with the key cut out.
func TestOpenAIErrors(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name     string
		status   int
		body     string
		wantCode string
		wantSays string
	}{
		{"401", 401, `{"error":{"message":"Incorrect API key provided: ` + openaiTestKey + `","type":"invalid_request_error","code":"invalid_api_key"}}`, leyline.CodeCredentialRejected, "Incorrect API key provided: …"},
		{"403", 403, `{"error":{"message":"not allowed in your region","type":"invalid_request_error"}}`, leyline.CodeCredentialRejected, "not allowed"},
		{"429 rate", 429, `{"error":{"message":"Rate limit reached","type":"requests","code":"rate_limit_exceeded"}}`, leyline.CodeProviderRefused, "Rate limit reached"},
		{"429 quota", 429, `{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}`, leyline.CodeProviderRefused, "current quota"},
		{"400 quota", 400, `{"error":{"message":"quota","type":"invalid_request_error","code":"insufficient_quota"}}`, leyline.CodeProviderRefused, "quota"},
		{"400 billing", 400, `{"error":{"message":"Your account is not active, please check your billing details","type":"invalid_request_error"}}`, leyline.CodeProviderRefused, "billing details"},
		{"400 credit", 400, `{"error":{"message":"Insufficient credits","code":402}}`, leyline.CodeProviderRefused, "Insufficient credits"},
		{"503 overloaded", 503, `{"error":{"message":"The engine is currently overloaded","type":"server_error"}}`, leyline.CodeProviderRefused, "overloaded"},
		{"500", 500, `{"error":{"message":"boom","type":"server_error"}}`, leyline.CodeProviderRefused, "boom"},
		{"overloaded type", 400, `{"error":{"message":"busy","type":"overloaded_error"}}`, leyline.CodeProviderRefused, "busy"},
		{"400 other", 400, `{"error":{"message":"Invalid parameter: messages with role 'tool' must be a response to a preceeding message with 'tool_calls'.","type":"invalid_request_error"}}`, leyline.CodeProviderUnavailable, "400 Bad Request: Invalid parameter"},
		{"404", 404, `{"error":{"message":"The model gpt-nope does not exist","code":"model_not_found"}}`, leyline.CodeProviderUnavailable, "does not exist"},
		{"302", 302, ``, leyline.CodeProviderUnavailable, "redirected"},
		{"plain text", 418, `I'm a teapot ` + openaiTestKey, leyline.CodeProviderUnavailable, "I'm a teapot …"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var followed atomic.Bool
			elsewhere := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { followed.Store(true) }))
			t.Cleanup(elsewhere.Close)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if tc.status == 302 {
					w.Header().Set("Location", elsewhere.URL+"/v1/chat/completions")
				}
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			t.Cleanup(srv.Close)
			_, err := (&OpenAI{Key: openaiTestKey, Endpoint: srv.URL, Model: "m"}).Respond(t.Context(), "s", nil, nil)
			var me *ModelError
			if !errors.As(err, &me) {
				t.Fatalf("not a ModelError: %v", err)
			}
			if me.Code != tc.wantCode || !strings.Contains(me.Message, tc.wantSays) {
				t.Errorf("got %s %q, want %s with %q", me.Code, me.Message, tc.wantCode, tc.wantSays)
			}
			if strings.Contains(me.Message, openaiTestKey) {
				t.Errorf("the key is in the message: %s", me.Message)
			}
			if followed.Load() {
				t.Error("the redirect was followed, with the key")
			}
		})
	}
	t.Run("no choices", func(t *testing.T) {
		t.Parallel()
		srv, _ := chatServer(t, `{"choices":[]}`)
		_, err := (&OpenAI{Key: openaiTestKey, Endpoint: srv.URL, Model: "m"}).Respond(t.Context(), "s", nil, nil)
		var me *ModelError
		if !errors.As(err, &me) || me.Code != leyline.CodeProviderUnavailable || !strings.Contains(me.Message, "no choices") {
			t.Errorf("got %v", err)
		}
	})
	t.Run("unreachable", func(t *testing.T) {
		t.Parallel()
		srv := httptest.NewServer(http.NotFoundHandler())
		url := srv.URL
		srv.Close()
		_, err := (&OpenAI{Key: openaiTestKey, Endpoint: url, Model: "m"}).Respond(t.Context(), "s", nil, nil)
		var me *ModelError
		if !errors.As(err, &me) || me.Code != leyline.CodeProviderUnavailable {
			t.Errorf("got %v", err)
		}
	})
	t.Run("cancelled", func(t *testing.T) {
		t.Parallel()
		ctx, cancel := context.WithCancel(t.Context())
		cancel()
		_, err := (&OpenAI{Key: openaiTestKey, Endpoint: "http://127.0.0.1:9", Model: "m"}).Respond(ctx, "s", nil, nil)
		if !errors.Is(err, context.Canceled) {
			t.Errorf("a cancelled call is not a provider failure: %v", err)
		}
	})
}

// The key crosses the network only over https, or in plain http to this machine.
func TestOpenAIHTTPSRule(t *testing.T) {
	t.Parallel()
	for endpoint, ok := range map[string]bool{
		"http://gateway.example/v1":  false,
		"http://192.168.1.20:11434":  false,
		"ftp://gateway.example":      false,
		"https://gateway.example/v1": true,
		"http://localhost:11434/v1":  true,
		"http://127.0.0.1:8080":      true,
		"http://[::1]:8080":          true,
	} {
		err := CheckEndpoint(endpoint)
		if (err == nil) != ok {
			t.Errorf("%s: %v", endpoint, err)
		}
	}
	_, err := (&OpenAI{Key: openaiTestKey, Endpoint: "http://gateway.example/v1", Model: "m"}).Respond(t.Context(), "s", nil, nil)
	var me *ModelError
	if !errors.As(err, &me) || me.Code != leyline.CodeProviderUnavailable || !strings.Contains(me.Message, "must be https") {
		t.Errorf("got %v", err)
	}
}
