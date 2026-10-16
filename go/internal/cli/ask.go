// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/internal/words"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

type askOptions struct {
	yes      bool
	cont     bool
	provider string
	model    string
	list     bool
	// remove is --delete's conversation id or id prefix.
	remove string
}

// newAskCommand builds `ley ask`: a request to the assistant, whose conversation is daemon state
// (proto/leyline/v1/ai.proto, "Assistant"). ask renders the conversation the daemon sends and
// answers what the assistant asks; the assistant itself runs in a worker the daemon starts.
func newAskCommand(app *App) *cobra.Command {
	var o askOptions
	cmd := &cobra.Command{
		Use:   "ask [request]",
		Short: "Ask the assistant to run the radio for you",
		Long: `ask hands a request to the assistant, Leyline's own agent running on your
provider key, and prints its answer as it arrives on stdout, with each tool
it calls as one line on stderr and the error beneath it when a call fails.

Reading the radio's state, and the tuning, setting, stopping, scanning and
recording you ask for, run at once and are reported. Taking over a radio
someone else is using, deleting a recording, keeping a job, adding a webhook
or several bookmarks, and paid transcription ask first with a [y/N] question
on stderr; --yes allows all of them, and with no terminal to answer on and
no --yes they are declined.

With no request, ask reads one request per line at a '> ' prompt until a
blank line or Ctrl-D. The conversation stays in the daemon after ask exits,
which keeps it on disk across restarts: --continue carries on the newest
idle one, whether ask or the app started it, and starts a new one when there
is none.

Ctrl-C stops the assistant's turn and keeps the conversation; a second
Ctrl-C, or one at the prompt, ends the conversation. SIGTERM leaves the
conversation as it is. An ended conversation can still be listed and read.

--list prints the conversations the daemon keeps, newest first: the id, when
each started and was last used, its state and the first words asked.
--delete removes one and its files, by id or the start of one; on a terminal
it asks first, and --yes is required when stdin is not a terminal. The
daemon keeps the newest 100 and drops any unused for 90 days.

The assistant calls the provider and model chosen with 'ley ai use
assistant'; --provider and --model choose others for a new conversation.

--json prints every state of the conversation as it changes, one
Conversation per line (NDJSON), and no prose; with --list it prints one
ListConversationsResponse, and with --delete the reply, which is empty.`,
		Example: `  ley ask "tune to the NOAA weather radio"
  ley ask                                    # a prompt, one request per line
  ley ask --continue "now record it for ten minutes"
  ley ask --yes "delete yesterday's recordings"   # allow what it asks
  ley ask --json "what is on 2m?" | jq -r .state
  ley ask --list
  ley ask --delete conv_01K... --yes`,
		GroupID: GroupListening,
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			request := ""
			if len(args) == 1 {
				if request = strings.TrimSpace(args[0]); request == "" {
					return usageErrorf("the request is empty; say what you want, such as: ley ask \"tune to 146.52\"")
				}
			}
			switch {
			case o.list && cmd.Flags().Changed("delete"):
				return usageErrorf("--list and --delete are separate runs of ley ask; give one")
			case (o.list || cmd.Flags().Changed("delete")) && o.cont:
				return usageErrorf("--continue carries on a conversation, which --list and --delete do not; give one")
			case o.list && len(args) == 1:
				return usageErrorf("--list takes no request; run ley ask --list on its own")
			case o.list:
				return runAskList(cmd.Context(), app)
			case cmd.Flags().Changed("delete") && len(args) == 1:
				return usageErrorf("--delete takes no request; run ley ask --delete %s on its own", o.remove)
			case cmd.Flags().Changed("delete"):
				return runAskDelete(cmd.Context(), app, o.remove, o.yes)
			}
			interrupts := make(chan os.Signal, 2)
			signal.Notify(interrupts, os.Interrupt, syscall.SIGTERM)
			defer signal.Stop(interrupts)
			return runAsk(cmd.Context(), app, o, request, interrupts)
		},
	}
	cmd.Flags().BoolVarP(&o.yes, "yes", "y", false, "allow everything the assistant asks to do, and --delete, without a question")
	cmd.Flags().BoolVar(&o.cont, "continue", false, "carry on the newest idle conversation, from before a restart too, instead of starting one")
	cmd.Flags().BoolVar(&o.list, "list", false, "list the conversations the daemon keeps, newest first")
	cmd.Flags().StringVar(&o.remove, "delete", "", "delete a conversation and its files, by `id` or the start of one")
	cmd.Flags().StringVar(&o.provider, "provider", "", "the provider a new conversation calls (default: ley ai use assistant's)")
	cmd.Flags().StringVar(&o.model, "model", "", "the model a new conversation calls (default: ley ai use assistant's)")
	return cmd
}

