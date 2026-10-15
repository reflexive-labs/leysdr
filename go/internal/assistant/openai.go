// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"

	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// OpenAI calls the chat completions API, which OpenAI serves and which gateways and local model
// servers copy, so one file covers every OpenAI-compatible endpoint. Like the Anthropic model it
// is net/http and one non-streaming request shape. The transcript stays in the worker's own form
// (model.go) and is converted on every call: a tool_use block is an entry in an assistant
// message's tool_calls, and a tool_result block is a message of role "tool".

// OpenAIAPI is OpenAI's own base, used when the key names no endpoint.
const OpenAIAPI = "https://api.openai.com"

// OpenAIDefaultModel is the model the openai provider runs when WorkerStart names none. It is a
// placeholder until the evals choose one (docs/plans/ai-features.md, AI-12).
const OpenAIDefaultModel = "gpt-5"

// openaiMaxTokens bounds one response. It is larger than the Anthropic bound because on a
// reasoning model max_completion_tokens counts the hidden reasoning too, and a bound that the
// reasoning alone reaches ends the turn with no answer.
const openaiMaxTokens = 16384

// openaiErrorPrefix heads a tool result the worker marks is_error: the chat API has no flag for
// it, so the model reads it in the text.
const openaiErrorPrefix = "error: "

// OpenAI is the Model that calls an OpenAI-compatible chat completions API with the user's key.
type OpenAI struct {
	Key      string
	Endpoint string // empty = OpenAIAPI
	Model    string
	// HTTP is the client the calls go out on; nil is one that never follows a redirect.
	HTTP *http.Client
	// legacyMaxTokens is set once the endpoint refused max_completion_tokens, so the rest of the
	// conversation sends max_tokens without being refused first.
	legacyMaxTokens atomic.Bool
}

type chatRequest struct {
	Model               string        `json:"model"`
	Messages            []chatMessage `json:"messages"`
	Tools               []chatTool    `json:"tools,omitempty"`
	ToolChoice          string        `json:"tool_choice,omitempty"`
	MaxCompletionTokens int           `json:"max_completion_tokens,omitempty"`
	MaxTokens           int           `json:"max_tokens,omitempty"`
	Stream              bool          `json:"stream"`
}

type chatMessage struct {
	Role       string     `json:"role"`
	Content    *string    `json:"content"`
	ToolCalls  []toolCall `json:"tool_calls,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
}

type chatTool struct {
	Type     string       `json:"type"`
	Function chatFunction `json:"function"`
}

type chatFunction struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	Parameters  json.RawMessage `json:"parameters"`
}

type toolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

type chatResponse struct {
	Choices []struct {
		Message struct {
			// Content is a string or null, or on some compatible servers a list of text parts.
			Content   json.RawMessage `json:"content"`
			Refusal   string          `json:"refusal"`
			ToolCalls []toolCall      `json:"tool_calls"`
		} `json:"message"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Usage struct {
		PromptTokens        uint64 `json:"prompt_tokens"`
		CompletionTokens    uint64 `json:"completion_tokens"`
		PromptTokensDetails struct {
			CachedTokens uint64 `json:"cached_tokens"`
		} `json:"prompt_tokens_details"`
	} `json:"usage"`
}

type openaiError struct {
	Error struct {
		Message string `json:"message"`
		Type    string `json:"type"`
		Param   string `json:"param"`
		Code    any    `json:"code"` // a string on OpenAI, a number on some compatible servers
	} `json:"error"`
}

// Respond makes one chat completions call, and once more with max_tokens when the endpoint
// refuses max_completion_tokens.
func (o *OpenAI) Respond(ctx context.Context, system string, tools []ToolDef, messages []Message) (Response, error) {
	if err := CheckEndpoint(o.Endpoint); err != nil {
		return Response{}, err
	}
	req, err := o.request(system, tools, messages)
	if err != nil {
		return Response{}, err
	}
	resp, err := o.call(ctx, req)
	if errors.Is(err, errMaxTokensRefused) {
		o.legacyMaxTokens.Store(true)
		req.MaxCompletionTokens, req.MaxTokens = 0, openaiMaxTokens
		resp, err = o.call(ctx, req)
	}
	return resp, err
}

// errMaxTokensRefused is a 400 that names max_completion_tokens: an endpoint that takes only the
// older max_tokens.
var errMaxTokensRefused = errors.New("the endpoint refused max_completion_tokens")

