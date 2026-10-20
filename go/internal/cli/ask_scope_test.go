// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"slices"
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/assistant"
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
	sock, c := askHarness(t, grantRowTurn)
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

// grantRowTurn is takeOverTurn's two take-overs, then a kept job, a row of its own.
var grantRowTurn = append(append(fakedaemon.AssistantTurn{}, takeOverTurn[:2]...),
	fakedaemon.AssistantStep{
		Ask: "watch", Args: `{"decoder":"aprs","keep":true}`, Offers: bothScopes, Row: "start a kept job",
		Reason: "start a kept aprs job that runs on after this conversation ends.", ResultApproved: "watching aprs",
	},
	fakedaemon.AssistantStep{Text: "Done."},
)

// Every Row a script in these tests names is a row the gate has, so a misspelt row cannot
// group grants the worker would keep apart.
func TestAskScriptRowsAreTheGatesRows(t *testing.T) {
	t.Parallel()
	gateRows := assistant.Rows()
	for _, turn := range []fakedaemon.AssistantTurn{takeOverTurn, grantRowTurn, deleteTurn} {
		for _, step := range turn {
			if step.Row != "" && !slices.Contains(gateRows, step.Row) {
				t.Errorf("the %s step names the row %q, which the gate does not have (assistant.Rows: %q)", step.Ask, step.Row, gateRows)
			}
		}
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

// --continue says the mode of the conversation it carries on when it asks nothing or this run
// changed it, so the reader knows before the request goes; a conversation that asks, as it did,
// gets no word.
func TestContinuingLineNamesTheMode(t *testing.T) {
	t.Parallel()
	auto := &leylinev1.Conversation{Mode: leylinev1.ApprovalMode_APPROVAL_MODE_AUTO, State: leylinev1.ConversationState_CONVERSATION_IDLE}
	ask := &leylinev1.Conversation{Mode: leylinev1.ApprovalMode_APPROVAL_MODE_ASK, State: leylinev1.ConversationState_CONVERSATION_IDLE}
	for _, tc := range []struct {
		cv      *leylinev1.Conversation
		changed bool
		suffix  string
	}{
		{auto, true, "; --yes sets it to allow everything without asking, until a client changes that"},
		{auto, false, "; it allows everything without asking, until a client changes that"},
		{ask, true, "; it asks first again, since this run has no --yes"},
		{ask, false, "(0 turns)"},
	} {
		if got := continuingLine(tc.cv, tc.changed); !strings.HasSuffix(got, tc.suffix) {
			t.Errorf("mode %v, changed %v: %q", tc.cv.GetMode(), tc.changed, got)
		}
	}
}

// --continue sets the conversation to the run's mode: a conversation left in AUTO by an earlier
// --yes asks again on a run without it, and one in ASK allows everything on a run with it.
func TestAskContinueSetsTheRunsMode(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name  string
		start leylinev1.ApprovalMode
		flags []string
		want  leylinev1.ApprovalMode
		says  string
	}{
		{"auto, then a run without --yes", leylinev1.ApprovalMode_APPROVAL_MODE_AUTO, nil, leylinev1.ApprovalMode_APPROVAL_MODE_ASK, "it asks first again"},
		{"ask, then a run with --yes", leylinev1.ApprovalMode_APPROVAL_MODE_ASK, []string{"--yes"}, leylinev1.ApprovalMode_APPROVAL_MODE_AUTO, "--yes sets it to allow everything"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			sock, c := askHarness(t, weatherTurn)
			if _, err := c.Assistant.StartConversation(t.Context(), &leylinev1.StartConversationRequest{Mode: tc.start}); err != nil {
				t.Fatal(err)
			}
			args := append([]string{"ask", "--continue", "hello"}, tc.flags...)
			out, _, err := runAskLey(t, sock, askRunOpts{width: 160, merged: true}, args...)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(out, tc.says) {
				t.Errorf("lacks %q:\n%s", tc.says, out)
			}
			if got := newestConversation(t, c).GetMode(); got != tc.want {
				t.Errorf("mode after the run: %v, want %v", got, tc.want)
			}
		})
	}
}
