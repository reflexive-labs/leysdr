// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// --jobs 3 runs three scenes at a time, each in its own run and control directory with its lines
// together, and a serial scene with nothing beside it.
func TestCheckJobs(t *testing.T) {
	dir := t.TempDir()
	var scenes strings.Builder
	scenes.WriteString("scenes:\n")
	for _, n := range []string{"a", "b", "c", "d", "e"} {
		fmt.Fprintf(&scenes, "  - name: %s\n    fixtures: [{name: scene_2m}]\n"+
			"    app: [{cmd: wait, seconds: 0.2}, {cmd: state, expect: {tuned_hz: 146520000}}, {cmd: snapshot, name: one}]\n", n)
	}
	scenes.WriteString("  - name: wide\n    serial: true\n    fixtures: [{name: scene_2m}]\n" +
		"    sizes: [{width: 100, height: 60}, {width: 80, height: 50}]\n" +
		"    app: [{cmd: wait, seconds: 0.2}, {cmd: state, expect: {tuned_hz: 146520000}}]\n")
	writeFile(t, filepath.Join(dir, "scenes.yaml"), scenes.String())
	fake := &fakeApp{alive: map[int]bool{}, state: map[string]any{"tuned_hz": 146520000}, shade: 0x40}
	var mu sync.Mutex
	running, most := 0, 0
	serialRunning := false
	var besideSerial []string
	var stdout bytes.Buffer
	o := checkOptions{
		runOptions: runOptions{root: dir, out: filepath.Join(dir, "checks"), stdout: &stdout, logf: t.Logf},
		checks:     filepath.Join(dir, "scenes.yaml"), goldens: filepath.Join(dir, "goldens"), release: "26.6", jobs: 3,
		prepare: func(_ context.Context, _ *CheckFile, s *CheckScene, run string) (*sceneDaemon, error) {
			mu.Lock()
			running++
			most = max(most, running)
			if serialRunning || (s.Serial && running > 1) {
				besideSerial = append(besideSerial, s.Name)
			}
			serialRunning = serialRunning || s.Serial
			mu.Unlock()
			stop := func() {
				mu.Lock()
				running--
				if s.Serial {
					serialRunning = false
				}
				mu.Unlock()
			}
			return &sceneDaemon{stop: stop}, os.MkdirAll(run, 0o755)
		},
		launch: fake.launch,
		alive: func(pid int) bool {
			fake.mu.Lock()
			defer fake.mu.Unlock()
			return fake.alive[pid]
		},
		kill:    func(pid int) { t.Errorf("killed %d", pid) },
		findPID: func(context.Context, string) int { return 0 },
		grace:   5 * time.Second, poll: 5 * time.Millisecond,
	}
	if err := checkScenes(context.Background(), o); err != nil {
		t.Fatalf("%v\n%s", err, stdout.String())
	}
	out := stdout.String()
	if most != 3 {
		t.Errorf("at most %d scenes ran at once, want 3", most)
	}
	if len(besideSerial) > 0 {
		t.Errorf("ran beside a serial scene: %v", besideSerial)
	}
	// Each scene's lines are together and end with its time; the serial sizes come last.
	lines := strings.Split(strings.TrimSpace(out), "\n")
	var order []string
	for i, l := range lines[:len(lines)-1] {
		f := strings.Fields(l)
		if f[0] != "time" {
			if next := strings.Fields(lines[i+1]); next[1] != f[1] || next[2] != f[2] {
				t.Errorf("line %d (%s %s) is followed by another scene's: %q", i+1, f[1], f[2], lines[i+1])
			}
			continue
		}
		order = append(order, f[1]+" "+f[2])
	}
	if len(order) != 7 || order[5] != "wide 100x60" || order[6] != "wide 80x50" {
		t.Errorf("the scenes' times in order: %v", order)
	}
	if !strings.HasPrefix(lines[len(lines)-1], "12 checked: 7 ok, 5 new; ") {
		t.Errorf("the summary: %s", lines[len(lines)-1])
	}
	// Each run had a control directory of its own.
	controls := map[string]bool{}
	fake.mu.Lock()
	for _, env := range fake.envs {
		for _, kv := range env {
			if v, ok := strings.CutPrefix(kv, "LEYLINE_APP_CONTROL="); ok {
				controls[v] = true
			}
		}
	}
	launches := len(fake.envs)
	fake.mu.Unlock()
	if launches != 7 || len(controls) != 7 {
		t.Errorf("%d launches with %d control directories", launches, len(controls))
	}
	if runs := readHistory(filepath.Join(dir, "checks", "history.jsonl")); len(runs) != 1 || runs[0].Jobs != 3 || len(runs[0].Times) != 7 {
		t.Errorf("history: %+v", runs)
	}
}
