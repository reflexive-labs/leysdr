// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// assistantKey stores a key and chooses the assistant's model, which StartConversation needs.
func assistantKey(t *testing.T, c *leyline.Client) {
	t.Helper()
	ctx := t.Context()
	if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: "anthropic", Secret: testSecret}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "assistant", Provider: "anthropic", Model: "claude-test"}); err != nil {
		t.Fatal(err)
	}
}

// watchUntil follows a conversation from since and returns every state up to and including the
// first one done says is the last.
func watchUntil(t *testing.T, c *leyline.Client, id string, since uint64, done func(*leylinev1.Conversation) bool) []*leylinev1.Conversation {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	stream, err := c.Assistant.WatchConversation(ctx, &leylinev1.WatchConversationRequest{ConversationId: id, SinceSeq: since})
	if err != nil {
		t.Fatal(err)
	}
	var out []*leylinev1.Conversation
	for {
		cv, err := stream.Recv()
		if err != nil {
			t.Fatalf("watch ended before the state we wait for (%v); saw %d states", err, len(out))
		}
		out = append(out, cv)
		if done(cv) {
			return out
		}
	}
}

func isState(s leylinev1.ConversationState) func(*leylinev1.Conversation) bool {
	return func(cv *leylinev1.Conversation) bool { return cv.State == s }
}

// A scripted turn plays step by step: the user turn, the text as it grows, a tool call RUNNING
// then DONE, and the turn done with the conversation IDLE; every change bumps the conversation's
// seq and goes out as Event.conversation, and GetState lists the conversation.
func TestAssistantPlaysAScriptedTurn(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{AssistantScript: []fakedaemon.AssistantTurn{{
		{Text: "Tuning"},
		{Tool: "tune", Args: `{"freq":"162.4M"}`, Result: "Tuned to 162.400 MHz NFM"},
		{Text: "Tuning to the weather station."},
	}}})
	assistantKey(t, c)
	ctx := t.Context()
	cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if cv.State != leylinev1.ConversationState_CONVERSATION_IDLE || cv.Provider != "anthropic" || cv.Model != "claude-test" ||
		!strings.HasPrefix(cv.ConversationId, "conv_") || cv.Seq != 1 {
		t.Fatalf("started: %v", cv)
	}
	sent, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: cv.ConversationId, Text: "weather radio"})
	if err != nil {
		t.Fatal(err)
	}
	if sent.State != leylinev1.ConversationState_CONVERSATION_THINKING || sent.Turns[0].TurnId != "t1" || sent.Turns[0].Role != leylinev1.Role_ROLE_USER {
		t.Fatalf("after SendMessage: %v", sent)
	}
	states := watchUntil(t, c, cv.ConversationId, cv.Seq, isState(leylinev1.ConversationState_CONVERSATION_IDLE))
	last := states[len(states)-1]
	if len(last.Turns) != 2 {
		t.Fatalf("turns: %v", last.Turns)
	}
	reply := last.Turns[1]
	if reply.TurnId != "t2" || reply.Role != leylinev1.Role_ROLE_ASSISTANT || !reply.Done || reply.Text != "Tuning to the weather station." {
		t.Errorf("assistant turn: %v", reply)
	}
	if len(reply.Tools) != 1 || reply.Tools[0].State != leylinev1.ToolCallState_TOOL_CALL_DONE || reply.Tools[0].ResultText != "Tuned to 162.400 MHz NFM" {
		t.Errorf("tool call: %v", reply.Tools)
	}
	sawRunning := false
	for i, s := range states {
		if i > 0 && s.Seq != states[i-1].Seq+1 {
			t.Errorf("seq jumps from %d to %d", states[i-1].Seq, s.Seq)
		}
		if n := len(s.Turns); n == 2 && len(s.Turns[1].Tools) == 1 && s.Turns[1].Tools[0].State == leylinev1.ToolCallState_TOOL_CALL_RUNNING {
			sawRunning = true
		}
	}
	if !sawRunning {
		t.Error("the tool call was never seen RUNNING")
	}
	conversations := 0
	for _, ev := range retained(t, c) {
		if got := ev.GetConversation(); got != nil && got.ConversationId == cv.ConversationId {
			conversations++
		}
	}
	if conversations != int(last.Seq) {
		t.Errorf("%d conversation events for %d changes", conversations, last.Seq)
	}
	st, err := c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if got := st.GetConversations(); len(got) != 1 || got[0].Seq != last.Seq {
		t.Errorf("GetState.conversations: %v", got)
	}
}

