// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// fakeLey is a ley for the runner's own commands: bookmarks prints a list and records the socket
// it was pointed at, fail fails, tune runs until interrupted and says so, quick exits at once.
const fakeLey = `#!/bin/sh
case "$1" in
  bookmarks) echo "$LEYLINE_SOCKET" > "$(dirname "$0")/socket.txt"; echo "Calling  146.520 MHz" ;;
  fail) echo "no such channel" >&2; exit 3 ;;
  tune) trap 'echo interrupted; exit 0' INT; echo tuned; while :; do sleep 0.02; done ;;
  quick) echo done ;;
esac
`

// checkWithFakeApp runs the scenes file at path against the fake app and a fake ley, and returns
// the output and the error.
func checkWithFakeApp(t *testing.T, dir, scenes string, prepare func(run string) (*sceneDaemon, error)) (*fakeApp, string, error) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the fake ley is a shell script")
	}
	ley := filepath.Join(dir, "bin", "ley")
	writeFile(t, ley, fakeLey)
	if err := os.Chmod(ley, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "scenes.yaml"), scenes)
	fake := &fakeApp{alive: map[int]bool{}, state: map[string]any{"tuned_hz": 146520000}}
	var stdout bytes.Buffer
	o := checkOptions{
		runOptions: runOptions{root: dir, out: filepath.Join(dir, "checks"), ley: ley, stdout: &stdout, logf: t.Logf},
		checks:     filepath.Join(dir, "scenes.yaml"), goldens: filepath.Join(dir, "goldens"), release: "26.6",
		prepare: func(_ context.Context, _ *CheckFile, _ *CheckScene, run string) (*sceneDaemon, error) {
			if err := os.MkdirAll(run, 0o755); err != nil {
				return nil, err
			}
			return prepare(run)
		},
		launch: fake.launch,
		alive: func(pid int) bool {
			fake.mu.Lock()
			defer fake.mu.Unlock()
			return fake.alive[pid]
		},
		kill:    func(pid int) { t.Errorf("killed %d; it should have quit", pid) },
		findPID: func(context.Context, string) int { return 0 },
		grace:   5 * time.Second, poll: 5 * time.Millisecond,
	}
	err := checkScenes(context.Background(), o)
	return fake, stdout.String(), err
}

// expectOutput checks the output's lines in order, each by its start.
func expectOutput(t *testing.T, out string, want ...string) {
	t.Helper()
	got := strings.Split(strings.TrimSpace(out), "\n")
	if len(got) != len(want) {
		t.Fatalf("output:\n%s\nwant %d lines", out, len(want))
	}
	for i, w := range want {
		if !strings.HasPrefix(got[i], w) {
			t.Errorf("line %d: %q, want it to start %q", i+1, got[i], w)
		}
	}
}

