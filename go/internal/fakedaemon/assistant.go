// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The assistant's conversations, faked the way the daemon keeps them (proto/leyline/v1/ai.proto,
// "Assistant"): whole state on every reply and event, a seq of the conversation's own, and the
// state derived from the turns. The fake has no worker. Its assistant plays Options.AssistantScript,
// one scripted turn per SendMessage, so a client sees a turn grow, a call wait for approval and a
// conversation fail exactly as a worker would make them happen.

// AssistantStep is one thing a scripted assistant turn does. Set one of Text, Tool, Ask, View or
// Fail; the others are read with it.
type AssistantStep struct {
	// Text sets the turn's text so far, as a worker writes it: whole each time, not appended.
	Text string
	// Tool adds a call that runs at once: RUNNING, then DONE with Result as its prose. Args is
	// the call's arguments_json.
	Tool, Args, Result string
	// Ask adds a call to the tool it names that waits for ResolveAction, with Reason as why it
	// asks. Approved, the call is DONE with ResultApproved; refused, it is REFUSED.
	Ask, Reason, ResultApproved string
	// View adds a view tool call that waits for AnswerViewTool, which supplies its result.
	View string
	// Fail marks the turn done and fails the conversation with INTERNAL and this message, as a
	// worker that stops does.
	Fail string
}

// AssistantTurn is one scripted assistant turn: its steps in order. The turn is done, and the
// conversation IDLE, after the last one.
type AssistantTurn []AssistantStep

// assistantState is every conversation and the next scripted turn. Guarded by Daemon.mu.
type assistantState struct {
	convs map[string]*fakeConversation
	// next is the index of the scripted turn the next SendMessage plays, across conversations.
	next int
}

type fakeConversation struct {
	conv *leylinev1.Conversation
	// versions is every state the conversation has had, oldest first, for since_seq replay.
	versions []*leylinev1.Conversation
	watchers map[*convWatcher]struct{}
	// stop is closed when the playing turn is stopped or the conversation ends; nil when no turn
	// is playing. resume is signalled when the call the turn waits on is answered.
	stop   chan struct{}
	resume chan struct{}
	// playing is the scripted turn the conversation is on, which holds the approved results.
	playing AssistantTurn
	calls   int
}

type convWatcher struct{ ch chan *leylinev1.Conversation }

// assistantSvc gives the Assistant RPCs a receiver of their own.
type assistantSvc struct {
	leylinev1.UnimplementedAssistantServer
	d *Daemon
}

func terminal(s leylinev1.ConversationState) bool {
	return s == leylinev1.ConversationState_CONVERSATION_ENDED || s == leylinev1.ConversationState_CONVERSATION_FAILED
}

// publishConvLocked bumps the conversation's seq, keeps the new state for replay, and sends it to
// its watchers and, as Event.conversation, to the event plane. Call with d.mu held.
func (d *Daemon) publishConvLocked(fc *fakeConversation, by *leylinev1.ClientInfo) {
	fc.conv.Seq++
	snap := proto.Clone(fc.conv).(*leylinev1.Conversation)
	fc.versions = append(fc.versions, snap)
	d.emit(by, snap)
	for w := range fc.watchers {
		offerConv(w.ch, snap)
	}
}

// offerConv queues c, dropping the oldest queued state when the watcher is behind: every state is
// whole, so the newest is the one that matters.
func offerConv(ch chan *leylinev1.Conversation, c *leylinev1.Conversation) {
	for {
		select {
		case ch <- c:
			return
		default:
		}
		select {
		case <-ch:
		default:
		}
	}
}

// conversationsLocked is every conversation, newest first. Call with d.mu held.
func (d *Daemon) conversationsLocked() []*leylinev1.Conversation {
	out := make([]*leylinev1.Conversation, 0, len(d.talk.convs))
	for _, fc := range d.talk.convs {
		out = append(out, proto.Clone(fc.conv).(*leylinev1.Conversation))
	}
	// Ids are monotonic ULIDs, so the larger is the newer.
	sort.Slice(out, func(i, j int) bool { return out[i].ConversationId > out[j].ConversationId })
	return out
}

