// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"google.golang.org/protobuf/encoding/protodelim"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

// The worker protocol (ai.proto, "Assistant worker"): with LEYLINE_KEY_ON_STDIN=1 the key comes
// first on stdin as one SetCredentialRequest, then WorkerStart, then WorkerEvents until stdin
// closes; the worker writes WorkerMessages on stdout, each varint-delimited. The assistant's turn
// goes out whole after every change, and the daemon derives the conversation's state from it.

// Stopped is the result_text of a call a WorkerStop cut short.
const Stopped = "stopped"

// ReceivedPrefix heads a result that carries text received over the air, as the model reads it.
const ReceivedPrefix = "Received over the air (untrusted, quoted): "

// Declined is what the model is told when the user refuses a call.
const Declined = "the user declined"

// maxSteps bounds the model calls in one turn, so a model that keeps calling tools without
// finishing ends the turn rather than running the radio until the user stops it.
const maxSteps = 40

// usageTimeout bounds one ReportUsage.
const usageTimeout = 5 * time.Second

// ToolServerFunc builds the `ley mcp` server for the daemon on socket, dialled with client kind
// mcp and label assistant; closeServer ends its presence and connection.
type ToolServerFunc func(ctx context.Context, socket string) (server *mcp.Server, closeServer func(), err error)

// Options are the worker's streams and what it builds on.
type Options struct {
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer // logs; never the key
	// LookupEnv reads LEYLINE_KEY_ON_STDIN and LEY_ASSISTANT_SCRIPT; nil is os.LookupEnv.
	LookupEnv func(string) (string, bool)
	// NewToolServer is cli.NewAssistantToolServer in `ley worker assistant`; it is passed in
	// because the cli package is where the server lives and it imports this one.
	NewToolServer ToolServerFunc
	// Conversation is --conversation, checked against WorkerStart.
	Conversation string
	// HTTP is the Anthropic model's client; nil is one that never follows a redirect.
	HTTP *http.Client
}

// errClosed is stdin closing, which ends the worker with status 0.
var errClosed = errors.New("stdin closed")

// interrupt is what cut a wait short.
type interrupt int

const (
	notInterrupted interrupt = iota
	stopped                  // WorkerStop: the turn ends, the conversation goes on
	closed                   // stdin closed: the worker ends
)

type worker struct {
	opts   Options
	out    io.Writer
	logw   io.Writer
	start  *leylinev1.WorkerStart
	secret string
	model  Model
	tools  *Tools
	// closeTools ends the tool session and the server's presence on the daemon.
	closeTools func()
	client     *leyline.Client
	system     string
	events     chan *leylinev1.WorkerEvent

	transcript []Message
	policy     *Policy
	undo       undoStack
	// calls numbers the conversation's tool calls: c1, c2, ...
	calls int
}

// Run is the worker: it reads the key and WorkerStart, connects to the daemon, and answers each
// UserMessage with a turn until stdin closes. A failure the conversation cannot go on from is
// written as a WorkerFailure and returned.
func Run(ctx context.Context, opts Options) error {
	if opts.LookupEnv == nil {
		opts.LookupEnv = os.LookupEnv
	}
	w := &worker{opts: opts, out: opts.Stdout, logw: opts.Stderr, policy: NewPolicy()}
	if w.logw == nil {
		w.logw = io.Discard
	}
	in := bufio.NewReader(opts.Stdin)
	if v, _ := opts.LookupEnv(plugin.KeyOnStdinEnv); v == "1" {
		cred, err := plugin.ReadCredential(in)
		if err != nil {
			return w.fail(leyline.CodeCredentialMissing, "the assistant worker did not get its key: "+err.Error())
		}
		w.secret = cred.GetSecret()
	}
	var first leylinev1.WorkerEvent
	if err := protodelim.UnmarshalFrom(in, &first); err != nil {
		if errors.Is(err, io.EOF) {
			return nil
		}
		return w.fail(leyline.CodeInternal, "reading WorkerStart: "+err.Error())
	}
	if w.start = first.GetStart(); w.start == nil {
		return w.fail(leyline.CodeInternal, "the first event after the key was not WorkerStart")
	}
	if opts.Conversation != "" && opts.Conversation != w.start.GetConversationId() {
		w.logf("started for %s, and WorkerStart names %s; going by WorkerStart", opts.Conversation, w.start.GetConversationId())
	}
	if err := w.connect(ctx); err != nil {
		return err
	}
	defer w.close()
	w.events = make(chan *leylinev1.WorkerEvent)
	go readEvents(in, w.events, w.logw)
	return w.serve(ctx)
}