// call posts one request and converts the answer.
func (o *OpenAI) call(ctx context.Context, body chatRequest) (Response, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return Response{}, err
	}
	base := strings.TrimRight(o.Endpoint, "/")
	if base == "" {
		base = OpenAIAPI
	}
	ctx, cancel := context.WithTimeout(ctx, modelCallTimeout)
	defer cancel()
	// An OpenAI-compatible base URL is often written with its /v1 already on it.
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(base, "/v1")+"/v1/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return Response{}, &ModelError{Code: leyline.CodeProviderUnavailable, Message: fmt.Sprintf("the endpoint %q is not a URL", o.Endpoint)}
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("authorization", "Bearer "+o.Key)
	resp, err := noRedirects(o.HTTP).Do(req)
	if err != nil {
		if errors.Is(ctx.Err(), context.Canceled) {
			return Response{}, ctx.Err()
		}
		return Response{}, o.fail(leyline.CodeProviderUnavailable, err.Error())
	}
	defer func() { _ = resp.Body.Close() }()
	got, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return Response{}, o.fail(leyline.CodeProviderUnavailable, "reading the response: "+err.Error())
	}
	if resp.StatusCode != http.StatusOK {
		return Response{}, o.statusError(resp, got, body.MaxCompletionTokens > 0)
	}
	var out chatResponse
	if err := json.Unmarshal(got, &out); err != nil {
		return Response{}, o.fail(leyline.CodeProviderUnavailable, "the response is not chat completions JSON: "+err.Error())
	}
	if len(out.Choices) == 0 {
		return Response{}, o.fail(leyline.CodeProviderUnavailable, "the response has no choices: "+string(got))
	}
	return fromChat(out), nil
}

// request is the body: the system prompt first, the transcript converted, the tools as functions.
// The API caches a repeated prefix by itself, so nothing is marked for it.
func (o *OpenAI) request(system string, tools []ToolDef, messages []Message) (chatRequest, error) {
	req := chatRequest{Model: o.Model, Messages: []chatMessage{{Role: "system", Content: &system}}}
	if o.legacyMaxTokens.Load() {
		req.MaxTokens = openaiMaxTokens
	} else {
		req.MaxCompletionTokens = openaiMaxTokens
	}
	for _, t := range tools {
		req.Tools = append(req.Tools, chatTool{Type: "function", Function: chatFunction{Name: t.Name, Description: t.Description, Parameters: t.InputSchema}})
	}
	if len(req.Tools) > 0 {
		req.ToolChoice = "auto"
	}
	for _, m := range messages {
		converted, err := toChat(m)
		if err != nil {
			return chatRequest{}, err
		}
		req.Messages = append(req.Messages, converted...)
	}
	return req, nil
}

// toChat converts one transcript message. An assistant message is one chat message, its text
// joined and its tool_use blocks as tool_calls in order. A user message is its tool results first,
// each a "tool" message, since the API wants them straight after the call they answer, then its
// text, if any, as one user message.
func toChat(m Message) ([]chatMessage, error) {
	var text string
	var out []chatMessage
	var calls []toolCall
	for _, b := range m.Content {
		switch b.Type {
		case "text":
			text = joinText(text, b.Text)
		case "tool_use":
			c := toolCall{ID: b.ID, Type: "function"}
			c.Function.Name, c.Function.Arguments = b.Name, arguments(b.Input)
			calls = append(calls, c)
		case "tool_result":
			content := b.Content
			if b.IsError {
				content = openaiErrorPrefix + content
			}
			out = append(out, chatMessage{Role: "tool", ToolCallID: b.ToolUseID, Content: &content})
		default:
			return nil, fmt.Errorf("the transcript has a %q block, which the chat API has no form for", b.Type)
		}
	}
	if m.Role == "assistant" {
		msg := chatMessage{Role: "assistant", ToolCalls: calls}
		if text != "" {
			msg.Content = &text
		}
		return append(out, msg), nil
	}
	if text != "" {
		out = append(out, chatMessage{Role: "user", Content: &text})
	}
	return out, nil
}

// arguments is a tool_use input as the API's arguments string. Input the model sent that was not
// a JSON object is kept as a JSON string (fromChat), and goes back as the model wrote it.
func arguments(input json.RawMessage) string {
	if len(input) == 0 {
		return "{}"
	}
	var s string
	if json.Unmarshal(input, &s) == nil {
		return s
	}
	return string(input)
}