// An Ask step waits WAITING with the call pending; ResolveAction approves it (DONE with the
// scripted result) or refuses it (REFUSED), and a resolve for another call, or for a conversation
// that is not waiting, is FAILED_PRECONDITION.
func TestAssistantAsksBeforeActing(t *testing.T) {
	t.Parallel()
	ask := fakedaemon.AssistantTurn{
		{Ask: "delete_recording", Args: `{"id":"job_1"}`, Reason: "deleting a recording asks every time", ResultApproved: "Deleted job_1"},
		{Text: "Done."},
	}
	c, _ := harness(t, fakedaemon.Options{AssistantScript: []fakedaemon.AssistantTurn{ask, ask}})
	assistantKey(t, c)
	ctx := t.Context()
	cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	for _, approve := range []bool{true, false} {
		sent, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: cv.ConversationId, Text: "delete it"})
		if err != nil {
			t.Fatal(err)
		}
		states := watchUntil(t, c, cv.ConversationId, sent.Seq, isState(leylinev1.ConversationState_CONVERSATION_WAITING))
		waiting := states[len(states)-1]
		p := waiting.GetPending()
		if p.GetTool() != "delete_recording" || p.GetReason() == "" || p.GetViewTool() {
			t.Fatalf("pending: %v", p)
		}
		if _, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: cv.ConversationId, Text: "again"}); leyline.Code(err) != leyline.CodeFailedPrecondition {
			t.Errorf("SendMessage while waiting: %v", err)
		}
		if _, err := c.Assistant.ResolveAction(ctx, &leylinev1.ResolveActionRequest{ConversationId: cv.ConversationId, CallId: "c99", Approve: true}); leyline.Code(err) != leyline.CodeFailedPrecondition {
			t.Errorf("resolving another call: %v", err)
		}
		if _, err := c.Assistant.ResolveAction(ctx, &leylinev1.ResolveActionRequest{ConversationId: cv.ConversationId, CallId: p.CallId, Approve: approve}); err != nil {
			t.Fatal(err)
		}
		states = watchUntil(t, c, cv.ConversationId, waiting.Seq, isState(leylinev1.ConversationState_CONVERSATION_IDLE))
		idle := states[len(states)-1]
		call := idle.Turns[len(idle.Turns)-1].Tools[0]
		want := leylinev1.ToolCallState_TOOL_CALL_REFUSED
		if approve {
			want = leylinev1.ToolCallState_TOOL_CALL_DONE
			if call.ResultText != "Deleted job_1" {
				t.Errorf("approved result: %q", call.ResultText)
			}
		}
		if call.State != want || idle.Pending != nil {
			t.Errorf("approve=%v: call %v, pending %v", approve, call, idle.Pending)
		}
	}
	if _, err := c.Assistant.ResolveAction(ctx, &leylinev1.ResolveActionRequest{ConversationId: cv.ConversationId, CallId: "c1", Approve: true}); leyline.Code(err) != leyline.CodeFailedPrecondition {
		t.Errorf("resolving while idle: %v", err)
	}
}

// A View step waits on AnswerViewTool, which supplies the result; ResolveAction cannot answer it.
func TestAssistantViewToolIsAnsweredByTheClient(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{AssistantScript: []fakedaemon.AssistantTurn{{{View: "show_band", Args: `{"band":"airband"}`}}}})
	assistantKey(t, c)
	ctx := t.Context()
	cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{
		ViewTools: []*leylinev1.ViewTool{{Name: "show_band", Description: "move the view"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	sent, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: cv.ConversationId, Text: "show me airband"})
	if err != nil {
		t.Fatal(err)
	}
	states := watchUntil(t, c, cv.ConversationId, sent.Seq, isState(leylinev1.ConversationState_CONVERSATION_WAITING))
	p := states[len(states)-1].GetPending()
	if !p.GetViewTool() {
		t.Fatalf("pending: %v", p)
	}
	if _, err := c.Assistant.ResolveAction(ctx, &leylinev1.ResolveActionRequest{ConversationId: cv.ConversationId, CallId: p.CallId, Approve: true}); leyline.Code(err) != leyline.CodeFailedPrecondition {
		t.Errorf("ResolveAction on a view tool: %v", err)
	}
	if _, err := c.Assistant.AnswerViewTool(ctx, &leylinev1.AnswerViewToolRequest{ConversationId: cv.ConversationId, CallId: p.CallId, ResultText: "shown"}); err != nil {
		t.Fatal(err)
	}
	states = watchUntil(t, c, cv.ConversationId, 0, isState(leylinev1.ConversationState_CONVERSATION_IDLE))
	if call := states[len(states)-1].Turns[1].Tools[0]; call.State != leylinev1.ToolCallState_TOOL_CALL_DONE || call.ResultText != "shown" {
		t.Errorf("view call: %v", call)
	}
}

