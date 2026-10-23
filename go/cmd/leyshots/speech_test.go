// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// The scene's decoders are the checkout's with speech replaced by the scripted engine under its
// name: the real speech decoder, which calls a provider, is not among them.
func TestSpeechStubInstall(t *testing.T) {
	src := filepath.Join("..", "..", "..", "decoders")
	run := t.TempDir()
	stub := &speechStub{script: "/s/net.txt"}
	dir, env, err := stub.install(run, src)
	if err != nil {
		t.Fatal(err)
	}
	if dir != filepath.Join(run, "decoders") || !slices.Equal(env, []string{"LEYDEC_SPEECH_SCRIPT=/s/net.txt"}) {
		t.Errorf("install gave %s, %v", dir, env)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	if !slices.Contains(names, "aprs") || !slices.Contains(names, "speech") || slices.Contains(names, "speech-scripted") {
		t.Errorf("decoders %v: want aprs and speech, and no speech-scripted", names)
	}
	b, err := os.ReadFile(filepath.Join(dir, "speech", "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m struct {
		Name               string   `json:"name"`
		Aliases            []string `json:"aliases"`
		Args               []string `json:"args"`
		CredentialProvider string   `json:"credentialProvider"`
		ContactsHosts      []string `json:"contactsHosts"`
	}
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	if m.Name != "speech" || !slices.Equal(m.Aliases, []string{"transcribe"}) || !slices.Equal(m.Args, []string{"--engine", "scripted"}) ||
		m.CredentialProvider != "" || len(m.ContactsHosts) != 0 {
		t.Errorf("the stand-in speech manifest: %+v", m)
	}
}

// A site scene takes a check scene's ai, a speech script and app commands, and a composite's
// first pane may wait for the app.
func TestDrivenSceneLoads(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "a.script"), `{"text":"hi"}`+"\n")
	writeFile(t, filepath.Join(dir, "words.txt"), "net control\n")
	path := filepath.Join(dir, "scenes.yaml")
	writeFile(t, path, `repo: a/b
scenes:
  - asset: x.png
    kind: composite
    alt: A.
    clock: "19:42"
    fixtures: [{name: x}]
    ai: {script: a.script, provider: openai}
    speech: {script: words.txt}
    stage: {settle: 1, window: {width: 1000, height: 700}}
    crop: {regions: [window]}
    terminal: {cols: 80, rows: 10, panes: [{command: ley tune 146.94, after_app: true}]}
    app:
      - {cmd: wait, seconds: 2}
      - {cmd: ley, args: [state]}
      - {cmd: state, expect: {tuned_hz: 146940000}}
      - {cmd: snapshot, name: shot}
`)
	f, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	s := f.Scenes[0]
	if s.AI == nil || s.AI.provider() != "openai" || s.Speech == nil || len(s.App) != 4 || !s.Terminal.Panes[0].AfterApp {
		t.Errorf("loaded %+v", s)
	}
}
