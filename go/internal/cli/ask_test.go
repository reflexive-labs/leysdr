// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"io"
	"os"
	"strings"
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

// Each tool call is one line on stderr when it starts and the first line of its result beneath
// it when it is done; the turn's text goes on after them on a line of its own.
func TestAskToolCalls(t *testing.T) {
	t.Parallel()
	screens := checkAskScreens(t, []fakedaemon.AssistantTurn{twoToolsTurn}, askRunOpts{}, "ask", "listen to the weather")
	t.Logf("ley ask at 80 columns:\n%s", screens[80])
	want := "Tuning to the NOAA station.\n" +
		"→ tune {\"freq\":\"162.4M\",\"mode\":\"nfm\"}\n" +
		"  Tuned to 162.400 MHz NFM on chan_01K\n" +
		"→ set {\"param\":\"squelch\",\"value\":\"-45\",\"channel\":\"chan_01K\"}\n" +
		"  Squelch -45.0 dBFS on 162.400 MHz\n" +
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
	if strings.Contains(out, "→") || !strings.Contains(errOut, "→ tune") {
		t.Errorf("the calls belong on stderr, the text on stdout\nstdout:\n%s\nstderr:\n%s", out, errOut)
	}
}

var deleteTurn = fakedaemon.AssistantTurn{
	{Ask: "delete_recording", Args: `{"recording":"job_01K"}`, Reason: "deleting a recording asks every time.", ResultApproved: "Deleted job_01K, 12.0 MB freed"},
	{Text: "Done."},
}

// A call that asks is a [y/N] question on a terminal, answered with ResolveAction; without a
// terminal it is declined with a line saying how to allow it, and --yes allows it unasked.
func TestAskApproval(t *testing.T) {
	t.Parallel()
	question := "The assistant wants to delete_recording {\"recording\":\"job_01K\"}: deleting a recording asks every time."
	for _, tc := range []struct {
		name     string
		o        askRunOpts
		flags    []string
		approved bool
		says     []string
	}{
		{
			name: "y on a terminal", o: askRunOpts{inTTY: true, stdin: "y\n"}, approved: true,
			says: []string{question + " Allow? [y/N] y\n", "  Deleted job_01K, 12.0 MB freed"},
		},
		{
			name: "n on a terminal", o: askRunOpts{inTTY: true, stdin: "n\n"},
			says: []string{"Allow? [y/N] ", "  ✗ declined"},
		},
		{
			name: "no terminal", o: askRunOpts{},
			says: []string{question + " Declined: stdin is not a terminal, so nobody can answer.", "Pass --yes to allow what the assistant asks.", "  ✗ declined"},
		},
		{
			name: "--yes", flags: []string{"--yes"}, approved: true,
			says: []string{question + " Allowed by --yes.", "  Deleted job_01K"},
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

// --continue carries on the newest IDLE conversation, passing over a newer one that has ended,
// and starts one when none is idle.
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
	if err != nil || !strings.Contains(errOut, "No idle conversation to continue; starting a new one") {
		t.Fatalf("stderr %q, err %v", errOut, err)
	}
	if n := len(newestConversation(t, c).Turns); n != 2 {
		t.Errorf("the new conversation has %d turns", n)
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
	want := "> Tuning to the weather station.\n> Squelch is at -45 dBFS.\n> \n"
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
	if err != nil || out != "> You said: hi\n> " {
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
