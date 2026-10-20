// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/testutil"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// askHarness is a fake daemon whose assistant plays script, with a key and the assistant's model
// already set.
func askHarness(t *testing.T, script ...fakedaemon.AssistantTurn) (string, *leyline.Client) {
	t.Helper()
	sock, c := harness(t, fakedaemon.Options{AssistantScript: script})
	ctx := t.Context()
	if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: "anthropic", Secret: aiSecret}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "assistant", Provider: "anthropic", Model: "claude-sonnet-5-5"}); err != nil {
		t.Fatal(err)
	}
	return sock, c
}

// askRunOpts is how one `ley ask` in a test sees its terminal.
type askRunOpts struct {
	width int
	color bool
	// inTTY says stdin is a terminal someone could answer on.
	inTTY bool
	stdin string
}

// runAskLey runs ley against sock with stdout and stderr on a terminal of o.width.
func runAskLey(t *testing.T, sock string, o askRunOpts, args ...string) (string, string, error) {
	t.Helper()
	out, errOut, _, err := runAskLeyStdin(t, sock, o, args...)
	return out, errOut, err
}

// runAskLeyStdin is runAskLey that also returns how much of o.stdin was left unread.
func runAskLeyStdin(t *testing.T, sock string, o askRunOpts, args ...string) (string, string, int, error) {
	t.Helper()
	var out, errb bytes.Buffer
	mode := "--color=never"
	if o.color {
		mode = "--color=always"
	}
	stdin := strings.NewReader(o.stdin)
	app := &App{
		Stdout: &out, Stderr: &errb, Stdin: stdin,
		IsTTY: func() bool { return true }, IsErrTTY: func() bool { return true }, IsInTTY: func() bool { return o.inTTY },
		TermWidth: func() int { return o.width }, ErrTermWidth: func() int { return o.width },
		LookupEnv: func(k string) (string, bool) {
			if k == "LANG" {
				return "en_US.UTF-8", true
			}
			return "", false
		},
	}
	err := Execute(t.Context(), app, append([]string{"--socket", sock, mode}, args...))
	return out.String(), errb.String(), stdin.Len(), err
}

// askLines parses ask's stdout as one Conversation a line, failing the test on anything else.
func askLines(t *testing.T, out string) []*leylinev1.Conversation {
	t.Helper()
	var states []*leylinev1.Conversation
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		cv := &leylinev1.Conversation{}
		if err := protojson.Unmarshal([]byte(l), cv); err != nil {
			t.Fatalf("not a Conversation (%v): %q", err, l)
		}
		states = append(states, cv)
	}
	return states
}

// lastState is the last Conversation ask printed.
func lastState(t *testing.T, out string) *leylinev1.Conversation {
	t.Helper()
	states := askLines(t, out)
	return states[len(states)-1]
}

// newestConversation is the conversation the daemon lists first.
func newestConversation(t *testing.T, c *leyline.Client) *leylinev1.Conversation {
	t.Helper()
	list, err := c.Assistant.ListConversations(t.Context(), &leylinev1.ListConversationsRequest{})
	if err != nil || len(list.GetConversations()) == 0 {
		t.Fatalf("no conversation listed (%v)", err)
	}
	return list.Conversations[0]
}

var twoToolsTurn = fakedaemon.AssistantTurn{
	{Text: "Tuning to the NOAA station."},
	{Tool: "tune", Args: `{"freq": "162.4M", "mode": "nfm"}`, Result: "Tuned to 162.400 MHz NFM on chan_01K\nsquelch auto"},
	{Tool: "set", Args: `{"param":"squelch","value":"-45","channel":"chan_01K"}`, Result: "Squelch -45.0 dBFS on 162.400 MHz"},
	{Text: "Tuning to the NOAA station. It is playing now; ley stop ends it."},
}

