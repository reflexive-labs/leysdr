// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// SpeechSetup is a site scene's `speech` key: the speech decoder replays a script in place of a
// provider. The scene's daemon reads its decoders from a copy of decoders/ in which `speech` is
// leydec-speech's scripted engine (speech-scripted's manifest under the name speech), and gets
// LEYDEC_SPEECH_SCRIPT, so `ley transcribe` and `ley watch speech` give the script's words, one
// line an over, with no key and nothing sent anywhere (docs/dev/evals.md, speech_script).
type SpeechSetup struct {
	// Script is the file of lines, relative to scenes.yaml: one over a line, the last line for
	// every over after it.
	Script string `yaml:"script"`
}

// speechScriptEnv names the scripted engine's file; the decoder inherits it from the daemon.
const speechScriptEnv = "LEYDEC_SPEECH_SCRIPT"

func (s *SpeechSetup) validate(path func(string) string) error {
	if s.Script == "" {
		return errors.New("speech needs script")
	}
	if _, err := os.Stat(path(s.Script)); err != nil {
		return fmt.Errorf("speech script: %w", err)
	}
	return nil
}

// speechStub is a scene's SpeechSetup resolved: the script's absolute path.
type speechStub struct{ script string }

func (s *SpeechSetup) stub(path func(string) string) (*speechStub, error) {
	script, err := filepath.Abs(path(s.Script))
	if err != nil {
		return nil, err
	}
	return &speechStub{script: script}, nil
}

// install writes run/decoders, a copy of the decoders directory src with speech replaced by the
// scripted engine, and returns it and the daemon's variable that names the script.
func (s *speechStub) install(run, src string) (string, []string, error) {
	dst := filepath.Join(run, "decoders")
	entries, err := os.ReadDir(src)
	if err != nil {
		return "", nil, err
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		b, err := os.ReadFile(filepath.Join(src, e.Name(), "manifest.json"))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return "", nil, err
		}
		if e.Name() == "speech" {
			continue // written from speech-scripted's below
		}
		if e.Name() == "speech-scripted" {
			if b, err = scriptedAsSpeech(b); err != nil {
				return "", nil, fmt.Errorf("%s: %w", filepath.Join(src, e.Name(), "manifest.json"), err)
			}
			if err := writeManifest(filepath.Join(dst, "speech"), b); err != nil {
				return "", nil, err
			}
			continue
		}
		if err := writeManifest(filepath.Join(dst, e.Name()), b); err != nil {
			return "", nil, err
		}
	}
	if _, err := os.Stat(filepath.Join(dst, "speech", "manifest.json")); err != nil {
		return "", nil, fmt.Errorf("%s has no speech-scripted decoder to stand in for speech", src)
	}
	return dst, []string{speechScriptEnv + "=" + s.script}, nil
}

// scriptedAsSpeech is speech-scripted's manifest named speech, with speech's alias.
func scriptedAsSpeech(b []byte) ([]byte, error) {
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	m["name"] = "speech"
	m["aliases"] = []string{"transcribe"}
	return json.MarshalIndent(m, "", "  ")
}

func writeManifest(dir string, b []byte) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "manifest.json"), b, 0o644)
}
