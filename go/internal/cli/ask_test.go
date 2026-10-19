// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"errors"
	"io"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/testutil"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
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
	// inTTY says stdin is a terminal someone can answer on.
	inTTY bool
	stdin string
	// merged writes stdout and stderr to one buffer, in the order a terminal shows them.
	merged bool
}

// runAskLey runs ley against sock as a terminal of o.width would.
func runAskLey(t *testing.T, sock string, o askRunOpts, args ...string) (string, string, error) {
	t.Helper()
	var out, errb bytes.Buffer
	stderr := &errb
	if o.merged {
		stderr = &out
	}
	mode := "--color=never"
	if o.color {
		mode = "--color=always"
	}
	// A terminal echoes what is typed at it; a merged transcript shows the answer where it was
	// typed.
	var stdin io.Reader = strings.NewReader(o.stdin)
	if o.merged && o.inTTY {
		stdin = io.TeeReader(stdin, &out)
	}
	app := &App{
		Stdout: &out, Stderr: stderr, Stdin: stdin,
		IsTTY: func() bool { return true }, IsErrTTY: func() bool { return true }, IsInTTY: func() bool { return o.inTTY },
		TermWidth: func() int { return o.width }, ErrTermWidth: func() int { return o.width },
		// The fake assistant answers at once; a waiting line drawn because the machine running
		// the test was slow would change the transcript.
		askClock: &askClock{now: time.Now, after: func(time.Duration) <-chan time.Time { return nil }},
		LookupEnv: func(k string) (string, bool) {
			if k == "LANG" {
				return "en_US.UTF-8", true
			}
			return "", false
		},
	}
	err := Execute(t.Context(), app, append([]string{"--socket", sock, mode}, args...))
	return out.String(), errb.String(), err
}

