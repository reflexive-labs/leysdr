// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// SetApprovalMode to AUTO on a WAITING conversation runs the call it waits on, approved once, and
// the conversation reports the mode; an ended conversation's mode cannot change.
func TestAssistantSetApprovalModeRunsTheWaitingCall(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{AssistantScript: []fakedaemon.AssistantTurn{takeOverTurn}})
	assistantKey(t, c)
	ctx := t.Context()
	cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	id := cv.GetConversationId()
	sent, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: id, Text: "take the radio"})
	if err != nil {
		t.Fatal(err)
	}
	watchUntil(t, c, id, sent.Seq, isState(leylinev1.ConversationState_CONVERSATION_WAITING))
	set, err := c.Assistant.SetApprovalMode(ctx, &leylinev1.SetApprovalModeRequest{ConversationId: id, Mode: leylinev1.ApprovalMode_APPROVAL_MODE_AUTO})
	if err != nil {
		t.Fatal(err)
	}
	if set.GetMode() != leylinev1.ApprovalMode_APPROVAL_MODE_AUTO {
		t.Errorf("mode = %v", set.GetMode())
	}
	states := watchUntil(t, c, id, set.Seq, isState(leylinev1.ConversationState_CONVERSATION_IDLE))
	for _, call := range states[len(states)-1].Turns[1].GetTools() {
		if call.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || call.GetAllowedBy() != "" || call.GetReason() == "" {
			t.Errorf("a call after AUTO: %v", call)
		}
	}
	if _, err := c.Assistant.EndConversation(ctx, &leylinev1.ConversationRef{ConversationId: id}); err != nil {
		t.Fatal(err)
	}
	_, err = c.Assistant.SetApprovalMode(ctx, &leylinev1.SetApprovalModeRequest{ConversationId: id, Mode: leylinev1.ApprovalMode_APPROVAL_MODE_ASK})
	if leyline.Code(err) != leyline.CodeFailedPrecondition {
		t.Errorf("SetApprovalMode on an ended conversation: %v", err)
	}
}

// Answering what a conversation waits on dates its last turn, as the daemon does: approving,
// declining, answering a view tool, and switching a waiting conversation to AUTO each move
// last_turn_at_ns past the question's, so a client ordering by the last turn sees it as used.
func TestAssistantAnswerDatesTheTurn(t *testing.T) {
	t.Parallel()
	ask := fakedaemon.AssistantTurn{
		{Ask: "delete_recording", Args: `{"id":"job_1"}`, Reason: "deleting a recording asks every time", ResultApproved: "Deleted job_1"},
		{Text: "Done."},
	}
	view := fakedaemon.AssistantTurn{{View: "show_band", Args: `{"band":"airband"}`}, {Text: "Done."}}
	type answer func(t *testing.T, c *leyline.Client, id string, p *leylinev1.PendingAction) (*leylinev1.Conversation, error)
	for _, tc := range []struct {
		name   string
		script fakedaemon.AssistantTurn
		answer answer
	}{
		{"approve", ask, func(t *testing.T, c *leyline.Client, id string, p *leylinev1.PendingAction) (*leylinev1.Conversation, error) {
			return c.Assistant.ResolveAction(t.Context(), &leylinev1.ResolveActionRequest{ConversationId: id, CallId: p.GetCallId(), Approve: true})
		}},
		{"decline", ask, func(t *testing.T, c *leyline.Client, id string, p *leylinev1.PendingAction) (*leylinev1.Conversation, error) {
			return c.Assistant.ResolveAction(t.Context(), &leylinev1.ResolveActionRequest{ConversationId: id, CallId: p.GetCallId()})
		}},
		{"view tool", view, func(t *testing.T, c *leyline.Client, id string, p *leylinev1.PendingAction) (*leylinev1.Conversation, error) {
			return c.Assistant.AnswerViewTool(t.Context(), &leylinev1.AnswerViewToolRequest{ConversationId: id, CallId: p.GetCallId(), ResultText: "shown"})
		}},
		{"auto", ask, func(t *testing.T, c *leyline.Client, id string, _ *leylinev1.PendingAction) (*leylinev1.Conversation, error) {
			return c.Assistant.SetApprovalMode(t.Context(), &leylinev1.SetApprovalModeRequest{ConversationId: id, Mode: leylinev1.ApprovalMode_APPROVAL_MODE_AUTO})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			c, _ := harness(t, fakedaemon.Options{AssistantScript: []fakedaemon.AssistantTurn{tc.script}})
			assistantKey(t, c)
			cv, err := c.Assistant.StartConversation(t.Context(), &leylinev1.StartConversationRequest{
				ViewTools: []*leylinev1.ViewTool{{Name: "show_band", Description: "move the view"}},
			})
			if err != nil {
				t.Fatal(err)
			}
			id := cv.GetConversationId()
			sent, err := c.Assistant.SendMessage(t.Context(), &leylinev1.SendMessageRequest{ConversationId: id, Text: "go"})
			if err != nil {
				t.Fatal(err)
			}
			states := watchUntil(t, c, id, sent.Seq, isState(leylinev1.ConversationState_CONVERSATION_WAITING))
			waiting := states[len(states)-1]
			// The clock moves on between the question and the answer.
			time.Sleep(2 * time.Millisecond)
			answered, err := tc.answer(t, c, id, waiting.GetPending())
			if err != nil {
				t.Fatal(err)
			}
			if answered.GetLastTurnAtNs() <= waiting.GetLastTurnAtNs() {
				t.Errorf("last_turn_at_ns is %d after the answer and %d at the question", answered.GetLastTurnAtNs(), waiting.GetLastTurnAtNs())
			}
		})
	}
}
