// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"
)

// historyRuns is how many runs history.jsonl keeps.
const historyRuns = 20

// historyMinRuns is how many earlier runs of a scene at a size it takes before a run is compared
// with their median.
const historyMinRuns = 3

// slowerFactor is how far over its median a scene's time must be to be named slower than usual.
const slowerFactor = 1.5

// sceneTime is one scene at one size's wall time, by phase, in seconds: its daemon set up, the
// app from launch to ready.json, the commands (relaunches included) and the quit. Seconds is the
// whole, the daemon's stop included.
type sceneTime struct {
	Scene    string  `json:"scene"`
	Size     string  `json:"size"`
	Seconds  float64 `json:"seconds"`
	Daemon   float64 `json:"daemon_seconds"`
	Ready    float64 `json:"ready_seconds"`
	Commands float64 `json:"commands_seconds"`
	Quit     float64 `json:"quit_seconds"`
	// Median is the scene's median over the earlier runs history.jsonl holds, when there are
	// historyMinRuns of them; Slower is a time over slowerFactor times it.
	Median float64 `json:"median_seconds,omitempty"`
	Slower bool    `json:"slower,omitempty"`
	// errored is a scene that ended in an error line: its time says nothing about the scene and
	// stays out of the history.
	errored bool
}

// key is the scene and size as the history names them.
func (t sceneTime) key() string { return t.Scene + " " + t.Size }

// line is the time as the output prints it, in the columns of a result's line.
func (t sceneTime) line() string {
	detail := fmt.Sprintf("daemon %s, ready %s, commands %s, quit %s",
		seconds(t.Daemon), seconds(t.Ready), seconds(t.Commands), seconds(t.Quit))
	if t.Slower {
		detail += fmt.Sprintf("; slower than usual (median %s)", seconds(t.Median))
	}
	return fmt.Sprintf("%-8s %s %s %-20s %s", "time", t.Scene, t.Size, seconds(t.Seconds), detail)
}

// seconds prints a duration in seconds as the lines do: 34.2 s.
func seconds(s float64) string { return fmt.Sprintf("%.1f s", s) }

// phases splits a scene's wall time: each lap adds the time since the last one to a phase.
type phases struct {
	start, last time.Time
	t           *sceneTime
}

func newPhases(t *sceneTime) *phases {
	now := time.Now()
	return &phases{start: now, last: now, t: t}
}

func (p *phases) lap(phase *float64) {
	now := time.Now()
	*phase += now.Sub(p.last).Seconds()
	p.last = now
}

func (p *phases) end() { p.t.Seconds = time.Since(p.start).Seconds() }

// historyRun is one line of history.jsonl: a run's time per scene and size, in seconds.
type historyRun struct {
	At    time.Time          `json:"at"`
	Jobs  int                `json:"jobs"`
	Times map[string]float64 `json:"times"`
}

// readHistory reads history.jsonl, skipping a line that does not parse; a missing file is none.
func readHistory(path string) []historyRun {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var runs []historyRun
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		var r historyRun
		if json.Unmarshal(sc.Bytes(), &r) == nil && r.Times != nil {
			runs = append(runs, r)
		}
	}
	return runs
}

// compare sets the time's median over the earlier runs that timed the same scene at the same
// size, and marks it slower than usual when it is over slowerFactor times that.
func (t *sceneTime) compare(runs []historyRun) {
	var earlier []float64
	for _, r := range runs {
		if s, ok := r.Times[t.key()]; ok {
			earlier = append(earlier, s)
		}
	}
	if len(earlier) < historyMinRuns {
		return
	}
	t.Median = median(earlier)
	t.Slower = !t.errored && t.Seconds > slowerFactor*t.Median
}

func median(v []float64) float64 {
	s := slices.Clone(v)
	slices.Sort(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// writeHistory appends this run's times, those that did not end in an error, and keeps the last
// historyRuns runs.
func writeHistory(path string, runs []historyRun, now time.Time, jobs int, times []sceneTime) error {
	this := historyRun{At: now.UTC().Truncate(time.Second), Jobs: jobs, Times: map[string]float64{}}
	for _, t := range times {
		if !t.errored {
			this.Times[t.key()] = float64(int(t.Seconds*10+0.5)) / 10
		}
	}
	if len(this.Times) == 0 {
		return nil
	}
	runs = append(runs, this)
	if len(runs) > historyRuns {
		runs = runs[len(runs)-historyRuns:]
	}
	var b bytes.Buffer
	for _, r := range runs {
		line, err := json.Marshal(r)
		if err != nil {
			return err
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b.Bytes(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// timeSummary is the summary line's part on time: the run's wall time, the three slowest scenes
// and sizes, and those slower than usual.
func timeSummary(total time.Duration, times []sceneTime) string {
	if len(times) == 0 {
		return seconds(total.Seconds())
	}
	byTime := slices.Clone(times)
	slices.SortStableFunc(byTime, func(a, b sceneTime) int {
		switch {
		case a.Seconds > b.Seconds:
			return -1
		case a.Seconds < b.Seconds:
			return 1
		}
		return 0
	})
	var slowest []string
	for _, t := range byTime[:min(3, len(byTime))] {
		slowest = append(slowest, t.key()+" "+seconds(t.Seconds))
	}
	out := seconds(total.Seconds()) + ", slowest " + strings.Join(slowest, ", ")
	var slower []string
	for _, t := range times {
		if t.Slower {
			slower = append(slower, t.key())
		}
	}
	if len(slower) > 0 {
		out += "; slower than usual: " + strings.Join(slower, ", ")
	}
	return out
}
