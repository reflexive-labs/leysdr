// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

// A checker turns one Check and the run into a verdict. Adding a check type is adding an entry
// here; the YAML needs no new schema, because Check's fields are the union of what any of them
// read.

// Verdict is one check's outcome.
type Verdict struct {
	Type   string `json:"type"`
	Why    string `json:"why,omitempty"`
	Pass   bool   `json:"pass"`
	Detail string `json:"detail"`
}

type checker func(c Check, s *Scenario, log *Log, answer map[string]any) Verdict

var checkers = map[string]checker{
	"json_equals":             checkJSONEquals,
	"json_set_equals":         checkJSONSetEquals,
	"json_within":             checkJSONWithin,
	"require_words":           checkRequireWords,
	"forbid_words":            checkForbidWords,
	"used_tool":               checkUsedTool,
	"used_one_of":             checkUsedOneOf,
	"not_used_tool":           checkNotUsedTool,
	"max_tool_calls":          checkMaxToolCalls,
	"no_shell":                checkNoShell,
	"take_over_after_refusal": checkTakeOverAfterRefusal,
	"no_tool_errors":          checkNoToolErrors,
	"answered":                checkAnswered,
}

func checkTypes() []string {
	out := make([]string, 0, len(checkers))
	for k := range checkers {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Grade runs every check of the scenario.
func Grade(s *Scenario, log *Log) []Verdict {
	answer, _ := log.Answer()
	out := make([]Verdict, 0, len(s.Checks))
	for _, c := range s.Checks {
		v := checkers[c.Type](c, s, log, answer)
		v.Type, v.Why = c.Type, c.Why
		out = append(out, v)
	}
	return out
}

// expected is the values a check compares against: the truth key it names, else its literal.
func expected(c Check, s *Scenario) ([]any, error) {
	if c.Truth != "" {
		v, ok := s.Truth[c.Truth]
		if !ok {
			return nil, fmt.Errorf("truth has no key %q", c.Truth)
		}
		if list, ok := v.([]any); ok {
			return list, nil
		}
		return []any{v}, nil
	}
	if c.Values != nil {
		return c.Values, nil
	}
	if c.Value != nil {
		return []any{c.Value}, nil
	}
	return nil, fmt.Errorf("the check names no truth, values or value")
}

// at walks a dotted path into the answer: "tone.hz", "carriers".
func at(answer map[string]any, path string) (any, bool) {
	var cur any = answer
	if path == "" {
		return cur, answer != nil
	}
	for _, key := range strings.Split(path, ".") {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		cur, ok = m[key]
		if !ok {
			return nil, false
		}
	}
	return cur, true
}

// number reads a JSON scalar as a float: a number, or a string holding one (proto3 JSON
// writes 64-bit integers as strings, and an agent may copy that).
func number(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case json.Number:
		f, err := x.Float64()
		return f, err == nil
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(x), 64)
		return f, err == nil
	}
	return 0, false
}

// scalarKey renders a scalar for set comparison: numbers as numbers, strings trimmed and
// case-folded, so "LEYTST-1" and "leytst-1" are one station.
func scalarKey(v any) string {
	if f, ok := number(v); ok {
		return strconv.FormatFloat(f, 'f', -1, 64)
	}
	return strings.ToLower(strings.TrimSpace(fmt.Sprint(v)))
}

// listAt is the list at path, each entry reduced to its field when one is named.
func listAt(answer map[string]any, path, field string) ([]any, error) {
	v, ok := at(answer, path)
	if !ok {
		return nil, fmt.Errorf("the answer has no %q", path)
	}
	list, ok := v.([]any)
	if !ok {
		return nil, fmt.Errorf("%q is not a list", path)
	}
	if field == "" {
		return list, nil
	}
	out := make([]any, 0, len(list))
	for _, item := range list {
		m, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("an entry of %q is not an object", path)
		}
		f, ok := m[field]
		if !ok {
			return nil, fmt.Errorf("an entry of %q has no %q", path, field)
		}
		out = append(out, f)
	}
	return out, nil
}

func fail(detail string) Verdict { return Verdict{Pass: false, Detail: detail} }
func pass(detail string) Verdict { return Verdict{Pass: true, Detail: detail} }

