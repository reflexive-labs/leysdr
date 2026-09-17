// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A stream the way `claude -p --output-format stream-json` writes one: init, a tool call and its
// result, prose, a second tool call whose result is an error, the final answer with its JSON
// block, and the result line with its numbers.
const sampleStream = `{"type":"system","subtype":"init","mcp_servers":[{"name":"leyline","status":"connected"}],"tools":["mcp__leyline__scan"]}
{"type":"assistant","message":{"content":[{"type":"text","text":"I will sweep the band."},{"type":"tool_use","id":"t1","name":"mcp__leyline__scan","input":{"range":"145M..147M"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"FREQUENCY  SNR\n145.200 MHz 40\n"}]}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"mcp__leyline__tune","input":{"frequency":"101.1","take_over":true}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"the radio is on 146.520 MHz with 1 channel listening. Call again with take_over: true","is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Four carriers.\n\n` + "```json\\n" + `{\"carriers\":[{\"hz\":145200000,\"snr_db\":40},{\"hz\":\"145600000\",\"snr_db\":32},{\"hz\":146400000,\"snr_db\":24},{\"hz\":146800000,\"snr_db\":16}],\"summary\":\"four carriers\"}\n` + "```" + `"}]}}
{"type":"result","subtype":"success","result":"Four carriers.\n\n` + "```json\\n" + `{\"carriers\":[{\"hz\":145200000,\"snr_db\":40},{\"hz\":\"145600000\",\"snr_db\":32},{\"hz\":146400000,\"snr_db\":24},{\"hz\":146800000,\"snr_db\":16}],\"summary\":\"four carriers\"}\n` + "```" + `","num_turns":3,"duration_ms":4200,"total_cost_usd":0.0123,"usage":{"input_tokens":10}}
`

func TestParseStreamAndAnswer(t *testing.T) {
	log, err := ParseStream(strings.NewReader(sampleStream))
	if err != nil {
		t.Fatal(err)
	}
	kinds := []string{}
	for _, e := range log.Events {
		kinds = append(kinds, e.Kind)
	}
	if got := strings.Join(kinds, " "); got != "init text tool_use tool_result tool_use tool_result text result" {
		t.Errorf("events: %s", got)
	}
	if log.Turns != 3 || log.CostUSD != 0.0123 || log.DurationMs != 4200 || log.Subtype != "success" {
		t.Errorf("result numbers: %+v", log)
	}
	if len(log.Lines) != 7 {
		t.Errorf("raw lines kept: %d", len(log.Lines))
	}
	answer, err := log.Answer()
	if err != nil {
		t.Fatal(err)
	}
	carriers, _ := listAt(answer, "carriers", "hz")
	if len(carriers) != 4 {
		t.Errorf("carriers: %v", carriers)
	}
	if r := log.ResultFor("t2"); r == nil || !r.IsError || !strings.Contains(r.Result, "take_over") {
		t.Errorf("t2's result: %+v", r)
	}
	m := MeasureLog(log)
	if m.ToolCalls != 2 || m.ToolErrors != 1 || m.ShellCalls != 0 || m.MCP != "connected" || m.ByTool["scan"] != 1 {
		t.Errorf("metrics: %+v", m)
	}
}

func TestChecksOnTheSample(t *testing.T) {
	log, _ := ParseStream(strings.NewReader(sampleStream))
	s := &Scenario{
		Name:  "sample",
		Task:  "x",
		Truth: map[string]any{"carriers": []any{145200000, 145600000, 146400000, 146800000}, "none": nil},
		Checks: []Check{
			{Type: "answered"},
			{Type: "json_within", Path: "carriers", Field: "hz", Truth: "carriers", Tolerance: 30000, Exact: true},
			{Type: "json_within", Path: "carriers", Field: "hz", Values: []any{145200000, 150000000}, Tolerance: 1000},
			{Type: "json_set_equals", Path: "carriers", Field: "snr_db", Values: []any{40, 32, 24, 16}, Exact: true},
			{Type: "json_equals", Path: "summary", Value: "Four Carriers"},
			{Type: "json_equals", Path: "missing", Truth: "none"},
			{Type: "used_tool", Tool: "scan"},
			{Type: "used_one_of", Values: []any{"snapshot", "tune"}},
			{Type: "not_used_tool", Tool: "snapshot"},
			{Type: "max_tool_calls", N: 2},
			{Type: "max_tool_calls", N: 1},
			{Type: "no_shell"},
			{Type: "no_tool_errors"},
			{Type: "require_words", Words: []string{"carriers"}},
			{Type: "forbid_words", Words: []string{"repeater"}},
			{Type: "take_over_after_refusal"},
		},
	}
	want := []bool{true, true, false, true, true, false, true, true, true, true, false, true, false, true, true, false}
	verdicts := Grade(s, log)
	for i, v := range verdicts {
		if v.Pass != want[i] {
			t.Errorf("check %d (%s): pass=%v, want %v: %s", i, v.Type, v.Pass, want[i], v.Detail)
		}
	}
	// The refusal check: take_over before any refusal fails, after one passes.
	log2, _ := ParseStream(strings.NewReader(strings.Replace(sampleStream,
		`"input":{"frequency":"101.1","take_over":true}`, `"input":{"frequency":"101.1"}`, 1)))
	if v := checkTakeOverAfterRefusal(Check{}, s, log2, nil); !v.Pass {
		t.Errorf("no take_over at all should pass: %s", v.Detail)
	}
}

