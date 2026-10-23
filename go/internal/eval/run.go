// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Result is one scenario's run: what was checked, how the agent worked, and where the log is.
type Result struct {
	Scenario    string    `json:"scenario"`
	Description string    `json:"description,omitempty"`
	Mode        string    `json:"mode"`
	Model       string    `json:"model,omitempty"`
	StartedAt   time.Time `json:"started_at"`
	// Skipped says why the scenario did not run; nothing else is set then.
	Skipped string `json:"skipped,omitempty"`
	// Error is a harness failure (the daemon or the agent could not run), not a failed check.
	Error    string    `json:"error,omitempty"`
	Verdicts []Verdict `json:"verdicts,omitempty"`
	Passed   int       `json:"passed"`
	Failed   int       `json:"failed"`
	Metrics  Metrics   `json:"metrics"`
	// Dir holds messages.jsonl, transcript.md and result.json.
	Dir string `json:"dir"`
}

// Metrics is how the agent worked, whatever it answered.
type Metrics struct {
	ToolCalls int            `json:"tool_calls"`
	ByTool    map[string]int `json:"by_tool"`
	// HarnessCalls are the agent's client loading tool schemas (ToolSearch), outside every budget.
	HarnessCalls int     `json:"harness_calls,omitempty"`
	ShellCalls   int     `json:"shell_calls"`
	ToolErrors   int     `json:"tool_errors"`
	Turns        int     `json:"turns"`
	DurationMs   int64   `json:"duration_ms"`
	CostUSD      float64 `json:"cost_usd"`
	// Tokens, in assistant mode, are the conversation's from the daemon's ledger (`ley ai usage`):
	// the provider's counts, which the owner prices from the provider's list.
	Tokens *Tokens `json:"tokens,omitempty"`
	// Subtype is the agent's result subtype: "success", or why it stopped.
	Subtype string `json:"subtype,omitempty"`
	// MCP is the leyline server's status at init, as the agent reported it.
	MCP string `json:"mcp,omitempty"`
}

// MeasureLog is the metrics of a log.
func MeasureLog(log *Log) Metrics {
	m := Metrics{ByTool: map[string]int{}, Turns: log.Turns, DurationMs: log.DurationMs, CostUSD: log.CostUSD, Subtype: log.Subtype}
	for _, e := range log.Events {
		switch e.Kind {
		case "tool_use":
			if IsHarness(e.Tool) {
				m.HarnessCalls++
				continue
			}
			m.ToolCalls++
			m.ByTool[ShortTool(e.Tool)]++
			if IsShell(e.Tool) {
				m.ShellCalls++
			}
		case "tool_result":
			if e.IsError {
				m.ToolErrors++
			}
		case "init":
			if s, ok := e.Servers["leyline"]; ok {
				m.MCP = s
			}
		}
	}
	return m
}

// RunScenario runs the scenario once in each of its modes (Scenario.ModesFor), each in its own
// run directory under outDir.
func RunScenario(ctx context.Context, env Env, s *Scenario, outDir string) []*Result {
	modes := s.ModesFor(env)
	if len(modes) == 0 {
		return []*Result{{
			Scenario: s.Name, Description: s.Description, Mode: env.Mode, StartedAt: time.Now(),
			Skipped: "runs in " + strings.Join(s.Modes, " and ") + " only",
		}}
	}
	out := make([]*Result, 0, len(modes))
	for _, mode := range modes {
		if ctx.Err() != nil {
			break
		}
		dirName := s.Name
		if len(s.Modes) > 0 {
			dirName += "." + mode
		}
		out = append(out, runMode(ctx, env, s, mode, filepath.Join(outDir, dirName)))
	}
	return out
}

// Run runs one scenario in its own mode, or the runner's, and writes its run directory under
// outDir.
func Run(ctx context.Context, env Env, s *Scenario, outDir string) *Result {
	mode := env.Mode
	if s.Mode != "" {
		mode = s.Mode
	}
	return runMode(ctx, env, s, mode, filepath.Join(outDir, s.Name))
}

