// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"strings"
	"testing"
	"time"
)

// `ley ask --yes --json` output by hand: the conversation as the request was sent, mid-turn with
// one call running, and done. The finished turn read the records, asked before a webhook watch
// (allowed by --yes), had one call declined, and answered with a JSON block.
const sampleConversation = `{"conversationId":"conv_01","state":"CONVERSATION_THINKING","provider":"anthropic","model":"claude-sonnet-5-5","turns":[{"turnId":"t1","role":"ROLE_USER","text":"list the APRS stations"}]}
{"conversationId":"conv_01","state":"CONVERSATION_THINKING","provider":"anthropic","model":"claude-sonnet-5-5","turns":[{"turnId":"t1","role":"ROLE_USER","text":"list the APRS stations"},{"turnId":"t2","role":"ROLE_ASSISTANT","text":"Reading.","tools":[{"callId":"c1","tool":"query_records","argumentsJson":"{\"protocol\":\"aprs\"}","state":"TOOL_CALL_RUNNING"}]}]}
{"conversationId":"conv_01","state":"CONVERSATION_IDLE","provider":"anthropic","model":"claude-sonnet-5-5","turns":[{"turnId":"t1","role":"ROLE_USER","text":"list the APRS stations"},{"turnId":"t2","role":"ROLE_ASSISTANT","done":true,"text":"Reading. Two stations.\n\n` + "```json\\n" + `{\"stations\":[{\"callsign\":\"LEYTST-1\"},{\"callsign\":\"LEYTST-4\"}]}\n` + "```" + `","tools":[{"callId":"c1","tool":"query_records","argumentsJson":"{\"protocol\":\"aprs\"}","state":"TOOL_CALL_DONE","resultText":"2 records","resultJson":"{\"records\":[]}"},{"callId":"c2","tool":"watch","argumentsJson":"{\"decoder\":\"aprs\",\"notify\":\"webhook:https://example.invalid/x\"}","state":"TOOL_CALL_DONE","reason":"add a webhook notifier: every matching record is sent to the URL","resultText":"Watching"},{"callId":"c3","tool":"delete_recording","argumentsJson":"{\"recording\":\"job_1\"}","state":"TOOL_CALL_REFUSED","reason":"delete the recording and its files; this cannot be undone"},{"callId":"c4","tool":"tune","argumentsJson":"{\"frequency\":\"144.8\"}","state":"TOOL_CALL_DONE","isError":true,"resultText":"FREQ_OUT_OF_RANGE"}]}]}
`

func TestParseConversation(t *testing.T) {
	log, err := ParseStream(strings.NewReader(sampleConversation))
	if err != nil {
		t.Fatal(err)
	}
	if log.ConversationID != "conv_01" || log.Subtype != "success" || log.Turns != 1 || len(log.Lines) != 3 {
		t.Errorf("conversation: id %q subtype %q turns %d lines %d", log.ConversationID, log.Subtype, log.Turns, len(log.Lines))
	}
	var kinds []string
	for _, e := range log.Events {
		kinds = append(kinds, e.Kind)
	}
	if got := strings.Join(kinds, " "); got != "tool_use tool_result tool_use tool_result tool_use tool_result tool_use tool_result result" {
		t.Errorf("events: %s", got)
	}
	if r := log.ResultFor("c1"); r == nil || !strings.Contains(r.Result, "2 records") || !strings.Contains(r.Result, `{"records":[]}`) {
		t.Errorf("c1's result: %+v", r)
	}
	if r := log.ResultFor("c2"); r == nil || r.IsError || !strings.HasPrefix(r.Result, "[the assistant asked first: add a webhook notifier") {
		t.Errorf("c2's result: %+v", r)
	}
	if r := log.ResultFor("c3"); r == nil || !r.IsError || !strings.Contains(r.Result, "declined") {
		t.Errorf("c3's result: %+v", r)
	}
	answer, err := log.Answer()
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := listAt(answer, "stations", "callsign"); len(got) != 2 {
		t.Errorf("stations: %v", got)
	}
	m := MeasureLog(log)
	if m.ToolCalls != 4 || m.ToolErrors != 2 || m.ShellCalls != 0 || m.ByTool["watch"] != 1 || m.Subtype != "success" {
		t.Errorf("metrics: %+v", m)
	}

	s := &Scenario{
		Name: "sample", Task: "list the APRS stations",
		Truth: map[string]any{"stations": []any{"LEYTST-1", "LEYTST-4"}},
		Checks: []Check{
			{Type: "answered"},
			{Type: "json_set_equals", Path: "stations", Field: "callsign", Truth: "stations", Exact: true},
			{Type: "used_one_of", Values: []any{"list_entities", "query_records"}},
			{Type: "used_tool", Tool: "watch"},
			{Type: "not_used_tool", Tool: "delete_recording"},
			{Type: "max_tool_calls", N: 4},
			{Type: "max_tool_calls", N: 3},
			{Type: "no_shell"},
			{Type: "no_tool_errors"},
			{Type: "require_words", Words: []string{"two stations"}},
		},
	}
	want := []bool{true, true, true, true, false, true, false, true, false, true}
	for i, v := range Grade(s, log) {
		if v.Pass != want[i] {
			t.Errorf("check %d (%s): pass=%v, want %v: %s", i, v.Type, v.Pass, want[i], v.Detail)
		}
	}

	res := &Result{Scenario: "sample", Mode: "assistant", StartedAt: time.Now(), Metrics: m}
	res.Metrics.Tokens = &Tokens{Requests: 3, InputTokens: 1200, OutputTokens: 300}
	out := Transcript(s, res, log)
	for _, w := range []string{"assistant mode", "The ledger: 3 requests, 1200 tokens in, 300 out", "**2. → watch**", "← error", "## Final answer", "Two stations."} {
		if !strings.Contains(out, w) {
			t.Errorf("transcript lacks %q:\n%s", w, out)
		}
	}
	if sum := Summary([]*Result{res}); !strings.Contains(sum, "2k tok") {
		t.Errorf("summary:\n%s", sum)
	}
}

// A conversation that failed is a log with no answer, and says why.
func TestParseFailedConversation(t *testing.T) {
	line := `{"conversationId":"conv_02","state":"CONVERSATION_FAILED","error":{"code":"CREDENTIAL_MISSING","message":"no key"},"turns":[{"turnId":"t1","role":"ROLE_USER","text":"hi"}]}` + "\n"
	log, err := ParseStream(strings.NewReader(line))
	if err != nil {
		t.Fatal(err)
	}
	if log.Subtype != "failed: CREDENTIAL_MISSING" || log.Final != "" {
		t.Errorf("failed conversation: %+v", log)
	}
	if _, err := log.Answer(); err == nil {
		t.Error("a failed conversation has no answer block")
	}
}
