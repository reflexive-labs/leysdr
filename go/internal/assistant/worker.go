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

// cutShort is the stop reasons that end a turn early, the line the turn ends with, and the
// reason the turn says it ended for (ai.proto, Turn.stop_reason).
var cutShort = map[string]struct {
	note   string
	reason leylinev1.StopReason
}{
	"max_tokens": {"(The response reached the model's output limit and was cut off. Ask again, for less at once.)", leylinev1.StopReason_STOP_REASON_MAX_TOKENS},
	"refusal":    {"(The model declined to answer this.)", leylinev1.StopReason_STOP_REASON_REFUSAL},
}

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
	// LookupEnv reads LEYLINE_KEY_ON_STDIN, LEY_ASSISTANT_SCRIPT and LEY_ASSISTANT_RECORD; nil is
	// os.LookupEnv.
	LookupEnv func(string) (string, bool)
	// NewToolServer is cli.NewAssistantToolServer in `ley worker assistant`; it is passed in
	// because the cli package is where the server lives and it imports this one.
	NewToolServer ToolServerFunc
	// Conversation is --conversation, checked against WorkerStart.
	Conversation string
	// HTTP is the model's client; nil is one that never follows a redirect.
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
	// transcriptFailed is set once an append to the transcript file has failed and been logged.
	transcriptFailed bool
	policy           *Policy
	undo             undoStack
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
	w.policy.Mode = w.start.GetMode()
	if opts.Conversation != "" && opts.Conversation != w.start.GetConversationId() {
		w.logf("started for %s, and WorkerStart names %s; going by WorkerStart", opts.Conversation, w.start.GetConversationId())
	}
	if err := w.connect(ctx); err != nil {
		return err
	}
	defer w.close()
	if w.start.GetResume() {
		w.resume()
	}
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
	for _, dropped := range w.tools.Dropped {
		w.logf("left out the view tool %s", dropped)
	}
	w.closeTools = func() { _ = w.tools.Close(); closeServer() }
	w.client, err = leyline.Dial(ctx, w.start.GetSocket(), leyline.WithKind("mcp"), leyline.WithLabel("assistant"))
	if err != nil {
		w.closeTools()
		return w.fail(leyline.CodeInternal, "the assistant cannot reach the daemon: "+err.Error())
	}
	w.policy.ResolveDecoder = func(name string) (string, error) {
		rctx, cancel := context.WithTimeout(ctx, usageTimeout)
		defer cancel()
		canonical, _, err := w.client.ResolveDecoder(rctx, name)
		return canonical, err
	}
	w.system = SystemPrompt(w.tools.instructions, w.policy.Mode)
	return nil
}

func (w *worker) close() {
	_ = w.client.Close()
	w.closeTools()
}

