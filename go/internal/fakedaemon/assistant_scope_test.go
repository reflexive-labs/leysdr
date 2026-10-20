// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"slices"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/assistant"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

var (
	scopeOnce         = leylinev1.ApprovalScope_APPROVAL_SCOPE_ONCE
	scopeConversation = leylinev1.ApprovalScope_APPROVAL_SCOPE_CONVERSATION
)

// takeOverTurn asks to take over the radio twice, offering both scopes.
var takeOverTurn = fakedaemon.AssistantTurn{
	{Ask: "tune", Args: `{"frequency":"150","take_over":true}`, Reason: "another client is using the radio", ResultApproved: "tuned", Offers: []leylinev1.ApprovalScope{scopeOnce, scopeConversation}},
	{Ask: "tune", Args: `{"frequency":"151","take_over":true}`, Reason: "another client is using the radio", ResultApproved: "tuned again", Offers: []leylinev1.ApprovalScope{scopeOnce, scopeConversation}},
	{Text: "Done."},
}

// An Ask step's offers reach the pending action; a scope it did not offer is INVALID_ARGUMENT and
// leaves the question open; an approval for the conversation lets the next Ask for that tool run
// at once, with allowed_by naming the call that granted it.
func TestAssistantScopesAndGrants(t *testing.T) {
	t.Parallel()
	deleteOnce := fakedaemon.AssistantTurn{{Ask: "delete_recording", Args: `{"id":"job_1"}`, Reason: "asks every time", ResultApproved: "Deleted"}}
	c, _ := harness(t, fakedaemon.Options{AssistantScript: []fakedaemon.AssistantTurn{deleteOnce, takeOverTurn}})
	assistantKey(t, c)
	ctx := t.Context()
	cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if cv.GetMode() != leylinev1.ApprovalMode_APPROVAL_MODE_ASK {
		t.Errorf("an unset mode reports %v", cv.GetMode())
	}
	id := cv.GetConversationId()

	sent, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: id, Text: "delete it"})
	if err != nil {
		t.Fatal(err)
	}
	states := watchUntil(t, c, id, sent.Seq, isState(leylinev1.ConversationState_CONVERSATION_WAITING))
	p := states[len(states)-1].GetPending()
	if !slices.Equal(p.GetOffers(), []leylinev1.ApprovalScope{scopeOnce}) {
		t.Errorf("an Ask without offers offers %v", p.GetOffers())
	}
	_, err = c.Assistant.ResolveAction(ctx, &leylinev1.ResolveActionRequest{ConversationId: id, CallId: p.GetCallId(), Approve: true, Scope: scopeConversation})
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Fatalf("a scope the call did not offer: %v", err)
	}
	resolved, err := c.Assistant.ResolveAction(ctx, &leylinev1.ResolveActionRequest{ConversationId: id, CallId: p.GetCallId(), Approve: true})
	if err != nil {
		t.Fatalf("the question was not left open: %v", err)
	}
	watchUntil(t, c, id, resolved.Seq, isState(leylinev1.ConversationState_CONVERSATION_IDLE))

	sent, err = c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: id, Text: "take the radio"})
	if err != nil {
		t.Fatal(err)
	}
	states = watchUntil(t, c, id, sent.Seq, isState(leylinev1.ConversationState_CONVERSATION_WAITING))
	p = states[len(states)-1].GetPending()
	if !slices.Equal(p.GetOffers(), []leylinev1.ApprovalScope{scopeOnce, scopeConversation}) {
		t.Errorf("offers = %v", p.GetOffers())
	}
	resolved, err = c.Assistant.ResolveAction(ctx, &leylinev1.ResolveActionRequest{ConversationId: id, CallId: p.GetCallId(), Approve: true, Scope: scopeConversation})
	if err != nil {
		t.Fatal(err)
	}
	states = watchUntil(t, c, id, resolved.Seq, isState(leylinev1.ConversationState_CONVERSATION_IDLE))
	tools := states[len(states)-1].Turns[3].GetTools()
	if len(tools) != 2 {
		t.Fatalf("calls: %v", tools)
	}
	if second := tools[1]; second.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || second.GetAllowedBy() != p.GetCallId() ||
		second.GetReason() == "" || second.GetResultText() != "tuned again" {
		t.Errorf("the granted call: %v", second)
	}
}

