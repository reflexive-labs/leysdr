// SPDX-License-Identifier: Apache-2.0

package assistant_test

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/assistant"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

// A turn of reads and the changes the user asked for runs without asking: each call is DONE in the
// turn, the tune's channel is kept and attributed to the assistant, and the turn ends with the
// model's text and the id the daemon matches.
func TestATurnRunsReadsAndAskedForChanges(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{
		line(map[string]any{"text": "Looking.", "tool": "get_state", "args": map[string]any{}}),
		toolLine("help", map[string]any{"topic": "squelch"}),
		toolLine("tune", map[string]any{"frequency": "146.52"}),
		toolLine("set", map[string]any{"param": "squelch", "value": "-45"}),
		line(map[string]any{"text": "Tuned 146.520 MHz NFM. ley stop ends it."}),
	}})
	w.say("t1", "put on the calling frequency")
	turn := w.doneTurn()
	if turn.GetTurnId() != "t2" || turn.GetRole() != leylinev1.Role_ROLE_ASSISTANT {
		t.Errorf("turn id %q role %v", turn.GetTurnId(), turn.GetRole())
	}
	if turn.GetText() != "Looking.\n\nTuned 146.520 MHz NFM. ley stop ends it." {
		t.Errorf("text: %q", turn.GetText())
	}
	if turn.GetStopReason() != leylinev1.StopReason_STOP_REASON_COMPLETED {
		t.Errorf("stop reason: %v", turn.GetStopReason())
	}
	var names []string
	for _, c := range turn.GetTools() {
		names = append(names, c.GetTool())
		if c.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || c.GetIsError() || c.GetReason() != "" {
			t.Errorf("%s: state %v error %v reason %q: %s", c.GetTool(), c.GetState(), c.GetIsError(), c.GetReason(), c.GetResultText())
		}
	}
	if strings.Join(names, ",") != "get_state,help,tune,set" {
		t.Errorf("calls: %v", names)
	}
	tune := callNamed(turn, "tune")
	if !strings.Contains(tune.GetArgumentsJson(), `"keep":true`) || tune.GetResultJson() == "" || !strings.Contains(tune.GetResultText(), "listening to 146.520 MHz") {
		t.Errorf("tune: %v", tune)
	}
	var ch *leylinev1.Channel
	for _, c := range w.state().GetChannels() {
		ch = c
	}
	if ch == nil || !ch.GetPersistent() || ch.GetOwner().GetLabel() != "assistant" || ch.GetOwner().GetKind() != "mcp" || ch.GetSquelchDb() != -45 ||
		ch.GetSquelchSource() != leylinev1.SquelchSource_SQUELCH_MANUAL {
		t.Errorf("the assistant's channel: %v", ch)
	}
}