// askRun is one `ley ask`: the conversation it follows, what it has printed of it, and where the
// answers to the assistant's questions come from.
type askRun struct {
	app        *App
	ctx        context.Context
	c          *leyline.Client
	o          askOptions
	interrupts <-chan os.Signal
	conv       *leylinev1.Conversation
	// updates carries every state the watch delivers; watchErr its end.
	updates  chan *leylinev1.Conversation
	watchErr chan error
	// seen is the newest seq handled, so a state that arrives twice is handled once.
	seen uint64
	// stdin reads a line each time want is sent on, and sends it on lines; lines is closed at
	// EOF. A line is read only when one is asked for, so nothing typed ahead is taken early.
	want     chan struct{}
	lines    chan string
	asked    bool
	answered map[string]bool
	view     askView
}

// errInterrupted reports a Ctrl-C that arrived while ask waited on stdin.
var errInterrupted = errors.New("interrupted")

// errTerminated reports SIGTERM: ask leaves at once and the conversation stays as it is.
var errTerminated = &ExitError{Code: ExitInterrupted}

// runAsk opens the conversation, then sends the request and follows the turn, or runs the prompt
// loop when there is no request. interrupts delivers Ctrl-C (and SIGTERM); a test sends on it.
func runAsk(ctx context.Context, app *App, o askOptions, request string, interrupts <-chan os.Signal) error {
	// Ctrl-C cancels the command's context as well as reaching interrupts, and the first one
	// only stops the turn, so the calls run on a context the signal does not end.
	base := context.WithoutCancel(ctx)
	c, err := app.dial(base)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	r := &askRun{
		app: app, ctx: base, c: c, o: o, interrupts: interrupts, answered: map[string]bool{},
		view: askView{text: map[string]string{}, calls: map[string]leylinev1.ToolCallState{}},
	}
	if err := r.open(); err != nil {
		return err
	}
	wctx, stopWatch := context.WithCancel(base)
	defer stopWatch()
	if err := r.watch(wctx); err != nil {
		return app.notRunning(err)
	}
	// A conversation --continue found mid-turn is followed to the end of that turn, answering
	// what it waits for, before anything is sent.
	if st := r.conv.GetState(); st != leylinev1.ConversationState_CONVERSATION_IDLE {
		if err := r.follow(r.conv.GetSeq()); err != nil {
			return err
		}
	}
	if request != "" {
		r.view.endTurn(app)
		return r.turn(request)
	}
	return r.promptLoop()
}

// open finds the conversation to carry on (--continue) or starts one, and marks what it already
// holds as shown, so only what happens from here is printed.
func (r *askRun) open() error {
	if r.o.cont {
		list, err := r.c.Assistant.ListConversations(r.ctx, &leylinev1.ListConversationsRequest{})
		if err != nil {
			return r.app.notRunning(err)
		}
		r.conv = newestOpenConversation(list.GetConversations())
		if !r.app.JSON {
			fmt.Fprintln(r.app.Stderr, r.app.ErrStyle.Muted(continuingLine(r.conv)))
		}
	}
	if r.conv == nil {
		cv, err := r.c.Assistant.StartConversation(r.ctx, &leylinev1.StartConversationRequest{Provider: r.o.provider, Model: r.o.model})
		if err != nil {
			return r.app.notRunning(err)
		}
		r.conv = cv
	}
	r.seen = r.conv.GetSeq()
	r.view.adopt(r.conv)
	return nil
}