// Every run prints each state the watch delivers as one Conversation per line in the standard
// proto3 JSON mapping, unstyled even with colour forced on a terminal, ending with the IDLE one,
// and nothing on stderr: --json is implied, and giving it changes nothing.
func TestAskWritesJSONLines(t *testing.T) {
	t.Parallel()
	for _, flags := range [][]string{nil, {"--json"}} {
		sock, c := askHarness(t, twoToolsTurn)
		args := append(append([]string{}, flags...), "ask", "listen to the weather")
		out, errOut, err := runAskLey(t, sock, askRunOpts{width: 80, color: true}, args...)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(out, "\x1b") || errOut != "" {
			t.Errorf("%v: styled or prose output:\nstdout %q\nstderr %q", flags, out, errOut)
		}
		states := askLines(t, out)
		if len(states) < 4 {
			t.Fatalf("%v: %d lines:\n%s", flags, len(states), out)
		}
		for i, cv := range states {
			// The line is the canonical mapping of the message, as every --json verb writes it.
			want, err := jsonMarshal.Marshal(cv)
			if err != nil {
				t.Fatal(err)
			}
			if got := strings.Split(strings.TrimSpace(out), "\n")[i]; got != string(want) {
				t.Errorf("%v: line %d is not the proto3 JSON mapping:\n%s\nwant\n%s", flags, i, got, want)
			}
		}
		last := states[len(states)-1]
		if last.State != leylinev1.ConversationState_CONVERSATION_IDLE || len(last.Turns) != 2 || len(last.Turns[1].Tools) != 2 ||
			last.Turns[1].Text != "Tuning to the NOAA station. It is playing now; ley stop ends it." {
			t.Errorf("%v: last line: %v", flags, last)
		}
		if got := newestConversation(t, c); got.ConversationId != last.ConversationId || got.Turns[0].Text != "listen to the weather" {
			t.Errorf("%v: the daemon's conversation: %v", flags, got)
		}
	}
}

var deleteTurn = fakedaemon.AssistantTurn{
	{Ask: "delete_recording", Args: `{"recording":"job_01K"}`, Reason: "deleting a recording asks every time.", ResultApproved: "Deleted job_01K, 12.0 MB freed"},
	{Text: "Done."},
}

// A call that asks is declined without --yes, even with a terminal on stdin and an answer typed
// at it: ask reads nothing and prints nothing but the conversation. --yes starts the conversation
// in AUTO, where the call runs unasked with the daemon's receipt as its result.
func TestAskApproval(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name  string
		o     askRunOpts
		flags []string
		mode  leylinev1.ApprovalMode
		state leylinev1.ToolCallState
	}{
		{"declined on a terminal", askRunOpts{inTTY: true, stdin: "y\n"}, nil, leylinev1.ApprovalMode_APPROVAL_MODE_ASK, leylinev1.ToolCallState_TOOL_CALL_REFUSED},
		{"declined off a terminal", askRunOpts{}, nil, leylinev1.ApprovalMode_APPROVAL_MODE_ASK, leylinev1.ToolCallState_TOOL_CALL_REFUSED},
		{"--yes", askRunOpts{}, []string{"--yes"}, leylinev1.ApprovalMode_APPROVAL_MODE_AUTO, leylinev1.ToolCallState_TOOL_CALL_DONE},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			sock, c := askHarness(t, deleteTurn)
			tc.o.width = 80
			args := append([]string{"ask", "delete the last recording"}, tc.flags...)
			out, errOut, unread, err := runAskLeyStdin(t, sock, tc.o, args...)
			if err != nil || errOut != "" {
				t.Fatalf("err %v, stderr %q", err, errOut)
			}
			if unread != len(tc.o.stdin) {
				t.Errorf("ask read %d bytes of stdin", len(tc.o.stdin)-unread)
			}
			states := askLines(t, out)
			waited := false
			for _, cv := range states {
				waited = waited || cv.State == leylinev1.ConversationState_CONVERSATION_WAITING
			}
			if waited != (tc.mode == leylinev1.ApprovalMode_APPROVAL_MODE_ASK) {
				t.Errorf("a line shows the question: %v, want %v", waited, !waited)
			}
			last := states[len(states)-1]
			call := last.Turns[1].Tools[0]
			if last.State != leylinev1.ConversationState_CONVERSATION_IDLE || last.Mode != tc.mode || call.State != tc.state {
				t.Errorf("last line: %v", last)
			}
			if tc.state == leylinev1.ToolCallState_TOOL_CALL_DONE && call.ResultText != "Deleted job_01K, 12.0 MB freed" {
				t.Errorf("the allowed call's result: %q", call.ResultText)
			}
			if got := newestConversation(t, c); got.GetMode() != tc.mode {
				t.Errorf("the conversation's mode is %v, want %v", got.GetMode(), tc.mode)
			}
		})
	}
}

