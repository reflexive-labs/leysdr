// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"testing"

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