// newestOpenConversation is the conversation --continue carries on: of those not ended or failed,
// the one whose last turn is newest, then the one started last. The daemon's listing order is not
// relied on, since a conversation started long ago may be the one in use. nil when there is none.
func newestOpenConversation(list []*leylinev1.Conversation) *leylinev1.Conversation {
	var best *leylinev1.Conversation
	for _, cv := range list {
		switch cv.GetState() {
		case leylinev1.ConversationState_CONVERSATION_IDLE, leylinev1.ConversationState_CONVERSATION_THINKING,
			leylinev1.ConversationState_CONVERSATION_WAITING:
		default:
			continue
		}
		if best == nil || cv.GetLastTurnAtNs() > best.GetLastTurnAtNs() ||
			(cv.GetLastTurnAtNs() == best.GetLastTurnAtNs() && cv.GetStartedAtNs() > best.GetStartedAtNs()) {
			best = cv
		}
	}
	return best
}

// continuingLine says which conversation --continue carries on, and what it waits for first.
func continuingLine(cv *leylinev1.Conversation) string {
	if cv == nil {
		return "No conversation to continue; starting a new one"
	}
	line := fmt.Sprintf("Continuing the conversation started %s (%s)", recordingClock(cv.GetStartedAtNs()),
		words.Count(len(cv.GetTurns()), "turn"))
	switch cv.GetState() {
	case leylinev1.ConversationState_CONVERSATION_WAITING:
		line += ", which is waiting for an answer"
	case leylinev1.ConversationState_CONVERSATION_THINKING:
		line += "; the assistant's turn finishes first"
	}
	return line
}

// watch follows the conversation from the state open found, for the rest of the run.
func (r *askRun) watch(ctx context.Context) error {
	stream, err := r.c.Assistant.WatchConversation(ctx, &leylinev1.WatchConversationRequest{
		ConversationId: r.conv.GetConversationId(), SinceSeq: r.conv.GetSeq(),
	})
	if err != nil {
		return err
	}
	r.updates, r.watchErr = make(chan *leylinev1.Conversation, 64), make(chan error, 1)
	go func() {
		for {
			cv, err := stream.Recv()
			if err != nil {
				r.watchErr <- err
				return
			}
			select {
			case r.updates <- cv:
			case <-ctx.Done():
				return
			}
		}
	}()
	return nil
}

// promptLoop reads a request a line at a time and runs each, until a blank line or the end of
// stdin. Ctrl-C at the prompt ends the conversation.
func (r *askRun) promptLoop() error {
	for {
		r.view.endTurn(r.app)
		fmt.Fprint(r.app.Stderr, r.app.ErrStyle.Label(">")+" ")
		line, err := r.readLine()
		if errors.Is(err, errInterrupted) {
			fmt.Fprintln(r.app.Stderr)
			return r.end()
		}
		if err != nil {
			return err
		}
		if line == nil || strings.TrimSpace(*line) == "" {
			if line == nil {
				// Ctrl-D leaves the cursor after the prompt.
				fmt.Fprintln(r.app.Stderr)
			}
			return nil
		}
		if err := r.turn(strings.TrimSpace(*line)); err != nil {
			return err
		}
	}
}

// turn sends one request and follows the conversation until the assistant's turn is done.
func (r *askRun) turn(request string) error {
	sent, err := r.c.Assistant.SendMessage(r.ctx, &leylinev1.SendMessageRequest{ConversationId: r.conv.GetConversationId(), Text: request})
	if err != nil {
		return r.app.notRunning(err)
	}
	r.view.adopt(sent)
	return r.follow(sent.GetSeq())
}