// --continue carries on the conversation with the newest turn, passing over a newer one that has
// ended, and starts one when none is open.
func TestAskContinue(t *testing.T) {
	t.Parallel()
	sock, c := askHarness(t)
	ctx := t.Context()
	start := func() *leylinev1.Conversation {
		cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
		if err != nil {
			t.Fatal(err)
		}
		return cv
	}
	older, idle, ended := start(), start(), start()
	if _, err := c.Assistant.EndConversation(ctx, &leylinev1.ConversationRef{ConversationId: ended.ConversationId}); err != nil {
		t.Fatal(err)
	}
	out, errOut, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", "--continue", "hello")
	if err != nil || errOut != "" {
		t.Fatalf("stderr %q, err %v", errOut, err)
	}
	if last := lastState(t, out); last.ConversationId != idle.ConversationId || last.Turns[1].Text != "You said: hello" {
		t.Errorf("--continue printed %v, want %s answered", last, idle.ConversationId)
	}
	list, err := c.Assistant.ListConversations(ctx, &leylinev1.ListConversationsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	turns := map[string]int{}
	for _, cv := range list.Conversations {
		turns[cv.ConversationId] = len(cv.Turns)
	}
	if turns[idle.ConversationId] != 2 || turns[older.ConversationId] != 0 || turns[ended.ConversationId] != 0 || len(list.Conversations) != 3 {
		t.Errorf("turns by conversation: %v (want 2 on %s)", turns, idle.ConversationId)
	}
	// With none idle, --continue starts one.
	for _, cv := range []*leylinev1.Conversation{older, idle} {
		if _, err := c.Assistant.EndConversation(ctx, &leylinev1.ConversationRef{ConversationId: cv.ConversationId}); err != nil {
			t.Fatal(err)
		}
	}
	out, _, err = runAskLey(t, sock, askRunOpts{width: 80}, "ask", "--continue", "hello")
	if err != nil {
		t.Fatal(err)
	}
	fresh := newestConversation(t, c)
	if last := lastState(t, out); last.ConversationId != fresh.ConversationId || len(fresh.Turns) != 2 ||
		fresh.ConversationId == older.ConversationId || fresh.ConversationId == idle.ConversationId {
		t.Errorf("the new conversation: printed %v, listed %v", last, fresh)
	}
}

// --continue picks by the last turn, not by when a conversation started: one started earlier and
// used since is the one carried on.
func TestAskContinuePicksTheLastTurn(t *testing.T) {
	t.Parallel()
	sock, c := askHarness(t)
	ctx := t.Context()
	used, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", "--continue", "first"); err != nil {
		t.Fatal(err)
	}
	// The newer conversation got that turn; send the older one a turn of its own, after it.
	newer := newestConversation(t, c)
	if len(newer.Turns) != 2 {
		t.Fatalf("the newest conversation was not continued: %v", newer)
	}
	time.Sleep(2 * time.Millisecond)
	if _, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: used.ConversationId, Text: "from the app"}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the app's turn to end", func() bool {
		list, err := c.Assistant.ListConversations(ctx, &leylinev1.ListConversationsRequest{})
		return err == nil && list.Conversations[1].State == leylinev1.ConversationState_CONVERSATION_IDLE && len(list.Conversations[1].Turns) == 2
	})
	out, _, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", "--continue", "second")
	if err != nil {
		t.Fatal(err)
	}
	if last := lastState(t, out); last.ConversationId != used.ConversationId || last.Turns[3].Text != "You said: second" {
		t.Errorf("--continue printed %v, want %s answered", last, used.ConversationId)
	}
	list, err := c.Assistant.ListConversations(ctx, &leylinev1.ListConversationsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if got := list.Conversations[1]; got.ConversationId != used.ConversationId || len(got.Turns) != 4 {
		t.Errorf("the conversation used last has %d turns: %v", len(got.Turns), got)
	}
}

