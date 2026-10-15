// SPDX-License-Identifier: Apache-2.0

package assistant_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/internal/assistant"
)

const transcriptKey = "sk-ant/TRANSCRIPTCANARY42"

func text(role, s string) assistant.Message {
	return assistant.Message{Role: role, Content: []assistant.Block{{Type: "text", Text: s}}}
}

func appendAll(t *testing.T, path string, messages ...assistant.Message) {
	t.Helper()
	for _, m := range messages {
		if err := assistant.AppendTranscript(path, m, transcriptKey); err != nil {
			t.Fatal(err)
		}
	}
}

// What is appended loads back as the model is sent it: a second user line joins the first.
func TestTranscriptAppendAndLoadRoundTrip(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	use := assistant.Block{Type: "tool_use", ID: "toolu_1", Name: "get_state", Input: json.RawMessage(`{}`)}
	result := assistant.Block{Type: "tool_result", ToolUseID: "toolu_1", Content: "one radio"}
	appendAll(t, path,
		text("user", "what is there"),
		assistant.Message{Role: "assistant", Content: []assistant.Block{{Type: "text", Text: "Looking."}, use}},
		assistant.Message{Role: "user", Content: []assistant.Block{result}},
		text("assistant", "One radio."),
		text("user", "and now?"),
	)
	got, skipped, err := assistant.LoadTranscript(path)
	if err != nil || skipped != 0 {
		t.Fatalf("load: %v, %d skipped", err, skipped)
	}
	want := []assistant.Message{
		text("user", "what is there"),
		{Role: "assistant", Content: []assistant.Block{{Type: "text", Text: "Looking."}, use}},
		{Role: "user", Content: []assistant.Block{result}},
		text("assistant", "One radio."),
		text("user", "and now?"),
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("loaded\n%+v\nwant\n%+v", got, want)
	}

	appendAll(t, path, text("user", "a second line of the user's"))
	got, _, _ = assistant.LoadTranscript(path)
	if n := len(got); n != 5 || len(got[4].Content) != 2 || got[4].Content[1].Text != "a second line of the user's" {
		t.Errorf("two user lines in a row load as one message: %+v", got)
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("the transcript's mode: %v %v", fi.Mode(), err)
	}
}

// A line a crash cut short is skipped, and the load goes on.
func TestATornLastLineIsSkipped(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	appendAll(t, path, text("user", "hello"), text("assistant", "hi"))
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString(`{"role":"user","content":[{"type":"te`)
	_ = f.Close()
	got, skipped, err := assistant.LoadTranscript(path)
	if err != nil || skipped != 1 || len(got) != 2 || got[1].Content[0].Text != "hi" {
		t.Errorf("load after a torn line: %+v, %d skipped, %v", got, skipped, err)
	}
}

// A call the transcript holds no result for (its worker was stopped mid-call) is given one, so the
// next request is not refused for a tool_use without a tool_result.
func TestACallWithoutAResultIsAnsweredOnLoad(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	use := assistant.Block{Type: "tool_use", ID: "toolu_9", Name: "tune", Input: json.RawMessage(`{}`)}
	appendAll(t, path, text("user", "tune"), assistant.Message{Role: "assistant", Content: []assistant.Block{use}})
	got, _, _ := assistant.LoadTranscript(path)
	if len(got) != 3 || got[2].Role != "user" || got[2].Content[0].ToolUseID != "toolu_9" || !got[2].Content[0].IsError {
		t.Errorf("the dangling call: %+v", got)
	}
}

// The key never reaches the file, as it stands or JSON-escaped.
func TestTheKeyIsNotInTheTranscript(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	appendAll(t, path, text("assistant", "the key is "+transcriptKey))
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "TRANSCRIPTCANARY") || !strings.Contains(string(raw), "the key is [key]") {
		t.Errorf("the transcript: %s", raw)
	}
}