// One test per row that asks: the call waits with its reason, a refusal leaves the daemon as it
// was and tells the model "the user declined", and an approval runs it.
func TestPolicyRowsAskTheUser(t *testing.T) {
	t.Parallel()
	sample, _ := filepath.Abs("../../../fixtures/chirp/sample.csv")
	cases := []struct {
		name string
		// setup runs before the turn and returns the script, which may name what it made.
		setup      func(w *worker) []string
		daemon     fakedaemon.Options
		wantReason string
		// changed reports whether the call's effect is on the daemon (or the bookmarks).
		changed func(w *worker) bool
	}{
		{
			name: "take over a radio",
			setup: func(w *worker) []string {
				w.listening()
				return []string{toolLine("tune", map[string]any{"frequency": "150"}), toolLine("tune", map[string]any{"frequency": "150", "take_over": true})}
			},
			wantReason: "another channel or client is using the radio: the radio is on 146.520 MHz with 1 channel listening: chan_",
			changed:    func(w *worker) bool { return w.state().GetCaptures()[0].GetCenterHz() == 150_000_000 },
		},
		{
			name: "a kept watch",
			setup: func(*worker) []string {
				return []string{toolLine("watch", map[string]any{"decoder": "aprs", "keep": true})}
			},
			wantReason: "start a kept aprs job",
			changed:    func(w *worker) bool { return len(w.jobs()) > 0 },
		},
		{
			name: "a kept decode job",
			setup: func(*worker) []string {
				return []string{toolLine("start_decode_job", map[string]any{"decoder": "aprs", "keep": true})}
			},
			wantReason: "start a kept aprs job",
			changed:    func(w *worker) bool { return len(w.jobs()) > 0 },
		},
		{
			name: "a webhook notifier",
			setup: func(*worker) []string {
				return []string{toolLine("watch", map[string]any{"decoder": "aprs", "notify": "webhook:http://127.0.0.1:9/hook"})}
			},
			wantReason: "add a webhook notifier: every matching record is sent to http://127.0.0.1:9/hook",
			changed:    func(w *worker) bool { return len(w.jobs()) > 0 },
		},
		{
			name:   "delete a recording",
			daemon: fakedaemon.Options{Recordings: []fakedaemon.SeedRecording{{JobID: "job_01SEEDED", Parts: [][]fakedaemon.SeedOver{{{OpenMs: 100, CloseMs: 900}}}}}},
			setup: func(*worker) []string {
				return []string{toolLine("delete_recording", map[string]any{"recording": "job_01SEEDED"})}
			},
			wantReason: "delete the recording job_01SEEDED and its files; this cannot be undone",
			changed:    func(w *worker) bool { return !w.hasRecording("job_01SEEDED") },
		},
		{
			name: "remove a bookmark",
			setup: func(*worker) []string {
				return []string{
					toolLine("add_bookmark", map[string]any{"frequency": "146.52", "name": "Calling"}),
					toolLine("remove_bookmark", map[string]any{"bookmark": "Calling"}),
				}
			},
			wantReason: `remove the bookmark "Calling"`,
			changed:    func(w *worker) bool { return !strings.Contains(w.bookmarks(), "Calling") },
		},
		{
			name: "cancel another client's job",
			setup: func(w *worker) []string {
				job, err := w.client.Jobs.StartJob(w.t.Context(), &leylinev1.StartJobRequest{Config: &leylinev1.StartJobRequest_Decode{Decode: &leylinev1.DecodeConfig{Decoder: "aprs", Keep: true}}})
				if err != nil {
					w.t.Fatal(err)
				}
				return []string{toolLine("cancel_job", map[string]any{"job": job.GetJobId()})}
			},
			wantReason: "a job the assistant did not start",
			changed:    func(w *worker) bool { return w.jobs()[0].GetState() != leylinev1.JobState_RUNNING },
		},
		{
			name: "import a CHIRP file",
			setup: func(*worker) []string {
				return []string{toolLine("import_chirp", map[string]any{"path": sample})}
			},
			wantReason: "import every channel in " + sample,
			changed:    func(w *worker) bool { return strings.Count(w.bookmarks(), `"name"`) > 0 },
		},
		{
			name: "a third bookmark in one turn",
			setup: func(*worker) []string {
				return []string{
					toolLine("add_bookmark", map[string]any{"frequency": "146.52", "name": "One"}),
					toolLine("add_bookmark", map[string]any{"frequency": "146.55", "name": "Two"}),
					toolLine("add_bookmark", map[string]any{"frequency": "146.58", "name": "Three"}),
				}
			},
			wantReason: `a third bookmark change this turn: add "Three" at 146.58`,
			changed:    func(w *worker) bool { return strings.Contains(w.bookmarks(), "Three") },
		},
		{
			name: "paid transcription",
			setup: func(*worker) []string {
				return []string{toolLine("start_decode_job", map[string]any{"decoder": "speech"})}
			},
			wantReason: "start paid transcription, live and unbounded",
			changed: func(w *worker) bool {
				// The fake has no speech key, so an approved start is refused by the daemon; the
				// call ran, which is what approval means.
				return callNamed(w.last, "start_decode_job").GetResultText() != assistant.Declined
			},
		},
		{
			name: "paid transcription by the speech decoder's alias",
			setup: func(*worker) []string {
				return []string{toolLine("start_decode_job", map[string]any{"decoder": "transcribe"})}
			},
			wantReason: "start paid transcription, live and unbounded",
			changed: func(w *worker) bool {
				return callNamed(w.last, "start_decode_job").GetResultText() != assistant.Declined
			},
		},
		{
			name: "a write after received text",
			setup: func(*worker) []string {
				return []string{toolLine("query_records", map[string]any{"protocol": "aprs"}), toolLine("tune", map[string]any{"frequency": "146.94"})}
			},
			wantReason: assistant.ReceivedReason,
			changed:    func(w *worker) bool { return len(w.state().GetChannels()) > 0 },
		},
	}
	// Each row runs on the scripted model in process and on the OpenAI model against an endpoint
	// that plays the same script, so the gate holds whichever API the calls come from.
	for _, tc := range cases {
		for _, via := range []string{"scripted", "openai"} {
			for _, approve := range []bool{false, true} {
				name := via + "/" + tc.name + "/declined"
				if approve {
					name = via + "/" + tc.name + "/approved"
				}
				t.Run(name, func(t *testing.T) {
					t.Parallel()
					cfg := workerConfig{daemon: tc.daemon, setup: tc.setup}
					if via == "openai" {
						cfg.via = via
					}
					runPolicyRow(t, cfg, tc.wantReason, tc.changed, approve)
				})
			}
		}
	}
}

