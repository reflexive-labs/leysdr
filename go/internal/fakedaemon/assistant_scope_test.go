// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"slices"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
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