// A Fail step fails the conversation with INTERNAL and the step's words, and the watch ends with
// that state.
func TestAssistantConversationFails(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{AssistantScript: []fakedaemon.AssistantTurn{{{Text: "Let me"}, {Fail: "the assistant stopped unexpectedly"}}}})
	assistantKey(t, c)
	ctx := t.Context()
	cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: cv.ConversationId, Text: "hello"}); err != nil {
		t.Fatal(err)
	}
	states := watchUntil(t, c, cv.ConversationId, cv.Seq, isState(leylinev1.ConversationState_CONVERSATION_FAILED))
	if e := states[len(states)-1].GetError(); e.GetCode() != leyline.CodeInternal || e.GetMessage() != "the assistant stopped unexpectedly" {
		t.Errorf("error: %v", e)
	}
	// The stream ends after the failed state.
	stream, err := c.Assistant.WatchConversation(ctx, &leylinev1.WatchConversationRequest{ConversationId: cv.ConversationId})
	if err != nil {
		t.Fatal(err)
	}
	if last, err := stream.Recv(); err != nil || last.State != leylinev1.ConversationState_CONVERSATION_FAILED {
		t.Fatalf("first state: %v %v", last, err)
	}
	if _, err := stream.Recv(); err == nil {
		t.Error("the watch went on after FAILED")
	}
}

// StopTurn ends a playing turn at once: the turn is done where it stood and the conversation is
// IDLE, and a message can be sent again. EndConversation then ends it, still listed, newest first.
func TestAssistantStopAndEnd(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{
		AssistantScript:    []fakedaemon.AssistantTurn{{{Text: "Working"}, {Text: "Working on it"}, {Text: "Working on it still"}}},
		AssistantStepDelay: 200 * time.Millisecond,
	})
	assistantKey(t, c)
	ctx := t.Context()
	older, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	cv, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	sent, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: cv.ConversationId, Text: "scan the band"})
	if err != nil {
		t.Fatal(err)
	}
	watchUntil(t, c, cv.ConversationId, sent.Seq, func(cv *leylinev1.Conversation) bool { return len(cv.Turns) == 2 })
	stopped, err := c.Assistant.StopTurn(ctx, &leylinev1.ConversationRef{ConversationId: cv.ConversationId})
	if err != nil {
		t.Fatal(err)
	}
	if stopped.State != leylinev1.ConversationState_CONVERSATION_IDLE || !stopped.Turns[1].Done || stopped.Turns[1].Text != "Working" {
		t.Fatalf("stopped: %v", stopped)
	}
	time.Sleep(500 * time.Millisecond)
	list, err := c.Assistant.ListConversations(ctx, &leylinev1.ListConversationsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if got := list.Conversations; len(got) != 2 || got[0].ConversationId != cv.ConversationId || got[1].ConversationId != older.ConversationId {
		t.Fatalf("list is not newest first: %v", got)
	}
	if got := list.Conversations[0]; got.Seq != stopped.Seq || got.Turns[1].Text != "Working" {
		t.Errorf("the stopped turn went on playing: %v", got)
	}
	ended, err := c.Assistant.EndConversation(ctx, &leylinev1.ConversationRef{ConversationId: cv.ConversationId})
	if err != nil {
		t.Fatal(err)
	}
	if ended.State != leylinev1.ConversationState_CONVERSATION_ENDED {
		t.Errorf("ended: %v", ended)
	}
	if _, err := c.Assistant.SendMessage(ctx, &leylinev1.SendMessageRequest{ConversationId: cv.ConversationId, Text: "more"}); leyline.Code(err) != leyline.CodeFailedPrecondition {
		t.Errorf("SendMessage after the end: %v", err)
	}
}

// StartConversation without a key for the provider is CREDENTIAL_MISSING naming the command that
// adds one; the request's provider wins over the feature model's.
func TestAssistantConversationNeedsAKey(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	if _, err := c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "assistant", Provider: "anthropic", Model: "claude-test"}); err != nil {
		t.Fatal(err)
	}
	_, err := c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{})
	if leyline.Code(err) != leyline.CodeCredentialMissing || !strings.Contains(err.Error(), "ley ai add anthropic") {
		t.Errorf("no key: %v", err)
	}
	_, err = c.Assistant.StartConversation(ctx, &leylinev1.StartConversationRequest{Provider: "openai", Model: "gpt"})
	if leyline.Code(err) != leyline.CodeCredentialMissing || !strings.Contains(err.Error(), "ley ai add openai") {
		t.Errorf("no key for the request's provider: %v", err)
	}
}
