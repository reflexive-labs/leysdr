// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/internal/assistant"
)

// The shim answers the key check itself and hands every other verb to the real ley, whose path
// may hold a quote.
func TestAIShim(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the shim is a shell script")
	}
	dir := filepath.Join(t.TempDir(), "it's here")
	realLey := filepath.Join(dir, "ley")
	writeFile(t, realLey, "#!/bin/sh\necho \"real ley: $*\"\n")
	if err := os.Chmod(realLey, 0o755); err != nil {
		t.Fatal(err)
	}
	run := filepath.Join(t.TempDir(), "run")
	stub := &aiStub{script: "/s/hello.script", provider: "anthropic", key: true}
	env, err := stub.install(run, realLey)
	if err != nil {
		t.Fatal(err)
	}
	shim := filepath.Join(run, "ai", "ley")
	want := []string{
		"LEYLINE_LEY=" + shim, "LEY_ASSISTANT_SCRIPT=/s/hello.script",
		"LEY_ASSISTANT_RECORD=" + filepath.Join(run, "ai", "record.jsonl"),
	}
	if !slices.Equal(env, want) {
		t.Errorf("the daemon's variables:\n%v\nwant\n%v", env, want)
	}
	check := exec.Command(shim, "worker", "check", "--provider", "anthropic")
	check.Stdin = strings.NewReader(fakeAIKey + "\n")
	out, err := check.Output()
	if err != nil || strings.TrimSpace(string(out)) != `{"outcome":"accepted","message":""}` {
		t.Errorf("worker check: %q, %v", out, err)
	}
	// With nothing on stdin it still answers, as the daemon's check would be.
	if out, err := exec.Command(shim, "worker", "check").Output(); err != nil || !strings.Contains(string(out), "accepted") {
		t.Errorf("worker check with no key: %q, %v", out, err)
	}
	out, err = exec.Command(shim, "worker", "assistant", "--conversation", "conv_1").Output()
	if err != nil || strings.TrimSpace(string(out)) != "real ley: worker assistant --conversation conv_1" {
		t.Errorf("worker assistant: %q, %v", out, err)
	}
}

// The key goes in on stdin and is the made-up one; a model is chosen only when the scene names
// one; key: false adds nothing.
func TestAIStubSteps(t *testing.T) {
	got := (&aiStub{provider: "anthropic", key: true}).steps()
	if len(got) != 1 || strings.Join(got[0].args, " ") != "ai add anthropic" || got[0].stdin != fakeAIKey+"\n" {
		t.Errorf("steps without a model: %+v", got)
	}
	got = (&aiStub{provider: "openai", model: "gpt-5", key: true}).steps()
	if len(got) != 2 || strings.Join(got[1].args, " ") != "ai use assistant openai gpt-5" || got[1].stdin != "" {
		t.Errorf("steps with a model: %+v", got)
	}
	if got := (&aiStub{provider: "anthropic"}).steps(); len(got) != 0 {
		t.Errorf("key: false ran %+v", got)
	}
}

func TestAISetupValidate(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "a.script"), `{"text":"hi"}`+"\n")
	path := func(p string) string { return filepath.Join(dir, p) }
	no := false
	cases := []struct {
		name string
		ai   AISetup
		ok   bool
	}{
		{"script", AISetup{Script: "a.script"}, true},
		{"model", AISetup{Script: "a.script", Model: "claude-sonnet-5-5"}, true},
		{"no script", AISetup{}, false},
		{"missing script", AISetup{Script: "b.script"}, false},
		{"model without a key", AISetup{Script: "a.script", Model: "m", Key: &no}, false},
		{"provider path", AISetup{Script: "a.script", Provider: "../x"}, false},
	}
	for _, c := range cases {
		if err := c.ai.validate(path); (err == nil) != c.ok {
			t.Errorf("%s: %v", c.name, err)
		}
	}
	s, err := (&AISetup{Script: "a.script"}).stub(path)
	if err != nil || s.provider != "anthropic" || !s.key || s.script != filepath.Join(dir, "a.script") {
		t.Errorf("stub: %+v, %v", s, err)
	}
}

// The example script is one the worker can play.
func TestAIExampleScript(t *testing.T) {
	if _, err := assistant.LoadScript("../../../app/checks/assistant/hello.script"); err != nil {
		t.Fatal(err)
	}
}

// A scene's ai key parses and is checked with the scene.
func TestChecksAIKey(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "a.script"), `{"text":"hi"}`+"\n")
	path := filepath.Join(dir, "scenes.yaml")
	writeFile(t, path, "scenes:\n  - name: s\n    fixtures: [{name: x}]\n    ai: {script: a.script, model: m}\n    app: [{cmd: state}]\n")
	f, err := LoadChecks(path)
	if err != nil {
		t.Fatal(err)
	}
	if ai := f.Scenes[0].AI; ai == nil || ai.Script != "a.script" || ai.Model != "m" || !ai.addsKey() {
		t.Errorf("ai: %+v", f.Scenes[0].AI)
	}
	writeFile(t, path, "scenes:\n  - name: s\n    fixtures: [{name: x}]\n    ai: {script: none.script}\n    app: [{cmd: state}]\n")
	if _, err := LoadChecks(path); err == nil {
		t.Error("a missing script loaded")
	}
}