// The runner's own commands run in order with the app's, against the scene's daemon; only the
// app's reach the command file, and a background ley left running is interrupted at the end.
func TestCheckLocalCommands(t *testing.T) {
	dir := t.TempDir()
	fake, out, err := checkWithFakeApp(t, dir, `scenes:
  - name: s
    fixtures: [{name: scene_2m}]
    app:
      - {cmd: ley, args: [bookmarks], expect_stdout: Calling}
      - {cmd: ley, args: [bookmarks], expect_stdout: ["!Club", "146\\.520", "147\\.180"]}
      - {cmd: ley, args: [fail]}
      - {cmd: ley, args: [fail], expect_exit: 3}
      - {cmd: ley_bg, id: tune, args: [tune]}
      - {cmd: wait, seconds: 0.3}
      - {cmd: state}
      - {cmd: kill, id: tune}
      - {cmd: file, path: ley_bg-tune.log, contains: [interrupted, "!panic"]}
      - {cmd: ley_bg, id: quick, args: [quick]}
      - {cmd: wait, seconds: 0.3}
      - {cmd: kill, id: quick}
      - {cmd: file, path: bookmarks.json, contains: x}
      - {cmd: ley_bg, id: left, args: [tune]}
      - {cmd: wait, seconds: 0.3}
`, func(string) (*sceneDaemon, error) {
		return &sceneDaemon{env: []string{"LEYLINE_SOCKET=/scene.sock"}, stop: func() {}}, nil
	})
	if !errors.Is(err, errChecksFailed) {
		t.Fatalf("err = %v\n%s", err, out)
	}
	expectOutput(t, out,
		`ok       s 1440x820 ley#1 stdout /Calling/ "Calling  146.520 MHz"`,
		`ok       s 1440x820 ley#2 stdout /!Club/ absent`,
		`ok       s 1440x820 ley#2 stdout /146\.520/ "Calling  146.520 MHz"`,
		`fail     s 1440x820 ley#2 stdout /147\.180/ no match`,
		`fail     s 1440x820 ley#3 exit           got 3 want 0: no such channel  checks/s/1440x820/run/steps.log`,
		`ok       s 1440x820 ley#4 exit           3`,
		`ok       s 1440x820 file#9 /interrupted/ "interrupted"`,
		`ok       s 1440x820 file#9 /!panic/      absent  checks/s/1440x820/run/ley_bg-tune.log`,
		`fail     s 1440x820 kill#12              ley_bg quick had already exited (exit status 0)  checks/s/1440x820/run/ley_bg-quick.log`,
		`fail     s 1440x820 file#13              no such file  checks/s/1440x820/run/bookmarks.json`,
		"10 checked: 6 ok, 4 fail; ",
	)
	run := filepath.Join(dir, "checks", "s", "1440x820", "run")
	if b, _ := os.ReadFile(filepath.Join(dir, "bin", "socket.txt")); strings.TrimSpace(string(b)) != "/scene.sock" {
		t.Errorf("ley was pointed at %q, not the scene's socket", b)
	}
	if b, _ := os.ReadFile(filepath.Join(run, "steps.log")); !strings.Contains(string(b), "$ ley fail   (ley#3)\nno such channel\nexit 3\n") {
		t.Errorf("steps.log:\n%s", b)
	}
	// The one left running was interrupted, not killed, before the run ended.
	if b, _ := os.ReadFile(filepath.Join(run, "ley_bg-left.log")); string(b) != "tuned\ninterrupted\n" {
		t.Errorf("the background ley left running: %q", b)
	}
	fake.mu.Lock()
	var cmds []string
	for _, c := range fake.commands {
		cmds = append(cmds, fmt.Sprintf("%v:%v", c["id"], c["cmd"]))
	}
	fake.mu.Unlock()
	if got := strings.Join(cmds, " "); got != "6:wait 7:state 11:wait 15:wait 16:quit" {
		t.Errorf("the app was sent %s", got)
	}
}

// A ley that cannot be started ends the scene with an error, and the app still quits.
func TestCheckLocalLeyMissing(t *testing.T) {
	dir := t.TempDir()
	fake, out, err := checkWithFakeApp(t, dir, `scenes:
  - name: s
    fixtures: [{name: scene_2m}]
    app:
      - {cmd: state}
      - {cmd: ley_bg, id: a, args: [tune]}
      - {cmd: state}
`, func(run string) (*sceneDaemon, error) {
		// The scene's ley is gone by the time the scene runs.
		return &sceneDaemon{stop: func() {}}, os.Remove(filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(run)))), "bin", "ley"))
	})
	if !errors.Is(err, errChecksFailed) {
		t.Fatalf("err = %v\n%s", err, out)
	}
	expectOutput(t, out, "error    s 1440x820 ley_bg#2             ley tune: ", "1 checked: 1 error; ")
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if n := len(fake.commands); n != 2 || fake.commands[1]["cmd"] != "quit" {
		t.Errorf("the app was sent %v", fake.commands)
	}
}

// daemon stops and starts the scene's daemon in order with the app's commands; one that will not
// start again ends the scene.
func TestCheckDaemonCommand(t *testing.T) {
	var calls []string
	scenes := `scenes:
  - name: s
    fixtures: [{name: scene_2m}]
    app:
      - {cmd: daemon, op: stop}
      - {cmd: state, expect: {tuned_hz: 146520000}}
      - {cmd: daemon, op: start}
      - {cmd: state, expect: {tuned_hz: 146520000}}
`
	var resumeErr error
	prepare := func(string) (*sceneDaemon, error) {
		return &sceneDaemon{
			stop: func() { calls = append(calls, "stop") },
			halt: func() { calls = append(calls, "halt") },
			resume: func(context.Context) error {
				calls = append(calls, "resume")
				return resumeErr
			},
		}, nil
	}
	_, out, err := checkWithFakeApp(t, t.TempDir(), scenes, prepare)
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if got := strings.Join(calls, " "); got != "halt resume stop" {
		t.Errorf("the daemon was %s", got)
	}
	calls, resumeErr = nil, errors.New("leylined did not answer")
	_, out, err = checkWithFakeApp(t, t.TempDir(), scenes, prepare)
	if !errors.Is(err, errChecksFailed) {
		t.Fatalf("err = %v\n%s", err, out)
	}
	expectOutput(t, out,
		"ok       s 1440x820 state#2 tuned_hz",
		"error    s 1440x820 daemon#3             the scene's daemon did not start again: leylined did not answer",
		"2 checked: 1 ok, 1 error; ",
	)
	if got := strings.Join(calls, " "); got != "halt resume stop" {
		t.Errorf("the daemon was %s", got)
	}
}
