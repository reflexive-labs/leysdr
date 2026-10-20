// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

var bothScopes = []leylinev1.ApprovalScope{leylinev1.ApprovalScope_APPROVAL_SCOPE_ONCE, leylinev1.ApprovalScope_APPROVAL_SCOPE_CONVERSATION}

// takeOverTurn asks twice to take a radio over; each question offers the rest of the
// conversation, and the fake grants the tool when the first is answered that way.
var takeOverTurn = fakedaemon.AssistantTurn{
	{
		Ask: "tune", Args: `{"frequency":"150","take_over":true}`, Offers: bothScopes,
		Reason: "another client is using the radio: chan_01J (146.520 MHz, ley tune).", ResultApproved: "Tuned to 150.000 MHz NFM on chan_01K",
	},
	{
		Ask: "tune", Args: `{"frequency":"151","take_over":true}`, Offers: bothScopes,
		Reason: "another client is using the radio: chan_01K (150.000 MHz, assistant).", ResultApproved: "Tuned to 151.000 MHz NFM on chan_01K",
	},
	{Text: "Done."},
}

// A question shows the letters its call offers: [y/N/a] when it can be allowed for the rest of the
// conversation, [y/N] when it cannot. a, all and always answer for the conversation, and the next
// call of that kind runs without a question, with its receipt beneath it; a typed where the call
// does not offer it declines.
func TestAskOffersTheLetters(t *testing.T) {
	t.Parallel()
	for _, answer := range []string{"a", "all", "Always"} {
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
				"→ tune {\"frequency\":\"151\",\"take_over\":true}\n  Tuned to 151.000 MHz NFM on chan_01K\n"; !strings.Contains(out, want) {
				t.Errorf("lacks %q:\n%s", want, out)
			}
			if n := strings.Count(out, "Allow?"); n != 1 {
				t.Errorf("asked %d times:\n%s", n, out)
			}
			tools := newestConversation(t, c).Turns[1].Tools
			if tools[1].GetAllowedBy() != tools[0].GetCallId() {
				t.Errorf("the second call was not allowed by the first answer: %v", tools[1])
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

// The answer typed at the question: once, for the conversation where it is offered, or no.
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
		{"always", both, true, leylinev1.ApprovalScope_APPROVAL_SCOPE_CONVERSATION},
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

// --continue names a conversation that asks nothing, so the reader knows before the request goes.
func TestContinuingLineNamesAuto(t *testing.T) {
	t.Parallel()
	cv := &leylinev1.Conversation{Mode: leylinev1.ApprovalMode_APPROVAL_MODE_AUTO, State: leylinev1.ConversationState_CONVERSATION_IDLE}
	if got := continuingLine(cv); !strings.HasSuffix(got, "; it was started with --yes, so the assistant asks nothing") {
		t.Errorf("continuingLine = %q", got)
	}
}