// --continue --yes on a conversation waiting for an answer sets it to AUTO first, so the daemon
// runs the call it waited on and ask answers no question itself; the request goes once that turn
// is done.
func TestAskContinueAnswersAWaitingConversation(t *testing.T) {
	t.Parallel()
	sock, c := askHarness(t, deleteTurn)
	ctx := t.Context()
	cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: cv.ConversationId, Text: "delete it"}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the question", func() bool {
		return newestConversation(t, c).State == leylinev1.ConversationState_CONVERSATION_WAITING
	})
	out, errOut, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", "--continue", "--yes", "thanks")
	if err != nil || errOut != "" {
		t.Fatalf("err %v, stderr %q", err, errOut)
	}
	if last := lastState(t, out); last.ConversationId != cv.ConversationId || len(last.Turns) != 4 || last.Turns[3].Text != "You said: thanks" {
		t.Errorf("last line: %v", last)
	}
	got := newestConversation(t, c)
	if got.GetMode() != leylinev1.ApprovalMode_APPROVAL_MODE_AUTO {
		t.Errorf("the conversation's mode is %v, want AUTO", got.GetMode())
	}
	call := got.Turns[1].Tools[0]
	if len(got.Turns) != 4 || call.State != leylinev1.ToolCallState_TOOL_CALL_DONE || call.AllowedBy != "" ||
		call.ResultText != "Deleted job_01K, 12.0 MB freed" {
		t.Errorf("conversation: %v", got)
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
	}{
		{"auto, then a run without --yes", leylinev1.ApprovalMode_APPROVAL_MODE_AUTO, nil, leylinev1.ApprovalMode_APPROVAL_MODE_ASK},
		{"ask, then a run with --yes", leylinev1.ApprovalMode_APPROVAL_MODE_ASK, []string{"--yes"}, leylinev1.ApprovalMode_APPROVAL_MODE_AUTO},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			sock, c := askHarness(t)
			if _, err := c.Assistant.StartConversation(t.Context(), &leylinev1.StartConversationRequest{Mode: tc.start}); err != nil {
				t.Fatal(err)
			}
			args := append([]string{"ask", "--continue", "hello"}, tc.flags...)
			out, _, err := runAskLey(t, sock, askRunOpts{width: 80}, args...)
			if err != nil {
				t.Fatal(err)
			}
			if got := lastState(t, out).GetMode(); got != tc.want {
				t.Errorf("the last line's mode: %v, want %v", got, tc.want)
			}
			if got := newestConversation(t, c).GetMode(); got != tc.want {
				t.Errorf("mode after the run: %v, want %v", got, tc.want)
			}
		})
	}
}

// A conversation that fails ends ask with exit 1 and the daemon's words and code, after the
// FAILED state's line.
func TestAskFailed(t *testing.T) {
	t.Parallel()
	sock, _ := askHarness(t, fakedaemon.AssistantTurn{{Text: "Let me look"}, {Fail: "the assistant stopped unexpectedly"}})
	out, _, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", "what is on 2m?")
	if exitCode(err) != 1 || err.Error() != "the assistant stopped unexpectedly [INTERNAL]" {
		t.Fatalf("exit %d: %v", exitCode(err), err)
	}
	if last := lastState(t, out); last.State != leylinev1.ConversationState_CONVERSATION_FAILED || last.Turns[1].Text != "Let me look" {
		t.Errorf("last line: %v", last)
	}
}