func noConversation(id string) *leyline.Error {
	return errorf(leyline.CodeInvalidArgument, id, fmt.Sprintf("there is no conversation %s; ley ask --continue finds the newest", id))
}

// conversation finds one by id. Call with d.mu held.
func (d *Daemon) conversation(id string) (*fakeConversation, *leyline.Error) {
	fc := d.talk.convs[id]
	if fc == nil {
		return nil, noConversation(id)
	}
	return fc, nil
}

// StartConversation implements Assistant: the request's provider and model, else the assistant
// feature model's, and a key for that provider, or CREDENTIAL_MISSING naming the command that
// adds one.
func (a assistantSvc) StartConversation(ctx context.Context, req *leylinev1.StartConversationRequest) (*leylinev1.Conversation, error) {
	d := a.d
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	provider, model := req.GetProvider(), req.GetModel()
	if fm := d.ai.features["assistant"]; fm != nil {
		if provider == "" {
			provider = fm.GetProvider()
		}
		if model == "" && provider == fm.GetProvider() {
			model = fm.GetModel()
		}
	}
	switch {
	case provider == "":
		return nil, fail(ctx, errorf(leyline.CodeFailedPrecondition, "assistant",
			"no model is chosen for the assistant; choose one with ley ai use assistant anthropic claude-sonnet-5-5"))
	case d.ai.credentials[provider] == nil:
		return nil, fail(ctx, credentialMissing(provider))
	case model == "":
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, provider,
			fmt.Sprintf("no %s model is chosen for the assistant; name one, or choose one with ley ai use assistant %s <model>", provider, provider)))
	}
	now := time.Now().UnixNano()
	fc := &fakeConversation{
		conv: &leylinev1.Conversation{
			ConversationId: newID("conv_"), State: leylinev1.ConversationState_CONVERSATION_IDLE,
			Provider: provider, Model: model, StartedBy: ci, StartedAtNs: now, LastTurnAtNs: now,
			ViewTools: req.GetViewTools(),
		},
		watchers: map[*convWatcher]struct{}{},
	}
	if d.talk.convs == nil {
		d.talk.convs = map[string]*fakeConversation{}
	}
	d.talk.convs[fc.conv.ConversationId] = fc
	d.publishConvLocked(fc, ci)
	return proto.Clone(fc.conv).(*leylinev1.Conversation), nil
}

// SendMessage implements Assistant: the user turn is added and the next scripted turn starts
// playing. FAILED_PRECONDITION unless IDLE.
func (a assistantSvc) SendMessage(ctx context.Context, req *leylinev1.SendMessageRequest) (*leylinev1.Conversation, error) {
	d := a.d
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	if req.GetText() == "" {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetConversationId(), "the message is empty; say what you want the assistant to do"))
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	fc, err := d.conversation(req.GetConversationId())
	if err != nil {
		return nil, fail(ctx, err)
	}
	if st := fc.conv.State; st != leylinev1.ConversationState_CONVERSATION_IDLE {
		return nil, fail(ctx, errorf(leyline.CodeFailedPrecondition, fc.conv.ConversationId,
			fmt.Sprintf("the conversation is %s, not idle; a message can be sent once the assistant's turn is done", stateName(st))))
	}
	now := time.Now().UnixNano()
	fc.conv.Turns = append(fc.conv.Turns, &leylinev1.Turn{
		TurnId: turnID(fc), Role: leylinev1.Role_ROLE_USER, Text: req.GetText(), AtNs: now, Done: true,
	})
	fc.conv.State = leylinev1.ConversationState_CONVERSATION_THINKING
	fc.conv.LastTurnAtNs = now
	d.publishConvLocked(fc, ci)
	steps := d.nextScriptedTurn(req.GetText())
	fc.playing = steps
	fc.stop, fc.resume = make(chan struct{}), make(chan struct{}, 1)
	go d.playTurn(fc, steps, fc.stop, fc.resume)
	return proto.Clone(fc.conv).(*leylinev1.Conversation), nil
}