// An AUTO conversation reports its mode, and its Ask steps run without waiting, reported with
// their reasons.
func TestAssistantAutoModeAsksNothing(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{AssistantScript: []fakedaemon.AssistantTurn{takeOverTurn}})
	assistantKey(t, c)
	ctx := t.Context()
	cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{Mode: leylinev1.ApprovalMode_APPROVAL_MODE_AUTO})
	if err != nil {
		t.Fatal(err)
	}
	if cv.GetMode() != leylinev1.ApprovalMode_APPROVAL_MODE_AUTO {
		t.Errorf("mode = %v", cv.GetMode())
	}
	sent, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: cv.GetConversationId(), Text: "take the radio"})
	if err != nil {
		t.Fatal(err)
	}
	states := watchUntil(t, c, cv.GetConversationId(), sent.Seq, isState(leylinev1.ConversationState_CONVERSATION_IDLE))
	for _, s := range states {
		if s.GetState() == leylinev1.ConversationState_CONVERSATION_WAITING {
			t.Fatalf("an AUTO conversation waited: %v", s.GetPending())
		}
	}
	for _, call := range states[len(states)-1].Turns[1].GetTools() {
		if call.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || call.GetReason() == "" || call.GetAllowedBy() != "" {
			t.Errorf("a call in AUTO: %v", call)
		}
	}
}

// rowGrantTurn takes the radio over by tune and then by scan, both on the gate's take-over row,
// then starts a kept job, a row of its own.
var rowGrantTurn = fakedaemon.AssistantTurn{
	{
		Ask: "tune", Args: `{"frequency":"150","take_over":true}`, Row: "take over a radio",
		Reason: "another client is using the radio", ResultApproved: "tuned", Offers: []leylinev1.ApprovalScope{scopeOnce, scopeConversation},
	},
	{
		Ask: "scan", Args: `{"range":"2m","take_over":true}`, Row: "take over a radio",
		Reason: "another client is using the radio", ResultApproved: "scanned", Offers: []leylinev1.ApprovalScope{scopeOnce, scopeConversation},
	},
	{
		Ask: "watch", Args: `{"decoder":"aprs","keep":true}`, Row: "start a kept job",
		Reason: "a kept job runs on after the conversation", ResultApproved: "watching", Offers: []leylinev1.ApprovalScope{scopeOnce, scopeConversation},
	},
	{Text: "Done."},
}

// Every Row a script in these tests names is a row the worker's gate has, so a misspelt row
// cannot group grants the worker would keep apart.
func TestAssistantScriptRowsAreTheGatesRows(t *testing.T) {
	t.Parallel()
	gate := assistant.Rows()
	for _, turn := range []fakedaemon.AssistantTurn{takeOverTurn, rowGrantTurn} {
		for _, step := range turn {
			if step.Row != "" && !slices.Contains(gate, step.Row) {
				t.Errorf("the %s step names the row %q, which the gate does not have (assistant.Rows: %q)", step.Ask, step.Row, gate)
			}
		}
	}
}

// A grant covers its row and no other: allowed for the conversation, a take-over by tune lets a
// take-over by scan run unasked, and a kept job, another row, still asks.
func TestAssistantGrantCoversOnlyItsRow(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{AssistantScript: []fakedaemon.AssistantTurn{rowGrantTurn}})
	assistantKey(t, c)
	ctx := t.Context()
	cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	id := cv.GetConversationId()
	sent, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: id, Text: "take the radio and keep a watch"})
	if err != nil {
		t.Fatal(err)
	}
	states := watchUntil(t, c, id, sent.Seq, isState(leylinev1.ConversationState_CONVERSATION_WAITING))
	tune := states[len(states)-1].GetPending()
	resolved, err := c.Assistant.ResolveAction(ctx, &leylinev1.ResolveActionRequest{ConversationId: id, CallId: tune.GetCallId(), Approve: true, Scope: scopeConversation})
	if err != nil {
		t.Fatal(err)
	}
	states = watchUntil(t, c, id, resolved.Seq, isState(leylinev1.ConversationState_CONVERSATION_WAITING))
	if watch := states[len(states)-1].GetPending(); watch.GetTool() != "watch" {
		t.Fatalf("the second question is %v, want the watch", watch)
	}
	tools := states[len(states)-1].Turns[1].GetTools()
	if len(tools) != 3 {
		t.Fatalf("calls: %v", tools)
	}
	if scan := tools[1]; scan.GetTool() != "scan" || scan.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || scan.GetAllowedBy() != tune.GetCallId() {
		t.Errorf("the scan on the granted row: %v", scan)
	}
	if watch := tools[2]; watch.GetAllowedBy() != "" {
		t.Errorf("the kept watch, another row, was allowed by %q", watch.GetAllowedBy())
	}
}