// runPolicyRow asks for the row's call, answers it, and checks the call and the daemon.
func runPolicyRow(t *testing.T, cfg workerConfig, wantReason string, changed func(*worker) bool, approve bool) {
	t.Helper()
	w := startWorker(t, cfg)
	w.say("t1", "do it")
	call := w.asking()
	if !strings.Contains(call.GetReason(), wantReason) {
		t.Errorf("reason %q lacks %q", call.GetReason(), wantReason)
	}
	w.resolve(call.GetCallId(), approve)
	turn := w.doneTurn()
	var got *leylinev1.ToolCall
	for _, c := range turn.GetTools() {
		if c.GetCallId() == call.GetCallId() {
			got = c
		}
	}
	if approve {
		if got.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE {
			t.Errorf("approved call: %v", got)
		}
	} else if got.GetState() != leylinev1.ToolCallState_TOOL_CALL_REFUSED || got.GetResultText() != assistant.Declined {
		t.Errorf("declined call: %v", got)
	}
	if changed(w) != approve {
		t.Errorf("the daemon changed = %v after approve = %v; call: %v", !approve, approve, got)
	}
}

// Undo puts back a set's old value from the state read before it, then stops the channel a tune
// made.
func TestUndo(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{
		toolLine("tune", map[string]any{"frequency": "146.52", "squelch": "-60"}),
		toolLine("set", map[string]any{"param": "squelch", "value": "-45"}),
		line(map[string]any{"text": "squelch -60 → -45 dBFS"}),
		toolLine("undo", nil),
		line(map[string]any{"text": "put it back"}),
		toolLine("undo", nil),
		toolLine("undo", nil),
		line(map[string]any{"text": "nothing left"}),
	}})
	w.say("t1", "tune 146.52 and open the squelch")
	w.doneTurn()
	if sq := w.state().GetChannels()[0].GetSquelchDb(); sq != -45 {
		t.Fatalf("squelch %v after the set", sq)
	}
	w.say("t3", "undo that")
	turn := w.doneTurn()
	undo := callNamed(turn, "undo")
	if undo.GetIsError() || !strings.Contains(undo.GetResultText(), "put back -60") || !strings.Contains(undo.GetResultText(), "→") {
		t.Errorf("undo of the set: %v", undo)
	}
	if sq := w.state().GetChannels()[0].GetSquelchDb(); sq != -60 {
		t.Errorf("squelch %v after undo, want -60", sq)
	}
	w.say("t5", "undo the tune too")
	turn = w.doneTurn()
	if c := turn.GetTools()[0]; c.GetIsError() || !strings.Contains(c.GetResultText(), "undid the tune") {
		t.Errorf("undo of the tune: %v", c)
	}
	if n := len(w.state().GetChannels()); n != 0 {
		t.Errorf("%d channels after undoing the tune", n)
	}
	if c := turn.GetTools()[1]; !c.GetIsError() || !strings.Contains(c.GetResultText(), "nothing to undo") {
		t.Errorf("an empty stack: %v", c)
	}
}

// WorkerStop during a slow response ends the turn at once; the conversation goes on with the
// next line of the script.
func TestStopDuringAResponse(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{
		line(map[string]any{"sleep_ms": 2000, "text": "too late"}),
		line(map[string]any{"text": "next"}),
	}})
	w.say("t1", "think hard")
	w.next() // the empty turn the worker writes when it begins
	began := time.Now()
	w.stop()
	turn := w.doneTurn()
	if took := time.Since(began); took > time.Second {
		t.Errorf("the stop took %v", took)
	}
	if turn.GetText() != "" || turn.GetStopReason() != leylinev1.StopReason_STOP_REASON_STOPPED {
		t.Errorf("a stopped response: text %q, stop reason %v", turn.GetText(), turn.GetStopReason())
	}
	w.say("t3", "again")
	if turn := w.doneTurn(); turn.GetTurnId() != "t4" || turn.GetText() != "next" {
		t.Errorf("after the stop: %v", turn)
	}
}