// nextScriptedTurn is the turn the script has next. A script that has run out, or none, answers
// with the user's words, so a test that only needs a reply needs no script. Call with d.mu held.
func (d *Daemon) nextScriptedTurn(said string) AssistantTurn {
	if d.talk.next < len(d.opts.AssistantScript) {
		t := d.opts.AssistantScript[d.talk.next]
		d.talk.next++
		return t
	}
	return AssistantTurn{{Text: "You said: " + said}}
}

// turnID is the id of the next turn: "t1", "t2", … counting user and assistant turns together,
// as the contract numbers them.
func turnID(fc *fakeConversation) string { return "t" + strconv.Itoa(len(fc.conv.Turns)+1) }

func stateName(s leylinev1.ConversationState) string {
	switch s {
	case leylinev1.ConversationState_CONVERSATION_IDLE:
		return "idle"
	case leylinev1.ConversationState_CONVERSATION_THINKING:
		return "thinking"
	case leylinev1.ConversationState_CONVERSATION_WAITING:
		return "waiting for an answer"
	case leylinev1.ConversationState_CONVERSATION_ENDED:
		return "ended"
	case leylinev1.ConversationState_CONVERSATION_FAILED:
		return "failed"
	}
	return "in no state"
}

// playTurn applies a scripted turn's steps one at a time, Options.AssistantStepDelay apart, until
// the turn is done, it is stopped, or a step fails the conversation.
func (d *Daemon) playTurn(fc *fakeConversation, steps AssistantTurn, stop <-chan struct{}, resume <-chan struct{}) {
	stopped := func() bool {
		select {
		case <-stop:
			return true
		default:
			return false
		}
	}
	pause := func() bool {
		if d.opts.AssistantStepDelay <= 0 {
			return !stopped()
		}
		select {
		case <-stop:
			return false
		case <-time.After(d.opts.AssistantStepDelay):
			return true
		}
	}
	by := byDaemon()
	for _, step := range steps {
		if !pause() {
			return
		}
		d.mu.Lock()
		if stopped() {
			d.mu.Unlock()
			return
		}
		waits := d.applyStepLocked(fc, step, by)
		failed := fc.conv.State == leylinev1.ConversationState_CONVERSATION_FAILED
		d.mu.Unlock()
		if failed {
			return
		}
		if waits {
			select {
			case <-stop:
				return
			case <-resume:
			}
		} else if step.Tool != "" {
			if !pause() {
				return
			}
			d.mu.Lock()
			if !stopped() {
				call := lastCall(fc)
				call.State, call.ResultText = leylinev1.ToolCallState_TOOL_CALL_DONE, step.Result
				d.publishConvLocked(fc, by)
			}
			d.mu.Unlock()
		}
	}
	if !pause() {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if stopped() {
		return
	}
	d.assistantTurnLocked(fc).Done = true
	d.settleLocked(fc, leylinev1.ConversationState_CONVERSATION_IDLE)
	d.publishConvLocked(fc, by)
}

// applyStepLocked makes one step's change and publishes it, and reports whether the turn now
// waits for an answer. Call with d.mu held.
func (d *Daemon) applyStepLocked(fc *fakeConversation, step AssistantStep, by *leylinev1.ClientInfo) (waits bool) {
	turn := d.assistantTurnLocked(fc)
	now := time.Now().UnixNano()
	fc.conv.LastTurnAtNs = now
	addCall := func(tool string, state leylinev1.ToolCallState) *leylinev1.ToolCall {
		fc.calls++
		c := &leylinev1.ToolCall{
			CallId: "c" + strconv.Itoa(fc.calls), Tool: tool, ArgumentsJson: step.Args, State: state, AtNs: now,
		}
		turn.Tools = append(turn.Tools, c)
		return c
	}
	switch {
	case step.Fail != "":
		turn.Done = true
		fc.conv.Error = &leylinev1.ErrorDetail{Code: leyline.CodeInternal, Message: step.Fail}
		d.settleLocked(fc, leylinev1.ConversationState_CONVERSATION_FAILED)
	case step.Tool != "":
		addCall(step.Tool, leylinev1.ToolCallState_TOOL_CALL_RUNNING)
	case step.Ask != "":
		c := addCall(step.Ask, leylinev1.ToolCallState_TOOL_CALL_AWAITING_APPROVAL)
		c.Reason = step.Reason
		fc.conv.State = leylinev1.ConversationState_CONVERSATION_WAITING
		fc.conv.Pending = &leylinev1.PendingAction{CallId: c.CallId, Tool: c.Tool, ArgumentsJson: c.ArgumentsJson, Reason: c.Reason}
		waits = true
	case step.View != "":
		c := addCall(step.View, leylinev1.ToolCallState_TOOL_CALL_AWAITING_CLIENT)
		fc.conv.State = leylinev1.ConversationState_CONVERSATION_WAITING
		fc.conv.Pending = &leylinev1.PendingAction{CallId: c.CallId, Tool: c.Tool, ArgumentsJson: c.ArgumentsJson, ViewTool: true}
		waits = true
	default:
		turn.Text = step.Text
	}
	d.publishConvLocked(fc, by)
	return waits
}

// assistantTurnLocked is the assistant turn being played, added when the turn's first change
// arrives, as a worker's first write adds it. Call with d.mu held.
func (d *Daemon) assistantTurnLocked(fc *fakeConversation) *leylinev1.Turn {
	if n := len(fc.conv.Turns); n > 0 {
		if t := fc.conv.Turns[n-1]; t.Role == leylinev1.Role_ROLE_ASSISTANT && !t.Done {
			return t
		}
	}
	t := &leylinev1.Turn{TurnId: turnID(fc), Role: leylinev1.Role_ROLE_ASSISTANT, AtNs: time.Now().UnixNano()}
	fc.conv.Turns = append(fc.conv.Turns, t)
	return t
}

func lastCall(fc *fakeConversation) *leylinev1.ToolCall {
	tools := fc.conv.Turns[len(fc.conv.Turns)-1].Tools
	return tools[len(tools)-1]
}

// settleLocked moves the conversation to a state no turn is playing in: the player is told to
// stop and nothing is pending. Call with d.mu held.
func (d *Daemon) settleLocked(fc *fakeConversation, state leylinev1.ConversationState) {
	if fc.stop != nil {
		close(fc.stop)
		fc.stop, fc.resume = nil, nil
	}
	fc.conv.State = state
	fc.conv.Pending = nil
}

// pendingCall is the call a WAITING conversation waits on, if it is callID and of the kind asked
// for; otherwise FAILED_PRECONDITION. Call with d.mu held.
func pendingCall(fc *fakeConversation, callID string, view bool) (*leylinev1.ToolCall, *leyline.Error) {
	p := fc.conv.Pending
	if fc.conv.State != leylinev1.ConversationState_CONVERSATION_WAITING || p.GetCallId() != callID || p.GetViewTool() != view {
		return nil, errorf(leyline.CodeFailedPrecondition, callID,
			fmt.Sprintf("the conversation is not waiting on call %s; it is %s", callID, stateName(fc.conv.State)))
	}
	return lastCall(fc), nil
}

// ResolveAction implements Assistant: the pending call runs or is refused, and the turn goes on.
func (a assistantSvc) ResolveAction(ctx context.Context, req *leylinev1.ResolveActionRequest) (*leylinev1.Conversation, error) {
	return a.answer(ctx, req.GetConversationId(), req.GetCallId(), false, func(c *leylinev1.ToolCall, step string) {
		if req.GetApprove() {
			c.State, c.ResultText = leylinev1.ToolCallState_TOOL_CALL_DONE, step
			return
		}
		c.State = leylinev1.ToolCallState_TOOL_CALL_REFUSED
	})
}

// AnswerViewTool implements Assistant: the client's answer is the pending view tool call's result.
func (a assistantSvc) AnswerViewTool(ctx context.Context, req *leylinev1.AnswerViewToolRequest) (*leylinev1.Conversation, error) {
	return a.answer(ctx, req.GetConversationId(), req.GetCallId(), true, func(c *leylinev1.ToolCall, _ string) {
		c.State = leylinev1.ToolCallState_TOOL_CALL_DONE
		c.ResultText, c.ResultJson, c.IsError = req.GetResultText(), req.GetResultJson(), req.GetIsError()
	})
}

// answer settles the pending call with settle, which is given the scripted approved result, and
// lets the turn go on.
func (a assistantSvc) answer(ctx context.Context, convID, callID string, view bool, settle func(*leylinev1.ToolCall, string)) (*leylinev1.Conversation, error) {
	d := a.d
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	fc, err := d.conversation(convID)
	if err != nil {
		return nil, fail(ctx, err)
	}
	call, err := pendingCall(fc, callID, view)
	if err != nil {
		return nil, fail(ctx, err)
	}
	settle(call, approvedResult(fc, call))
	fc.conv.State, fc.conv.Pending = leylinev1.ConversationState_CONVERSATION_THINKING, nil
	d.publishConvLocked(fc, ci)
	select {
	case fc.resume <- struct{}{}:
	default:
	}
	return proto.Clone(fc.conv).(*leylinev1.Conversation), nil
}

// approvedResult is the result the script gives the call once approved: the Ask step's
// ResultApproved, found by the call's tool and arguments in the turn the conversation is playing.
func approvedResult(fc *fakeConversation, call *leylinev1.ToolCall) string {
	for _, s := range fc.playing {
		if s.Ask == call.Tool && s.Args == call.ArgumentsJson {
			return s.ResultApproved
		}
	}
	return ""
}

// StopTurn implements Assistant: the turn is marked done where it stands and the conversation is
// IDLE. A call that was waiting is refused; one that was running is reported stopped. An idle
// conversation is returned as it is.
func (a assistantSvc) StopTurn(ctx context.Context, req *leylinev1.ConversationRef) (*leylinev1.Conversation, error) {
	d := a.d
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	fc, err := d.conversation(req.GetConversationId())
	if err != nil {
		return nil, fail(ctx, err)
	}
	switch fc.conv.State {
	case leylinev1.ConversationState_CONVERSATION_THINKING, leylinev1.ConversationState_CONVERSATION_WAITING:
	case leylinev1.ConversationState_CONVERSATION_IDLE:
		return proto.Clone(fc.conv).(*leylinev1.Conversation), nil
	default:
		return nil, fail(ctx, errorf(leyline.CodeFailedPrecondition, fc.conv.ConversationId,
			fmt.Sprintf("the conversation has %s; there is no turn to stop", stateName(fc.conv.State))))
	}
	d.stopTurnLocked(fc)
	d.settleLocked(fc, leylinev1.ConversationState_CONVERSATION_IDLE)
	d.publishConvLocked(fc, ci)
	return proto.Clone(fc.conv).(*leylinev1.Conversation), nil
}

// stopTurnLocked marks the playing assistant turn done where it stands. Call with d.mu held.
func (d *Daemon) stopTurnLocked(fc *fakeConversation) {
	n := len(fc.conv.Turns)
	if n == 0 || fc.conv.Turns[n-1].Role != leylinev1.Role_ROLE_ASSISTANT {
		return
	}
	t := fc.conv.Turns[n-1]
	t.Done = true
	for _, c := range t.Tools {
		switch c.State {
		case leylinev1.ToolCallState_TOOL_CALL_AWAITING_APPROVAL, leylinev1.ToolCallState_TOOL_CALL_AWAITING_CLIENT:
			c.State = leylinev1.ToolCallState_TOOL_CALL_REFUSED
		case leylinev1.ToolCallState_TOOL_CALL_RUNNING:
			c.State, c.IsError, c.ResultText = leylinev1.ToolCallState_TOOL_CALL_DONE, true, "stopped"
		}
	}
}

// EndConversation implements Assistant: any turn stops and the conversation is ENDED, still
// listed. Ending one that has already ended or failed returns it as it is.
func (a assistantSvc) EndConversation(ctx context.Context, req *leylinev1.ConversationRef) (*leylinev1.Conversation, error) {
	d := a.d
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	fc, err := d.conversation(req.GetConversationId())
	if err != nil {
		return nil, fail(ctx, err)
	}
	if terminal(fc.conv.State) {
		return proto.Clone(fc.conv).(*leylinev1.Conversation), nil
	}
	d.stopTurnLocked(fc)
	d.settleLocked(fc, leylinev1.ConversationState_CONVERSATION_ENDED)
	d.publishConvLocked(fc, ci)
	return proto.Clone(fc.conv).(*leylinev1.Conversation), nil
}

// DeleteConversation implements Assistant: a conversation still going is ended first, so its
// watchers and the event plane see it ENDED, and then it is no longer listed. The fake keeps
// nothing on disk, so there is nothing else to remove and nothing survives the fake.
func (a assistantSvc) DeleteConversation(ctx context.Context, req *leylinev1.ConversationRef) (*leylinev1.Empty, error) {
	d := a.d
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	fc, err := d.conversation(req.GetConversationId())
	if err != nil {
		return nil, fail(ctx, err)
	}
	if !terminal(fc.conv.State) {
		d.stopTurnLocked(fc)
		d.settleLocked(fc, leylinev1.ConversationState_CONVERSATION_ENDED)
		d.publishConvLocked(fc, ci)
	}
	delete(d.talk.convs, fc.conv.ConversationId)
	return &leylinev1.Empty{}, nil
}

// ListConversations implements Assistant: newest first, ended ones included.
func (a assistantSvc) ListConversations(ctx context.Context, _ *leylinev1.ListConversationsRequest) (*leylinev1.ListConversationsResponse, error) {
	a.d.touchUnary(clientFrom(ctx))
	a.d.mu.Lock()
	defer a.d.mu.Unlock()
	return &leylinev1.ListConversationsResponse{Conversations: a.d.conversationsLocked()}, nil
}

// WatchConversation implements Assistant: the states after since_seq (the current one when it is
// 0), then every change, ending after the conversation ends or fails.
func (a assistantSvc) WatchConversation(req *leylinev1.WatchConversationRequest, srv grpc.ServerStreamingServer[leylinev1.Conversation]) error {
	d := a.d
	ctx, stop := d.streamContext(srv.Context())
	defer stop()
	done := d.streamOpened(ctx)
	defer done()
	w := &convWatcher{ch: make(chan *leylinev1.Conversation, 256)}
	d.mu.Lock()
	fc, err := d.conversation(req.GetConversationId())
	if err != nil {
		d.mu.Unlock()
		return fail(ctx, err)
	}
	// Replay under the lock, before registering, so replay and live states cannot interleave.
	if req.GetSinceSeq() == 0 {
		offerConv(w.ch, proto.Clone(fc.conv).(*leylinev1.Conversation))
	} else {
		for _, v := range fc.versions {
			if v.Seq > req.GetSinceSeq() {
				offerConv(w.ch, v)
			}
		}
	}
	// A conversation that has ended, and whose last state the client already holds, has nothing
	// more to send.
	if terminal(fc.conv.State) && len(w.ch) == 0 {
		d.mu.Unlock()
		return nil
	}
	fc.watchers[w] = struct{}{}
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(fc.watchers, w)
		d.mu.Unlock()
	}()
	for {
		select {
		case <-ctx.Done():
			return nil
		case c := <-w.ch:
			if err := srv.Send(c); err != nil {
				return err
			}
			if terminal(c.State) {
				return nil
			}
		}
	}
}
