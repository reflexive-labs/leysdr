// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"encoding/json"
	"strings"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// The assistant's log, as `ley ask --json` writes it: one Conversation (proto3 JSON) a line, each
// the whole conversation as it stood, the last one with the turn done. The grader reads the last
// line and lays its assistant turns out as the same events claude's stream gives, so every check
// reads both agents alike: each ToolCall is a tool_use with its arguments followed by its
// tool_result, and the last assistant turn's text is the final answer.

// isConversationLine reports whether a JSON line is a Conversation rather than a stream-json
// message: it has a conversation id and no message type.
func isConversationLine(line string) bool {
	var head struct {
		Type    string `json:"type"`
		ID      string `json:"conversationId"`
		SnakeID string `json:"conversation_id"`
	}
	if err := json.Unmarshal([]byte(line), &head); err != nil {
		return false
	}
	return head.Type == "" && (head.ID != "" || head.SnakeID != "")
}

// parseConversation builds a Log from `ley ask --json` lines. Lines that do not parse are kept
// in Lines and skipped, as ParseStream does with a stream.
func parseConversation(lines []string) *Log {
	log := &Log{Lines: lines}
	var last *leylinev1.Conversation
	for _, line := range lines {
		cv := &leylinev1.Conversation{}
		if err := (protojson.UnmarshalOptions{DiscardUnknown: true}).Unmarshal([]byte(line), cv); err == nil {
			last = cv
		}
	}
	if last == nil {
		return log
	}
	log.ConversationID = last.GetConversationId()
	var assistant []*leylinev1.Turn
	for _, t := range last.GetTurns() {
		if t.GetRole() == leylinev1.Role_ROLE_ASSISTANT {
			assistant = append(assistant, t)
		}
	}
	for i, t := range assistant {
		for _, tc := range t.GetTools() {
			log.Events = append(log.Events, toolEvents(tc)...)
		}
		if i == len(assistant)-1 {
			log.Final = t.GetText()
		} else if strings.TrimSpace(t.GetText()) != "" {
			log.Events = append(log.Events, Event{Kind: "text", Text: t.GetText()})
		}
	}
	log.Turns = len(assistant)
	log.Subtype = conversationSubtype(last)
	log.Events = append(log.Events, Event{Kind: "result", Text: log.Final})
	return log
}

// toolEvents is one ToolCall as a tool_use and, once it has an outcome, its tool_result. A call
// the gate asked about says so on the result's first line, since the reader wants to know the
// assistant would have stopped there without --yes; a declined one is an error result.
func toolEvents(tc *leylinev1.ToolCall) []Event {
	input := json.RawMessage(tc.GetArgumentsJson())
	if !json.Valid(input) {
		input, _ = json.Marshal(tc.GetArgumentsJson())
	}
	out := []Event{{Kind: "tool_use", Tool: tc.GetTool(), ID: tc.GetCallId(), Input: input}}
	var b strings.Builder
	if r := tc.GetReason(); r != "" {
		b.WriteString("[the assistant asked first: " + r + "]\n")
	}
	switch tc.GetState() {
	case leylinev1.ToolCallState_TOOL_CALL_DONE:
		b.WriteString(tc.GetResultText())
		if j := strings.TrimSpace(tc.GetResultJson()); j != "" {
			b.WriteString("\n" + j)
		}
		out = append(out, Event{Kind: "tool_result", ID: tc.GetCallId(), Result: b.String(), IsError: tc.GetIsError()})
	case leylinev1.ToolCallState_TOOL_CALL_REFUSED:
		b.WriteString("declined")
		out = append(out, Event{Kind: "tool_result", ID: tc.GetCallId(), Result: b.String(), IsError: true})
	}
	return out
}

// conversationSubtype is the conversation's end in the words claude's result subtype uses:
// "success" for a turn that finished, else the state, and the failure's code.
func conversationSubtype(cv *leylinev1.Conversation) string {
	switch cv.GetState() {
	case leylinev1.ConversationState_CONVERSATION_IDLE:
		return "success"
	case leylinev1.ConversationState_CONVERSATION_FAILED:
		return "failed: " + cv.GetError().GetCode()
	}
	return strings.ToLower(strings.TrimPrefix(cv.GetState().String(), "CONVERSATION_"))
}