// WorkerStop while a call waits for approval refuses it and ends the turn.
func TestStopWhileAsking(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{toolLine("delete_recording", map[string]any{"recording": "job_x"})}})
	w.say("t1", "delete it")
	call := w.asking()
	w.stop()
	turn := w.doneTurn()
	if c := lastCall(turn); c.GetCallId() != call.GetCallId() || c.GetState() != leylinev1.ToolCallState_TOOL_CALL_REFUSED || c.GetResultText() != assistant.Stopped {
		t.Errorf("the waiting call after a stop: %v", c)
	}
	if turn.GetStopReason() != leylinev1.StopReason_STOP_REASON_STOPPED {
		t.Errorf("stop reason: %v", turn.GetStopReason())
	}
}

// WorkerStop while a tool runs ends the call as an error, "stopped", and the turn within 2 s.
func TestStopWhileAToolRuns(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{
		toolLine("record", map[string]any{"target": "146.52", "duration_s": 30}),
		line(map[string]any{"text": "next"}),
	}})
	w.say("t1", "record for a while")
	w.until(func(t *leylinev1.Turn) bool {
		return lastCall(t).GetTool() == "record" && lastCall(t).GetState() == leylinev1.ToolCallState_TOOL_CALL_RUNNING
	})
	began := time.Now()
	w.stop()
	turn := w.doneTurn()
	if took := time.Since(began); took > 2*time.Second {
		t.Errorf("the stop took %v", took)
	}
	if c := lastCall(turn); c.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || !c.GetIsError() || c.GetResultText() != assistant.Stopped {
		t.Errorf("the running call after a stop: %v", c)
	}
	if turn.GetStopReason() != leylinev1.StopReason_STOP_REASON_STOPPED {
		t.Errorf("stop reason: %v", turn.GetStopReason())
	}
	w.say("t3", "go on")
	if turn := w.doneTurn(); turn.GetTurnId() != "t4" || turn.GetText() != "next" {
		t.Errorf("after the stop: %v", turn)
	}
}

// Turn ids follow the daemon's numbering, and call ids are the worker's own, unique within the
// conversation.
func TestTurnAndCallIDs(t *testing.T) {
	t.Parallel()
	for in, want := range map[string]string{"t1": "t2", "t3": "t4", "t41": "t42", "u7": "u7-a", "t": "t-a"} {
		if got := assistant.ReplyTurnID(in); got != want {
			t.Errorf("ReplyTurnID(%q) = %q, want %q", in, got, want)
		}
	}
	w := startWorker(t, workerConfig{script: []string{
		toolLine("get_state", nil), toolLine("list_devices", nil), line(map[string]any{"text": "a"}),
		toolLine("get_state", nil), line(map[string]any{"text": "b"}),
	}})
	w.say("t1", "one")
	first := w.doneTurn()
	w.say("t3", "two")
	second := w.doneTurn()
	var ids []string
	for _, c := range append(first.GetTools(), second.GetTools()...) {
		ids = append(ids, c.GetCallId())
	}
	if strings.Join(ids, ",") != "c1,c2,c3" || second.GetTurnId() != "t4" {
		t.Errorf("call ids %v, second turn %q", ids, second.GetTurnId())
	}
}

// Each model response is one request on the ledger under the conversation, with its tokens.
func TestUsageIsReportedPerResponse(t *testing.T) {
	t.Parallel()
	usage := map[string]any{"input_tokens": 100, "output_tokens": 10, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 0}
	cached := map[string]any{"input_tokens": 20, "output_tokens": 5, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 1000}
	w := startWorker(t, workerConfig{script: []string{
		line(map[string]any{"tool": "get_state", "args": map[string]any{}, "usage": usage}),
		line(map[string]any{"text": "ok", "usage": cached}),
	}})
	w.say("t1", "state?")
	w.doneTurn()
	got, err := w.client.Usage.GetUsage(t.Context(), &leylinev1.GetUsageRequest{ScopeId: convID})
	if err != nil {
		t.Fatal(err)
	}
	if len(got.GetLines()) != 1 {
		t.Fatalf("ledger: %v", got)
	}
	l := got.GetLines()[0]
	if l.GetRequests() != 2 || l.GetInputTokens() != 120 || l.GetOutputTokens() != 15 || l.GetCacheWriteTokens() != 1000 || l.GetCacheReadTokens() != 1000 ||
		l.GetFeature() != "assistant" || l.GetProvider() != "anthropic" || l.GetModel() != "claude-test" {
		t.Errorf("ledger line: %v", l)
	}
}

