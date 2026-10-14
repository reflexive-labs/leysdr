// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"os"
	"sort"
	"strings"
)

// transcript is one segment's text as an engine returns it.
type transcript struct {
	text     string
	language string
	// confidence is the engine's own figure, 0 to 1. hasConfidence is false when the engine
	// reports none, and the record then carries no confidence field rather than an invented one.
	confidence    float64
	hasConfidence bool
	// raw is the provider's response as it arrived, kept on the record so a later reader sees
	// what the engine returned rather than what this plugin made of it.
	raw []byte
}

// engine turns one segment of audio into text. seq is the segment's 1-based position in this
// run of the plugin.
type engine interface {
	transcribe(samples []float32, audioRate float64, seq int) (transcript, error)
	// provider is who ran the model, for the record's usage report; model is the model's name.
	provider() string
	model() string
}

// engineConfig is what the flags say about the engine.
type engineConfig struct {
	model    string
	language string
	getenv   func(string) string
}

// engines are the engines this build has, by --engine name.
var engines = map[string]func(engineConfig) engine{
	"scripted": newScripted,
}

// newEngine builds the engine --engine names, or says which ones there are.
func newEngine(name string, cfg engineConfig) (engine, error) {
	build, ok := engines[name]
	if !ok {
		names := make([]string, 0, len(engines))
		for n := range engines {
			names = append(names, n)
		}
		sort.Strings(names)
		return nil, fmt.Errorf("no engine %s; the engines are: %s", name, strings.Join(names, ", "))
	}
	return build(cfg), nil
}

// scriptEnv names the file the scripted engine reads.
const scriptEnv = "LEYDEC_SPEECH_SCRIPT"

// scripted is the engine for tests. It ignores the audio and returns the lines of the file
// LEYDEC_SPEECH_SCRIPT names, one per segment in order; when the file runs out it repeats the last
// line, and with no file it returns "segment N". A test of the whole path, daemon to record store,
// then knows the words in advance.
type scripted struct {
	lines    []string
	modelID  string
	language string
}

func newScripted(cfg engineConfig) engine {
	s := &scripted{modelID: cfg.model, language: cfg.language}
	if s.modelID == "" {
		s.modelID = "scripted"
	}
	if path := cfg.getenv(scriptEnv); path != "" {
		if data, err := os.ReadFile(path); err == nil && len(data) > 0 {
			for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
				s.lines = append(s.lines, strings.TrimRight(line, "\r"))
			}
		}
	}
	return s
}

func (s *scripted) transcribe(_ []float32, _ float64, seq int) (transcript, error) {
	text := fmt.Sprintf("segment %d", seq)
	if n := len(s.lines); n > 0 {
		text = s.lines[min(seq, n)-1]
	}
	return transcript{text: text, language: s.language, confidence: 1, hasConfidence: true, raw: []byte(text)}, nil
}

func (s *scripted) provider() string { return "scripted" }
func (s *scripted) model() string    { return s.modelID }