// runMode runs the scenario in one mode in dir.
func runMode(ctx context.Context, env Env, s *Scenario, mode, dir string) *Result {
	res := &Result{Scenario: s.Name, Description: s.Description, StartedAt: time.Now(), Mode: mode, Model: env.Model}
	if s.Skip != "" {
		res.Skipped = s.Skip
		return res
	}
	if mode == "assistant" {
		if why := env.assistantSkip(); why != "" {
			res.Skipped = why
			return res
		}
		if env.Script != "" {
			res.Model = "scripted"
		} else if res.Model == "" {
			res.Model = DefaultAssistantModel
		}
	}
	for _, f := range s.Fixtures {
		if env.fixtureMissing(f) {
			if f.Optional {
				res.Skipped = fmt.Sprintf("fixture %s is not on this machine", f.File)
				return res
			}
			res.Error = fmt.Sprintf("fixture %s is missing", f.File)
			return res
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		res.Error = err.Error()
		return res
	}
	res.Dir = dir
	env.Log("%s: starting the daemon", s.Name)
	d, err := startDaemon(ctx, env, dir, s.SpeechScript)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	defer d.stop()
	// From before the fixtures, so the log holds every write of the run and the checks tell the
	// agent's from the setup's by caused_by.
	rec, err := startEventRecorder(ctx, d.client, filepath.Join(dir, "events.jsonl"))
	if err != nil {
		res.Error = err.Error()
		return res
	}
	for _, f := range s.Fixtures {
		if err := d.attach(ctx, f); err != nil {
			res.Error = err.Error()
			return res
		}
	}
	if err := d.setup(ctx, s.Setup); err != nil {
		res.Error = err.Error()
		return res
	}
	prompt := s.Prompt(mode)
	_ = os.WriteFile(filepath.Join(dir, "prompt.md"), []byte(prompt), 0o644)
	actx, cancel := context.WithTimeout(ctx, env.Timeout)
	defer cancel()
	log, tokens, err := runAgentIn(actx, env, s, d, dir, prompt, mode)
	if err != nil {
		res.Error = err.Error()
	}
	if log != nil {
		recordWrites(ctx, env, d, rec, dir, log)
		res.Verdicts = Grade(s, log)
		res.Metrics = MeasureLog(log)
		res.Metrics.Tokens = tokens
		for _, v := range res.Verdicts {
			if v.Pass {
				res.Passed++
			} else {
				res.Failed++
			}
		}
		_ = os.WriteFile(filepath.Join(dir, "transcript.md"), []byte(Transcript(s, res, log)), 0o644)
	}
	if b, err := json.MarshalIndent(res, "", "  "); err == nil {
		_ = os.WriteFile(filepath.Join(dir, "result.json"), b, 0o644)
	}
	return res
}

// runAgentIn runs the mode's agent and saves its log as messages.jsonl.
func runAgentIn(ctx context.Context, env Env, s *Scenario, d *daemon, dir, prompt, mode string) (*Log, *Tokens, error) {
	if mode == "assistant" {
		env.Log("%s: running the assistant", s.Name)
		log, raw, tokens, err := runAssistant(ctx, env, d, dir, prompt)
		_ = os.WriteFile(filepath.Join(dir, "messages.jsonl"), raw, 0o644)
		return log, tokens, err
	}
	mcpPath, err := mcpConfig(dir, env.Ley, d.socket, filepath.Join(dir, "leylined.log"))
	if err != nil {
		return nil, nil, err
	}
	maxTurns := s.MaxTurns
	if maxTurns == 0 {
		maxTurns = env.MaxTurns
	}
	env.Log("%s: running the agent (%s mode, %d turns at most)", s.Name, mode, maxTurns)
	log, raw, err := runAgent(ctx, env, dir, prompt, mode, maxTurns, mcpPath)
	_ = os.WriteFile(filepath.Join(dir, "messages.jsonl"), raw, 0o644)
	return log, nil, err
}

// recordWrites ends the event log at the daemon's event_seq now that the agent has exited, and
// hands the log what no_write reads. A log that could not be finished is left unrecorded, so
// no_write fails rather than passes on part of one.
func recordWrites(ctx context.Context, env Env, d *daemon, rec *eventRecorder, dir string, log *Log) {
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	st, err := d.client.State(wctx)
	if err != nil {
		env.Log("reading the daemon's event seq: %v", err)
		_ = rec.stopAt(wctx, 0)
		return
	}
	if err := rec.stopAt(wctx, st.GetEventSeq()); err != nil {
		env.Log("the daemon's event log: %v", err)
		return
	}
	f, err := os.Open(filepath.Join(dir, "events.jsonl"))
	if err != nil {
		env.Log("the daemon's event log: %v", err)
		return
	}
	defer f.Close()
	events, err := ReadEvents(f)
	if err != nil {
		env.Log("the daemon's event log: %v", err)
		return
	}
	log.DaemonEvents, log.HasDaemonEvents = events, true
}

// Summary is the table a run ends with, one line per scenario.
func Summary(results []*Result) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%-28s %-9s %6s %6s %6s %6s %10s %s\n", "SCENARIO", "MODE", "PASS", "FAIL", "TOOLS", "SHELL", "COST", "NOTE")
	for _, r := range results {
		note := ""
		switch {
		case r.Skipped != "":
			note = "skipped: " + r.Skipped
		case r.Error != "":
			note = "error: " + firstLine(r.Error)
		case r.Failed == 0:
			note = "ok"
		}
		if r.Skipped != "" || (r.Error != "" && r.Verdicts == nil) {
			fmt.Fprintf(&b, "%-28s %-9s %6s %6s %6s %6s %10s %s\n", r.Scenario, r.Mode, "-", "-", "-", "-", "-", note)
			continue
		}
		fmt.Fprintf(&b, "%-28s %-9s %6d %6d %6d %6d %10s %s\n", r.Scenario, r.Mode, r.Passed, r.Failed,
			r.Metrics.ToolCalls, r.Metrics.ShellCalls, costCell(r.Metrics), note)
	}
	return b.String()
}

// costCell is the summary's cost: claude's dollars, or the assistant's tokens in and out (the
// ledger counts tokens, not money; result.json has the cache columns too).
func costCell(m Metrics) string {
	if m.Tokens != nil {
		return fmt.Sprintf("%dk tok", (m.Tokens.InputTokens+m.Tokens.OutputTokens+500)/1000)
	}
	return fmt.Sprintf("%.3f", m.CostUSD)
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// sortedTools is a metrics map as "scan×3, get_state×1".
func sortedTools(m map[string]int) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s×%d", k, m[k]))
	}
	return strings.Join(parts, ", ")
}