// pickModel is the scripted model when LEY_ASSISTANT_SCRIPT names one, else the provider's: the
// Messages API for anthropic, and chat completions for openai and for any other provider whose
// key names an endpoint, which is how gateways and local model servers are added.
func (w *worker) pickModel() (Model, error) {
	if path, ok := w.opts.LookupEnv(ScriptEnv); ok && path != "" {
		script, err := LoadScript(path)
		if err != nil {
			return nil, err
		}
		script.Record, _ = w.opts.LookupEnv(RecordEnv)
		return script, nil
	}
	provider, endpoint := w.start.GetProvider(), w.start.GetEndpoint()
	openAICompatible := provider == "openai" || (provider != "anthropic" && provider != "" && endpoint != "")
	if provider != "anthropic" && !openAICompatible {
		return nil, &ModelError{
			Code: leyline.CodeProviderUnavailable,
			Message: fmt.Sprintf("the assistant cannot call %q: it calls anthropic, openai, or an OpenAI-compatible server added with an endpoint; "+
				"ley ai use assistant <provider> <model> chooses another", provider),
		}
	}
	if w.secret == "" {
		return nil, &ModelError{Code: leyline.CodeCredentialMissing, Message: fmt.Sprintf("the assistant has no key for %s; ley ai add %s stores one", provider, provider)}
	}
	if err := CheckEndpoint(endpoint); err != nil {
		return nil, err
	}
	if provider == "anthropic" {
		return &Anthropic{Key: w.secret, Endpoint: endpoint, Model: w.start.GetModel(), HTTP: w.opts.HTTP}, nil
	}
	if w.start.GetModel() == "" {
		if provider != "openai" {
			return nil, &ModelError{
				Code:    leyline.CodeFailedPrecondition,
				Message: fmt.Sprintf("the assistant has no model for %s; ley ai use assistant %s <model> chooses one", provider, provider),
			}
		}
		// The usage reports name the model that ran.
		w.start.Model = OpenAIDefaultModel
	}
	return &OpenAI{Key: w.secret, Endpoint: endpoint, Model: w.start.GetModel(), HTTP: w.opts.HTTP}, nil
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
		if sm := ev.GetSetMode(); sm != nil {
			w.setMode(sm.GetMode())
			continue
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
			return w.finish(turn, leylinev1.StopReason_STOP_REASON_STEP_LIMIT)
		}
		var resp Response
		var err error
		// The call runs on during's goroutine while this one may take a set_mode, which rewrites
		// w.system; the call reads copies made here, and a new mode reaches the next call.
		system, defs, transcript := w.system, w.tools.Defs(), w.transcript
		switch w.during(ctx, func(cctx context.Context) { resp, err = w.model.Respond(cctx, system, defs, transcript) }) {
		case stopped:
			return w.finish(turn, leylinev1.StopReason_STOP_REASON_STOPPED)
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
		if cut, ends := cutShort[resp.StopReason]; ends {
			// A response cut at the output limit may end in a half-made tool call, and a refusal
			// has nothing to run: keep the text, drop the calls, and end the turn saying why.
			if text := resp.Text(); text != "" {
				w.record(Message{Role: "assistant", Content: []Block{{Type: "text", Text: text}}})
			}
			turn.Text = joinText(joinText(turn.Text, resp.Text()), cut.note)
			return w.finish(turn, cut.reason)
		}
		if len(resp.Content) > 0 {
			w.record(Message{Role: "assistant", Content: resp.Content})
		}
		turn.Text = joinText(turn.Text, resp.Text())
		uses := resp.ToolUses()
		if len(uses) == 0 {
			return w.finish(turn, leylinev1.StopReason_STOP_REASON_COMPLETED)
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
				return w.finish(turn, leylinev1.StopReason_STOP_REASON_STOPPED)
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
	// A model on a chat completions API writes its arguments as a string, which may not be a JSON
	// object; such a call is refused below rather than run with none.
	badArgs := len(use.Input) > 0 && json.Unmarshal(use.Input, &args) != nil
	if args == nil || badArgs { // null is no arguments
		args = map[string]any{}
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
	if badArgs {
		call.ArgumentsJson = string(use.Input)
		call.State, call.IsError, call.ResultText = leylinev1.ToolCallState_TOOL_CALL_DONE, true, "the arguments are not a JSON object"
		return result(call.ResultText, true), notInterrupted, w.write(turn)
	}
	if w.tools.IsView(use.Name) {
		return w.viewCall(ctx, turn, call, result)
	}
	if d := w.policy.Check(use.Name, args, w.tools.IsWrite(use.Name)); d.Asks() {
		call.State, call.Reason, call.Offers = leylinev1.ToolCallState_TOOL_CALL_AWAITING_APPROVAL, d.Reason, d.Offers
		if err := w.write(turn); err != nil {
			return Block{}, notInterrupted, err
		}
		ev, intr := w.waitFor(ctx, call.CallId, false)
		if intr != notInterrupted {
			call.State, call.ResultText = leylinev1.ToolCallState_TOOL_CALL_REFUSED, Stopped
			return Block{}, intr, w.writeUnlessClosed(turn, intr)
		}
		if !ev.GetResolved().GetApproved() {
			call.State, call.ResultText = leylinev1.ToolCallState_TOOL_CALL_REFUSED, Declined
			return result(Declined, true), notInterrupted, w.write(turn)
		}
		if g, granted := w.policy.Resolve(d, call.CallId, ev.GetResolved()); granted {
			w.recordGrant(g)
		} else if ev.GetResolved().GetScope() == leylinev1.ApprovalScope_APPROVAL_SCOPE_CONVERSATION {
			w.logf("%s was approved for the conversation, which it did not offer; allowed once", call.CallId)
		}
		call.State = leylinev1.ToolCallState_TOOL_CALL_RUNNING
	} else {
		// A call a grant or AUTO lets through keeps the reason it would have asked with, so a
		// reader sees it was one the user allowed, and allowed_by says which answer allowed it.
		call.Reason, call.AllowedBy = d.Reported, d.AllowedBy
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
func (w *worker) viewCall(ctx context.Context, turn *leylinev1.Turn, call *leylinev1.ToolCall, result func(string, bool) Block) (Block, interrupt, error) {
	call.State = leylinev1.ToolCallState_TOOL_CALL_AWAITING_CLIENT
	if err := w.write(turn); err != nil {
		return Block{}, notInterrupted, err
	}
	ev, intr := w.waitFor(ctx, call.CallId, true)
	if intr != notInterrupted {
		call.State, call.ResultText = leylinev1.ToolCallState_TOOL_CALL_REFUSED, Stopped
		return Block{}, intr, w.writeUnlessClosed(turn, intr)
	}
	a := ev.GetViewAnswer()
	res := Result{Text: a.GetResultText(), JSON: a.GetResultJson(), IsError: a.GetIsError()}
	call.State, call.ResultText, call.ResultJson, call.IsError = leylinev1.ToolCallState_TOOL_CALL_DONE, res.Text, res.JSON, res.IsError
	// A client's answer may carry decoded text it shows (a record in the Library, a label), so
	// it is quoted and taints the conversation as records do.
	w.policy.Received()
	return result(modelContent(res, true), res.IsError), notInterrupted, w.write(turn)
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
	return modelContent(res, IsReceived(tool, res))
}

// ModelResultLimit bounds what the model reads of one result: a 20 MHz scan or a page of records
// is more JSON than a turn should spend its context on. The client's ToolCall keeps it whole.
const ModelResultLimit = 32 << 10

// CutNote ends a result cut at ModelResultLimit.
const CutNote = "(result cut at 32 KB; ask for fewer)"

// modelContent cuts a result at ModelResultLimit and quotes it when it cannot be trusted.
func modelContent(res Result, received bool) string {
	text := res.ForModel()
	cut := len(text) > ModelResultLimit
	if cut {
		text = strings.ToValidUTF8(text[:ModelResultLimit], "")
	}
	if received {
		quoted, _ := json.Marshal(text)
		text = ReceivedPrefix + string(quoted)
	}
	if cut {
		text += "\n" + CutNote
	}
	return text
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
		case <-ctx.Done():
			// The worker is told to end (SIGTERM); fn's context is already cancelled.
			<-done
			return closed
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
			case ev.GetSetMode() != nil:
				// The next call's gate reads the new mode; the call running now goes on.
				w.setMode(ev.GetSetMode().GetMode())
				continue
			}
			w.logf("ignored %s while the turn runs", eventName(ev))
		}
	}
}

// waitFor waits for the answer to one call: ActionResolved, or ViewToolAnswer when view is set.
func (w *worker) waitFor(ctx context.Context, callID string, view bool) (*leylinev1.WorkerEvent, interrupt) {
	for {
		var ev *leylinev1.WorkerEvent
		select {
		case <-ctx.Done():
			return nil, closed
		case e, ok := <-w.events:
			if !ok {
				return nil, closed
			}
			ev = e
		}
		switch {
		case ev.GetStop() != nil:
			return nil, stopped
		case ev.GetSetMode() != nil:
			w.setMode(ev.GetSetMode().GetMode())
			if !view && w.policy.Mode == leylinev1.ApprovalMode_APPROVAL_MODE_AUTO {
				// In AUTO nothing waits: the question is answered as an approval once, which
				// grants nothing, so the call runs with its reason and no allowed_by.
				return &leylinev1.WorkerEvent{Event: &leylinev1.WorkerEvent_Resolved{Resolved: &leylinev1.ActionResolved{
					CallId: callID, Approved: true, Scope: leylinev1.ApprovalScope_APPROVAL_SCOPE_ONCE,
				}}}, notInterrupted
			}
			continue
		case !view && ev.GetResolved().GetCallId() == callID:
			return ev, notInterrupted
		case view && ev.GetViewAnswer().GetCallId() == callID:
			return ev, notInterrupted
		}
		w.logf("ignored %s while waiting on %s", eventName(ev), callID)
	}
}

// appendUser adds blocks to the transcript as the user's (record joins them to a last message
// that is the user's already).
func (w *worker) appendUser(blocks ...Block) {
	w.record(Message{Role: "user", Content: blocks})
}

// finish marks the turn done, with why it ended, and writes it.
func (w *worker) finish(turn *leylinev1.Turn, reason leylinev1.StopReason) error {
	turn.Done, turn.StopReason = true, reason
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
	})
	if err != nil {
		w.logf("the response's usage was not reported: %v", err)
	}
}

// setMode takes the conversation's new mode into the gate and the system prompt.
func (w *worker) setMode(mode leylinev1.ApprovalMode) {
	if mode != leylinev1.ApprovalMode_APPROVAL_MODE_AUTO {
		mode = leylinev1.ApprovalMode_APPROVAL_MODE_ASK
	}
	w.policy.Mode = mode
	w.system = SystemPrompt(w.tools.instructions, mode)
	w.logf("the conversation's mode is now %s", mode)
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
	case ev.GetSetMode() != nil:
		return "SetMode"
	}
	return "an empty event"
}