func TestTranscriptReadsInOrder(t *testing.T) {
	log, _ := ParseStream(strings.NewReader(sampleStream))
	s := &Scenario{Name: "sample", Description: "a sample", Task: "sweep it", Checks: []Check{{Type: "no_shell"}}}
	res := &Result{Scenario: "sample", Mode: "mcp", Verdicts: Grade(s, log), Metrics: MeasureLog(log), StartedAt: time.Now()}
	res.Passed = 1
	out := Transcript(s, res, log)
	for _, want := range []string{
		"# sample", "## Checks: 1 passed", "`no_shell`", "## Task", "> sweep it",
		"**1. → scan** `{\"range\":\"145M..147M\"}`", "← error", "## Final answer", "MCP servers at start: leyline: connected",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("transcript lacks %q:\n%s", want, out)
		}
	}
	if strings.Index(out, "→ scan") > strings.Index(out, "→ tune") {
		t.Error("tool calls out of order")
	}
	// A bare log renders too, with no scenario or result.
	if bare := Transcript(nil, nil, log); !strings.Contains(bare, "## Conversation") {
		t.Errorf("bare transcript:\n%s", bare)
	}
}

func TestScenariosParse(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "evals", "scenarios")
	all, err := LoadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) < 4 {
		t.Errorf("only %d scenarios", len(all))
	}
	for _, s := range all {
		if s.Description == "" || s.AnswerSchema == "" {
			t.Errorf("%s: no description or answer schema", s.Name)
		}
		if !strings.Contains(s.Prompt("mcp"), "```json") || !strings.Contains(s.Prompt("mcp"), "no shell") {
			t.Errorf("%s: the prompt should carry the schema and the mode rule", s.Name)
		}
	}
	bad := filepath.Join(t.TempDir(), "bad.yaml")
	_ = os.WriteFile(bad, []byte("task: x\nchecks:\n  - type: nonsense\n"), 0o644)
	if _, err := Load(bad); err == nil || !strings.Contains(err.Error(), "unknown type") {
		t.Errorf("an unknown check type must be refused when the scenario loads: %v", err)
	}
}

// The runner end to end with the real daemon and a fake agent: the fixture is attached under
// its neutral name, the prompt and MCP config are written, the fake's stream is graded and the
// run directory holds what `leyeval show` reads. Needs a built leylined, as the e2e does.
func TestRunWithAFakeAgent(t *testing.T) {
	daemon := os.Getenv("LEYLINED_BIN")
	ley := os.Getenv("LEY_BIN")
	if daemon == "" || ley == "" {
		t.Skip("set LEYLINED_BIN and LEY_BIN to run the eval runner against the real daemon")
	}
	fixtures, _ := filepath.Abs(filepath.Join("..", "..", "..", "fixtures"))
	if _, err := os.Stat(filepath.Join(fixtures, "scan_band.cf32")); err != nil {
		t.Skip("scan_band.cf32 missing; run make fixtures")
	}
	// The fake agent: it checks that the MCP config names ley mcp on the eval socket, keeps the
	// prompt it was given on stdin, then plays the sample stream, answer included.
	dir := t.TempDir()
	fake := filepath.Join(dir, "fake-agent.sh")
	stream := filepath.Join(dir, "stream.jsonl")
	// The sample's take_over-before-refusal is there for the checks test; the survey scenario
	// grades it, so the fake plays the stream without it.
	polite := strings.Replace(sampleStream, `"input":{"frequency":"101.1","take_over":true}`, `"input":{"frequency":"101.1"}`, 1)
	if err := os.WriteFile(stream, []byte(polite), 0o644); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\ncfg=''\nwhile [ $# -gt 0 ]; do if [ \"$1\" = --mcp-config ]; then cfg=$2; fi; shift; done\n" +
		"grep -q '\"mcp\"' \"$cfg\" || { echo 'no mcp config' >&2; exit 3; }\n" +
		"cat > \"$(dirname \"$cfg\")/seen-prompt.txt\"\ncat " + stream + "\n"
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	s, err := Load(filepath.Join("..", "..", "..", "evals", "scenarios", "survey-2m.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	env := Env{
		Daemon: daemon, Ley: ley, Fixtures: fixtures, Claude: fake, Mode: "mcp", MaxTurns: 5,
		Timeout: time.Minute, Log: func(string, ...any) {},
	}
	res := Run(context.Background(), env, s, dir)
	if res.Error != "" {
		t.Fatalf("run: %s", res.Error)
	}
	if res.Failed != 0 {
		for _, v := range res.Verdicts {
			t.Logf("%s: %v %s", v.Type, v.Pass, v.Detail)
		}
		t.Errorf("%d checks failed on the sample stream", res.Failed)
	}
	for _, f := range []string{"messages.jsonl", "transcript.md", "result.json", "prompt.md", "mcp.json", "seen-prompt.txt"} {
		if _, err := os.Stat(filepath.Join(res.Dir, f)); err != nil {
			t.Errorf("run directory lacks %s", f)
		}
	}
	prompt, _ := os.ReadFile(filepath.Join(res.Dir, "seen-prompt.txt"))
	if !strings.Contains(string(prompt), "145 and 147") {
		t.Errorf("the agent did not get the task:\n%s", prompt)
	}
	// The fixture went in under its neutral name: the radios directory holds radio-a and its
	// sidecar says nothing but format, rate and centre.
	side, err := os.ReadFile(filepath.Join(res.Dir, "radios", "radio-a.json"))
	if err != nil || strings.Contains(string(side), "description") || !strings.Contains(string(side), "146000000") {
		t.Errorf("neutral sidecar: %v\n%s", err, side)
	}
	if sum := Summary([]*Result{res}); !strings.Contains(sum, "survey-2m") || !strings.Contains(sum, "ok") {
		t.Errorf("summary:\n%s", sum)
	}
}
