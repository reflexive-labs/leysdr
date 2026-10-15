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
	for _, want := range []string{"which is waiting for an answer", "Allowed by --yes.", "  Deleted job_01K", "Done.\nYou said: thanks\n"} {
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
	if out != "Tuning to 162.4\nScanning instead.\n" || errOut != "(revised)\n" {
		t.Errorf("a rewrite: stdout %q, stderr %q", out, errOut)
	}
}

// Leading whitespace is dropped from the first text after a tool line only.
func TestAskRenderTextTrimsOnlyAfterATool(t *testing.T) {
	call := &leylinev1.ToolCall{CallId: "c1", Tool: "tune", State: leylinev1.ToolCallState_TOOL_CALL_DONE, ResultText: "Tuned"}
	out, errOut := renderTurns(assistantTurn("Tuned.", false, call), assistantTurn("Tuned. Now listening.", true, call))
	if out != "Tuned.\nNow listening.\n" || errOut != "-> tune\n  Tuned\n" {
		t.Errorf("after a tool: stdout %q, stderr %q", out, errOut)
	}
	out, _ = renderTurns(assistantTurn("Steps:\n", false), assistantTurn("Steps:\n  1. tune", true))
	if out != "Steps:\n  1. tune\n" {
		t.Errorf("an indented line lost its indent: %q", out)
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