// follow prints the conversation and answers what it asks until the assistant's turn is done in
// a state newer than seq after.
func (r *askRun) follow(after uint64) error {
	stops := 0
	if r.conv.GetState() == leylinev1.ConversationState_CONVERSATION_WAITING {
		if err := r.answer(r.conv.GetPending()); errors.Is(err, errInterrupted) {
			stops++
			if err := r.interrupt(stops); err != nil {
				return err
			}
		} else if err != nil {
			return err
		}
	}
	for {
		// A Ctrl-C already pressed is handled before anything else arrives, so a second one is
		// not lost behind the states the first one caused.
		select {
		case sig := <-r.interrupts:
			if sig == syscall.SIGTERM {
				return errTerminated
			}
			stops++
			if err := r.interrupt(stops); err != nil {
				return err
			}
			continue
		default:
		}
		select {
		case cv := <-r.updates:
			done, err := r.handle(cv, after)
			if errors.Is(err, errInterrupted) {
				stops++
				if err := r.interrupt(stops); err != nil {
					return err
				}
				continue
			}
			if done || err != nil {
				return err
			}
		case err := <-r.watchErr:
			// The stream ends after the state that ended the conversation, which may still be
			// queued behind it.
			for {
				select {
				case cv := <-r.updates:
					if done, herr := r.handle(cv, after); done || herr != nil {
						return herr
					}
					continue
				default:
				}
				return r.watchEnded(err)
			}
		case sig := <-r.interrupts:
			if sig == syscall.SIGTERM {
				return errTerminated
			}
			stops++
			if err := r.interrupt(stops); err != nil {
				return err
			}
		}
	}
}

// interrupt is Ctrl-C during a turn: the first stops the turn, and ask goes on following the
// conversation until the daemon says the turn is done; the second ends the conversation.
func (r *askRun) interrupt(stops int) error {
	if stops > 1 {
		return r.end()
	}
	if terminalConversation(r.conv) {
		// The daemon has ended it already; its last state, on its way, ends the run.
		return nil
	}
	r.view.group(r.app, askTrace)
	fmt.Fprintln(r.app.Stderr, r.app.ErrStyle.Muted("Stopping the assistant; Ctrl-C again ends the conversation"))
	if _, err := r.c.Assistant.StopTurn(r.ctx, &leylinev1.ConversationRef{ConversationId: r.conv.GetConversationId()}); err != nil {
		return r.app.notRunning(err)
	}
	return nil
}

func terminalConversation(cv *leylinev1.Conversation) bool {
	st := cv.GetState()
	return st == leylinev1.ConversationState_CONVERSATION_ENDED || st == leylinev1.ConversationState_CONVERSATION_FAILED
}

// end ends the conversation and leaves with the interrupted status.
func (r *askRun) end() error {
	r.view.breakLine(r.app)
	if terminalConversation(r.conv) {
		return &ExitError{Code: ExitInterrupted}
	}
	if _, err := r.c.Assistant.EndConversation(r.ctx, &leylinev1.ConversationRef{ConversationId: r.conv.GetConversationId()}); err != nil {
		return r.app.notRunning(err)
	}
	fmt.Fprintln(r.app.Stderr, "Ended the conversation.")
	return &ExitError{Code: ExitInterrupted}
}

// handle prints one state of the conversation and answers what it asks, and reports whether the
// turn sent at seq sent is over.
func (r *askRun) handle(cv *leylinev1.Conversation, sent uint64) (bool, error) {
	if cv.GetSeq() <= r.seen {
		return false, nil
	}
	r.seen, r.conv = cv.GetSeq(), cv
	if r.app.JSON {
		if err := r.app.printJSON(cv); err != nil {
			return false, err
		}
	} else {
		r.view.render(r.app, cv)
	}
	switch cv.GetState() {
	case leylinev1.ConversationState_CONVERSATION_WAITING:
		return false, r.answer(cv.GetPending())
	case leylinev1.ConversationState_CONVERSATION_IDLE:
		if cv.GetSeq() <= sent {
			return false, nil
		}
		r.view.breakLine(r.app)
		return true, nil
	case leylinev1.ConversationState_CONVERSATION_FAILED:
		r.view.breakLine(r.app)
		e := cv.GetError()
		msg := e.GetMessage()
		if msg == "" {
			msg = "the assistant failed"
		}
		if e.GetCode() != "" {
			msg += " [" + e.GetCode() + "]"
		}
		return true, &ExitError{Code: 1, Message: msg}
	case leylinev1.ConversationState_CONVERSATION_ENDED:
		r.view.breakLine(r.app)
		return true, &ExitError{Code: 1, Message: "the conversation ended before the assistant finished its turn; start another with: ley ask"}
	}
	return false, nil
}