// connect picks the model, dials the daemon for usage reports and builds the tools.
func (w *worker) connect(ctx context.Context) error {
	model, err := w.pickModel()
	if err != nil {
		var me *ModelError
		if errors.As(err, &me) {
			return w.fail(me.Code, me.Message)
		}
		return w.fail(leyline.CodeInternal, err.Error())
	}
	w.model = model
	if w.opts.NewToolServer == nil {
		return w.fail(leyline.CodeInternal, "the worker was built without a tool server")
	}
	if w.start.GetSocket() == "" {
		// The daemon names its socket in the environment too.
		w.start.Socket, _ = w.opts.LookupEnv(SocketEnv)
	}
	server, closeServer, err := w.opts.NewToolServer(ctx, w.start.GetSocket())
	if err != nil {
		return w.fail(leyline.CodeInternal, "the assistant cannot reach the daemon: "+err.Error())
	}
	w.tools, err = NewTools(ctx, server, w.start.GetViewTools())
	if err != nil {
		closeServer()
		return w.fail(leyline.CodeInternal, err.Error())
	}
	w.closeTools = func() { _ = w.tools.Close(); closeServer() }
	w.client, err = leyline.Dial(ctx, w.start.GetSocket(), leyline.WithKind("mcp"), leyline.WithLabel("assistant"))
	if err != nil {
		w.closeTools()
		return w.fail(leyline.CodeInternal, "the assistant cannot reach the daemon: "+err.Error())
	}
	w.system = SystemPrompt(w.tools.instructions)
	return nil
}

func (w *worker) close() {
	_ = w.client.Close()
	w.closeTools()
}

// pickModel is the scripted model when LEY_ASSISTANT_SCRIPT names one, else the provider's.
func (w *worker) pickModel() (Model, error) {
	if path, ok := w.opts.LookupEnv(ScriptEnv); ok && path != "" {
		return LoadScript(path)
	}
	if w.start.GetProvider() != "anthropic" {
		return nil, &ModelError{
			Code:    leyline.CodeProviderUnavailable,
			Message: fmt.Sprintf("the assistant cannot call %q: it calls anthropic only; ley ai use assistant <provider> <model> chooses another", w.start.GetProvider()),
		}
	}
	if w.secret == "" {
		return nil, &ModelError{Code: leyline.CodeCredentialMissing, Message: "the assistant has no key for anthropic; ley ai add anthropic stores one"}
	}
	return &Anthropic{Key: w.secret, Endpoint: w.start.GetEndpoint(), Model: w.start.GetModel(), HTTP: w.opts.HTTP}, nil
}

// readEvents forwards stdin's events and closes out when stdin ends.
func readEvents(in *bufio.Reader, out chan<- *leylinev1.WorkerEvent, logw io.Writer) {
	defer close(out)
	for {
		ev := &leylinev1.WorkerEvent{}
		if err := protodelim.UnmarshalFrom(in, ev); err != nil {
			if !errors.Is(err, io.EOF) {
				fmt.Fprintf(logw, "ley worker assistant: reading stdin: %v\n", err)
			}
			return
		}
		out <- ev
	}
}

// serve answers user messages until stdin closes.
func (w *worker) serve(ctx context.Context) error {
	for {
		var ev *leylinev1.WorkerEvent
		select {
		case <-ctx.Done():
			return nil
		case e, ok := <-w.events:
			if !ok {
				return nil
			}
			ev = e
		}
		user := ev.GetUser()
		if user == nil {
			if ev.GetStop() == nil { // a stop between turns has nothing to stop
				w.logf("ignored %s between turns", eventName(ev))
			}
			continue
		}
		if err := w.runTurn(ctx, user); err != nil {
			if errors.Is(err, errClosed) {
				return nil
			}
			return err
		}
	}
}

