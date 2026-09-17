// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// The transcript is the message log for a person: the verdicts first, then the conversation in
// order with every tool call and what came back, long results folded so the page scans and
// nothing is lost. It is Markdown, so it reads in a terminal, an editor or a viewer alike.

// resultFold is how much of a tool result shows before the rest folds away.
const resultFold = 700

// Transcript renders one run. s and res may be nil for a log rendered on its own (`leyeval show`).
func Transcript(s *Scenario, res *Result, log *Log) string {
	var b strings.Builder
	name := "log"
	if s != nil {
		name = s.Name
	} else if res != nil {
		name = res.Scenario
	}
	fmt.Fprintf(&b, "# %s\n\n", name)
	if s != nil && s.Description != "" {
		b.WriteString(s.Description + "\n\n")
	}
	if res != nil {
		fmt.Fprintf(&b, "%s mode", res.Mode)
		if res.Model != "" {
			fmt.Fprintf(&b, ", model %s", res.Model)
		}
		fmt.Fprintf(&b, ", %s. ", res.StartedAt.Format(time.RFC3339))
		m := res.Metrics
		fmt.Fprintf(&b, "%d tool calls (%s), %d to the host, %d errors, %d turns, %.1f s, $%.3f.\n\n",
			m.ToolCalls, sortedTools(m.ByTool), m.ShellCalls, m.ToolErrors, m.Turns, float64(m.DurationMs)/1000, m.CostUSD)
		if res.Error != "" {
			fmt.Fprintf(&b, "**Harness error:** %s\n\n", res.Error)
		}
		if len(res.Verdicts) > 0 {
			fmt.Fprintf(&b, "## Checks: %d passed, %d failed\n\n", res.Passed, res.Failed)
			b.WriteString("| result | check | detail | why |\n|---|---|---|---|\n")
			for _, v := range res.Verdicts {
				mark := "pass"
				if !v.Pass {
					mark = "**FAIL**"
				}
				fmt.Fprintf(&b, "| %s | `%s` | %s | %s |\n", mark, v.Type, cell(v.Detail), cell(v.Why))
			}
			b.WriteString("\n")
		}
	}
	if s != nil {
		b.WriteString("## Task\n\n")
		b.WriteString(indent(strings.TrimSpace(s.Task)) + "\n\n")
	}
	b.WriteString("## Conversation\n\n")
	step := 0
	for _, e := range log.Events {
		switch e.Kind {
		case "init":
			if len(e.Servers) > 0 {
				var parts []string
				for k, v := range e.Servers {
					parts = append(parts, k+": "+v)
				}
				fmt.Fprintf(&b, "_MCP servers at start: %s_\n\n", strings.Join(parts, ", "))
			}
		case "text":
			b.WriteString(indent(strings.TrimSpace(e.Text)) + "\n\n")
		case "tool_use":
			step++
			fmt.Fprintf(&b, "**%d. → %s** `%s`\n\n", step, ShortTool(e.Tool), compactJSON(e.Input))
		case "tool_result":
			label := "←"
			if e.IsError {
				label = "← error"
			}
			body := strings.TrimSpace(e.Result)
			if len(body) <= resultFold {
				fmt.Fprintf(&b, "%s\n\n```\n%s\n```\n\n", label, body)
			} else {
				fmt.Fprintf(&b, "%s (%d chars)\n\n```\n%s\n```\n\n<details><summary>the rest</summary>\n\n```\n%s\n```\n\n</details>\n\n",
					label, len(body), body[:resultFold], body[resultFold:])
			}
		case "result":
			b.WriteString("## Final answer\n\n")
			b.WriteString(strings.TrimSpace(e.Text) + "\n\n")
		}
	}
	if log.Subtype != "" && log.Subtype != "success" {
		fmt.Fprintf(&b, "_The agent stopped with `%s`._\n", log.Subtype)
	}
	return b.String()
}

// indent quotes prose as the agent's, one level.
func indent(s string) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = "> " + l
	}
	return strings.Join(lines, "\n")
}

// cell keeps a table cell on one line.
func cell(s string) string {
	s = strings.ReplaceAll(s, "|", "\\|")
	return strings.ReplaceAll(s, "\n", " ")
}

// compactJSON is tool input on one line, or the raw bytes when it is not JSON.
func compactJSON(raw json.RawMessage) string {
	if len(raw) == 0 {
		return "{}"
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return string(raw)
	}
	out, err := json.Marshal(v)
	if err != nil {
		return string(raw)
	}
	s := string(out)
	if len(s) > 400 {
		s = s[:400] + "…"
	}
	return s
}