// watchEnded is the watch closing while a turn is under way, which only a daemon going away does.
func (r *askRun) watchEnded(err error) error {
	r.view.breakLine(r.app)
	if err == nil || errors.Is(err, io.EOF) {
		return &ExitError{Code: 1, Message: "the daemon stopped sending the conversation before the assistant finished; see where it stands with: ley ask --continue"}
	}
	return r.app.notRunning(err)
}

// answer settles a pending call: a view tool is answered with an error, since ask has no view;
// an action is allowed by --yes, asked about on a terminal, and declined without one.
func (r *askRun) answer(p *leylinev1.PendingAction) error {
	if p == nil || r.answered[p.GetCallId()] {
		return nil
	}
	r.answered[p.GetCallId()] = true
	ref := r.conv.GetConversationId()
	if p.GetViewTool() {
		_, err := r.c.Assistant.AnswerViewTool(r.ctx, &leylinev1.AnswerViewToolRequest{
			ConversationId: ref, CallId: p.GetCallId(), ResultText: "ley ask has no view", IsError: true,
		})
		return r.settled(err)
	}
	r.view.group(r.app, askTrace)
	s := r.app.ErrStyle
	what := "The assistant wants to " + strings.TrimSpace(p.GetTool()+" "+compactArgs(p.GetArgumentsJson()))
	if reason := strings.TrimRight(strings.TrimSpace(p.GetReason()), "."); reason != "" {
		what += ": " + reason
	}
	approve := false
	switch {
	case r.o.yes:
		approve = true
		if !r.app.JSON {
			fmt.Fprintln(r.app.Stderr, strings.Join(wrapWords(what+". "+s.Ok("Allowed")+" by --yes.", s.Width), "\n"))
		}
	case !r.app.IsInTTY():
		fmt.Fprintln(r.app.Stderr, strings.Join(wrapWords(what+". "+s.Warn("Declined")+
			": stdin is not a terminal, so nobody can answer. Pass --yes to allow what the assistant asks.", s.Width), "\n"))
	default:
		fmt.Fprint(r.app.Stderr, strings.Join(wrapWords(what+". Allow? [y/N]", max(s.Width-len(" yes"), 0)), "\n")+" ")
		line, err := r.readLine()
		if err != nil {
			// The cursor is still after the question.
			fmt.Fprintln(r.app.Stderr)
			return err
		}
		if line == nil {
			fmt.Fprintln(r.app.Stderr)
		}
		if line != nil {
			a := strings.ToLower(strings.TrimSpace(*line))
			approve = a == "y" || a == "yes"
		}
	}
	_, err := r.c.Assistant.ResolveAction(r.ctx, &leylinev1.ResolveActionRequest{ConversationId: ref, CallId: p.GetCallId(), Approve: approve})
	return r.settled(err)
}

// settled passes an answer's error on, unless another client answered first: the conversation
// has moved on and the next state shows how.
func (r *askRun) settled(err error) error {
	if leyline.Code(err) == leyline.CodeFailedPrecondition {
		return nil
	}
	return r.app.notRunning(err)
}