// checkAskScreens runs ask on a fresh daemon playing script, at 40, 80 and 160 columns, plain and
// in colour: colour adds ink and nothing else, and no line is wider than the terminal. It returns
// the plain transcript (stderr and stdout merged as a terminal shows them) at each width.
func checkAskScreens(t *testing.T, script []fakedaemon.AssistantTurn, o askRunOpts, args ...string) map[int]string {
	t.Helper()
	screens := map[int]string{}
	for _, w := range []int{40, 80, 160} {
		var got [2]string
		for i, color := range []bool{false, true} {
			sock, _ := askHarness(t, script...)
			run := o
			run.width, run.color, run.merged = w, color, true
			out, _, err := runAskLey(t, sock, run, args...)
			if err != nil {
				t.Fatalf("ley %v at %d (colour %v): %v\n%s", args, w, color, err, out)
			}
			got[i] = out
		}
		if ui.Strip(got[1]) != got[0] {
			t.Errorf("width %d: colour changed the words\nplain:\n%s\ninked, stripped:\n%s", w, got[0], ui.Strip(got[1]))
		}
		for _, line := range strings.Split(strings.TrimRight(got[0], "\n"), "\n") {
			if ui.Visible(line) > w {
				t.Errorf("width %d: %d-column line %q", w, ui.Visible(line), line)
			}
		}
		screens[w] = got[0]
	}
	return screens
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

var weatherTurn = fakedaemon.AssistantTurn{
	{Text: "Tuning"},
	{Text: "Tuning to the weather station."},
}

// A text-only turn streams the assistant's words to stdout, whole once the turn is done, and
// ask exits 0 with the conversation left IDLE.
func TestAskTextOnly(t *testing.T) {
	t.Parallel()
	screens := checkAskScreens(t, []fakedaemon.AssistantTurn{weatherTurn}, askRunOpts{}, "ask", "tune to the weather radio")
	for w, s := range screens {
		if s != "Tuning to the weather station.\n" {
			t.Errorf("width %d: %q", w, s)
		}
	}
	sock, c := askHarness(t, weatherTurn)
	out, errOut, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", "tune to the weather radio")
	if err != nil || out != "Tuning to the weather station.\n" || errOut != "" {
		t.Fatalf("stdout %q, stderr %q, err %v", out, errOut, err)
	}
	cv := newestConversation(t, c)
	if cv.State != leylinev1.ConversationState_CONVERSATION_IDLE || len(cv.Turns) != 2 || cv.Turns[0].Text != "tune to the weather radio" {
		t.Errorf("conversation: %v", cv)
	}
}

var twoToolsTurn = fakedaemon.AssistantTurn{
	{Text: "Tuning to the NOAA station."},
	{Tool: "tune", Args: `{"freq": "162.4M", "mode": "nfm"}`, Result: "Tuned to 162.400 MHz NFM on chan_01K\nsquelch auto"},
	{Tool: "set", Args: `{"param":"squelch","value":"-45","channel":"chan_01K"}`, Result: "Squelch -45.0 dBFS on 162.400 MHz"},
	{Text: "Tuning to the NOAA station. It is playing now; ley stop ends it."},
}

// Each tool call is one line on stderr when it starts, and a call that ran adds nothing more; the
// calls and the text are blocks with a blank line on stderr between them.
func TestAskToolCalls(t *testing.T) {
	t.Parallel()
	screens := checkAskScreens(t, []fakedaemon.AssistantTurn{twoToolsTurn}, askRunOpts{}, "ask", "listen to the weather")
	t.Logf("ley ask at 80 columns:\n%s", screens[80])
	want := "Tuning to the NOAA station.\n\n" +
		"→ tune {\"freq\":\"162.4M\",\"mode\":\"nfm\"}\n" +
		"→ set {\"param\":\"squelch\",\"value\":\"-45\",\"channel\":\"chan_01K\"}\n\n" +
		"It is playing now; ley stop ends it.\n"
	if screens[80] != want {
		t.Errorf("80 columns:\n%s\nwant:\n%s", screens[80], want)
	}
	if !strings.Contains(screens[40], "→ set {\"param\":\"squelch\",\"value\":\"-45\",…\n") {
		t.Errorf("40 columns does not cut the call to the width:\n%s", screens[40])
	}
	sock, _ := askHarness(t, twoToolsTurn)
	out, errOut, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", "listen to the weather")
	if err != nil {
		t.Fatal(err)
	}
	if out != "Tuning to the NOAA station.\nIt is playing now; ley stop ends it.\n" || !strings.Contains(errOut, "→ tune") {
		t.Errorf("the calls belong on stderr, the text on stdout\nstdout:\n%s\nstderr:\n%s", out, errOut)
	}
}

var deleteTurn = fakedaemon.AssistantTurn{
	{Ask: "delete_recording", Args: `{"recording":"job_01K"}`, Reason: "deleting a recording asks every time.", ResultApproved: "Deleted job_01K, 12.0 MB freed"},
	{Text: "Done."},
}

// A call that asks is a [y/N] question on a terminal, answered with ResolveAction; without a
// terminal it is declined with a line saying how to allow it, and --yes allows it unasked. Each
// form is the call on its line, the reason beneath it, and the question or the answer on a line
// of its own.
func TestAskApproval(t *testing.T) {
	t.Parallel()
	question := "→ delete_recording {\"recording\":\"job_01K\"}\n  deleting a recording asks every time.\n"
	for _, tc := range []struct {
		name     string
		o        askRunOpts
		flags    []string
		approved bool
		says     []string
	}{
		{
			name: "y on a terminal", o: askRunOpts{inTTY: true, stdin: "y\n"}, approved: true,
			says: []string{question + "Allow? [y/N] y\n  Deleted job_01K, 12.0 MB freed\n\nDone.\n"},
		},
		{
			name: "n on a terminal", o: askRunOpts{inTTY: true, stdin: "n\n"},
			says: []string{question + "Allow? [y/N] ", "  ✗ declined"},
		},
		{
			name: "no terminal", o: askRunOpts{},
			says: []string{question + "Declined: stdin is not a terminal, so nobody can answer. Pass --yes to allow what the assistant asks.\n  ✗ declined"},
		},
		{
			name: "--yes", flags: []string{"--yes"}, approved: true,
			says: []string{question + "Allowed by --yes.\n  Deleted job_01K, 12.0 MB freed\n\nDone.\n"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			args := append([]string{"ask", "delete the last recording"}, tc.flags...)
			screens := checkAskScreens(t, []fakedaemon.AssistantTurn{deleteTurn}, tc.o, args...)
			if tc.name == "y on a terminal" {
				t.Logf("ley ask at 80 columns:\n%s", screens[80])
			}
			sock, c := askHarness(t, deleteTurn)
			o := tc.o
			o.width, o.merged = 160, true
			out, _, err := runAskLey(t, sock, o, args...)
			if err != nil {
				t.Fatal(err)
			}
			for _, want := range tc.says {
				if !strings.Contains(out, want) {
					t.Errorf("lacks %q:\n%s", want, out)
				}
			}
			call := newestConversation(t, c).Turns[1].Tools[0]
			want := leylinev1.ToolCallState_TOOL_CALL_REFUSED
			if tc.approved {
				want = leylinev1.ToolCallState_TOOL_CALL_DONE
			}
			if call.State != want {
				t.Errorf("the call is %v, want %v", call.State, want)
			}
		})
	}
}

// A question shows every argument of the call it asks about: the call line is wrapped, not cut as
// a plain call line is, since keep past the cut would be allowed unseen. The --yes and declined
// forms show the same card.
func TestAskQuestionShowsEveryArgument(t *testing.T) {
	t.Parallel()
	call0 := `{"frequency":"146.52","take_over":true,"squelch":"auto","mode":"nfm","keep":true,"bandwidth":"12.5k"}`
	turn := fakedaemon.AssistantTurn{
		{Ask: "tune", Args: call0, Reason: "keeping a channel after the conversation asks first.", ResultApproved: "listening to 146.520 MHz NFM"},
		{Text: "Done."},
	}
	for _, tc := range []struct {
		name  string
		o     askRunOpts
		flags []string
		then  string
	}{
		{"y on a terminal", askRunOpts{inTTY: true, stdin: "y\n"}, nil, "Allow? [y/N] y"},
		{"--yes", askRunOpts{}, []string{"--yes"}, "Allowed by --yes."},
		{"no terminal", askRunOpts{}, nil, "Declined: stdin is not a terminal"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			args := append([]string{"ask", "keep 146.52"}, tc.flags...)
			checkAskScreens(t, []fakedaemon.AssistantTurn{turn}, tc.o, args...)
			sock, _ := askHarness(t, turn)
			o := tc.o
			o.width, o.merged = 60, true
			screen, _, err := runAskLey(t, sock, o, args...)
			if err != nil {
				t.Fatal(err)
			}
			call, _, ok := strings.Cut(screen, "\n  keeping a channel")
			if !ok || !strings.Contains(screen, "\n"+tc.then) {
				t.Fatalf("at 60 columns:\n%s", screen)
			}
			joined := ""
			for i, line := range strings.Split(call, "\n") {
				if i > 0 && !strings.HasPrefix(line, "  ") {
					t.Errorf("continuation line %q is not indented", line)
				}
				joined += strings.TrimPrefix(line, "  ")
			}
			if want := "→ tune " + call0; joined != want {
				t.Errorf("the call at 60 columns reads\n%s\nwant every argument of\n%s", call, want)
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
	if err != nil || out != "You said: hello\n" || !strings.Contains(errOut, "Continuing the conversation started") {
		t.Fatalf("stdout %q, stderr %q, err %v", out, errOut, err)
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
	_, errOut, err = runAskLey(t, sock, askRunOpts{width: 80}, "ask", "--continue", "hello")
	if err != nil || !strings.Contains(errOut, "No conversation to continue; starting a new one") {
		t.Fatalf("stderr %q, err %v", errOut, err)
	}
	if n := len(newestConversation(t, c).Turns); n != 2 {
		t.Errorf("the new conversation has %d turns", n)
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
	if err != nil || out != "You said: second\n" {
		t.Fatalf("stdout %q, err %v", out, err)
	}
	list, err := c.Assistant.ListConversations(ctx, &leylinev1.ListConversationsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if got := list.Conversations[1]; got.ConversationId != used.ConversationId || len(got.Turns) != 4 {
		t.Errorf("the conversation used last has %d turns: %v", len(got.Turns), got)
	}
}

// --continue on a conversation waiting for an answer asks its question first, then sends the
// request once the turn is done.
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
	out, _, err := runAskLey(t, sock, askRunOpts{width: 160, merged: true}, "ask", "--continue", "--yes", "thanks")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"which is waiting for an answer", "Allowed by --yes.\n  Deleted job_01K, 12.0 MB freed\n\nDone.\n\nYou said: thanks\n"} {
		if !strings.Contains(out, want) {
			t.Errorf("lacks %q:\n%s", want, out)
		}
	}
	got := newestConversation(t, c)
	if len(got.Turns) != 4 || got.Turns[1].Tools[0].State != leylinev1.ToolCallState_TOOL_CALL_DONE {
		t.Errorf("conversation: %v", got)
	}
}

// renderTurns feeds a turn's states, one text each, to a fresh view and returns stdout and stderr.
func renderTurns(states ...*leylinev1.Turn) (string, string) {
	var out, errb strings.Builder
	app := &App{Stdout: &out, Stderr: &errb}
	v := askView{text: map[string]string{}, calls: map[string]leylinev1.ToolCallState{}}
	for _, t := range states {
		v.render(app, &leylinev1.Conversation{Turns: []*leylinev1.Turn{t}})
	}
	v.breakLine(app)
	return out.String(), errb.String()
}

func assistantTurn(text string, done bool, tools ...*leylinev1.ToolCall) *leylinev1.Turn {
	return &leylinev1.Turn{TurnId: "t2", Role: leylinev1.Role_ROLE_ASSISTANT, Text: text, Done: done, Tools: tools}
}

// A state whose text is a prefix of what is shown prints nothing; a rewrite prints the new text
// whole, once the turn is done, after a dim "(revised)" on stderr.
func TestAskRenderTextRewrites(t *testing.T) {
	out, errOut := renderTurns(assistantTurn("Tuning to 162.4", false), assistantTurn("Tuning", false), assistantTurn("Tuning to 162.4 MHz.", true))
	if out != "Tuning to 162.4 MHz.\n" || errOut != "" {
		t.Errorf("a shorter state: stdout %q, stderr %q", out, errOut)
	}
	out, errOut = renderTurns(assistantTurn("Tuning to 162.4", false), assistantTurn("Scanning instead", false),
		assistantTurn("Scanning instead.", true))
	if out != "Tuning to 162.4\nScanning instead.\n" || errOut != "\n(revised)\n" {
		t.Errorf("a rewrite: stdout %q, stderr %q", out, errOut)
	}
}

// Leading whitespace is dropped from the first text after a tool line only. A call that ran shows
// no result, and a blank line on stderr separates the calls from the text on either side.
func TestAskRenderTextTrimsOnlyAfterATool(t *testing.T) {
	call := &leylinev1.ToolCall{CallId: "c1", Tool: "tune", State: leylinev1.ToolCallState_TOOL_CALL_DONE, ResultText: "Tuned"}
	out, errOut := renderTurns(assistantTurn("Tuned.", false, call), assistantTurn("Tuned. Now listening.", true, call))
	if out != "Tuned.\nNow listening.\n" || errOut != "\n-> tune\n\n" {
		t.Errorf("after a tool: stdout %q, stderr %q", out, errOut)
	}
	out, _ = renderTurns(assistantTurn("Steps:\n", false), assistantTurn("Steps:\n  1. tune", true))
	if out != "Steps:\n  1. tune\n" {
		t.Errorf("an indented line lost its indent: %q", out)
	}
}

// A failed call shows the first line of why under it; text that already ends in a blank line gets
// no second one before the calls.
func TestAskRenderFailedCall(t *testing.T) {
	call := &leylinev1.ToolCall{
		CallId: "c1", Tool: "get_state", State: leylinev1.ToolCallState_TOOL_CALL_DONE, IsError: true,
		ResultText: "the daemon is not running\nstart it with: ley daemon start",
	}
	out, errOut := renderTurns(assistantTurn("Looking.\n\n", false, call), assistantTurn("Looking.\n\nIt is down.", true, call))
	if out != "Looking.\n\nIt is down.\n" || errOut != "-> get_state\n  x the daemon is not running\n\n" {
		t.Errorf("stdout %q, stderr %q", out, errOut)
	}
}

// A call that asked first keeps the first line of its result under it once it is done, the
// daemon's receipt for what the user allowed, whatever states the view saw on the way: the
// worker's own (waiting, running, done) or the end alone in one update. A call that did not ask
// shows none.
func TestAskRenderReceiptForAnAskedCall(t *testing.T) {
	const reason = "deleting a recording asks every time."
	call := func(st leylinev1.ToolCallState, reason string) *leylinev1.ToolCall {
		return &leylinev1.ToolCall{
			CallId: "c1", Tool: "delete_recording", State: st, Reason: reason,
			ResultText: "Deleted job_01K, 12.0 MB freed\nmanifest removed",
		}
	}
	const (
		waiting = leylinev1.ToolCallState_TOOL_CALL_AWAITING_APPROVAL
		running = leylinev1.ToolCallState_TOOL_CALL_RUNNING
		done    = leylinev1.ToolCallState_TOOL_CALL_DONE
	)
	out, errOut := renderTurns(assistantTurn("", false, call(waiting, reason)), assistantTurn("", false, call(running, reason)),
		assistantTurn("", false, call(done, reason)), assistantTurn("Done.", true, call(done, reason)))
	if out != "Done.\n" || errOut != "  Deleted job_01K, 12.0 MB freed\n\n" {
		t.Errorf("waiting, running, done: stdout %q, stderr %q", out, errOut)
	}
	_, errOut = renderTurns(assistantTurn("", false, call(done, reason)), assistantTurn("Done.", true, call(done, reason)))
	if errOut != "-> delete_recording\n  Deleted job_01K, 12.0 MB freed\n\n" {
		t.Errorf("done in one update: stderr %q", errOut)
	}
	_, errOut = renderTurns(assistantTurn("", false, call(running, "")), assistantTurn("", false, call(done, "")),
		assistantTurn("Done.", true, call(done, "")))
	if errOut != "-> delete_recording\n\n" {
		t.Errorf("did not ask: stderr %q", errOut)
	}
}

// A blank line that arrives split across two pieces of text still counts, so no second one is
// added before the calls; and text that opens a turn keeps its indent on stdout.
func TestAskRenderTextBlankAndIndent(t *testing.T) {
	call := &leylinev1.ToolCall{CallId: "c1", Tool: "tune", State: leylinev1.ToolCallState_TOOL_CALL_DONE}
	out, errOut := renderTurns(assistantTurn("Hi\n", false), assistantTurn("Hi\n\n", false), assistantTurn("Hi\n\n", true, call))
	if out != "Hi\n\n" || errOut != "-> tune\n" {
		t.Errorf("a split blank line: stdout %q, stderr %q", out, errOut)
	}
	out, _ = renderTurns(assistantTurn("  ley tune 1\n", true))
	if out != "  ley tune 1\n" {
		t.Errorf("the opening indent was lost: %q", out)
	}
}

// The transcripts in docs/reference/cli.md's `ley ask` section are what ask renders at 80
// columns, so the reference cannot drift from the renderer.
func TestAskReferenceTranscripts(t *testing.T) {
	t.Parallel()
	doc, err := os.ReadFile("../../../docs/reference/cli.md")
	if err != nil {
		t.Fatal(err)
	}
	_, section, ok := strings.Cut(string(doc), "**The assistant**")
	_, block, ok2 := strings.Cut(section, "```\n")
	block, _, ok3 := strings.Cut(block, "```")
	if !ok || !ok2 || !ok3 {
		t.Fatal("docs/reference/cli.md has no `ley ask` section with a transcript block")
	}
	documented := map[string]string{}
	var cmd string
	for _, line := range strings.SplitAfter(block, "\n") {
		if strings.HasPrefix(line, "$ ") {
			cmd = strings.TrimSpace(line)
			continue
		}
		documented[cmd] += line
	}
	for _, tc := range []struct {
		cmd    string
		script fakedaemon.AssistantTurn
		o      askRunOpts
		args   []string
	}{
		{`$ ley ask "listen to the NOAA weather radio"`, twoToolsTurn, askRunOpts{}, []string{"ask", "listen to the NOAA weather radio"}},
		{`$ ley ask "delete the last recording"`, deleteTurn, askRunOpts{inTTY: true, stdin: "y\n"}, []string{"ask", "delete the last recording"}},
		{`$ ley ask "delete the last recording" < /dev/null`, deleteTurn, askRunOpts{}, []string{"ask", "delete the last recording"}},
	} {
		want, ok := documented[tc.cmd]
		if !ok {
			t.Errorf("the reference has no transcript for %s", tc.cmd)
			continue
		}
		got := checkAskScreens(t, []fakedaemon.AssistantTurn{tc.script}, tc.o, tc.args...)[80]
		if strings.TrimRight(want, "\n") != strings.TrimRight(got, "\n") {
			t.Errorf("%s: the reference shows\n%s\nask renders\n%s", tc.cmd, want, got)
		}
	}
	if len(documented) != 3 {
		t.Errorf("the reference has %d transcripts; this test checks 3", len(documented))
	}
}

// --json prints every state the watch delivers as one Conversation per line, unstyled, ending
// with the IDLE one, and no prose.
func TestAskJSON(t *testing.T) {
	t.Parallel()
	sock, _ := askHarness(t, twoToolsTurn)
	out, errOut, err := runAskLey(t, sock, askRunOpts{width: 80, color: true}, "--json", "ask", "listen to the weather")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "\x1b") || errOut != "" {
		t.Errorf("styled or prose output:\nstdout %q\nstderr %q", out, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) < 4 {
		t.Fatalf("%d lines:\n%s", len(lines), out)
	}
	var last leylinev1.Conversation
	for _, l := range lines {
		last.Reset()
		if err := protojson.Unmarshal([]byte(l), &last); err != nil {
			t.Fatalf("not a Conversation (%v): %s", err, l)
		}
	}
	if last.State != leylinev1.ConversationState_CONVERSATION_IDLE || len(last.Turns[1].Tools) != 2 {
		t.Errorf("last line: %v", &last)
	}
}

// A conversation that fails ends ask with exit 1 and the daemon's words and code.
func TestAskFailed(t *testing.T) {
	t.Parallel()
	sock, _ := askHarness(t, fakedaemon.AssistantTurn{{Text: "Let me look"}, {Fail: "the assistant stopped unexpectedly"}})
	out, _, err := runAskLey(t, sock, askRunOpts{width: 80}, "ask", "what is on 2m?")
	if exitCode(err) != 1 || err.Error() != "the assistant stopped unexpectedly [INTERNAL]" {
		t.Fatalf("exit %d: %v", exitCode(err), err)
	}
	if out != "Let me look\n" {
		t.Errorf("stdout %q", out)
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

// With no request, ask reads one per line at a '> ' prompt, runs each to the end of its turn in
// one conversation, and stops at the end of stdin.
func TestAskPromptLoop(t *testing.T) {
	t.Parallel()
	sock, c := askHarness(t, weatherTurn, fakedaemon.AssistantTurn{{Text: "Squelch is at -45 dBFS."}})
	out, _, err := runAskLey(t, sock, askRunOpts{width: 80, merged: true, stdin: "tune to the weather radio\nwhat is the squelch?\n"}, "ask")
	if err != nil {
		t.Fatal(err)
	}
	want := "> Tuning to the weather station.\n\n> Squelch is at -45 dBFS.\n\n> \n"
	if out != want {
		t.Errorf("transcript %q, want %q", out, want)
	}
	cv := newestConversation(t, c)
	if len(cv.Turns) != 4 || cv.Turns[2].Text != "what is the squelch?" {
		t.Errorf("turns: %v", cv.Turns)
	}
	// A blank line ends the loop too.
	sock, _ = askHarness(t)
	out, _, err = runAskLey(t, sock, askRunOpts{width: 80, merged: true, stdin: "hi\n\nnot sent\n"}, "ask")
	if err != nil || out != "> You said: hi\n\n> " {
		t.Errorf("transcript %q, err %v", out, err)
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
		var out syncBuffer
		app := &App{Stdout: &out, Stderr: &out, Stdin: strings.NewReader(""), Socket: sock, IsInTTY: func() bool { return false }}
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
			if !strings.Contains(out.String(), "Stopping the assistant; Ctrl-C again ends the conversation") {
				t.Errorf("transcript:\n%s", out.String())
			}
			continue
		}
		if exitCode(err) != ExitInterrupted || cv.State != leylinev1.ConversationState_CONVERSATION_ENDED {
			t.Errorf("two Ctrl-C: exit %d (%v), conversation %v", exitCode(err), err, cv.State)
		}
		if !strings.Contains(out.String(), "Ended the conversation.") {
			t.Errorf("transcript:\n%s", out.String())
		}
	}
}

// A view tool call, which ask never declares, is answered with an error rather than left waiting.
func TestAskAnswersAViewToolWithAnError(t *testing.T) {
	t.Parallel()
	sock, c := askHarness(t, fakedaemon.AssistantTurn{{View: "show_band", Args: `{"band":"airband"}`}, {Text: "I cannot move a view here."}})
	out, _, err := runAskLey(t, sock, askRunOpts{width: 80, merged: true}, "ask", "show me airband")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "  ✗ ley ask has no view") {
		t.Errorf("transcript:\n%s", out)
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

// stepClock is the waiting line's clock in a test: each timer the line sets arrives on armed, and
// fires when the test says, at the time the test sets. The first prefire timers have fired already
// when the line gets them.
type stepClock struct {
	at       time.Time
	armed    chan stepTimer
	prefired int
}

type stepTimer struct {
	d    time.Duration
	fire chan time.Time
}

func newStepClock() *stepClock {
	return &stepClock{at: time.Unix(1_000_000, 0), armed: make(chan stepTimer)}
}

func (c *stepClock) clock() *askClock {
	return &askClock{
		now: func() time.Time { return c.at },
		after: func(d time.Duration) <-chan time.Time {
			// Buffered, so a timer the line no longer waits on can still be fired.
			fire := make(chan time.Time, 1)
			if c.prefired > 0 {
				c.prefired--
				fire <- c.at
			}
			c.armed <- stepTimer{d, fire}
			return fire
		},
	}
}

// waitRun is a `ley ask` following a turn on a terminal (stdout and stderr merged, as one shows
// them), fed the conversation's states by the test, with the waiting line on a step clock.
type waitRun struct {
	t     *testing.T
	r     *askRun
	out   *bytes.Buffer
	clk   *stepClock
	start time.Time
	done  chan error
	sig   chan os.Signal
}

// startWaitRun follows a turn as turn does, with the wait started first. A state queued sits
// waiting for follow, and so does a first timer that has fired, when prefired is set.
func startWaitRun(t *testing.T, queued *leylinev1.Conversation, prefired bool) *waitRun {
	t.Helper()
	out, clk, sig := &bytes.Buffer{}, newStepClock(), make(chan os.Signal, 1)
	if prefired {
		clk.prefired = 1
	}
	app := &App{
		Stdout: out, Stderr: out, askClock: clk.clock(),
		IsTTY: func() bool { return true }, IsErrTTY: func() bool { return true },
	}
	r := &askRun{
		app: app, ctx: t.Context(), interrupts: sig, answered: map[string]bool{},
		conv:    &leylinev1.Conversation{Seq: 1, State: leylinev1.ConversationState_CONVERSATION_THINKING},
		seen:    1,
		updates: make(chan *leylinev1.Conversation, 1), watchErr: make(chan error, 1),
		view: askView{text: map[string]string{}, calls: map[string]leylinev1.ToolCallState{}},
	}
	r.useWaitLine()
	if queued != nil {
		r.updates <- queued
	}
	r.wait.start()
	w := &waitRun{t: t, r: r, out: out, clk: clk, start: clk.at, done: make(chan error, 1), sig: sig}
	go func() { w.done <- r.follow(1) }()
	return w
}

// next is the timer the line sets next, which must be d long.
func (w *waitRun) next(d time.Duration) stepTimer {
	w.t.Helper()
	tm := <-w.clk.armed
	if tm.d != d {
		w.t.Fatalf("the line set a %v timer, want %v", tm.d, d)
	}
	return tm
}

// fire sets the clock to at after the start and fires tm, then waits for the timer after it.
func (w *waitRun) fire(tm stepTimer, at, next time.Duration) stepTimer {
	w.t.Helper()
	w.clk.at = w.start.Add(at)
	tm.fire <- w.clk.at
	return w.next(next)
}

func (w *waitRun) send(cv *leylinev1.Conversation) {
	w.r.updates <- cv
}

func (w *waitRun) check(what, want string) {
	w.t.Helper()
	if got := w.out.String(); got != want {
		w.t.Fatalf("%s:\n got %q\nwant %q", what, got, want)
	}
}

func thinkingState(seq uint64, st leylinev1.ConversationState, turn *leylinev1.Turn) *leylinev1.Conversation {
	cv := &leylinev1.Conversation{Seq: seq, State: st}
	if turn != nil {
		cv.Turns = []*leylinev1.Turn{turn}
	}
	return cv
}

// The waiting line shows on stderr once nothing has been printed for 300 ms, counts the seconds
// from 3, and is erased before the text on stdout and before a call line, and comes back after the
// call line. It is not drawn while the text is mid-line, which "\r\033[K" would wipe.
func TestAskWaitingLine(t *testing.T) {
	const (
		erase    = "\r\x1b[K"
		thinking = leylinev1.ConversationState_CONVERSATION_THINKING
	)
	w := startWaitRun(t, nil, false)
	tm := w.next(waitDelay)
	w.check("before the delay", "")
	tm = w.fire(tm, 300*time.Millisecond, time.Second)
	want := erase + "thinking..."
	w.check("after the delay", want)
	tm = w.fire(tm, 1300*time.Millisecond, time.Second)
	w.check("a second later", want)
	_ = w.fire(tm, 3300*time.Millisecond, time.Second)
	want += erase + "thinking... 3s"
	w.check("after three seconds", want)

	w.send(thinkingState(2, thinking, assistantTurn("Tuning", false)))
	tm = w.next(waitDelay)
	want += erase + "Tuning"
	w.check("the first text", want)
	_ = w.fire(tm, 3600*time.Millisecond, waitDelay)
	w.check("mid-line", want)

	call := &leylinev1.ToolCall{CallId: "c1", Tool: "tune", State: leylinev1.ToolCallState_TOOL_CALL_RUNNING}
	w.send(thinkingState(3, thinking, assistantTurn("Tuning.\n", false, call)))
	tm = w.next(waitDelay)
	want += ".\n\n-> tune\n"
	w.check("the call line", want)
	_ = w.fire(tm, 4000*time.Millisecond, time.Second)
	want += erase + "thinking..."
	w.check("after the call line", want)

	done := &leylinev1.ToolCall{CallId: "c1", Tool: "tune", State: leylinev1.ToolCallState_TOOL_CALL_DONE}
	w.send(thinkingState(4, leylinev1.ConversationState_CONVERSATION_IDLE, assistantTurn("Tuning.\nTuned.", true, done)))
	if err := <-w.done; err != nil {
		t.Fatal(err)
	}
	want += erase + "\nTuned.\n"
	w.check("the answer", want)
}

// A turn that ends while the line is up, or SIGTERM, leaves no line behind for the prompt or the
// shell.
func TestAskWaitingLineErasedOnExit(t *testing.T) {
	const erase = "\r\x1b[K"
	w := startWaitRun(t, nil, false)
	_ = w.fire(w.next(waitDelay), 300*time.Millisecond, time.Second)
	w.send(thinkingState(2, leylinev1.ConversationState_CONVERSATION_IDLE, nil))
	if err := <-w.done; err != nil {
		t.Fatal(err)
	}
	w.check("a turn that ends with no more words", erase+"thinking..."+erase)

	w = startWaitRun(t, nil, false)
	_ = w.fire(w.next(waitDelay), 300*time.Millisecond, time.Second)
	w.sig <- syscall.SIGTERM
	if err := <-w.done; !errors.Is(err, errTerminated) {
		t.Fatalf("SIGTERM: %v", err)
	}
	w.check("SIGTERM", erase+"thinking..."+erase)
}

// With stderr off a terminal, or under --json, there is no waiting line and nothing is routed
// through it.
func TestAskWaitingLineOnlyOnATerminal(t *testing.T) {
	for _, app := range []*App{
		{IsErrTTY: func() bool { return false }, IsTTY: func() bool { return true }},
		{IsErrTTY: func() bool { return true }, JSON: true},
		{},
	} {
		app.Stdout, app.Stderr = io.Discard, io.Discard
		app.askClock = &askClock{now: time.Now, after: func(time.Duration) <-chan time.Time {
			t.Error("the line set a timer")
			return nil
		}}
		r := &askRun{app: app}
		r.useWaitLine()
		if r.wait != nil || r.app != app || r.wait.timer() != nil {
			t.Errorf("tty %v, json %v: the waiting line is on", app.IsErrTTY != nil && app.IsErrTTY(), app.JSON)
		}
	}
}

// A state already queued when the timer fires is printed, and the line is not drawn for the one
// frame before that state would erase it. select picks at random, so the race is run many times.
func TestAskWaitingLinePrefersAQueuedState(t *testing.T) {
	for range 50 {
		w := startWaitRun(t, thinkingState(2, leylinev1.ConversationState_CONVERSATION_THINKING, assistantTurn("Tuning\n", false)), true)
		w.next(waitDelay)
		w.next(waitDelay)
		w.check("a state queued behind the timer", "Tuning\n")
		w.send(thinkingState(3, leylinev1.ConversationState_CONVERSATION_IDLE, assistantTurn("Tuning\n", true)))
		if err := <-w.done; err != nil {
			t.Fatal(err)
		}
	}
}

// The wait counts from before the request is sent, so the count includes the send's round trip:
// the waiting line first reads the clock while the conversation has no turns yet.
func TestAskWaitingLineCountsFromTheRequest(t *testing.T) {
	_, c := askHarness(t)
	clk := newStepClock()
	go func() {
		for range clk.armed { //nolint:revive // the timers never fire; the turn ends on its own
		}
	}()
	defer close(clk.armed)
	ck := clk.clock()
	turns := -1
	now := ck.now
	ck.now = func() time.Time {
		if turns < 0 {
			turns = len(newestConversation(t, c).GetTurns())
		}
		return now()
	}
	app := &App{Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}, IsErrTTY: func() bool { return true }, askClock: ck}
	r := &askRun{
		app: app, ctx: t.Context(), c: c, interrupts: make(chan os.Signal), answered: map[string]bool{},
		view: askView{text: map[string]string{}, calls: map[string]leylinev1.ToolCallState{}},
	}
	r.useWaitLine()
	if err := r.open(); err != nil {
		t.Fatal(err)
	}
	if err := r.watch(t.Context()); err != nil {
		t.Fatal(err)
	}
	if err := r.turn("hi"); err != nil {
		t.Fatal(err)
	}
	if turns != 0 {
		t.Errorf("the wait started with %d turns in the conversation, after the request was sent", turns)
	}
}