// Without a key for the assistant's provider, ask exits 1 with CREDENTIAL_MISSING and the
// command that adds one; with no daemon, it exits 3.
func TestAskNeedsAKeyAndADaemon(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{})
	if _, err := c.Credentials.SetFeatureModel(t.Context(), &leylinev1.FeatureModel{Feature: "assistant", Provider: "anthropic", Model: "m"}); err != nil {
		t.Fatal(err)
	}
	_, _, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", "hello")
	if exitCode(err) != 1 || !strings.Contains(err.Error(), "[CREDENTIAL_MISSING]") || !strings.Contains(err.Error(), "ley ai add anthropic") {
		t.Errorf("exit %d: %v", exitCode(err), err)
	}
	_, _, err = runAskLey(t, testutil.SocketPath(t, "gone.sock"), askRunOpts{width: 80}, "ask", "hello")
	if exitCode(err) != ExitNotRunning {
		t.Errorf("no daemon: exit %d: %v", exitCode(err), err)
	}
}

// A conversation run needs its request on the command line; there is no prompt to type one at.
func TestAskNeedsARequest(t *testing.T) {
	t.Parallel()
	sock, c := askHarness(t)
	for _, args := range [][]string{{"ask"}, {"ask", "--continue"}, {"ask", "  "}} {
		_, _, unread, err := runAskLeyStdin(t, sock, askRunOpts{width: 80, inTTY: true, stdin: "hello\n"}, args...)
		if exitCode(err) != ExitUsage || unread != len("hello\n") {
			t.Errorf("%v: exit %d (%v), %d bytes of stdin unread", args, exitCode(err), err, unread)
		}
	}
	list, err := c.Assistant.ListConversations(t.Context(), &leylinev1.ListConversationsRequest{})
	if err != nil || len(list.GetConversations()) != 0 {
		t.Errorf("a conversation was started: %v %v", list, err)
	}
}

// Ctrl-C during a turn stops it with StopTurn and ask follows the conversation until the turn is
// done, then exits 0 with the conversation IDLE; a second Ctrl-C ends the conversation, exit 130.
func TestAskInterrupt(t *testing.T) {
	t.Parallel()
	slow := fakedaemon.AssistantTurn{{Text: "Scanning"}, {Text: "Scanning the band"}, {Text: "Scanning the band slowly"}}
	for _, presses := range []int{1, 2} {
		sock, c := harness(t, fakedaemon.Options{AssistantScript: []fakedaemon.AssistantTurn{slow}, AssistantStepDelay: 300 * time.Millisecond})
		ctx := t.Context()
		if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: "anthropic", Secret: aiSecret}); err != nil {
			t.Fatal(err)
		}
		var out, errOut syncBuffer
		app := &App{Stdout: &out, Stderr: &errOut, Stdin: strings.NewReader(""), Socket: sock, IsInTTY: func() bool { return false }}
		interrupts := make(chan os.Signal, 2)
		done := make(chan error, 1)
		go func() {
			done <- runAsk(ctx, app, askOptions{provider: "anthropic", model: "m"}, "scan 2m", interrupts)
		}()
		waitFor(t, "the first words", func() bool { return strings.Contains(out.String(), "Scanning") })
		for range presses {
			interrupts <- os.Interrupt
		}
		var err error
		select {
		case err = <-done:
		case <-time.After(5 * time.Second):
			t.Fatal("ask did not return after Ctrl-C")
		}
		cv := newestConversation(t, c)
		if presses == 1 {
			if err != nil || cv.State != leylinev1.ConversationState_CONVERSATION_IDLE || !cv.Turns[1].Done || cv.Turns[1].Text == "Scanning the band slowly" {
				t.Errorf("one Ctrl-C: err %v, conversation %v", err, cv)
			}
			if last := lastState(t, out.String()); last.State != leylinev1.ConversationState_CONVERSATION_IDLE {
				t.Errorf("one Ctrl-C: the last line is %v", last.State)
			}
			if !strings.Contains(errOut.String(), "Stopping the assistant; Ctrl-C again ends the conversation") {
				t.Errorf("stderr:\n%s", errOut.String())
			}
			continue
		}
		if exitCode(err) != ExitInterrupted || cv.State != leylinev1.ConversationState_CONVERSATION_ENDED {
			t.Errorf("two Ctrl-C: exit %d (%v), conversation %v", exitCode(err), err, cv.State)
		}
		if !strings.Contains(errOut.String(), "Ended the conversation.") {
			t.Errorf("stderr:\n%s", errOut.String())
		}
	}
}