// runTurn answers one user message: model, tools, model, until the model ends the turn or the
// user stops it.
func (w *worker) runTurn(ctx context.Context, user *leylinev1.UserMessage) error {
	w.policy.BeginTurn()
	turn := &leylinev1.Turn{TurnId: ReplyTurnID(user.GetTurnId()), Role: leylinev1.Role_ROLE_ASSISTANT, AtNs: time.Now().UnixNano()}
	w.appendUser(Block{Type: "text", Text: user.GetText()})
	if err := w.write(turn); err != nil {
		return err
	}
	for step := 0; ; step++ {
		if step == maxSteps {
			turn.Text = joinText(turn.Text, fmt.Sprintf("(The assistant stopped after %d steps without finishing. Ask again to go on.)", maxSteps))
			return w.finish(turn)
		}
		var resp Response
		var err error
		switch w.during(ctx, func(cctx context.Context) { resp, err = w.model.Respond(cctx, w.system, w.tools.Defs(), w.transcript) }) {
		case stopped:
			return w.finish(turn)
		case closed:
			return errClosed
		}
		if err != nil {
			var me *ModelError
			if errors.As(err, &me) {
				return w.fail(me.Code, me.Message)
			}
			return w.fail(leyline.CodeProviderUnavailable, err.Error())
		}
		w.reportUsage(ctx, resp.Usage)
		if len(resp.Content) > 0 {
			w.transcript = append(w.transcript, Message{Role: "assistant", Content: resp.Content})
		}
		turn.Text = joinText(turn.Text, resp.Text())
		uses := resp.ToolUses()
		if len(uses) == 0 {
			return w.finish(turn)
		}
		if err := w.write(turn); err != nil {
			return err
		}
		results := make([]Block, 0, len(uses))
		for i, use := range uses {
			result, intr, err := w.runCall(ctx, turn, use)
			if err != nil {
				return err
			}
			if intr != notInterrupted {
				// Every tool_use needs its tool_result, or the next request is refused.
				for _, rest := range uses[i:] {
					results = append(results, Block{Type: "tool_result", ToolUseID: rest.ID, Content: "the user stopped the turn before this ran", IsError: true})
				}
				w.appendUser(results...)
				if intr == closed {
					return errClosed
				}
				return w.finish(turn)
			}
			results = append(results, result)
		}
		w.appendUser(results...)
	}
}

// runCall takes one tool call through the gate, the waits and the tool, writing the turn after
// each change, and returns what the model is told.
func (w *worker) runCall(ctx context.Context, turn *leylinev1.Turn, use Block) (Block, interrupt, error) {
	args := map[string]any{}
	if len(use.Input) > 0 {
		_ = json.Unmarshal(use.Input, &args)
	}
	if use.Name == "tune" {
		if _, set := args["keep"]; !set {
			// The worker's connection ends with the conversation, and a channel the user asked for
			// should not end with it (the prompt has the assistant say that ley stop ends it).
			args["keep"] = true
		}
	}
	raw := mustJSON(args)
	w.calls++
	call := &leylinev1.ToolCall{CallId: fmt.Sprintf("c%d", w.calls), Tool: use.Name, ArgumentsJson: string(raw), State: leylinev1.ToolCallState_TOOL_CALL_RUNNING, AtNs: time.Now().UnixNano()}
	turn.Tools = append(turn.Tools, call)
	result := func(content string, isError bool) Block {
		return Block{Type: "tool_result", ToolUseID: use.ID, Content: content, IsError: isError}
	}

	if !w.tools.IsServer(use.Name) && !w.tools.IsView(use.Name) && use.Name != UndoTool {
		call.State, call.IsError, call.ResultText = leylinev1.ToolCallState_TOOL_CALL_DONE, true, fmt.Sprintf("there is no tool called %s", use.Name)
		return result(call.ResultText, true), notInterrupted, w.write(turn)
	}
	if w.tools.IsView(use.Name) {
		return w.viewCall(turn, call, result)
	}
	if reason := w.policy.Check(use.Name, args, w.tools.IsWrite(use.Name)); reason != "" {
		call.State, call.Reason = leylinev1.ToolCallState_TOOL_CALL_AWAITING_APPROVAL, reason
		if err := w.write(turn); err != nil {
			return Block{}, notInterrupted, err
		}
		ev, intr := w.waitFor(call.CallId, false)
		if intr != notInterrupted {
			call.State, call.ResultText = leylinev1.ToolCallState_TOOL_CALL_REFUSED, Stopped
			return Block{}, intr, w.writeUnlessClosed(turn, intr)
		}
		if !ev.GetResolved().GetApproved() {
			call.State, call.ResultText = leylinev1.ToolCallState_TOOL_CALL_REFUSED, Declined
			return result(Declined, true), notInterrupted, w.write(turn)
		}
		call.State = leylinev1.ToolCallState_TOOL_CALL_RUNNING
	}
	if err := w.write(turn); err != nil {
		return Block{}, notInterrupted, err
	}
	var res Result
	if intr := w.during(ctx, func(cctx context.Context) { res = w.execute(cctx, use.Name, args, raw) }); intr != notInterrupted {
		call.State, call.IsError, call.ResultText = leylinev1.ToolCallState_TOOL_CALL_DONE, true, Stopped
		return Block{}, intr, w.writeUnlessClosed(turn, intr)
	}
	w.policy.Ran(use.Name, args, res)
	call.State, call.ResultText, call.ResultJson, call.IsError = leylinev1.ToolCallState_TOOL_CALL_DONE, res.Text, res.JSON, res.IsError
	return result(ForModel(use.Name, res), res.IsError), notInterrupted, w.write(turn)
}

