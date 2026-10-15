// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

const testKey = "sk-ant-test-0123456789abcdef"

// The request is the Messages API's: the key in its header and nowhere else, the system prompt
// and the last tool marked for the cache, the transcript as given, tool results in the order the
// calls were made.
func TestAnthropicRequestShape(t *testing.T) {
	t.Parallel()
	var body []byte
	var header http.Header
	var path string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ = io.ReadAll(r.Body)
		header, path = r.Header.Clone(), r.URL.Path
		_, _ = io.WriteString(w, `{"content":[{"type":"text","text":"tuned"},{"type":"tool_use","id":"toolu_2","name":"get_state","input":{}}],
			"stop_reason":"tool_use","usage":{"input_tokens":120,"output_tokens":30,"cache_creation_input_tokens":900,"cache_read_input_tokens":4000}}`)
	}))
	t.Cleanup(srv.Close)
	a := &Anthropic{Key: testKey, Endpoint: srv.URL + "/v1/", Model: "claude-test"}
	tools := []ToolDef{
		{Name: "get_state", Description: "the state", InputSchema: json.RawMessage(`{"type":"object"}`)},
		{Name: "tune", Description: "tune", InputSchema: json.RawMessage(`{"type":"object","properties":{"frequency":{"type":"string"}}}`)},
	}
	msgs := []Message{
		{Role: "user", Content: []Block{{Type: "text", Text: "what is on?"}}},
		{Role: "assistant", Content: []Block{
			{Type: "tool_use", ID: "toolu_a", Name: "get_state", Input: json.RawMessage(`{}`)},
			{Type: "tool_use", ID: "toolu_b", Name: "tune", Input: json.RawMessage(`{"frequency":"noaa"}`)},
		}},
		{Role: "user", Content: []Block{
			{Type: "tool_result", ToolUseID: "toolu_a", Content: "state"},
			{Type: "tool_result", ToolUseID: "toolu_b", Content: "the user declined", IsError: true},
		}},
	}
	resp, err := a.Respond(t.Context(), "the system prompt", tools, msgs)
	if err != nil {
		t.Fatal(err)
	}
	if path != "/v1/messages" {
		t.Errorf("path %q: an endpoint written with /v1 must not double it", path)
	}
	if header.Get("x-api-key") != testKey || header.Get("anthropic-version") != "2023-06-01" {
		t.Errorf("headers: %v", header)
	}
	if strings.Contains(string(body), testKey) {
		t.Error("the key is in the body")
	}
	var req struct {
		Model     string `json:"model"`
		MaxTokens int    `json:"max_tokens"`
		System    []struct {
			Type, Text   string
			CacheControl *struct{ Type string } `json:"cache_control"`
		} `json:"system"`
		Tools []struct {
			Name         string
			InputSchema  json.RawMessage        `json:"input_schema"`
			CacheControl *struct{ Type string } `json:"cache_control"`
		} `json:"tools"`
		Messages []struct {
			Role    string
			Content []map[string]any
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		t.Fatalf("%v: %s", err, body)
	}
	if req.Model != "claude-test" || req.MaxTokens <= 0 {
		t.Errorf("model %q, max_tokens %d", req.Model, req.MaxTokens)
	}
	if len(req.System) != 1 || req.System[0].Text != "the system prompt" || req.System[0].CacheControl == nil || req.System[0].CacheControl.Type != "ephemeral" {
		t.Errorf("system: %s", body)
	}
	if len(req.Tools) != 2 || req.Tools[0].CacheControl != nil || req.Tools[1].CacheControl == nil || req.Tools[1].CacheControl.Type != "ephemeral" {
		t.Errorf("only the last tool carries cache_control: %s", body)
	}
	if string(req.Tools[1].InputSchema) != `{"type":"object","properties":{"frequency":{"type":"string"}}}` {
		t.Errorf("input_schema: %s", req.Tools[1].InputSchema)
	}
	results := req.Messages[2].Content
	if req.Messages[2].Role != "user" || len(results) != 2 || results[0]["tool_use_id"] != "toolu_a" || results[1]["tool_use_id"] != "toolu_b" ||
		results[0]["type"] != "tool_result" || results[1]["is_error"] != true {
		t.Errorf("tool results out of order or misshapen: %v", results)
	}
	if resp.StopReason != "tool_use" || resp.Text() != "tuned" || len(resp.ToolUses()) != 1 || resp.ToolUses()[0].Name != "get_state" {
		t.Errorf("response: %+v", resp)
	}
	if u := resp.Usage; u.InputTokens != 120 || u.OutputTokens != 30 || u.CacheCreationInputTokens != 900 || u.CacheReadInputTokens != 4000 {
		t.Errorf("usage: %+v", u)
	}
}