// readLine is the next line of stdin, nil at its end. Ctrl-C while it waits is errInterrupted.
func (r *askRun) readLine() (*string, error) {
	if r.lines == nil {
		r.want, r.lines = make(chan struct{}), make(chan string)
		go func(in *bufio.Reader, want <-chan struct{}, out chan<- string) {
			defer close(out)
			for range want {
				line, err := in.ReadString('\n')
				if line != "" || err == nil {
					out <- strings.TrimRight(line, "\r\n")
				}
				if err != nil {
					return
				}
			}
		}(bufio.NewReader(r.app.Stdin), r.want, r.lines)
	}
	// A read interrupted by Ctrl-C is still under way, and its line is the next one.
	if !r.asked {
		select {
		case r.want <- struct{}{}:
			r.asked = true
		case line, ok := <-r.lines:
			// The reader has ended; only its close is left to receive.
			if !ok {
				return nil, nil
			}
			return &line, nil
		}
	}
	select {
	case line, ok := <-r.lines:
		r.asked = false
		if !ok {
			return nil, nil
		}
		return &line, nil
	case sig := <-r.interrupts:
		if sig == syscall.SIGTERM {
			return nil, errTerminated
		}
		return nil, errInterrupted
	}
}

// compactArgs is a call's arguments on one line: compact JSON, or nothing for none.
func compactArgs(args string) string {
	var b bytes.Buffer
	if err := json.Compact(&b, []byte(args)); err != nil {
		return strings.Join(strings.Fields(args), " ")
	}
	if s := b.String(); s != "{}" && s != "null" {
		return s
	}
	return ""
}

// askView is what ask has printed of the conversation: each assistant turn's text so far and the
// state each tool call was last shown in. The text goes to stdout and the calls to stderr, so a
// line of text is ended before a call is printed.
//
// The screen is in blocks: the assistant's text is one kind, and the trace (the calls, the
// questions, ask's own notes) the other. A blank line on stderr goes between two blocks of
// different kinds and between a turn and the next prompt, so stdout keeps only the assistant's
// words (docs/dev/cli-style.md, "Blank lines group").
type askView struct {
	text  map[string]string
	calls map[string]leylinev1.ToolCallState
	// revised holds the turns whose text the worker rewrote rather than added to; the new text
	// is printed whole once the turn is done.
	revised map[string]bool
	midLine bool
	// last is the kind of block printed last; askNone at the start of a turn.
	last askBlock
	// blankEnd is set when the text printed last ends in a blank line of its own, so no second
	// one is added after it.
	blankEnd bool
}

// askBlock is a kind of block on ask's screen.
type askBlock int

const (
	askNone askBlock = iota
	askText
	askTrace
)

// adopt marks everything in cv as shown: what was said before this run, and the user's turns.
func (v *askView) adopt(cv *leylinev1.Conversation) {
	for _, t := range cv.GetTurns() {
		v.text[t.GetTurnId()] = t.GetText()
		for _, c := range t.GetTools() {
			v.calls[c.GetCallId()] = c.GetState()
		}
	}
}

// breakLine ends a line of the assistant's text that is still open.
func (v *askView) breakLine(app *App) {
	if v.midLine {
		fmt.Fprintln(app.Stdout)
		v.midLine = false
	}
}

// separate ends the open line and leaves a blank one on stderr, unless nothing has been printed
// since the last separation or the text already ends in one.
func (v *askView) separate(app *App) {
	v.breakLine(app)
	if v.last != askNone && (v.last != askText || !v.blankEnd) {
		fmt.Fprintln(app.Stderr)
	}
}

// endTurn leaves a blank line after a turn that printed anything, before the next prompt or
// request.
func (v *askView) endTurn(app *App) {
	v.separate(app)
	v.last = askNone
}

// group starts a block of kind b, after a blank line when the block before it is of the other
// kind.
func (v *askView) group(app *App, b askBlock) {
	if v.last != b {
		v.separate(app)
	}
	v.breakLine(app)
	v.last = b
}