// A view tool call, which ask never declares, is answered with an error rather than left waiting.
func TestAskAnswersAViewToolWithAnError(t *testing.T) {
	t.Parallel()
	sock, c := askHarness(t, fakedaemon.AssistantTurn{{View: "show_band", Args: `{"band":"airband"}`}, {Text: "I cannot move a view here."}})
	out, _, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", "show me airband")
	if err != nil {
		t.Fatal(err)
	}
	if call := lastState(t, out).Turns[1].Tools[0]; !call.IsError || call.ResultText != "ley ask has no view" {
		t.Errorf("the last line's call: %v", call)
	}
	call := newestConversation(t, c).Turns[1].Tools[0]
	if !call.IsError || call.ResultText != "ley ask has no view" {
		t.Errorf("call: %v", call)
	}
}

// startConversations has the fake daemon's assistant answer each request in a conversation of its
// own, oldest first, and returns their ids.
func startConversations(t *testing.T, sock string, c *leyline.Client, requests ...string) []string {
	t.Helper()
	var ids []string
	for _, r := range requests {
		if _, errOut, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", r); err != nil {
			t.Fatalf("ley ask %q: %v\n%s", r, err, errOut)
		}
		ids = append(ids, newestConversation(t, c).GetConversationId())
	}
	return ids
}

