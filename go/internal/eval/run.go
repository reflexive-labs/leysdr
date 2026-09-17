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

// Run runs one scenario and writes its run directory under outDir.
func Run(ctx context.Context, env Env, s *Scenario, outDir string) *Result {
	res := &Result{Scenario: s.Name, Description: s.Description, StartedAt: time.Now(), Mode: env.Mode, Model: env.Model}
	if s.Mode != "" {
		res.Mode = s.Mode
	}
	if s.Skip != "" {
		res.Skipped = s.Skip
		return res
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
	dir := filepath.Join(outDir, s.Name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		res.Error = err.Error()
		return res
	}
	res.Dir = dir
	env.Log("%s: starting the daemon", s.Name)
	d, err := startDaemon(ctx, env, dir)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	defer d.stop()
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
	mcpPath, err := mcpConfig(dir, env.Ley, d.socket, filepath.Join(dir, "leylined.log"))
	if err != nil {
		res.Error = err.Error()
		return res
	}
	maxTurns := s.MaxTurns
	if maxTurns == 0 {
		maxTurns = env.MaxTurns
	}
	prompt := s.Prompt(res.Mode)
	_ = os.WriteFile(filepath.Join(dir, "prompt.md"), []byte(prompt), 0o644)
	env.Log("%s: running the agent (%s mode, %d turns at most)", s.Name, res.Mode, maxTurns)
	actx, cancel := context.WithTimeout(ctx, env.Timeout)
	defer cancel()
	log, raw, err := runAgent(actx, env, dir, prompt, res.Mode, maxTurns, mcpPath)
	_ = os.WriteFile(filepath.Join(dir, "messages.jsonl"), raw, 0o644)
	if err != nil {
		res.Error = err.Error()
	}
	if log != nil {
		res.Verdicts = Grade(s, log)
		res.Metrics = MeasureLog(log)
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

// Summary is the table a run ends with, one line per scenario.
func Summary(results []*Result) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%-28s %-8s %6s %6s %6s %6s %8s %s\n", "SCENARIO", "MODE", "PASS", "FAIL", "TOOLS", "SHELL", "COST", "NOTE")
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
			fmt.Fprintf(&b, "%-28s %-8s %6s %6s %6s %6s %8s %s\n", r.Scenario, r.Mode, "-", "-", "-", "-", "-", note)
			continue
		}
		fmt.Fprintf(&b, "%-28s %-8s %6d %6d %6d %6d %8.3f %s\n", r.Scenario, r.Mode, r.Passed, r.Failed,
			r.Metrics.ToolCalls, r.Metrics.ShellCalls, r.Metrics.CostUSD, note)
	}
	return b.String()
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