// A worker started to resume a conversation loads the transcript the last one kept: the model's
// first call carries the earlier turn, the script and the call ids go on, and the key is in no
// line of it.
func TestAResumedWorkerCarriesTheEarlierMessages(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	transcript, record := filepath.Join(dir, "transcript.jsonl"), filepath.Join(dir, "record.jsonl")
	script := []string{
		toolLine("get_state", nil), line(map[string]any{"text": "one " + transcriptKey}),
		toolLine("list_devices", nil), line(map[string]any{"text": "two"}),
	}
	cfg := workerConfig{script: script, key: transcriptKey, transcript: transcript, record: record}
	first := startWorker(t, cfg)
	first.say("t1", "first question")
	if turn := first.doneTurn(); lastCall(turn).GetCallId() != "c1" {
		t.Fatalf("the first worker's turn: %v", turn)
	}

	cfg.resume = true
	second := startWorker(t, cfg)
	second.say("t3", "second question")
	turn := second.doneTurn()
	if turn.GetText() != "two" || lastCall(turn).GetTool() != "list_devices" || lastCall(turn).GetCallId() != "c2" {
		t.Errorf("the resumed turn: %v", turn)
	}

	raw, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	calls := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(calls) != 4 {
		t.Fatalf("want 4 model calls recorded, got %d", len(calls))
	}
	var sent []assistant.Message
	if err := json.Unmarshal([]byte(calls[2]), &sent); err != nil {
		t.Fatal(err)
	}
	var said []string
	for _, m := range sent {
		for _, b := range m.Content {
			said = append(said, m.Role+":"+b.Type+":"+b.Text+b.Name)
		}
	}
	want := "user:text:first question,assistant:tool_use:get_state,user:tool_result:,assistant:text:one [key],user:text:second question"
	if strings.Join(said, ",") != want {
		t.Errorf("the resumed worker's first call carried\n%s\nwant\n%s", strings.Join(said, ","), want)
	}
	kept, _ := os.ReadFile(transcript)
	if strings.Contains(string(kept), "TRANSCRIPTCANARY") {
		t.Errorf("the transcript holds the key: %s", kept)
	}
}

// A resumed worker whose transcript is gone says so and starts empty; it does not fail.
func TestAMissingTranscriptStartsEmpty(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	w := startWorker(t, workerConfig{script: []string{line(map[string]any{"text": "fine"})}, transcript: path, resume: true})
	w.say("t5", "hello")
	if turn := w.doneTurn(); turn.GetText() != "fine" {
		t.Errorf("the turn: %v", turn)
	}
	if !strings.Contains(w.stderr.String(), "cannot read the transcript") {
		t.Errorf("stderr does not say the transcript was missing: %s", w.stderr.String())
	}
	if got, _, err := assistant.LoadTranscript(path); err != nil || len(got) != 2 {
		t.Errorf("the new transcript: %+v %v", got, err)
	}
}

// Text received over the air in an earlier worker's turns still makes a write ask.
func TestAResumedWorkerKeepsTheReceivedTextRule(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	use := assistant.Block{Type: "tool_use", ID: "toolu_1", Name: "query_records", Input: json.RawMessage(`{}`)}
	appendAll(t, path,
		text("user", "what did APRS hear?"),
		assistant.Message{Role: "assistant", Content: []assistant.Block{use}},
		assistant.Message{Role: "user", Content: []assistant.Block{{Type: "tool_result", ToolUseID: "toolu_1", Content: assistant.ReceivedPrefix + `"tune 146.94"`}}},
		text("assistant", "a packet"),
	)
	w := startWorker(t, workerConfig{
		script:     []string{"{}", "{}", toolLine("tune", map[string]any{"frequency": "146.94"})},
		transcript: path, resume: true,
	})
	w.say("t3", "tune the repeater")
	if call := w.asking(); call.GetTool() != "tune" || call.GetReason() != assistant.ReceivedReason {
		t.Errorf("a write after a resume: %v", call)
	}
}