// --list is a table of the conversations, the one used last first, that fits 40, 80 and 160
// columns: the times go before the id or the first words do.
func TestAskList(t *testing.T) {
	t.Parallel()
	sock, c := askHarness(t)
	ids := startConversations(t, sock, c, "what is on two metres tonight, and is anyone talking on the calling frequency", "tune the weather radio")
	screens := checkScreen(t, sock, "ask", "--list")
	wide := screens[160]
	for _, want := range []string{"ID", "STARTED", "LAST TURN", "STATE", "FIRST WORDS", ids[0], ids[1], "idle", "tune the weather radio"} {
		if !strings.Contains(wide, want) {
			t.Errorf("160 columns lack %q:\n%s", want, wide)
		}
	}
	if strings.Index(wide, ids[1]) > strings.Index(wide, ids[0]) {
		t.Errorf("the conversation used last is not first:\n%s", wide)
	}
	if narrow := screens[40]; strings.Contains(narrow, "STARTED") || !strings.Contains(narrow, "FIRST WORDS") {
		t.Errorf("40 columns keep the times over the first words:\n%s", narrow)
	}

	out, _, err := runLey(t, sock, 80, false, "", "ask", "--list", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var listed leylinev1.ListConversationsResponse
	if err := protojson.Unmarshal([]byte(out), &listed); err != nil || len(listed.GetConversations()) != 2 ||
		listed.GetConversations()[0].GetConversationId() != ids[1] {
		t.Errorf("--list --json: %v (%v)", out, err)
	}
	if _, _, err := runLey(t, sock, 80, false, "", "ask", "--list", "hello"); exitCode(err) != ExitUsage {
		t.Errorf("--list with a request: %v", err)
	}
	if _, _, err := runLey(t, sock, 80, false, "", "ask", "--list", "--continue"); exitCode(err) != ExitUsage {
		t.Errorf("--list with --continue: %v", err)
	}
}

func TestAskListEmpty(t *testing.T) {
	t.Parallel()
	sock, _ := askHarness(t)
	for w, screen := range checkScreen(t, sock, "ask", "--list") {
		if !strings.Contains(strings.Join(strings.Fields(screen), " "), "no conversations; start one with: ley ask") {
			t.Errorf("width %d:\n%s", w, screen)
		}
	}
}

// --delete asks on a terminal and needs --yes off one; it takes the start of an id, and the
// conversation is gone from the list after.
func TestAskDelete(t *testing.T) {
	t.Parallel()
	sock, c := askHarness(t)
	ids := startConversations(t, sock, c, "first", "second")

	_, errOut, err := runLey(t, sock, 80, false, "", "ask", "--delete", ids[0])
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "ley ask --delete "+ids[0]+" --yes") {
		t.Errorf("off a terminal without --yes: %v\n%s", err, errOut)
	}
	_, errOut, err = runAskLey(t, sock, askRunOpts{width: 80, inTTY: true, stdin: "n\n"}, "ask", "--delete", ids[0])
	if err != nil || !strings.Contains(errOut, `Delete the conversation started`) || !strings.Contains(errOut, `"first"? [y/N]`) ||
		!strings.Contains(errOut, "Kept "+ids[0]+"; nothing was deleted.") {
		t.Errorf("answered no: %v\n%s", err, errOut)
	}
	_, errOut, err = runAskLey(t, sock, askRunOpts{width: 80, inTTY: true, stdin: "y\n"}, "ask", "--delete", ids[0])
	if err != nil || !strings.Contains(errOut, "Deleted "+ids[0]) {
		t.Errorf("answered yes: %v\n%s", err, errOut)
	}
	if got := newestConversation(t, c).GetConversationId(); got != ids[1] {
		t.Errorf("the list after the delete starts with %s", got)
	}
	out, errOut, err := runLey(t, sock, 80, false, "", "--json", "ask", "--delete", strings.TrimSuffix(ids[1], ids[1][len(ids[1])-4:]), "--yes")
	if err != nil || strings.TrimSpace(out) != "{}" || !strings.Contains(errOut, "Deleted "+ids[1]) {
		t.Errorf("--yes by prefix: %v\nstdout %q\nstderr %s", err, out, errOut)
	}
	list, err := c.Assistant.ListConversations(t.Context(), &leylinev1.ListConversationsRequest{})
	if err != nil || len(list.GetConversations()) != 0 {
		t.Errorf("left after both deletes: %v %v", list, err)
	}
	if _, _, err := runLey(t, sock, 80, false, "", "ask", "--delete", "conv_nope", "--yes"); exitCode(err) != ExitUsage ||
		!strings.Contains(err.Error(), "no conversation called conv_nope") {
		t.Errorf("an unknown id: %v", err)
	}
}

// ask is hidden, so the help goldens leave it out; its help still says it is the harness, that
// the request is an argument and never read from stdin, that --list and --delete need none, and
// it is plain ASCII, since help goes through --ascii unchanged.
func TestAskHelp(t *testing.T) {
	t.Parallel()
	out, errOut, err := runApp(t, helpApp(), "ask", "--help")
	if err != nil || errOut != "" {
		t.Fatalf("ley ask --help: err=%v stderr=%q", err, errOut)
	}
	for _, want := range []string{"test harness", "as an argument", "never from stdin", "ley ask [request] [flags]", "the Assistant panel in the app"} {
		if !strings.Contains(out, want) {
			t.Errorf("the help lacks %q:\n%s", want, out)
		}
	}
	for _, r := range out {
		if r > 127 {
			t.Errorf("the help holds %q, which --ascii cannot draw:\n%s", r, out)
			break
		}
	}
	root := NewRootCommand(helpApp())
	if cmd, _, err := root.Find([]string{"ask"}); err != nil || !cmd.Hidden {
		t.Errorf("ask is not hidden (err %v)", err)
	}
}