// fromChat converts the first choice into the worker's form: its text, then a tool_use block per
// tool call in the order given, with the finish reason in the Messages API's words.
func fromChat(out chatResponse) Response {
	choice := out.Choices[0]
	var resp Response
	if text := contentText(choice.Message.Content); text != "" {
		resp.Content = append(resp.Content, Block{Type: "text", Text: text})
	}
	if choice.Message.Refusal != "" {
		resp.Content = append(resp.Content, Block{Type: "text", Text: choice.Message.Refusal})
	}
	for _, c := range choice.Message.ToolCalls {
		resp.Content = append(resp.Content, Block{Type: "tool_use", ID: callID(c.ID), Name: c.Function.Name, Input: toolInput(c.Function.Arguments)})
	}
	switch {
	case choice.FinishReason == "length":
		resp.StopReason = "max_tokens"
	case choice.FinishReason == "content_filter" || choice.Message.Refusal != "":
		resp.StopReason = "refusal"
	case len(choice.Message.ToolCalls) > 0:
		// Some compatible servers finish a response with tool calls as "stop".
		resp.StopReason = "tool_use"
	default:
		resp.StopReason = "end_turn"
	}
	cached := min(out.Usage.PromptTokensDetails.CachedTokens, out.Usage.PromptTokens)
	// prompt_tokens counts the cached tokens too; the ledger's input is the uncached part, as the
	// Messages API reports it, so input and cache read add up to what was sent.
	resp.Usage = Usage{InputTokens: out.Usage.PromptTokens - cached, OutputTokens: out.Usage.CompletionTokens, CacheReadInputTokens: cached}
	return resp
}

// contentText is a message's content as text: a string, null, or a list of text parts.
func contentText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	text := ""
	if json.Unmarshal(raw, &parts) == nil {
		for _, p := range parts {
			if p.Type == "text" || p.Type == "output_text" {
				text = joinText(text, p.Text)
			}
		}
	}
	return text
}

// toolInput is a call's arguments as a tool_use input: the JSON object as it is, and anything
// else as a JSON string, so the transcript stays valid JSON and the worker refuses the call
// rather than running it with no arguments.
func toolInput(args string) json.RawMessage {
	if strings.TrimSpace(args) == "" {
		return json.RawMessage("{}")
	}
	var obj map[string]any
	if json.Unmarshal([]byte(args), &obj) == nil && obj != nil {
		return json.RawMessage(args)
	}
	quoted, _ := json.Marshal(args)
	return quoted
}

// callID is the call's id, or a made-up one when a compatible server sent none, since every
// tool_result names the call it answers.
func callID(id string) string {
	if id != "" {
		return id
	}
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return "call_ley" + hex.EncodeToString(b)
}

// statusError maps a refusal onto the conversation's codes, as the speech engine does: a rejected
// key, the provider declining for its own reasons (a rate or spend limit, an outage), and
// everything else as the provider being unavailable. A 400 that names max_completion_tokens is
// returned as errMaxTokensRefused for Respond to try again with max_tokens.
func (o *OpenAI) statusError(resp *http.Response, raw []byte, sentMaxCompletion bool) error {
	var shaped openaiError
	msg := ""
	if json.Unmarshal(raw, &shaped) == nil {
		msg = shaped.Error.Message
	} else {
		msg = string(raw)
	}
	if strings.TrimSpace(msg) == "" {
		msg = resp.Status
	}
	code, _ := shaped.Error.Code.(string)
	status := resp.StatusCode
	switch {
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		return o.fail(leyline.CodeCredentialRejected, msg)
	case status == http.StatusTooManyRequests || status >= 500 || code == "insufficient_quota" ||
		strings.Contains(shaped.Error.Type, "overloaded") || strings.Contains(code, "overloaded"):
		return o.fail(leyline.CodeProviderRefused, msg)
	case status == http.StatusBadRequest && mentionsBilling(msg):
		// An account out of credit may be refused as a bad request; it is the provider's limit,
		// not a fault in the request.
		return o.fail(leyline.CodeProviderRefused, msg)
	case status == http.StatusBadRequest && sentMaxCompletion &&
		(shaped.Error.Param == "max_completion_tokens" || strings.Contains(msg, "max_completion_tokens")):
		return errMaxTokensRefused
	case status >= 300 && status < 400:
		return o.fail(leyline.CodeProviderUnavailable, "redirected, and the key is not sent on: "+resp.Status)
	}
	return o.fail(leyline.CodeProviderUnavailable, resp.Status+": "+msg)
}

// fail builds the error with the key cut out of the provider's words.
func (o *OpenAI) fail(code, msg string) error { return providerError(code, msg, o.Key) }