// render prints what cv adds to what has been shown: the new end of each assistant turn's text,
// and each tool call as it starts and as it finishes.
func (v *askView) render(app *App, cv *leylinev1.Conversation) {
	for _, t := range cv.GetTurns() {
		if t.GetRole() != leylinev1.Role_ROLE_ASSISTANT {
			continue
		}
		v.renderText(app, t)
		for _, c := range t.GetTools() {
			v.renderCall(app, c)
		}
	}
}

func (v *askView) renderText(app *App, t *leylinev1.Turn) {
	id, was, now := t.GetTurnId(), v.text[t.GetTurnId()], t.GetText()
	switch {
	case v.revised[id]:
		if !t.GetDone() {
			return
		}
		// The rewritten text, whole, once the worker has finished it, directly under its note.
		delete(v.revised, id)
		v.text[id] = now
		v.group(app, askTrace)
		fmt.Fprintln(app.Stderr, app.ErrStyle.Muted("(revised)"))
		v.last = askNone
		v.write(app, now)
		return
	case strings.HasPrefix(was, now):
		// Nothing new, or a shorter state of what is already on the screen.
		return
	case !strings.HasPrefix(now, was):
		// The worker rewrote the text rather than adding to it. Text on a terminal cannot be
		// taken back, so the new version waits for the end of the turn.
		if v.revised == nil {
			v.revised = map[string]bool{}
		}
		v.revised[id] = true
		v.renderText(app, t)
		return
	}
	v.text[id] = now
	v.write(app, strings.TrimPrefix(now, was))
}

// write prints text on stdout. Text that starts a block loses its leading whitespace, since the
// block starts a line of its own.
func (v *askView) write(app *App, add string) {
	if v.last != askText {
		if add = strings.TrimLeft(add, " \n"); add == "" {
			return
		}
		v.group(app, askText)
	}
	if add == "" {
		return
	}
	fmt.Fprint(app.Stdout, add)
	v.midLine = !strings.HasSuffix(add, "\n")
	v.blankEnd = strings.HasSuffix(add, "\n\n")
}

// renderCall prints a call as one muted line when it starts, and beneath it why a call failed, or
// that it was declined. A call that ran is not followed by its result: the assistant's text
// reports it, and no one line of a verb's output stands for the rest (get_state's first line is
// the daemon's version, tune's the mode it chose, a listing's its header).
func (v *askView) renderCall(app *App, c *leylinev1.ToolCall) {
	was, seen := v.calls[c.GetCallId()]
	now := c.GetState()
	if seen && was == now {
		return
	}
	v.calls[c.GetCallId()] = now
	s := app.ErrStyle
	g := s.Glyphs()
	line := func(text string) {
		v.group(app, askTrace)
		fmt.Fprintln(app.Stderr, text)
	}
	switch now {
	case leylinev1.ToolCallState_TOOL_CALL_AWAITING_APPROVAL, leylinev1.ToolCallState_TOOL_CALL_AWAITING_CLIENT:
		// The question names the call; answer prints it.
		return
	}
	if !seen {
		line(s.Muted(fitWidth(s, g.Call+" "+strings.TrimSpace(c.GetTool()+" "+compactArgs(c.GetArgumentsJson())), 0)))
	}
	switch now {
	case leylinev1.ToolCallState_TOOL_CALL_DONE:
		if c.GetIsError() {
			line("  " + s.Err(fitWidth(s, g.Fail+" "+firstLine(c.GetResultText()), 2)))
		}
	case leylinev1.ToolCallState_TOOL_CALL_REFUSED:
		line("  " + s.Warn(g.Fail+" declined"))
	}
}

// fitWidth cuts text to the terminal's width less indent, when the width is known.
func fitWidth(s ui.Style, text string, indent int) string {
	if s.Width <= 0 {
		return text
	}
	return s.Truncate(text, s.Width-indent)
}

func firstLine(text string) string {
	text = strings.TrimSpace(text)
	if i := strings.IndexByte(text, '\n'); i >= 0 {
		return strings.TrimSpace(text[:i])
	}
	return text
}
