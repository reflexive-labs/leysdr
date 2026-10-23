// SPDX-License-Identifier: Apache-2.0

package assistant_test

import (
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// A set_mode that arrives while the model call is under way changes the mode for the calls after
// it and does not touch what the running call reads: run under -race, this exercises the worker
// taking the mode on its own goroutine while the model call runs on during's.
func TestSetModeDuringAModelCall(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{
		line(map[string]any{"sleep_ms": 400, "tool": "watch", "args": map[string]any{"decoder": "aprs", "keep": true}}),
		line(map[string]any{"text": "watching"}),
	}})
	w.say("t1", "watch APRS for good")
	// The empty turn comes before the model is called; the call then sleeps.
	w.until(func(*leylinev1.Turn) bool { return true })
	w.setMode(leylinev1.ApprovalMode_APPROVAL_MODE_AUTO)
	turn := w.doneTurn()
	call := callNamed(turn, "watch")
	if call.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || call.GetReason() == "" {
		t.Errorf("the kept watch after AUTO arrived mid-call should run unasked: %v", call)
	}
	for _, c := range turn.GetTools() {
		if c.GetState() == leylinev1.ToolCallState_TOOL_CALL_AWAITING_APPROVAL {
			t.Errorf("a call waited: %v", c)
		}
	}
}