func checkAnswered(_ Check, _ *Scenario, log *Log, answer map[string]any) Verdict {
	if answer == nil {
		_, err := log.Answer()
		return fail(err.Error())
	}
	return pass("the answer ends with a JSON block")
}

func checkJSONEquals(c Check, s *Scenario, _ *Log, answer map[string]any) Verdict {
	if answer == nil {
		return fail("no answer block")
	}
	want, err := expected(c, s)
	if err != nil {
		return fail(err.Error())
	}
	got, ok := at(answer, c.Path)
	if !ok {
		return fail(fmt.Sprintf("the answer has no %q", c.Path))
	}
	if scalarKey(got) == scalarKey(want[0]) {
		return pass(fmt.Sprintf("%s = %v", c.Path, got))
	}
	return fail(fmt.Sprintf("%s = %v, want %v", c.Path, got, want[0]))
}

func checkJSONSetEquals(c Check, s *Scenario, _ *Log, answer map[string]any) Verdict {
	if answer == nil {
		return fail("no answer block")
	}
	want, err := expected(c, s)
	if err != nil {
		return fail(err.Error())
	}
	got, err := listAt(answer, c.Path, c.Field)
	if err != nil {
		return fail(err.Error())
	}
	wantSet := map[string]bool{}
	for _, w := range want {
		wantSet[scalarKey(w)] = true
	}
	gotSet := map[string]bool{}
	for _, g := range got {
		gotSet[scalarKey(g)] = true
	}
	var missing, extra []string
	for k := range wantSet {
		if !gotSet[k] {
			missing = append(missing, k)
		}
	}
	for k := range gotSet {
		if !wantSet[k] {
			extra = append(extra, k)
		}
	}
	sort.Strings(missing)
	sort.Strings(extra)
	switch {
	case len(missing) > 0:
		return fail(fmt.Sprintf("%s lacks %s", c.Path, strings.Join(missing, ", ")))
	case len(extra) > 0 && c.Exact:
		return fail(fmt.Sprintf("%s has entries the truth does not: %s", c.Path, strings.Join(extra, ", ")))
	case len(extra) > 0:
		return pass(fmt.Sprintf("%s has every expected entry (and %d more)", c.Path, len(extra)))
	}
	return pass(fmt.Sprintf("%s is exactly the %d expected", c.Path, len(want)))
}

// checkJSONWithin matches each expected number to an answer entry within the tolerance, once.
func checkJSONWithin(c Check, s *Scenario, _ *Log, answer map[string]any) Verdict {
	if answer == nil {
		return fail("no answer block")
	}
	want, err := expected(c, s)
	if err != nil {
		return fail(err.Error())
	}
	got, err := listAt(answer, c.Path, c.Field)
	if err != nil {
		return fail(err.Error())
	}
	nums := make([]float64, 0, len(got))
	for _, g := range got {
		f, ok := number(g)
		if !ok {
			return fail(fmt.Sprintf("an entry of %s is not a number: %v", c.Path, g))
		}
		nums = append(nums, f)
	}
	used := make([]bool, len(nums))
	var missing []string
	for _, w := range want {
		wf, ok := number(w)
		if !ok {
			return fail(fmt.Sprintf("truth entry is not a number: %v", w))
		}
		found := false
		for i, g := range nums {
			if !used[i] && math.Abs(g-wf) <= c.Tolerance {
				used[i] = true
				found = true
				break
			}
		}
		if !found {
			missing = append(missing, strconv.FormatFloat(wf, 'f', -1, 64))
		}
	}
	extra := 0
	for _, u := range used {
		if !u {
			extra++
		}
	}
	switch {
	case len(missing) > 0:
		return fail(fmt.Sprintf("%s misses %s (tolerance %g)", c.Path, strings.Join(missing, ", "), c.Tolerance))
	case extra > 0 && c.Exact:
		return fail(fmt.Sprintf("%s has %d entries the truth does not", c.Path, extra))
	case extra > 0:
		return pass(fmt.Sprintf("every expected value matched (%d extra entries)", extra))
	}
	return pass(fmt.Sprintf("all %d expected values matched within %g", len(want), c.Tolerance))
}

