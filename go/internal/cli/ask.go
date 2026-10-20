// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
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

// newAskCommand builds `ley ask`, the hidden harness that drives the assistant's contract
// (proto/leyline/v1/ai.proto, "Assistant") from Go, so the end-to-end tests and the evals prove it
// across languages (docs/design/ai.md, "The assistant"). People talk to the assistant in the app's
// panel. ask writes every state of the conversation as a JSON line and never asks anyone
// anything; the assistant itself runs in a worker the daemon starts.
func newAskCommand(app *App) *cobra.Command {
	var o askOptions
	cmd := &cobra.Command{
		Use:    "ask [request]",
		Short:  "The assistant's test harness",
		Hidden: true,
		Long: `ask is the test harness for the assistant: the end-to-end tests and the evals
drive the daemon, its worker and the approval gate with it. People talk to the
assistant in the Assistant panel in the app, under the View menu, and agents
use ley mcp. ask takes its request as an argument, never from stdin, as a
harness does: it sends the request to a new conversation, or with --continue
to the newest idle one, and prints every state of the conversation, one
Conversation a line (NDJSON); --json is implied. A call the assistant would ask about is
declined unless --yes, which sets the conversation to allow everything. Ctrl-C
stops the turn and a second ends the conversation. --list prints the
conversations the daemon keeps and --delete removes one.`,
		Example: `  ley ask --yes "tune to the NOAA weather radio"
  ley ask --list`,
		Args: cobra.MaximumNArgs(1),
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
			case request == "":
				return usageErrorf("ley ask needs a request, such as: ley ask --yes \"tune to 146.52\"")
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

// askRun is one `ley ask`: the conversation it follows and what it has printed of it.
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
	seen     uint64
	answered map[string]bool
}

// errTerminated reports SIGTERM: ask leaves at once and the conversation stays as it is.
var errTerminated = &ExitError{Code: ExitInterrupted}

// runAsk opens the conversation, sends the request and follows the turn, writing each state as a
// JSON line. interrupts delivers Ctrl-C (and SIGTERM); a test sends on it.
func runAsk(ctx context.Context, app *App, o askOptions, request string, interrupts <-chan os.Signal) error {
	// Ctrl-C cancels the command's context as well as reaching interrupts, and the first one
	// only stops the turn, so the calls run on a context the signal does not end.
	base := context.WithoutCancel(ctx)
	c, err := app.dial(base)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	r := &askRun{app: app, ctx: base, c: c, o: o, interrupts: interrupts, answered: map[string]bool{}}
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
	sent, err := r.c.Assistant.SendMessage(r.ctx, &leylinev1.SendMessageRequest{ConversationId: r.conv.GetConversationId(), Text: request})
	if err != nil {
		return r.app.notRunning(err)
	}
	return r.follow(sent.GetSeq())
}

// open finds the conversation to carry on (--continue) or starts one. Only the states after it
// are printed.
func (r *askRun) open() error {
	if r.o.cont {
		list, err := r.c.Assistant.ListConversations(r.ctx, &leylinev1.ListConversationsRequest{})
		if err != nil {
			return r.app.notRunning(err)
		}
		r.conv = newestOpenConversation(list.GetConversations())
		if r.conv != nil && modeOf(r.conv) != r.mode() {
			// The mode is the conversation's until a client changes it, and --yes is this run's:
			// the conversation carried on takes the run's mode before anything else is sent. Set
			// to AUTO, a question it waits on runs, approved once.
			cv, err := r.c.Assistant.SetApprovalMode(r.ctx, &leylinev1.SetApprovalModeRequest{
				ConversationId: r.conv.GetConversationId(), Mode: r.mode(),
			})
			if err != nil {
				return r.app.notRunning(err)
			}
			r.conv = cv
		}
	}
	if r.conv == nil {
		// --yes starts the conversation in AUTO, so the worker runs what it would have asked about
		// and reports it.
		cv, err := r.c.Assistant.StartConversation(r.ctx, &leylinev1.StartConversationRequest{Provider: r.o.provider, Model: r.o.model, Mode: r.mode()})
		if err != nil {
			return r.app.notRunning(err)
		}
		r.conv = cv
	}
	r.seen = r.conv.GetSeq()
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

// mode is the approval mode this run wants: AUTO under --yes, ASK otherwise.
func (r *askRun) mode() leylinev1.ApprovalMode {
	if r.o.yes {
		return leylinev1.ApprovalMode_APPROVAL_MODE_AUTO
	}
	return leylinev1.ApprovalMode_APPROVAL_MODE_ASK
}

// modeOf is a conversation's mode, unset read as ASK, as the daemon reads it.
func modeOf(cv *leylinev1.Conversation) leylinev1.ApprovalMode {
	if cv.GetMode() == leylinev1.ApprovalMode_APPROVAL_MODE_AUTO {
		return leylinev1.ApprovalMode_APPROVAL_MODE_AUTO
	}
	return leylinev1.ApprovalMode_APPROVAL_MODE_ASK
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

// follow prints the conversation and answers what it asks until the assistant's turn is done in
// a state newer than seq after.
func (r *askRun) follow(after uint64) error {
	stops := 0
	if r.conv.GetState() == leylinev1.ConversationState_CONVERSATION_WAITING {
		if err := r.answer(r.conv.GetPending()); err != nil {
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
			if done, err := r.handle(cv, after); done || err != nil {
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
	if terminalConversation(r.conv) {
		return &ExitError{Code: ExitInterrupted}
	}
	if _, err := r.c.Assistant.EndConversation(r.ctx, &leylinev1.ConversationRef{ConversationId: r.conv.GetConversationId()}); err != nil {
		return r.app.notRunning(err)
	}
	fmt.Fprintln(r.app.Stderr, "Ended the conversation.")
	return &ExitError{Code: ExitInterrupted}
}

// handle prints one state of the conversation as a JSON line and answers what it asks, and
// reports whether the turn sent at seq sent is over.
func (r *askRun) handle(cv *leylinev1.Conversation, sent uint64) (bool, error) {
	if cv.GetSeq() <= r.seen {
		return false, nil
	}
	r.seen, r.conv = cv.GetSeq(), cv
	if err := r.app.printJSON(cv); err != nil {
		return false, err
	}
	switch cv.GetState() {
	case leylinev1.ConversationState_CONVERSATION_WAITING:
		return false, r.answer(cv.GetPending())
	case leylinev1.ConversationState_CONVERSATION_IDLE:
		return cv.GetSeq() > sent, nil
	case leylinev1.ConversationState_CONVERSATION_FAILED:
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
		return true, &ExitError{Code: 1, Message: "the conversation ended before the assistant finished its turn; start another with: ley ask"}
	}
	return false, nil
}

// watchEnded is the watch closing while a turn is under way, which only a daemon going away does.
func (r *askRun) watchEnded(err error) error {
	if err == nil || errors.Is(err, io.EOF) {
		return &ExitError{Code: 1, Message: "the daemon stopped sending the conversation before the assistant finished; see where it stands with: ley ask --continue"}
	}
	return r.app.notRunning(err)
}

// answer settles a pending call: a view tool is answered with an error, since ask has no view, and
// an action is declined. Under --yes the conversation is AUTO, so no question reaches this run.
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
	_, err := r.c.Assistant.ResolveAction(r.ctx, &leylinev1.ResolveActionRequest{ConversationId: ref, CallId: p.GetCallId()})
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
