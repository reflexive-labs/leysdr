// SPDX-License-Identifier: Apache-2.0

// Package eval runs an agent against `ley mcp` on a daemon playing fixtures, and grades what it
// did. Every scenario is a YAML file (evals/scenarios): which recordings the daemon plays as
// radios, what the agent is asked, the JSON block it must end with, the truth the fixtures make
// known before the agent starts, and the checks that turn its answer and its tool calls into
// pass or fail. Nothing here needs a radio or a person on the air, so a run is reproducible; what
// varies is the agent (docs/dev/evals.md).
package eval

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Scenario is one eval as its YAML file describes it.
type Scenario struct {
	// Name is the file's stem unless the file says otherwise; it names the run directory.
	Name        string `yaml:"name"`
	Description string `yaml:"description"`
	// Fixtures the daemon plays as radios before the agent starts.
	Fixtures []Fixture `yaml:"fixtures"`
	// Setup runs after the fixtures are attached and before the agent: a `ley` verb against the
	// eval daemon, or a decode job started through the client library.
	Setup []SetupStep `yaml:"setup"`
	// SpeechScript is what the speech decoder hears: one line per over, in order, the last line
	// again for every over after. The runner writes it to the run directory and names the file in
	// the daemon's LEYDEC_SPEECH_SCRIPT, which leydec-speech's scripted engine inherits, so a
	// speech job in the setup stores records whose words the scenario fixed in advance.
	SpeechScript []string `yaml:"speech_script"`
	// Task is what the agent is asked, verbatim.
	Task string `yaml:"task"`
	// AnswerSchema is the JSON block the agent must end its answer with, shown to it verbatim,
	// and what the json_* checks read.
	AnswerSchema string `yaml:"answer_schema"`
	// Truth is what the fixtures make known; checks refer to it by key.
	Truth  map[string]any `yaml:"truth"`
	Checks []Check        `yaml:"checks"`
	// MaxTurns bounds the agent (claude's --max-turns). 0 is the runner's default. The assistant
	// has its own bound (40 model calls a turn) and ignores it.
	MaxTurns int `yaml:"max_turns"`
	// Mode overrides the runner's: "mcp" (tools only), "shell" (a shell as well, to measure how
	// often the agent leaves the tools) or "assistant" (`ley ask` is the agent).
	Mode string `yaml:"mode"`
	// Modes runs the scenario once in each mode listed, each in its own run directory
	// (<name>.<mode>); a mode given to the runner picks one of them. Not with Mode.
	Modes []string `yaml:"modes"`
	// Skip, when set, is why this scenario is not run (a fixture that only exists on one machine
	// is handled by the runner; this is for a scenario disabled by hand).
	Skip string `yaml:"skip"`

	// Path is where the scenario was read from.
	Path string `yaml:"-"`
}

// Fixture is one recording attached as a radio.
type Fixture struct {
	// File is the recording, relative to the fixtures directory or absolute; its sidecar sits
	// beside it. cf32 and cu8 both work.
	File string `yaml:"file"`
	// As is the name the agent sees as the radio's model: the file is copied under it, and the
	// sidecar rewritten to say nothing but its format, rate and centre, because a fixture's
	// filename and description are the answer key.
	As string `yaml:"as"`
	// Capture, the default, tunes the radio to the recording's centre before the agent starts,
	// so a decode job finds a capture that covers its frequency. `capture: false` leaves the radio
	// idle, which is what a sweep wants.
	Capture *bool `yaml:"capture"`
	// Optional, when true, skips the scenario rather than failing it when the file is missing:
	// a real-radio capture that lives on one checkout.
	Optional bool `yaml:"optional"`
	// Center, when set, is where the radio says it is tuned (a bare number is MHz) instead of
	// the recording's own centre: a noise-only fixture has no frequency of its own, and placing
	// it on a decoder's channel keeps the agent from noticing the frequency is off the recipe.
	Center string `yaml:"center"`
}

// SetupStep is one thing done to the daemon before the agent starts.
type SetupStep struct {
	// Ley is a verb and its arguments, run as `ley --socket <eval socket> ...`. A verb that streams
	// until Ctrl-C is not a setup step; use `--persistent` forms or a job.
	Ley []string `yaml:"ley"`
	// Job starts a decode job through the client library.
	Job *JobStep `yaml:"job"`
}

// JobStep is a decode job to start before the agent runs.
type JobStep struct {
	Decoder   string `yaml:"decoder"`
	Frequency string `yaml:"frequency"`
	Keep      bool   `yaml:"keep"`
	// Records, for a kept job, waits until the job has stored at least this many records before
	// the next step, so the agent starts with them on hand however quickly it asks.
	Records int `yaml:"records"`
}