// A view tool waits for the client that declared it, and its answer is the result.
func TestViewTool(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{
		viewTools: []*leylinev1.ViewTool{{Name: "show_band", Description: "move the waterfall", InputSchemaJson: `{"type":"object","properties":{"from_mhz":{"type":"number"},"to_mhz":{"type":"number"}}}`}},
		script:    []string{toolLine("show_band", map[string]any{"from_mhz": 118, "to_mhz": 137}), line(map[string]any{"text": "shown"}), toolLine("tune", map[string]any{"frequency": "146.52"})},
	})
	w.say("t1", "show me airband")
	turn := w.until(func(t *leylinev1.Turn) bool {
		return lastCall(t).GetState() == leylinev1.ToolCallState_TOOL_CALL_AWAITING_CLIENT
	})
	call := lastCall(turn)
	if call.GetTool() != "show_band" || call.GetReason() != "" {
		t.Errorf("view call: %v", call)
	}
	w.send(&leylinev1.WorkerEvent{Event: &leylinev1.WorkerEvent_ViewAnswer{ViewAnswer: &leylinev1.ViewToolAnswer{
		CallId: call.GetCallId(), ResultText: "the waterfall shows 118.000 to 137.000 MHz", ResultJson: `{"ok":true}`,
	}}})
	turn = w.doneTurn()
	if c := turn.GetTools()[0]; c.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || c.GetResultJson() != `{"ok":true}` || turn.GetText() != "shown" {
		t.Errorf("after the answer: %v", turn)
	}
	if n := len(w.state().GetCaptures()); n != 0 {
		t.Errorf("a view tool touched the radio: %d captures", n)
	}
	// The client's answer may carry decoded text, so it taints the conversation as records do.
	w.say("t3", "now tune 146.52")
	if call := w.asking(); call.GetTool() != "tune" || call.GetReason() != assistant.ReceivedReason {
		t.Errorf("a write after a view tool's answer: %v", call)
	}
}

// A view tool cannot take a radio tool's name.
func TestViewToolCannotShadowARadioTool(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{
		viewTools: []*leylinev1.ViewTool{{Name: "tune", Description: "pretend"}},
		script:    []string{toolLine("tune", map[string]any{"frequency": "146.52"})},
	})
	w.say("t1", "tune")
	turn := w.doneTurn()
	if c := turn.GetTools()[0]; c.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || c.GetIsError() {
		t.Errorf("tune went to the client or failed: %v", c)
	}
}

// Over-the-air text reaches the model quoted, and the turn's next write asks.
func TestReceivedTextMakesWritesAsk(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{
		toolLine("query_records", map[string]any{"protocol": "aprs"}),
		toolLine("get_state", map[string]any{}),
		toolLine("tune", map[string]any{"frequency": "146.94"}),
	}})
	w.say("t1", "what did APRS hear, then tune the repeater")
	call := w.asking()
	if call.GetTool() != "tune" || call.GetReason() != assistant.ReceivedReason {
		t.Errorf("the write after received text: %v", call)
	}
	if read := callNamed(w.last, "get_state"); read.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE {
		t.Errorf("a read after received text should run: %v", read)
	}
	if q := callNamed(w.last, "query_records"); strings.HasPrefix(q.GetResultText(), assistant.ReceivedPrefix) {
		t.Errorf("the client sees the result as the tool returned it, not as the model reads it: %q", q.GetResultText())
	}
}

// The taint outlasts the turn: a write in a later turn still asks.
func TestReceivedTextTaintsLaterTurns(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{
		toolLine("query_records", map[string]any{"protocol": "aprs"}),
		line(map[string]any{"text": "nothing heard"}),
		toolLine("tune", map[string]any{"frequency": "146.94"}),
	}})
	w.say("t1", "what did APRS hear?")
	w.doneTurn()
	w.say("t3", "tune the repeater")
	if call := w.asking(); call.GetTool() != "tune" || call.GetReason() != assistant.ReceivedReason {
		t.Errorf("a write a turn later: %v", call)
	}
}