// viewCall hands a view tool to the client that declared it and waits for its answer.
func (w *worker) viewCall(turn *leylinev1.Turn, call *leylinev1.ToolCall, result func(string, bool) Block) (Block, interrupt, error) {
	call.State = leylinev1.ToolCallState_TOOL_CALL_AWAITING_CLIENT
	if err := w.write(turn); err != nil {
		return Block{}, notInterrupted, err
	}
	ev, intr := w.waitFor(call.CallId, true)
	if intr != notInterrupted {
		call.State, call.ResultText = leylinev1.ToolCallState_TOOL_CALL_REFUSED, Stopped
		return Block{}, intr, w.writeUnlessClosed(turn, intr)
	}
	a := ev.GetViewAnswer()
	res := Result{Text: a.GetResultText(), JSON: a.GetResultJson(), IsError: a.GetIsError()}
	call.State, call.ResultText, call.ResultJson, call.IsError = leylinev1.ToolCallState_TOOL_CALL_DONE, res.Text, res.JSON, res.IsError
	return result(res.ForModel(), res.IsError), notInterrupted, w.write(turn)
}

// execute runs a call the gate let through: undo from the stack, set and tune with what undo
// needs read around them, anything else as it is.
func (w *worker) execute(ctx context.Context, name string, args map[string]any, raw json.RawMessage) Result {
	switch name {
	case UndoTool:
		return w.undo.undo(ctx, w.tools)
	case "set":
		before := readState(ctx, w.tools)
		res := w.tools.Call(ctx, name, raw)
		w.undo.noteSet(before, args, res)
		return res
	case "tune":
		res := w.tools.Call(ctx, name, raw)
		w.undo.noteTune(res)
		return res
	}
	return w.tools.Call(ctx, name, raw)
}

// SocketEnv is where the daemon also names its socket, for a WorkerStart without one.
const SocketEnv = "LEYLINE_SOCKET"

// ReplyTurnID is the id of the turn that answers the user's: the daemon numbers turns on both
// sides, so "t3" is answered by "t4". An id not of that form gets "-a" appended.
func ReplyTurnID(userTurnID string) string {
	if digits, ok := strings.CutPrefix(userTurnID, "t"); ok {
		if n, err := strconv.Atoi(digits); err == nil && n >= 0 {
			return "t" + strconv.Itoa(n+1)
		}
	}
	return userTurnID + "-a"
}

// ForModel is a result as the model reads it: text received over the air is quoted as one JSON
// string behind a line that says where it came from, so nothing in it reads as an instruction.
func ForModel(tool string, res Result) string {
	text := res.ForModel()
	if !IsReceived(tool, res) {
		return text
	}
	quoted, _ := json.Marshal(text)
	return ReceivedPrefix + string(quoted)
}

// during runs fn while watching stdin for a stop, which cancels fn's context.
func (w *worker) during(ctx context.Context, fn func(context.Context)) interrupt {
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		fn(cctx)
	}()
	for {
		select {
		case <-done:
			return notInterrupted
		case ev, ok := <-w.events:
			switch {
			case !ok:
				cancel()
				<-done
				return closed
			case ev.GetStop() != nil:
				cancel()
				<-done
				return stopped
			}
			w.logf("ignored %s while the turn runs", eventName(ev))
		}
	}
}