// Check is one graded assertion. `Type` picks the checker (checks.go); the rest are its
// parameters, which differ by type and are left untyped so a new checker needs no new schema.
type Check struct {
	Type string `yaml:"type"`
	// Path is a dotted path into the answer block: "carriers", "stations", "tone.hz".
	Path string `yaml:"path"`
	// Field, for a path that reaches a list of objects, is the field compared in each.
	Field string `yaml:"field"`
	// Truth names a key of the scenario's truth map to compare against; Values is the literal
	// alternative.
	Truth  string `yaml:"truth"`
	Values []any  `yaml:"values"`
	Value  any    `yaml:"value"`
	// Tolerance is for numeric comparisons (json_within).
	Tolerance float64 `yaml:"tolerance"`
	// Exact, for json_within and json_set_equals, also fails on entries the truth does not have.
	Exact bool `yaml:"exact"`
	// Words is for require_words and forbid_words, matched case-insensitively in the agent's prose.
	Words []string `yaml:"words"`
	// Tool is a leyline tool's short name (scan, not mcp__leyline__scan).
	Tool string `yaml:"tool"`
	// N is a count bound (max_tool_calls).
	N int `yaml:"n"`
	// Kind and Where are no_write's: the kind of object the event changed (job, channel, capture,
	// device, playback) and field equalities on it (events.go, whereKeys).
	Kind  string            `yaml:"kind"`
	Where map[string]string `yaml:"where"`
	// Why says what the check proves, for the report.
	Why string `yaml:"why"`
}

// Load reads one scenario file.
func Load(path string) (*Scenario, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Scenario
	if err := yaml.Unmarshal(raw, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	s.Path = path
	if s.Name == "" {
		s.Name = strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	}
	if strings.TrimSpace(s.Task) == "" {
		return nil, fmt.Errorf("%s: no task", path)
	}
	if len(s.Checks) == 0 {
		return nil, fmt.Errorf("%s: no checks; a scenario nothing grades is a demo", path)
	}
	for i, c := range s.Checks {
		if _, ok := checkers[c.Type]; !ok {
			return nil, fmt.Errorf("%s: check %d: unknown type %q (known: %s)", path, i+1, c.Type, strings.Join(checkTypes(), ", "))
		}
		if c.Type == "no_write" {
			if err := validateNoWrite(c); err != nil {
				return nil, fmt.Errorf("%s: check %d: %w", path, i+1, err)
			}
		}
	}
	if s.Mode != "" && len(s.Modes) > 0 {
		return nil, fmt.Errorf("%s: mode and modes both set; modes lists every mode the scenario runs in", path)
	}
	for _, m := range append([]string{s.Mode}, s.Modes...) {
		if m != "" && !knownModes[m] {
			return nil, fmt.Errorf("%s: unknown mode %q (known: assistant, mcp, shell)", path, m)
		}
	}
	for i, f := range s.Fixtures {
		if f.File == "" || f.As == "" {
			return nil, fmt.Errorf("%s: fixture %d needs file and as", path, i+1)
		}
	}
	// The script file is one over a line, so a line holding a newline would become two overs.
	for i, line := range s.SpeechScript {
		if strings.ContainsAny(line, "\r\n") {
			return nil, fmt.Errorf("%s: speech_script line %d holds a line break; each line is one over", path, i+1)
		}
	}
	return &s, nil
}

// LoadDir reads every .yaml in dir, sorted by name.
func LoadDir(dir string) ([]*Scenario, error) {
	names, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil {
		return nil, err
	}
	var out []*Scenario
	for _, n := range names {
		s, err := Load(n)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no scenarios in %s", dir)
	}
	return out, nil
}

var knownModes = map[string]bool{"mcp": true, "shell": true, "assistant": true}

// ModesFor is the modes the scenario runs in under env: every mode it lists (only the runner's,
// when the runner was told one), else its own mode, else the runner's. Empty when the runner's
// chosen mode is not among the scenario's.
func (s *Scenario) ModesFor(env Env) []string {
	switch {
	case len(s.Modes) > 0 && env.ModeChosen:
		for _, m := range s.Modes {
			if m == env.Mode {
				return []string{m}
			}
		}
		return nil
	case len(s.Modes) > 0:
		return s.Modes
	case s.Mode != "":
		return []string{s.Mode}
	}
	return []string{env.Mode}
}

// Prompt is what the agent is given: the task, the answer block it must end with, and the
// rule of the mode.
func (s *Scenario) Prompt(mode string) string {
	var b strings.Builder
	b.WriteString(strings.TrimSpace(s.Task))
	b.WriteString("\n\n")
	switch mode {
	case "mcp":
		b.WriteString("Use only the leyline MCP tools; there is no shell for this task.\n\n")
	case "assistant":
		b.WriteString("Use only your tools; there is no shell for this task.\n\n")
	default:
		b.WriteString("The leyline MCP tools are available, and so is a shell with `ley` on it; prefer the tools.\n\n")
	}
	if strings.TrimSpace(s.AnswerSchema) != "" {
		b.WriteString("End your answer with one JSON block, and nothing after it, in exactly this shape:\n\n```json\n")
		b.WriteString(strings.TrimSpace(s.AnswerSchema))
		b.WriteString("\n```\n")
	}
	return b.String()
}
