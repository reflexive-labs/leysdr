// SPDX-License-Identifier: Apache-2.0

package assistant_test

import (
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// A question still waiting when the mode becomes AUTO is approved once: the call runs with its
// reason and no allowed_by, and a later call that would ask runs without asking.
func TestAutoWhileWaitingRunsTheCall(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{keptWatch, line(map[string]any{"text": "watching"}), webhook}})
	w.say("t1", "watch APRS for good")
	asked := w.asking()
	w.setMode(leylinev1.ApprovalMode_APPROVAL_MODE_AUTO)
	turn := w.doneTurn()
	call := callNamed(turn, "watch")
	if call.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || call.GetCallId() != asked.GetCallId() ||
		call.GetReason() == "" || call.GetAllowedBy() != "" {
		t.Errorf("the waiting call after AUTO: %v", call)
	}
	w.say("t3", "send it to my hook")
	next := w.doneTurn()
	if hook := lastCall(next); hook.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || !strings.Contains(hook.GetReason(), "webhook") {
		t.Errorf("a webhook in AUTO: %v", hook)
	}
}

// A mode set back to ASK between turns makes the next call that asks wait again.
func TestAskAgainAfterAuto(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{mode: leylinev1.ApprovalMode_APPROVAL_MODE_AUTO, script: []string{keptWatch, line(map[string]any{"text": "watching"}), webhook}})
	w.say("t1", "watch APRS for good")
	w.doneTurn()
	w.setMode(leylinev1.ApprovalMode_APPROVAL_MODE_ASK)
	w.say("t3", "send it to my hook")
	if call := w.asking(); !strings.Contains(call.GetReason(), "webhook") {
		t.Errorf("the webhook after ASK: %v", call)
	}
}