func checkRequireWords(c Check, _ *Scenario, log *Log, _ map[string]any) Verdict {
	prose := strings.ToLower(log.Prose())
	var missing []string
	for _, w := range c.Words {
		if !strings.Contains(prose, strings.ToLower(w)) {
			missing = append(missing, w)
		}
	}
	if len(missing) > 0 {
		return fail("the answer never says " + strings.Join(missing, ", "))
	}
	return pass("the answer says " + strings.Join(c.Words, ", "))
}

func checkForbidWords(c Check, _ *Scenario, log *Log, _ map[string]any) Verdict {
	prose := strings.ToLower(log.Prose())
	var found []string
	for _, w := range c.Words {
		if strings.Contains(prose, strings.ToLower(w)) {
			found = append(found, w)
		}
	}
	if len(found) > 0 {
		return fail("the answer says " + strings.Join(found, ", "))
	}
	return pass("the answer avoids " + strings.Join(c.Words, ", "))
}

func toolCount(log *Log, short string) int {
	n := 0
	for _, e := range log.ToolCalls() {
		if ShortTool(e.Tool) == short {
			n++
		}
	}
	return n
}

func checkUsedTool(c Check, _ *Scenario, log *Log, _ map[string]any) Verdict {
	if n := toolCount(log, c.Tool); n > 0 {
		return pass(fmt.Sprintf("%s called %d time(s)", c.Tool, n))
	}
	return fail(c.Tool + " was never called")
}

// checkUsedOneOf passes when any of the named tools was called: a task with more than one
// honest route (start a decoder and fold, or fold one already running).
func checkUsedOneOf(c Check, _ *Scenario, log *Log, _ map[string]any) Verdict {
	var names []string
	for _, v := range c.Values {
		name := fmt.Sprint(v)
		names = append(names, name)
		if toolCount(log, name) > 0 {
			return pass(name + " was called")
		}
	}
	return fail("none of " + strings.Join(names, ", ") + " was called")
}

func checkNotUsedTool(c Check, _ *Scenario, log *Log, _ map[string]any) Verdict {
	if n := toolCount(log, c.Tool); n > 0 {
		return fail(fmt.Sprintf("%s called %d time(s)", c.Tool, n))
	}
	return pass(c.Tool + " was not called")
}

func checkMaxToolCalls(c Check, _ *Scenario, log *Log, _ map[string]any) Verdict {
	n := len(log.ToolCalls())
	if n > c.N {
		return fail(fmt.Sprintf("%d tool calls, budget %d", n, c.N))
	}
	return pass(fmt.Sprintf("%d tool calls within the budget of %d", n, c.N))
}

func checkNoShell(_ Check, _ *Scenario, log *Log, _ map[string]any) Verdict {
	var shell []string
	for _, e := range log.ToolCalls() {
		if IsShell(e.Tool) {
			shell = append(shell, e.Tool)
		}
	}
	if len(shell) > 0 {
		return fail(fmt.Sprintf("left the tools for the host %d time(s): %s", len(shell), strings.Join(shell, ", ")))
	}
	return pass("stayed on the MCP tools")
}

func checkNoToolErrors(_ Check, _ *Scenario, log *Log, _ map[string]any) Verdict {
	n := 0
	for _, e := range log.Events {
		if e.Kind == "tool_result" && e.IsError {
			n++
		}
	}
	if n > 0 {
		return fail(fmt.Sprintf("%d tool call(s) came back as errors", n))
	}
	return pass("no tool call came back as an error")
}

// checkTakeOverAfterRefusal: take_over may be sent only after a result that refused for
// don't-disturb reasons said so. An agent that takes the radio over on its first try has not
// respected anyone.
func checkTakeOverAfterRefusal(_ Check, _ *Scenario, log *Log, _ map[string]any) Verdict {
	refused := false
	for _, e := range log.Events {
		switch e.Kind {
		case "tool_result":
			if strings.Contains(e.Result, "take_over") {
				refused = true
			}
		case "tool_use":
			var in struct {
				TakeOver bool `json:"take_over"`
			}
			_ = json.Unmarshal(e.Input, &in)
			if in.TakeOver && !refused {
				return fail(ShortTool(e.Tool) + " was called with take_over before any refusal")
			}
		}
	}
	return pass("take_over was used only after a refusal, or not at all")
}
