// SPDX-License-Identifier: Apache-2.0

// Package assistant is the worker behind `ley worker assistant`: the loop that runs a model with
// the `ley mcp` tools for one conversation the daemon holds (docs/dev/assistant.md). The daemon
// spawns it with the provider's key on stdin, sends it what the user says and decides, and reads
// back the assistant's turn, whole, after every change.
package assistant

import (
	"context"
	"encoding/json"
	"fmt"
)

// The transcript is kept in the Messages API's own shapes, because Anthropic is the one provider
// the assistant calls and a second shape would only be translated back on every request.

// Block is one content block: text, a tool call the model made (tool_use), or what the call
// returned (tool_result).
type Block struct {
	Type      string          `json:"type"`
	Text      string          `json:"text,omitempty"`
	ID        string          `json:"id,omitempty"`
	Name      string          `json:"name,omitempty"`
	Input     json.RawMessage `json:"input,omitempty"`
	ToolUseID string          `json:"tool_use_id,omitempty"`
	Content   string          `json:"content,omitempty"`
	IsError   bool            `json:"is_error,omitempty"`
}

// Message is one turn of the transcript as the model sees it: role "user" or "assistant".
type Message struct {
	Role    string  `json:"role"`
	Content []Block `json:"content"`
}

// ToolDef is a tool as the model is offered it.
type ToolDef struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	InputSchema json.RawMessage `json:"input_schema"`
}

// Usage is what one response used, in the provider's units.
type Usage struct {
	InputTokens              uint64 `json:"input_tokens"`
	OutputTokens             uint64 `json:"output_tokens"`
	CacheCreationInputTokens uint64 `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     uint64 `json:"cache_read_input_tokens"`
}

// Response is one model response: its blocks in order, why it stopped ("tool_use" asks for the
// results and another call; "end_turn" ends the turn) and what it used.
type Response struct {
	Content    []Block
	StopReason string
	Usage      Usage
}

// ToolUses is the response's tool calls, in the order the model made them.
func (r Response) ToolUses() []Block {
	var uses []Block
	for _, b := range r.Content {
		if b.Type == "tool_use" {
			uses = append(uses, b)
		}
	}
	return uses
}

// Text is the response's text blocks joined.
func (r Response) Text() string {
	text := ""
	for _, b := range r.Content {
		if b.Type == "text" && b.Text != "" {
			text = joinText(text, b.Text)
		}
	}
	return text
}

// Model is a provider the loop calls once per step of a turn. The system prompt and the tools are
// the same on every call of a conversation, so a provider with a prompt cache reads them from it.
type Model interface {
	Respond(ctx context.Context, system string, tools []ToolDef, messages []Message) (Response, error)
}

// ModelError is a model call that failed, with the stable code the conversation fails with
// (CREDENTIAL_REJECTED, PROVIDER_REFUSED, PROVIDER_UNAVAILABLE) and the provider's words.
type ModelError struct {
	Code    string
	Message string
}

func (e *ModelError) Error() string { return fmt.Sprintf("%s [%s]", e.Message, e.Code) }

// joinText adds a paragraph to text the turn already has.
func joinText(text, more string) string {
	if text == "" || more == "" {
		return text + more
	}
	return text + "\n\n" + more
}