// Each refusal maps onto the conversation's codes in the provider's words, with the key cut out.
func TestAnthropicErrors(t *testing.T) {
	t.Parallel()
	cases := []struct {
		status   int
		body     string
		wantCode string
		wantSays string
	}{
		{401, `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key ` + testKey + `"}}`, leyline.CodeCredentialRejected, "invalid x-api-key …"},
		{403, `{"type":"error","error":{"type":"permission_error","message":"not allowed"}}`, leyline.CodeCredentialRejected, "not allowed"},
		{429, `{"type":"error","error":{"type":"rate_limit_error","message":"rate limited, slow down"}}`, leyline.CodeProviderRefused, "rate limited, slow down"},
		{529, `{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`, leyline.CodeProviderRefused, "Overloaded"},
		{500, `{"type":"error","error":{"type":"overloaded_error","message":"busy"}}`, leyline.CodeProviderRefused, "busy"},
		{500, `{"type":"error","error":{"type":"api_error","message":"boom"}}`, leyline.CodeProviderUnavailable, "500 Internal Server Error: boom"},
		{302, ``, leyline.CodeProviderUnavailable, "redirected"},
		{502, `<html>bad gateway</html>`, leyline.CodeProviderUnavailable, "502 Bad Gateway"},
	}
	for _, tc := range cases {
		t.Run(strconv.Itoa(tc.status), func(t *testing.T) {
			t.Parallel()
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if tc.status == 302 {
					w.Header().Set("Location", "https://elsewhere.example/v1/messages")
				}
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			t.Cleanup(srv.Close)
			_, err := (&Anthropic{Key: testKey, Endpoint: srv.URL, Model: "m"}).Respond(t.Context(), "s", nil, nil)
			var me *ModelError
			if !errors.As(err, &me) {
				t.Fatalf("not a ModelError: %v", err)
			}
			if me.Code != tc.wantCode || !strings.Contains(me.Message, tc.wantSays) {
				t.Errorf("got %s %q, want %s with %q", me.Code, me.Message, tc.wantCode, tc.wantSays)
			}
			if strings.Contains(me.Message, testKey) {
				t.Errorf("the key is in the message: %s", me.Message)
			}
		})
	}
	t.Run("unreachable", func(t *testing.T) {
		t.Parallel()
		srv := httptest.NewServer(http.NotFoundHandler())
		url := srv.URL
		srv.Close()
		_, err := (&Anthropic{Key: testKey, Endpoint: url, Model: "m"}).Respond(t.Context(), "s", nil, nil)
		var me *ModelError
		if !errors.As(err, &me) || me.Code != leyline.CodeProviderUnavailable {
			t.Errorf("got %v", err)
		}
	})
	t.Run("cancelled", func(t *testing.T) {
		t.Parallel()
		ctx, cancel := context.WithCancel(t.Context())
		cancel()
		_, err := (&Anthropic{Key: testKey, Endpoint: "http://127.0.0.1:9", Model: "m"}).Respond(ctx, "s", nil, nil)
		if !errors.Is(err, context.Canceled) {
			t.Errorf("a cancelled call is not a provider failure: %v", err)
		}
	})
}
