// SPDX-License-Identifier: Apache-2.0

package assistant_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/assistant"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

var (
	scopeOnce         = leylinev1.ApprovalScope_APPROVAL_SCOPE_ONCE
	scopeConversation = leylinev1.ApprovalScope_APPROVAL_SCOPE_CONVERSATION
)

// keptWatch and keptDecode are two tools on one row, "start a kept job"; webhook is another row.
var (
	keptWatch  = toolLine("watch", map[string]any{"decoder": "aprs", "keep": true})
	keptDecode = toolLine("start_decode_job", map[string]any{"decoder": "aprs", "keep": true})
	webhook    = toolLine("watch", map[string]any{"decoder": "aprs", "notify": "webhook:http://127.0.0.1:9/hook"})
)

// A question answered for the conversation offers both scopes, and the grant lets a later call on
// the same row run, by another tool and in a later turn, reported with its reason and the question
// that granted it; a call on another row still asks.
func TestAGrantCoversLaterCallsOnItsRow(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{keptWatch, line(map[string]any{"text": "watching"}), keptDecode, webhook}})
	w.say("t1", "watch APRS for good")
	first := w.asking()
	if !slices.Equal(first.GetOffers(), []leylinev1.ApprovalScope{scopeOnce, scopeConversation}) {
		t.Errorf("the question's offers: %v", first.GetOffers())
	}
	w.allow(first.GetCallId(), scopeConversation)
	w.doneTurn()

	w.say("t3", "and decode it too, then send it to my hook")
	call := w.asking()
	if call.GetTool() != "watch" || !strings.Contains(call.GetReason(), "webhook") || call.GetAllowedBy() != "" {
		t.Errorf("the webhook should ask: %v", call)
	}
	decode := callNamed(w.last, "start_decode_job")
	// It reached the tool without asking; the tool's own answer (the radio is busy with the
	// watch) is the daemon's business.
	if decode.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE {
		t.Fatalf("the kept decode job should have run: %v", decode)
	}
	if decode.GetAllowedBy() != first.GetCallId() || !strings.Contains(decode.GetReason(), "start a kept aprs job") || len(decode.GetOffers()) != 0 {
		t.Errorf("the call the grant covered: %v", decode)
	}
	w.resolve(call.GetCallId(), false)
	w.doneTurn()
}

// An answer once grants nothing: the next call on the row asks again.
func TestAnAnswerOnceGrantsNothing(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{script: []string{keptWatch, keptDecode}})
	w.say("t1", "watch and decode APRS for good")
	w.allow(w.asking().GetCallId(), scopeOnce)
	if again := w.asking(); again.GetTool() != "start_decode_job" {
		t.Errorf("the second kept job: %v", again)
	}
}

// A delete offers once only, and an answer for the conversation sent anyway allows it once.
func TestADeleteOffersOnceOnly(t *testing.T) {
	t.Parallel()
	seeded := []fakedaemon.SeedRecording{
		{JobID: "job_01SEEDA", Parts: [][]fakedaemon.SeedOver{{{OpenMs: 100, CloseMs: 900}}}},
		{JobID: "job_01SEEDB", Parts: [][]fakedaemon.SeedOver{{{OpenMs: 100, CloseMs: 900}}}},
	}
	w := startWorker(t, workerConfig{daemon: fakedaemon.Options{Recordings: seeded}, script: []string{
		toolLine("delete_recording", map[string]any{"recording": "job_01SEEDA"}),
		toolLine("delete_recording", map[string]any{"recording": "job_01SEEDB"}),
	}})
	w.say("t1", "delete both")
	call := w.asking()
	if !slices.Equal(call.GetOffers(), []leylinev1.ApprovalScope{scopeOnce}) {
		t.Errorf("a delete's offers: %v", call.GetOffers())
	}
	w.allow(call.GetCallId(), scopeConversation)
	second := w.asking()
	if second.GetCallId() == call.GetCallId() || !strings.Contains(second.GetReason(), "job_01SEEDB") {
		t.Errorf("the second delete should ask: %v", second)
	}
	if w.hasRecording("job_01SEEDA") {
		t.Error("the first delete did not run")
	}
}

// In AUTO nothing asks: a delete and a kept job run at once, each reported with its reason.
func TestAutoModeRunsEveryRow(t *testing.T) {
	t.Parallel()
	seeded := []fakedaemon.SeedRecording{{JobID: "job_01SEEDED", Parts: [][]fakedaemon.SeedOver{{{OpenMs: 100, CloseMs: 900}}}}}
	w := startWorker(t, workerConfig{
		mode: leylinev1.ApprovalMode_APPROVAL_MODE_AUTO, daemon: fakedaemon.Options{Recordings: seeded},
		script: []string{toolLine("delete_recording", map[string]any{"recording": "job_01SEEDED"}), keptWatch},
	})
	w.say("t1", "delete it and watch APRS for good")
	turn := w.doneTurn()
	for _, c := range turn.GetTools() {
		if c.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || c.GetIsError() || c.GetReason() == "" || c.GetAllowedBy() != "" {
			t.Errorf("a call in AUTO: %v", c)
		}
	}
	kept := 0
	for _, j := range w.jobs() {
		if j.GetDecode().GetKeep() {
			kept++
		}
	}
	if w.hasRecording("job_01SEEDED") || kept != 1 {
		t.Errorf("the calls did not run: recording kept %v, %d kept jobs", w.hasRecording("job_01SEEDED"), kept)
	}
}

// A grant is kept with the transcript: a worker that resumes the conversation runs a call the
// grant covers, and the grant line never reaches the model.
func TestAGrantSurvivesAResume(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	transcript, record := filepath.Join(dir, "transcript.jsonl"), filepath.Join(dir, "record.jsonl")
	cfg := workerConfig{script: []string{keptWatch, line(map[string]any{"text": "watching"}), keptDecode, webhook}, transcript: transcript, record: record}
	first := startWorker(t, cfg)
	first.say("t1", "watch APRS for good")
	asked := first.asking()
	first.allow(asked.GetCallId(), scopeConversation)
	first.doneTurn()

	cfg.resume = true
	second := startWorker(t, cfg)
	second.say("t3", "decode it too")
	if call := second.asking(); call.GetTool() != "watch" || !strings.Contains(call.GetReason(), "webhook") {
		t.Errorf("the webhook should still ask: %v", call)
	}
	decode := callNamed(second.last, "start_decode_job")
	if decode.GetState() != leylinev1.ToolCallState_TOOL_CALL_DONE || decode.GetAllowedBy() != asked.GetCallId() {
		t.Errorf("the resumed worker's kept job: %v", decode)
	}

	if _, skipped, err := assistant.LoadTranscript(transcript); err != nil || skipped != 0 {
		t.Errorf("LoadTranscript skipped %d lines (%v)", skipped, err)
	}
	raw, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	for i, sent := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var messages []assistant.Message
		if err := json.Unmarshal([]byte(sent), &messages); err != nil {
			t.Fatal(err)
		}
		for _, m := range messages {
			if m.Role != "user" && m.Role != "assistant" {
				t.Errorf("model call %d carried a %q message", i+1, m.Role)
			}
		}
	}
}
