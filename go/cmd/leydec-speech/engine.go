// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"os"
	"sort"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
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

// stopError is a failure that ends the plugin rather than costing one segment its record. exit is
// the status: 75 (EX_TEMPFAIL) when the provider turned the call away for its own reason, a rate
// or spend limit or an outage, which the daemon waits out; 1 when trying again cannot help, a
// rejected key or an endpoint that is not one. msg is the plugin's last line on stderr, which the
// daemon reports as the job's reason.
type stopError struct {
	exit int
	msg  string
}

func (e *stopError) Error() string { return e.msg }

// exitTempFail is EX_TEMPFAIL from sysexits.h, the status the daemon reads as a provider's
// refusal (docs/reference/writing-a-decoder.md, "The wire").
const exitTempFail = 75

// engineConfig is what the flags say about the engine.
type engineConfig struct {
	model    string
	language string
	// prompt is the vocabulary hint an engine that takes one sends with the audio.
	prompt string
	getenv func(string) string
}

// engines are the engines this build has, by --engine name. cred is the key the daemon handed
// over, nil when it sent none.
var engines = map[string]func(engineConfig, *leylinev1.SetCredentialRequest) (engine, error){
	"openai":   newOpenAI,
	"scripted": newScripted,
}

// checkEngine refuses an --engine name this build does not have, naming the ones it has.
func checkEngine(name string) error {
	if _, ok := engines[name]; ok {
		return nil
	}
	names := make([]string, 0, len(engines))
	for n := range engines {
		names = append(names, n)
	}
	sort.Strings(names)
	return fmt.Errorf("no engine %s; the engines are: %s", name, strings.Join(names, ", "))
}

// newEngine builds the engine --engine names.
func newEngine(name string, cfg engineConfig, cred *leylinev1.SetCredentialRequest) (engine, error) {
	if err := checkEngine(name); err != nil {
		return nil, err
	}
	return engines[name](cfg, cred)
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

func newScripted(cfg engineConfig, _ *leylinev1.SetCredentialRequest) (engine, error) {
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
	return s, nil
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