// waitFor waits for the answer to one call: ActionResolved, or ViewToolAnswer when view is set.
func (w *worker) waitFor(callID string, view bool) (*leylinev1.WorkerEvent, interrupt) {
	for ev := range w.events {
		switch {
		case ev.GetStop() != nil:
			return nil, stopped
		case !view && ev.GetResolved().GetCallId() == callID:
			return ev, notInterrupted
		case view && ev.GetViewAnswer().GetCallId() == callID:
			return ev, notInterrupted
		}
		w.logf("ignored %s while waiting on %s", eventName(ev), callID)
	}
	return nil, closed
}

// appendUser adds blocks to the transcript as the user's, joining the last message when it is the
// user's already (a turn stopped before the model answered leaves one).
func (w *worker) appendUser(blocks ...Block) {
	if n := len(w.transcript); n > 0 && w.transcript[n-1].Role == "user" {
		w.transcript[n-1].Content = append(w.transcript[n-1].Content, blocks...)
		return
	}
	w.transcript = append(w.transcript, Message{Role: "user", Content: blocks})
}

// finish marks the turn done and writes it.
func (w *worker) finish(turn *leylinev1.Turn) error {
	turn.Done = true
	return w.write(turn)
}

// writeUnlessClosed writes the turn after a stop; after stdin closed nobody reads it.
func (w *worker) writeUnlessClosed(turn *leylinev1.Turn, intr interrupt) error {
	if intr == closed {
		return nil
	}
	return w.write(turn)
}

// write sends the turn, whole.
func (w *worker) write(turn *leylinev1.Turn) error {
	_, err := protodelim.MarshalTo(w.out, &leylinev1.WorkerMessage{Message: &leylinev1.WorkerMessage_Turn{Turn: turn}})
	return err
}

// fail writes a WorkerFailure, with the key cut out of the message, and returns it as the error
// the worker exits with.
func (w *worker) fail(code, msg string) error {
	if w.secret != "" {
		msg = strings.ReplaceAll(msg, w.secret, "…")
	}
	_, _ = protodelim.MarshalTo(w.out, &leylinev1.WorkerMessage{Message: &leylinev1.WorkerMessage_Failure{
		Failure: &leylinev1.WorkerFailure{Error: &leylinev1.ErrorDetail{Code: code, Message: msg}},
	}})
	return &ModelError{Code: code, Message: msg}
}

// reportUsage adds one response to the ledger under the conversation. A report that does not
// reach the daemon is logged and the turn goes on.
func (w *worker) reportUsage(ctx context.Context, u Usage) {
	rctx, cancel := context.WithTimeout(ctx, usageTimeout)
	defer cancel()
	_, err := w.client.Usage.ReportUsage(rctx, &leylinev1.UsageReport{
		Provider: w.start.GetProvider(), Model: w.start.GetModel(), Feature: "assistant",
		ConversationId: w.start.GetConversationId(), Requests: 1,
		InputTokens: u.InputTokens, OutputTokens: u.OutputTokens,
		CacheReadTokens: u.CacheReadInputTokens, CacheWriteTokens: u.CacheCreationInputTokens,
		AtNs: time.Now().UnixNano(),
	})
	if err != nil {
		w.logf("the response's usage was not reported: %v", err)
	}
}

func (w *worker) logf(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	if w.secret != "" {
		msg = strings.ReplaceAll(msg, w.secret, "…")
	}
	fmt.Fprintf(w.logw, "ley worker assistant: %s\n", msg)
}

// eventName names an event for a log line.
func eventName(ev *leylinev1.WorkerEvent) string {
	switch {
	case ev.GetStart() != nil:
		return "a second WorkerStart"
	case ev.GetUser() != nil:
		return "a UserMessage"
	case ev.GetResolved() != nil:
		return "ActionResolved for " + ev.GetResolved().GetCallId()
	case ev.GetViewAnswer() != nil:
		return "ViewToolAnswer for " + ev.GetViewAnswer().GetCallId()
	case ev.GetStop() != nil:
		return "WorkerStop"
	}
	return "an empty event"
}
