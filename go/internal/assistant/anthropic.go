// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// Anthropic calls the Messages API with net/http rather than anthropic-sdk-go: the SDK's module
// graph brings the AWS and Google Cloud SDKs for its Bedrock and Vertex clients, dozens of
// licence rows for one POST. The loop needs one non-streaming request shape and four error
// outcomes, which is this file.

// AnthropicAPI is the Messages API's own base, used when the key names no endpoint.
const AnthropicAPI = "https://api.anthropic.com"

// anthropicVersion is the API version the request shape below follows.
const anthropicVersion = "2023-06-01"

// anthropicMaxTokens bounds one response. A turn is a few sentences and tool calls; a response
// that reaches it stops with "max_tokens" and the turn ends with what it had.
const anthropicMaxTokens = 4096

// anthropicTimeout bounds one call. A long response takes tens of seconds; a call that takes
// minutes is a provider that is not answering.
const anthropicTimeout = 3 * time.Minute

// Anthropic is the Model that calls Claude with the user's key.
type Anthropic struct {
	Key      string
	Endpoint string // empty = AnthropicAPI
	Model    string
	// HTTP is the client the calls go out on; nil is one that never follows a redirect, because Go
	// re-sends a header set by hand to a redirect's host, and the key must reach no other host.
	HTTP *http.Client
}

// cacheControl marks the end of the prefix the provider caches: the system prompt and the tool
// definitions are the same on every call of a conversation.
type cacheControl struct {
	Type string `json:"type"`
}

var ephemeral = &cacheControl{Type: "ephemeral"}

type systemBlock struct {
	Type         string        `json:"type"`
	Text         string        `json:"text"`
	CacheControl *cacheControl `json:"cache_control,omitempty"`
}

type toolEntry struct {
	ToolDef
	CacheControl *cacheControl `json:"cache_control,omitempty"`
}

type messagesRequest struct {
	Model     string        `json:"model"`
	MaxTokens int           `json:"max_tokens"`
	System    []systemBlock `json:"system"`
	Tools     []toolEntry   `json:"tools,omitempty"`
	Messages  []Message     `json:"messages"`
}

type messagesResponse struct {
	Content    []Block `json:"content"`
	StopReason string  `json:"stop_reason"`
	Usage      Usage   `json:"usage"`
}

type apiError struct {
	Error struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	} `json:"error"`
}

// Respond makes one Messages call.
func (a *Anthropic) Respond(ctx context.Context, system string, tools []ToolDef, messages []Message) (Response, error) {
	body, err := json.Marshal(a.request(system, tools, messages))
	if err != nil {
		return Response{}, err
	}
	base := strings.TrimRight(a.Endpoint, "/")
	if base == "" {
		base = AnthropicAPI
	}
	ctx, cancel := context.WithTimeout(ctx, anthropicTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(base, "/v1")+"/v1/messages", bytes.NewReader(body))
	if err != nil {
		return Response{}, &ModelError{Code: leyline.CodeProviderUnavailable, Message: fmt.Sprintf("the endpoint %q is not a URL", a.Endpoint)}
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("x-api-key", a.Key)
	req.Header.Set("anthropic-version", anthropicVersion)
	resp, err := a.client().Do(req)
	if err != nil {
		if errors.Is(ctx.Err(), context.Canceled) {
			return Response{}, ctx.Err()
		}
		return Response{}, a.fail(leyline.CodeProviderUnavailable, err.Error())
	}
	defer func() { _ = resp.Body.Close() }()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return Response{}, a.fail(leyline.CodeProviderUnavailable, "reading the response: "+err.Error())
	}
	if resp.StatusCode != http.StatusOK {
		return Response{}, a.statusError(resp, raw)
	}
	var out messagesResponse
	if err := json.Unmarshal(raw, &out); err != nil {
		return Response{}, a.fail(leyline.CodeProviderUnavailable, "the response is not the Messages API's JSON: "+err.Error())
	}
	return Response(out), nil
}

// request is the body: the system prompt and the last tool marked for the cache, so every call
// after the first reads both from it.
func (a *Anthropic) request(system string, tools []ToolDef, messages []Message) messagesRequest {
	req := messagesRequest{
		Model:     a.Model,
		MaxTokens: anthropicMaxTokens,
		System:    []systemBlock{{Type: "text", Text: system, CacheControl: ephemeral}},
		Messages:  messages,
	}
	for i, t := range tools {
		e := toolEntry{ToolDef: t}
		if i == len(tools)-1 {
			e.CacheControl = ephemeral
		}
		req.Tools = append(req.Tools, e)
	}
	return req
}

// statusError maps a refusal onto the conversation's codes: a rejected key, the provider
// declining for its own reasons (a rate or spend limit, overload), and everything else as the
// provider being unavailable.
func (a *Anthropic) statusError(resp *http.Response, raw []byte) error {
	var shaped apiError
	msg := ""
	if json.Unmarshal(raw, &shaped) == nil {
		msg = shaped.Error.Message
	}
	if strings.TrimSpace(msg) == "" {
		msg = resp.Status
	}
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return a.fail(leyline.CodeCredentialRejected, msg)
	case resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode == 529 || shaped.Error.Type == "overloaded_error":
		return a.fail(leyline.CodeProviderRefused, msg)
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return a.fail(leyline.CodeProviderUnavailable, "redirected, and the key is not sent on: "+resp.Status)
	}
	return a.fail(leyline.CodeProviderUnavailable, resp.Status+": "+msg)
}

// fail builds the error with the provider's words on one line and the key cut out of them: a
// gateway may echo the request back, header and all, and the message travels on to every client
// that watches the conversation.
func (a *Anthropic) fail(code, msg string) error {
	msg = strings.Join(strings.Fields(msg), " ")
	if a.Key != "" {
		msg = strings.ReplaceAll(msg, a.Key, "…")
	}
	if r := []rune(msg); len(r) > 300 {
		msg = string(r[:299]) + "…"
	}
	return &ModelError{Code: code, Message: msg}
}

func (a *Anthropic) client() *http.Client {
	if a.HTTP != nil {
		return a.HTTP
	}
	return &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}
