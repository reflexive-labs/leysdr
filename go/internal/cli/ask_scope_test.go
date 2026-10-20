// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

var bothScopes = []leylinev1.ApprovalScope{leylinev1.ApprovalScope_APPROVAL_SCOPE_ONCE, leylinev1.ApprovalScope_APPROVAL_SCOPE_CONVERSATION}

// takeOverRow is the policy row the worker grants for a take-over, whatever the tool.
const takeOverRow = "take over a radio"

// takeOverTurn takes a radio over by tune and then by scan, both on the take-over row; each
// question offers the rest of the conversation, and the fake grants the row when the first is
// answered that way.
var takeOverTurn = fakedaemon.AssistantTurn{
	{
		Ask: "tune", Args: `{"frequency":"150","take_over":true}`, Offers: bothScopes, Row: takeOverRow,
		Reason: "another client is using the radio: chan_01J (146.520 MHz, ley tune).", ResultApproved: "Tuned to 150.000 MHz NFM on chan_01K",
	},
	{
		Ask: "scan", Args: `{"range":"2m","take_over":true}`, Offers: bothScopes, Row: takeOverRow,
		Reason: "another client is using the radio: chan_01K (150.000 MHz, assistant).", ResultApproved: "Scanned 144.000 MHz to 148.000 MHz: 3 detections",
	},
	{Text: "Done."},
}

// A question shows the letters its call offers: [y/N/a] when it can be allowed for the rest of the
// conversation, [y/N] when it cannot. a and all answer for the conversation, and the next call on
// that row runs without a question, whatever its tool, with its receipt beneath it; a typed where
// the call does not offer it declines.
func TestAskOffersTheLetters(t *testing.T) {
	t.Parallel()
	for _, answer := range []string{"a", "All"} {
		t.Run(answer, func(t *testing.T) {
			t.Parallel()
			o := askRunOpts{inTTY: true, stdin: answer + "\n"}
			checkAskScreens(t, []fakedaemon.AssistantTurn{takeOverTurn}, o, "ask", "take the radio")
			sock, c := askHarness(t, takeOverTurn)
			o.width, o.merged = 160, true
			out, _, err := runAskLey(t, sock, o, "ask", "take the radio")
			if err != nil {
				t.Fatal(err)
			}
			if want := "Allow? [y/N/a] " + answer + "\n  Tuned to 150.000 MHz NFM on chan_01K\n" +
				"→ scan {\"range\":\"2m\",\"take_over\":true}\n  Scanned 144.000 MHz to 148.000 MHz: 3 detections\n"; !strings.Contains(out, want) {
				t.Errorf("lacks %q:\n%s", want, out)
			}
			if n := strings.Count(out, "Allow?"); n != 1 {
				t.Errorf("asked %d times:\n%s", n, out)
			}
			tools := newestConversation(t, c).Turns[1].Tools
			if tools[1].GetAllowedBy() != tools[0].GetCallId() {
				t.Errorf("the scan was not allowed by the tune's answer: %v", tools[1])
			}
		})
	}
	t.Run("a on a delete", func(t *testing.T) {
		t.Parallel()
		sock, c := askHarness(t, deleteTurn)
		out, _, err := runAskLey(t, sock, askRunOpts{width: 160, merged: true, inTTY: true, stdin: "a\n"}, "ask", "delete it")
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(out, "Allow? [y/N] a\n  ✗ declined") {
			t.Errorf("a delete offers once only, and a declines it:\n%s", out)
		}
		if got := newestConversation(t, c).Turns[1].Tools[0].GetState(); got != leylinev1.ToolCallState_TOOL_CALL_REFUSED {
			t.Errorf("the delete is %v", got)
		}
	})
}

// A grant covers its row and no other: after a for a take-over by tune, a take-over by scan runs,
// and a kept job, another row, still asks.
func TestAskGrantCoversOnlyItsRow(t *testing.T) {
	t.Parallel()
	turn := append(fakedaemon.AssistantTurn{}, takeOverTurn[:2]...)
	turn = append(turn,
		fakedaemon.AssistantStep{
			Ask: "watch", Args: `{"decoder":"aprs","keep":true}`, Offers: bothScopes, Row: "start a kept job",
			Reason: "start a kept aprs job that runs on after this conversation ends.", ResultApproved: "watching aprs",
		},
		fakedaemon.AssistantStep{Text: "Done."},
	)
	sock, c := askHarness(t, turn)
	out, _, err := runAskLey(t, sock, askRunOpts{width: 160, merged: true, inTTY: true, stdin: "a\nn\n"}, "ask", "take the radio and keep a watch")
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(out, "Allow? [y/N/a]"); n != 2 {
		t.Errorf("want the tune and the watch asked, got %d questions:\n%s", n, out)
	}
	tools := newestConversation(t, c).Turns[1].Tools
	if len(tools) != 3 {
		t.Fatalf("calls: %v", tools)
	}
	if scan := tools[1]; scan.GetTool() != "scan" || scan.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || scan.GetAllowedBy() != tools[0].GetCallId() {
		t.Errorf("the scan on the granted row: %v", scan)
	}
	if watch := tools[2]; watch.GetState() != leylinev1.ToolCallState_TOOL_CALL_REFUSED || watch.GetAllowedBy() != "" {
		t.Errorf("the kept watch, another row, should have asked and been declined: %v", watch)
	}
}

// The answer typed at the question: once, for the conversation where it is offered, or no.
// Only the letters the help names count.
func TestParseAllow(t *testing.T) {
	t.Parallel()
	both := &leylinev1.PendingAction{Offers: bothScopes}
	once := &leylinev1.PendingAction{Offers: bothScopes[:1]}
	for _, tc := range []struct {
		line    string
		p       *leylinev1.PendingAction
		approve bool
		scope   leylinev1.ApprovalScope
	}{
		{"y", both, true, leylinev1.ApprovalScope_APPROVAL_SCOPE_ONCE},
		{" YES ", once, true, leylinev1.ApprovalScope_APPROVAL_SCOPE_ONCE},
		{"a", both, true, leylinev1.ApprovalScope_APPROVAL_SCOPE_CONVERSATION},
		{"ALL", both, true, leylinev1.ApprovalScope_APPROVAL_SCOPE_CONVERSATION},
		{"always", both, false, leylinev1.ApprovalScope_APPROVAL_SCOPE_UNSPECIFIED},
		{"a", once, false, leylinev1.ApprovalScope_APPROVAL_SCOPE_UNSPECIFIED},
		{"", both, false, leylinev1.ApprovalScope_APPROVAL_SCOPE_UNSPECIFIED},
		{"n", both, false, leylinev1.ApprovalScope_APPROVAL_SCOPE_UNSPECIFIED},
		{"sure", both, false, leylinev1.ApprovalScope_APPROVAL_SCOPE_UNSPECIFIED},
	} {
		if approve, scope := parseAllow(tc.line, tc.p); approve != tc.approve || scope != tc.scope {
			t.Errorf("%q with offers %v: %v %v, want %v %v", tc.line, tc.p.GetOffers(), approve, scope, tc.approve, tc.scope)
		}
	}
}

// --continue says when the conversation it carries on asks nothing, so the reader knows before the
// request goes.
func TestContinuingLineNamesAuto(t *testing.T) {
	t.Parallel()
	cv := &leylinev1.Conversation{Mode: leylinev1.ApprovalMode_APPROVAL_MODE_AUTO, State: leylinev1.ConversationState_CONVERSATION_IDLE}
	if got := continuingLine(cv); !strings.HasSuffix(got, "; it allows everything without asking") {
		t.Errorf("continuingLine = %q", got)
	}
}