// A response cut at the output limit ends the turn with a line saying so, and its tool call does
// not run.
func TestMaxTokensEndsTheTurn(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{
		line(map[string]any{"text": "Tuning", "tool": "tune", "args": map[string]any{"frequency": "146.52"}, "stop_reason": "max_tokens"}),
		line(map[string]any{"text": "again"}),
	}})
	w.say("t1", "tune")
	turn := w.doneTurn()
	if len(turn.GetTools()) != 0 || !strings.HasPrefix(turn.GetText(), "Tuning\n\n(The response reached the model's output limit") ||
		turn.GetStopReason() != leylinev1.StopReason_STOP_REASON_MAX_TOKENS {
		t.Errorf("turn: %v", turn)
	}
	if n := len(w.state().GetChannels()); n != 0 {
		t.Errorf("a cut-off tool call ran: %d channels", n)
	}
	w.say("t3", "go on")
	if turn := w.doneTurn(); turn.GetText() != "again" {
		t.Errorf("after the cut: %v", turn)
	}
}

// A refusal and the step bound each end the turn, and the turn says which.
func TestARefusalAndTheStepLimitSayWhyTheTurnEnded(t *testing.T) {
	t.Parallel()
	script := []string{line(map[string]any{"text": "No.", "stop_reason": "refusal"})}
	for range 40 {
		script = append(script, toolLine("get_state", map[string]any{}))
	}
	w := startWorker(t, workerConfig{script: script})
	w.say("t1", "something it will not do")
	if turn := w.doneTurn(); turn.GetStopReason() != leylinev1.StopReason_STOP_REASON_REFUSAL {
		t.Errorf("refused turn: %v", turn)
	}
	w.say("t3", "look forever")
	turn := w.doneTurn()
	if turn.GetStopReason() != leylinev1.StopReason_STOP_REASON_STEP_LIMIT || !strings.Contains(turn.GetText(), "stopped after 40 steps") {
		t.Errorf("turn at the step bound: %v", turn)
	}
}

// Undo of a channel the user has stopped since says so and moves on to the change before it.
func TestUndoAStoppedChannel(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{
		toolLine("tune", map[string]any{"frequency": "146.52"}),
		toolLine("set", map[string]any{"param": "squelch", "value": "-45"}),
		line(map[string]any{"text": "done"}),
		toolLine("undo", nil),
		toolLine("undo", nil),
		toolLine("undo", nil),
		line(map[string]any{"text": "ok"}),
	}})
	w.say("t1", "tune and set")
	w.doneTurn()
	ch := w.state().GetChannels()[0]
	if _, err := w.client.Control.DestroyChannel(t.Context(), &leylinev1.DestroyChannelRequest{ChannelId: ch.GetChannelId()}); err != nil {
		t.Fatal(err)
	}
	w.say("t3", "undo everything")
	turn := w.doneTurn()
	var said []string
	for _, c := range turn.GetTools() {
		said = append(said, c.GetResultText())
		if strings.Contains(c.GetResultText(), "already stopped") && c.GetIsError() {
			t.Errorf("a stopped channel is not an error: %v", c)
		}
	}
	if len(said) != 3 || !strings.Contains(said[0], "that channel was already stopped") ||
		!strings.Contains(said[1], "that channel was already stopped") || !strings.Contains(said[2], "nothing to undo") {
		t.Errorf("undo results: %q", said)
	}
}

// A view tool name the Messages API would refuse is left out, with a line on stderr.
func TestBadViewToolNamesAreDropped(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{
		viewTools: []*leylinev1.ViewTool{{Name: "move view!"}, {Name: "show_band"}},
		script:    []string{toolLine("move view!", nil)},
	})
	w.say("t1", "move")
	turn := w.doneTurn()
	if c := turn.GetTools()[0]; !c.GetIsError() || !strings.Contains(c.GetResultText(), "no tool called") {
		t.Errorf("a dropped view tool ran: %v", c)
	}
	if !strings.Contains(w.stderr.String(), `left out the view tool "move view!"`) {
		t.Errorf("stderr: %s", w.stderr.String())
	}
}
