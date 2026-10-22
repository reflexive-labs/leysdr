// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// AISetup is a check scene's `ai` key: the assistant on a scripted model (docs/plans/mac-loop.md,
// ML-9b, H3). The scene's daemon runs its workers through a `ley` that answers `worker check` as
// accepted and hands every other verb to the real one, and gets LEY_ASSISTANT_SCRIPT, so the
// worker plays the script in place of a provider whatever the provider is. With Key, a made-up
// key is added before anything else runs. Nothing reaches a provider or the network, and the
// key lands in the daemon's own data directory (daemonrun keeps keys out of the keychain).
type AISetup struct {
	// Script is the scripted model's file, relative to scenes.yaml: one JSON response a line
	// (go/internal/assistant, Scripted).
	Script string `yaml:"script"`
	// Provider is the provider the key is added for; empty is anthropic.
	Provider string `yaml:"provider"`
	// Model is `ley ai use assistant <provider> <model>` after the key; empty keeps the
	// provider's default, which `ley ai add` sets.
	Model string `yaml:"model"`
	// Key adds the key before the app starts; nil is true. False leaves the daemon with no key, so
	// a scene can add one itself, through Settings or a `ley` command.
	Key *bool `yaml:"key"`
}

// fakeAIKey is the key a scene adds: plainly not a provider's, and only ever seen by the shim.
const fakeAIKey = "sk-leyshots-not-a-key-0000"

// The variables that point a daemon's assistant at a script and its workers at a `ley`. A
// scene without `ai` unsets them, so a value in the caller's environment never reaches its daemon.
var aiEnvNames = []string{"LEY_ASSISTANT_SCRIPT", "LEY_ASSISTANT_RECORD", "LEYLINE_LEY"}

func (a *AISetup) provider() string {
	if a.Provider == "" {
		return "anthropic"
	}
	return a.Provider
}

func (a *AISetup) addsKey() bool { return a.Key == nil || *a.Key }

func (a *AISetup) validate(path func(string) string) error {
	if a.Script == "" {
		return errors.New("ai needs script")
	}
	if _, err := os.Stat(path(a.Script)); err != nil {
		return fmt.Errorf("ai script: %w", err)
	}
	if strings.ContainsAny(a.provider(), " /") {
		return fmt.Errorf("ai provider %q is not a provider name", a.Provider)
	}
	if a.Model != "" && !a.addsKey() {
		return errors.New("ai model is chosen after the key is added; it needs key: true")
	}
	return nil
}

// aiStub is a scene's AISetup resolved against its run: the script's absolute path and the ley the
// shim hands to.
type aiStub struct {
	script, provider, model string
	key                     bool
}

func (a *AISetup) stub(path func(string) string) (*aiStub, error) {
	script, err := filepath.Abs(path(a.Script))
	if err != nil {
		return nil, err
	}
	return &aiStub{script: script, provider: a.provider(), model: a.Model, key: a.addsKey()}, nil
}

// install writes the shim into run/ai and returns the daemon's variables: its workers' ley, the
// script, and the file the scripted model records each call's messages in.
func (s *aiStub) install(run, ley string) ([]string, error) {
	dir := filepath.Join(run, "ai")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	absLey, err := filepath.Abs(ley)
	if err != nil {
		return nil, err
	}
	shim := filepath.Join(dir, "ley")
	if err := os.WriteFile(shim, []byte(shimScript(absLey)), 0o755); err != nil {
		return nil, err
	}
	return []string{
		"LEYLINE_LEY=" + shim,
		"LEY_ASSISTANT_SCRIPT=" + s.script,
		"LEY_ASSISTANT_RECORD=" + filepath.Join(dir, "record.jsonl"),
	}, nil
}

// steps are the ley commands that give the daemon its key and model, and the stdin of each.
func (s *aiStub) steps() []leyCall {
	if !s.key {
		return nil
	}
	out := []leyCall{{args: []string{"ai", "add", s.provider}, stdin: fakeAIKey + "\n"}}
	if s.model != "" {
		out = append(out, leyCall{args: []string{"ai", "use", "assistant", s.provider, s.model}})
	}
	return out
}

// leyCall is one ley command a scene's setup runs.
type leyCall struct {
	args  []string
	stdin string
}

// shimScript is the daemon's `ley`: `worker check` reads the key and answers accepted without
// calling anyone; everything else, the assistant's worker included, is the real ley.
func shimScript(ley string) string {
	return `#!/bin/sh
# leyshots' stand-in for ley as a check scene's daemon runs it (app/checks/scenes.yaml, ai).
if [ "$1" = worker ] && [ "$2" = check ]; then
  read -r _ || true
  echo '{"outcome":"accepted","message":""}'
  exit 0
fi
exec ` + shellQuote(ley) + ` "$@"
`
}

// shellQuote quotes s for sh: single quotes, with each single quote closed, escaped and reopened.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
