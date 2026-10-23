// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// Each scene and size prints its time and phases after its lines, the summary line gives the
// run's time and the slowest, summary.json and history.jsonl keep them, and a scene much slower
// than its median in the earlier runs is named.
func TestCheckTiming(t *testing.T) {
	dir := t.TempDir()
	scenes := `scenes:
  - name: quick
    fixtures: [{name: scene_2m}]
    app: [{cmd: state, expect: {tuned_hz: 146520000}}]
  - name: slow
    fixtures: [{name: scene_2m}]
    sizes: [{width: 100, height: 60}, {width: 80, height: 50}]
    app: [{cmd: wait, seconds: 0.3}]
`
	daemon := func(string) (*sceneDaemon, error) { return &sceneDaemon{stop: func() {}}, nil }
	_, out, err := checkWithFakeApp(t, dir, scenes, daemon)
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	timeLine := regexp.MustCompile(`(?m)^time     slow 100x60 0\.[3-9] s +daemon 0\.0 s, ready 0\.[0-9] s, commands 0\.[3-9] s, quit 0\.[0-9] s$`)
	if !timeLine.MatchString(out) {
		t.Errorf("no time line for slow 100x60:\n%s", out)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if !strings.HasPrefix(lines[1], "time     quick 1440x820 ") {
		t.Errorf("the time does not follow the scene's lines:\n%s", out)
	}
	summary := regexp.MustCompile(`^1 checked: 1 ok; [0-9.]+ s, slowest slow (100x60|80x50) 0\.[3-9] s, slow (100x60|80x50) 0\.[3-9] s, quick 1440x820 [0-9.]+ s; checks/summary.json$`)
	if last := lines[len(lines)-1]; !summary.MatchString(last) {
		t.Errorf("the summary line: %q", last)
	}
	var sum struct {
		Seconds float64     `json:"seconds"`
		Times   []sceneTime `json:"times"`
	}
	b, err := os.ReadFile(filepath.Join(dir, "checks", "summary.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &sum); err != nil {
		t.Fatal(err)
	}
	if len(sum.Times) != 3 || sum.Times[1].Scene != "slow" || sum.Times[1].Commands < 0.3 || sum.Seconds < 0.6 {
		t.Errorf("summary.json's times: %s", b)
	}
	history := filepath.Join(dir, "checks", "history.jsonl")
	if runs := readHistory(history); len(runs) != 1 || runs[0].Times["slow 80x50"] < 0.3 {
		t.Errorf("history.jsonl: %+v", runs)
	}

	// Three earlier runs at a tenth of a second: slow is now slower than usual, quick is not.
	var h strings.Builder
	for i := 0; i < 3; i++ {
		fmt.Fprintf(&h, `{"at":"2026-10-22T10:0%d:00Z","jobs":1,"times":{"slow 100x60":0.1,"quick 1440x820":5}}`+"\n", i)
	}
	writeFile(t, history, h.String())
	_, out, err = checkWithFakeApp(t, dir, scenes, daemon)
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if !regexp.MustCompile(`(?m)^time     slow 100x60 .*; slower than usual \(median 0\.1 s\)$`).MatchString(out) {
		t.Errorf("slow 100x60 is not named slower than usual:\n%s", out)
	}
	if regexp.MustCompile(`(?m)^time     quick .*slower`).MatchString(out) {
		t.Errorf("quick named slower:\n%s", out)
	}
	if !strings.Contains(out, "; slower than usual: slow 100x60; checks/summary.json") {
		t.Errorf("the summary line does not name it:\n%s", out)
	}
	// slow 80x50 has no earlier runs, so it is not compared.
	if regexp.MustCompile(`(?m)^time     slow 80x50 .*slower than usual`).MatchString(out) {
		t.Errorf("slow 80x50 compared with no history:\n%s", out)
	}
	if runs := readHistory(history); len(runs) != 4 {
		t.Errorf("history.jsonl holds %d runs, want 4", len(runs))
	}
}

// The history keeps the last historyRuns runs, and a scene that ended in an error stays out.
func TestWriteHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "history.jsonl")
	var runs []historyRun
	for i := 0; i < historyRuns; i++ {
		runs = append(runs, historyRun{Jobs: 1, Times: map[string]float64{"a 1x1": float64(i)}})
	}
	times := []sceneTime{
		{Scene: "a", Size: "1x1", Seconds: 34.25},
		{Scene: "b", Size: "1x1", Seconds: 2, errored: true},
	}
	if err := writeHistory(path, runs, time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC), 3, times); err != nil {
		t.Fatal(err)
	}
	got := readHistory(path)
	if len(got) != historyRuns || got[0].Times["a 1x1"] != 1 {
		t.Fatalf("kept %d runs, the first %v", len(got), got[0].Times)
	}
	last := got[len(got)-1]
	if last.Jobs != 3 || last.Times["a 1x1"] != 34.3 || len(last.Times) != 1 || !last.At.Equal(time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC)) {
		t.Errorf("the run written: %+v", last)
	}
	if median([]float64{3, 1, 2}) != 2 || median([]float64{4, 1, 2, 3}) != 2.5 {
		t.Error("median")
	}
}
