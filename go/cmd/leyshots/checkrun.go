// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// answerGrace is how long the app has to answer a command beyond the time the command itself
// takes (a stage's settle, a wait's seconds).
const answerGrace = 30 * time.Second

// quitGrace is how long the app has to exit after it answers quit before it is killed.
const quitGrace = 5 * time.Second

// errChecksFailed is a check run with a diff, a failure or an error; the lines already say which.
var errChecksFailed = errors.New("checks failed")

// checkOptions are `leyshots check`'s inputs. The function fields are the seams the tests
// replace: the scene's daemon, the app's launch and the process table.
type checkOptions struct {
	runOptions
	// checks is app/checks/scenes.yaml; goldens the directory above <release>-<arch>.
	checks, goldens string
	// release is the running macOS as major.minor.
	release string
	record  bool
	// hold leaves the one scene's app and daemon running after its commands, for driving by hand
	// over the command file, until the app quits or the run is interrupted.
	hold bool
	// prepare starts the scene's daemon in run and returns the environment that points the app
	// at it, and how to stop it.
	prepare func(ctx context.Context, f *CheckFile, s *CheckScene, run string) (env []string, stop func(), err error)
	launch  func(ctx context.Context, l appLaunch) error
	alive   func(pid int) bool
	kill    func(pid int)
	// findPID finds the app started with this control directory, for when it never wrote
	// ready.json; 0 when there is none.
	findPID func(ctx context.Context, control string) int
	// grace stands for answerGrace and the wait for ready.json beyond the stage's own time.
	grace time.Duration
	poll  time.Duration
}

// appLaunch is one start of the app.
type appLaunch struct {
	app string
	// env is what the app gets, as KEY=value: open does not pass the caller's environment.
	env []string
	// output receives the app's stdout and stderr.
	output string
}

// checkResult is one line of the output and one entry of summary.json.
type checkResult struct {
	// Status is ok, diff, new, recorded, fail or error.
	Status string `json:"status"`
	Scene  string `json:"scene"`
	Size   string `json:"size"`
	Item   string `json:"item"`
	// Changed is a compared snapshot's percentage of changed pixels.
	Changed *float64 `json:"changed_percent,omitempty"`
	Path    string   `json:"path,omitempty"`
	Detail  string   `json:"detail,omitempty"`
}

// line is the result as the output prints it.
func (r checkResult) line() string {
	var rest []string
	if r.Changed != nil {
		rest = append(rest, fmt.Sprintf("%.2f %%", *r.Changed))
	}
	if r.Detail != "" {
		rest = append(rest, r.Detail)
	}
	if r.Path != "" {
		rest = append(rest, r.Path)
	}
	return strings.TrimRight(fmt.Sprintf("%-8s %s %s %-20s %s", r.Status, r.Scene, r.Size, r.Item, strings.Join(rest, "  ")), " ")
}

// failing reports whether the result makes the run exit 1.
func (r checkResult) failing() bool {
	return r.Status == "diff" || r.Status == "fail" || r.Status == "error"
}

// answer is the app's out/<id>.json.
type answer struct {
	ID     int             `json:"id"`
	OK     bool            `json:"ok"`
	Error  string          `json:"error"`
	Files  []string        `json:"files"`
	Result json.RawMessage `json:"result"`
}

// ready is the app's ready.json.
type ready struct {
	OK           bool    `json:"ok"`
	PID          int     `json:"pid"`
	WindowNumber int     `json:"window_number"`
	Scale        float64 `json:"scale"`
	Error        string  `json:"error"`
}

// snapshotResult is a snapshot answer's result.
type snapshotResult struct {
	Scale    float64         `json:"scale"`
	WidthPt  float64         `json:"width_pt"`
	HeightPt float64         `json:"height_pt"`
	Regions  json.RawMessage `json:"regions"`
}

// regions reads the snapshot's regions: a map of name to rectangle, or regions.json's whole
// object with that map under "regions".
func (s snapshotResult) regions() (map[string]Rect, error) {
	if len(s.Regions) == 0 {
		return nil, nil
	}
	var whole struct {
		Regions map[string]Rect `json:"regions"`
	}
	if err := json.Unmarshal(s.Regions, &whole); err == nil && whole.Regions != nil {
		return whole.Regions, nil
	}
	var m map[string]Rect
	if err := json.Unmarshal(s.Regions, &m); err != nil {
		return nil, fmt.Errorf("the snapshot's regions: %w", err)
	}
	return m, nil
}

// checker runs the scenes and collects the results.
type checker struct {
	o       checkOptions
	f       *CheckFile
	results []checkResult
}

// checkScenes runs each selected scene at each of its sizes, prints a line per artefact and
// expectation and a summary, and writes summary.json in o.out. It returns errChecksFailed when a
// line is a diff, a failure or an error.
func checkScenes(ctx context.Context, o checkOptions) error {
	f, err := LoadChecks(o.checks)
	if err != nil {
		return err
	}
	scenes, err := f.Select(o.only)
	if err != nil {
		return err
	}
	if o.hold && len(scenes) != 1 {
		return errors.New("--hold takes one scene: name it with --only")
	}
	if err := os.MkdirAll(o.out, 0o755); err != nil {
		return err
	}
	if o.stageApp != nil && len(scenes) > 0 {
		if o.app, err = o.stageApp(ctx, o.app); err != nil {
			return err
		}
	}
	c := &checker{o: o, f: f}
	for _, s := range scenes {
		sizes := s.sizes()
		if o.hold {
			sizes = sizes[:1] // a hold ends the run, so the scene's first size is the only one
		}
		for _, size := range sizes {
			if ctx.Err() != nil {
				break
			}
			c.o.logf("%s %s", s.Name, size)
			c.runSize(ctx, s, size)
		}
	}
	if err := ctx.Err(); err != nil {
		// An interrupted run checked less than it was asked to: it fails, with what did run above.
		c.add(checkResult{Status: "error", Scene: "-", Size: "-", Item: "-", Detail: "interrupted: " + err.Error()})
	}
	counts := map[string]int{}
	failing := false
	for _, r := range c.results {
		counts[r.Status]++
		failing = failing || r.failing()
	}
	var parts []string
	for _, st := range []string{"ok", "recorded", "new", "diff", "fail", "error"} {
		if counts[st] > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", counts[st], st))
		}
	}
	summary := filepath.Join(o.out, "summary.json")
	fmt.Fprintf(o.stdout, "%d checked: %s; %s\n", len(c.results), strings.Join(parts, ", "), c.rel(summary))
	b, err := json.MarshalIndent(struct {
		Goldens string         `json:"goldens"`
		Record  bool           `json:"record"`
		Counts  map[string]int `json:"counts"`
		Results []checkResult  `json:"results"`
	}{c.goldenRoot(), o.record, counts, c.results}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(summary, append(b, '\n'), 0o644); err != nil {
		return err
	}
	if failing {
		return errChecksFailed
	}
	return nil
}

// add records a result and prints its line.
func (c *checker) add(r checkResult) {
	c.results = append(c.results, r)
	fmt.Fprintln(c.o.stdout, r.line())
}

// rel is p relative to the checkout when it is inside it, so the lines stay short.
func (c *checker) rel(p string) string {
	if c.o.root == "" {
		return p
	}
	if r, err := filepath.Rel(c.o.root, p); err == nil && !strings.HasPrefix(r, "..") {
		return r
	}
	return p
}

func (c *checker) goldenRoot() string {
	return filepath.Join(c.o.goldens, c.o.release+"-"+runtime.GOARCH)
}

// runSize runs one scene at one window size: its daemon, the app, the commands, then quit.
func (c *checker) runSize(ctx context.Context, s *CheckScene, size Size) {
	dir := filepath.Join(c.o.out, s.Name, size.String())
	fail := func(err error) {
		c.add(checkResult{Status: "error", Scene: s.Name, Size: size.String(), Item: "-", Detail: err.Error()})
	}
	if err := os.RemoveAll(dir); err != nil {
		fail(err)
		return
	}
	run := filepath.Join(dir, "run")
	env, stop, err := c.o.prepare(ctx, c.f, s, run)
	if err != nil {
		fail(err)
		return
	}
	defer stop()
	app, err := c.launch(ctx, s, size, run, env)
	if err != nil {
		fail(err)
		return
	}
	// A held app may have been sent commands by hand, so quit takes the id after the last used.
	defer func() { app.quit(ctx, app.nextID(len(s.App)+1)) }()
	for i := range s.App {
		cmd := &s.App[i]
		id := i + 1
		a, err := app.send(ctx, cmd, id, c.f.Path)
		if err != nil {
			fail(fmt.Errorf("%s: %w", cmd.label(id), err))
			return
		}
		c.handle(ctx, s, size, dir, app, cmd, id, a)
	}
	if c.o.hold {
		app.hold(ctx, s, size, env)
	}
}

// hold prints how to drive the app over its command file and waits until the app exits or the
// run is interrupted. The scene's daemon runs as long as the hold does.
func (a *runningApp) hold(ctx context.Context, s *CheckScene, size Size, env []string) {
	next := a.nextID(len(s.App) + 1)
	cmds := filepath.Join(a.control, "commands.jsonl")
	a.c.o.logf("holding %s %s: the app is pid %d; its log is %s", s.Name, size, a.pid, a.log)
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "LEYLINE_SOCKET="); ok {
			a.c.o.logf("  the scene's daemon: ley --socket %s …", v)
		}
	}
	a.c.o.logf("  send a command: echo '{\"id\":%d,\"cmd\":\"snapshot\"}' >> %s", next, cmds)
	a.c.o.logf("  read its answer: %s (ids from %d, each used once)", filepath.Join(a.control, "out", strconv.Itoa(next)+".json"), next)
	a.c.o.logf("  end the hold: a quit command, or interrupt leyshots (pid %d)", os.Getpid())
	for ctx.Err() == nil {
		pid := a.pid
		if pid == 0 {
			pid = a.c.o.findPID(ctx, a.control)
		}
		if pid == 0 || !a.c.o.alive(pid) {
			a.c.o.logf("the app has exited; the hold ends")
			return
		}
		if sleepFor(ctx, a.c.o.poll) != nil {
			return
		}
	}
}

// nextID is the id after the largest commands.jsonl holds, and at least least.
func (a *runningApp) nextID(least int) int {
	b, err := os.ReadFile(filepath.Join(a.control, "commands.jsonl"))
	if err != nil {
		return least
	}
	for _, line := range bytes.Split(b, []byte("\n")) {
		var w struct {
			ID int `json:"id"`
		}
		if json.Unmarshal(line, &w) == nil && w.ID >= least {
			least = w.ID + 1
		}
	}
	return least
}

// runningApp is a launched app and its control directory.
type runningApp struct {
	c       *checker
	control string
	log     string
	pid     int
}

// launch writes the stage file (the scene's stage at this size), starts the app with
// `open -g -n`, so nothing takes focus, and waits for ready.json.
func (c *checker) launch(ctx context.Context, s *CheckScene, size Size, run string, env []string) (*runningApp, error) {
	control := filepath.Join(run, "control")
	if err := os.MkdirAll(filepath.Join(control, "out"), 0o755); err != nil {
		return nil, err
	}
	st := Stage{}
	if s.Stage != nil {
		var err error
		if st, err = resolveStage(c.f.Path, s.Stage); err != nil {
			return nil, err
		}
	}
	// The stage file is written even for a scene without a stage: it is what sizes the window.
	st.Window = &Size{Width: size.Width, Height: size.Height}
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return nil, err
	}
	stagePath := filepath.Join(run, "stage.json")
	if err := os.WriteFile(stagePath, b, 0o644); err != nil {
		return nil, err
	}
	a := &runningApp{c: c, control: control, log: filepath.Join(run, "app.log")}
	l := appLaunch{app: c.o.app, output: filepath.Join(run, "app.stderr")}
	for _, kv := range env {
		if strings.HasPrefix(kv, "LEYLINE_") {
			l.env = append(l.env, kv)
		}
	}
	l.env = append(l.env, "LEYLINE_APP_CONTROL="+control, "LEYLINE_APP_STAGE="+stagePath, "LEYLINE_APP_LOG="+a.log)
	if err := c.o.launch(ctx, l); err != nil {
		return nil, err
	}
	wait := time.Duration(st.Settle*float64(time.Second)) + c.o.grace
	if st.OnAir {
		wait += onAirGrace
	}
	path := filepath.Join(control, "ready.json")
	deadline := time.Now().Add(wait)
	var parseErr error
	for {
		if b, err := os.ReadFile(path); err == nil {
			// A file that does not parse may be mid-write: read it again until the deadline.
			var r ready
			parseErr = json.Unmarshal(b, &r)
			if parseErr == nil {
				a.pid = r.PID
				if !r.OK {
					a.quit(ctx, 0)
					return nil, fmt.Errorf("the app was not ready: %s; its log is %s", r.Error, c.rel(a.log))
				}
				return a, nil
			}
		}
		if time.Now().After(deadline) {
			a.quit(ctx, 0)
			if parseErr != nil {
				return nil, fmt.Errorf("%s did not parse within %.0f s: %w; the app's log is %s", path, wait.Seconds(), parseErr, c.rel(a.log))
			}
			return nil, fmt.Errorf("the app wrote no ready.json within %.0f s; its log is %s and its output %s",
				wait.Seconds(), c.rel(a.log), c.rel(l.output))
		}
		if err := sleepFor(ctx, c.o.poll); err != nil {
			a.quit(ctx, 0)
			return nil, err
		}
	}
}

// send appends the command to commands.jsonl and waits for its answer.
func (a *runningApp) send(ctx context.Context, cmd *AppCommand, id int, path func(string) string) (*answer, error) {
	w, err := cmd.wire(id, path)
	if err != nil {
		return nil, err
	}
	if err := a.write(w); err != nil {
		return nil, err
	}
	wait := a.c.o.grace
	switch {
	case cmd.Stage != nil:
		wait += time.Duration(cmd.Stage.Settle * float64(time.Second))
		if cmd.Stage.OnAir {
			wait += onAirGrace
		}
	default:
		wait += time.Duration((cmd.Settle + cmd.Seconds) * float64(time.Second))
	}
	return a.await(ctx, id, wait)
}

// write appends one line to commands.jsonl in a single write, so the app never reads half of it.
func (a *runningApp) write(w wireCommand) error {
	b, err := json.Marshal(w)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(a.control, "commands.jsonl"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(b, '\n')); err != nil {
		_ = f.Close() // the write error is the one to report
		return err
	}
	return f.Close()
}

// await waits for out/<id>.json. The app writes it by renaming a finished file, so a file that is
// there is whole.
func (a *runningApp) await(ctx context.Context, id int, wait time.Duration) (*answer, error) {
	path := filepath.Join(a.control, "out", strconv.Itoa(id)+".json")
	deadline := time.Now().Add(wait)
	for {
		if b, err := os.ReadFile(path); err == nil {
			var ans answer
			if err := json.Unmarshal(b, &ans); err != nil {
				return nil, fmt.Errorf("%s: %w", path, err)
			}
			return &ans, nil
		}
		if a.pid != 0 && !a.c.o.alive(a.pid) {
			return nil, fmt.Errorf("the app exited without answering; its log is %s; crash reports are in ~/Library/Logs/DiagnosticReports", a.c.rel(a.log))
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("no answer within %.0f s; the app's log is %s", wait.Seconds(), a.c.rel(a.log))
		}
		if err := sleepFor(ctx, a.c.o.poll); err != nil {
			return nil, err
		}
	}
}

// quit sends quit as command id (0 when the app never became ready), gives the app quitGrace to
// exit, and kills it if it has not.
func (a *runningApp) quit(ctx context.Context, id int) {
	grace := min(quitGrace, a.c.o.grace)
	if id > 0 {
		if err := a.write(wireCommand{ID: id, Cmd: "quit"}); err == nil {
			_, _ = a.await(ctx, id, grace) // an app that does not answer is killed below
		}
	}
	pid := a.pid
	if pid == 0 {
		pid = a.c.o.findPID(context.WithoutCancel(ctx), a.control)
	}
	if pid == 0 {
		a.c.o.logf("found no app process started with control directory %s; it may still be running", a.control)
		return
	}
	for deadline := time.Now().Add(grace); time.Now().Before(deadline); {
		if !a.c.o.alive(pid) {
			return
		}
		time.Sleep(a.c.o.poll)
	}
	a.c.o.logf("the app (pid %d) did not exit; killing it", pid)
	a.c.o.kill(pid)
}

// handle turns one answer into result lines: a snapshot or ax tree is kept and compared with its
// golden, a state answer is kept and its expectations checked; other commands print only when
// the app could not run them.
func (c *checker) handle(ctx context.Context, s *CheckScene, size Size, dir string, app *runningApp, cmd *AppCommand, id int, a *answer) {
	base := checkResult{Scene: s.Name, Size: size.String(), Item: cmd.label(id)}
	fail := func(status, detail string) {
		r := base
		r.Status, r.Detail = status, detail
		c.add(r)
	}
	if !a.OK {
		fail("fail", "the app: "+a.Error)
		return
	}
	switch cmd.Cmd {
	case "snapshot":
		src, ok := answerFile(a, ".png")
		if !ok {
			fail("error", "the answer names no .png")
			return
		}
		actual := filepath.Join(dir, cmd.Name+".png")
		if err := copyArtefact(filepath.Join(app.control, src), actual); err != nil {
			fail("error", err.Error())
			return
		}
		var res snapshotResult
		if err := json.Unmarshal(a.Result, &res); err != nil {
			fail("error", "the snapshot's result: "+err.Error())
			return
		}
		r := c.compareSnapshot(s, size, cmd, actual, res)
		r.Scene, r.Size, r.Item = base.Scene, base.Size, base.Item
		c.add(r)
	case "ax":
		src, ok := answerFile(a, ".ax.txt")
		if !ok {
			fail("error", "the answer names no .ax.txt")
			return
		}
		actual := filepath.Join(dir, cmd.Name+".ax.txt")
		if err := copyArtefact(filepath.Join(app.control, src), actual); err != nil {
			fail("error", err.Error())
			return
		}
		var res snapshotResult
		if len(a.Result) > 0 {
			if err := json.Unmarshal(a.Result, &res); err != nil {
				fail("error", "the ax answer's result: "+err.Error())
				return
			}
		}
		r := c.compareAX(ctx, s, size, cmd, actual, res)
		r.Scene, r.Size, r.Item = base.Scene, base.Size, base.Item
		c.add(r)
	case "state":
		path := filepath.Join(dir, fmt.Sprintf("state-%d.json", id))
		if err := os.WriteFile(path, a.Result, 0o644); err != nil {
			fail("error", err.Error())
			return
		}
		for _, r := range checkExpect(a.Result, cmd.Expect) {
			r.Scene, r.Size, r.Item = base.Scene, base.Size, base.Item+" "+r.Item
			c.add(r)
		}
	}
}

// answerFile is the first file of the answer with the suffix, relative to the control directory.
func answerFile(a *answer, suffix string) (string, bool) {
	for _, f := range a.Files {
		if strings.HasSuffix(f, suffix) {
			return f, true
		}
	}
	return "", false
}

func copyArtefact(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, 0o644)
}

// record copies an artefact over its golden.
func (c *checker) record(actual, golden string) checkResult {
	if err := os.MkdirAll(filepath.Dir(golden), 0o755); err != nil {
		return checkResult{Status: "error", Detail: err.Error()}
	}
	if err := copyArtefact(actual, golden); err != nil {
		return checkResult{Status: "error", Detail: err.Error()}
	}
	return checkResult{Status: "recorded", Path: c.rel(golden)}
}

// maskRegions is the rectangles, in points from the window's top-left corner, of the regions the
// command masks: its own mask, else defaultMask. A region named in the command's own mask that
// the app did not report is an error; one of defaultMask's is skipped.
func maskRegions(cmd *AppCommand, res snapshotResult) ([]Rect, error) {
	regions, err := res.regions()
	if err != nil {
		return nil, err
	}
	names, explicit := cmd.Mask, true
	if names == nil {
		names, explicit = defaultMask, false
	}
	var rects []Rect
	for _, n := range names {
		r, ok := regions[n]
		if !ok {
			if explicit {
				return nil, fmt.Errorf("the app reported no %s region to mask", n)
			}
			continue
		}
		rects = append(rects, r)
	}
	return rects, nil
}

// compareSnapshot records or compares one picture.
func (c *checker) compareSnapshot(s *CheckScene, size Size, cmd *AppCommand, actual string, res snapshotResult) checkResult {
	golden := filepath.Join(goldenDir(c.o.goldens, c.o.release, s.Name, size), cmd.Name+".png")
	if c.o.record {
		return c.record(actual, golden)
	}
	if _, err := os.Stat(golden); errors.Is(err, os.ErrNotExist) {
		return checkResult{Status: "new", Path: c.rel(actual)}
	}
	want, err := readPNG(golden)
	if err != nil {
		return checkResult{Status: "error", Detail: err.Error()}
	}
	got, err := readPNG(actual)
	if err != nil {
		return checkResult{Status: "error", Detail: err.Error()}
	}
	rects, err := maskRegions(cmd, res)
	if err != nil {
		return checkResult{Status: "error", Detail: err.Error()}
	}
	scale := res.Scale
	if scale <= 0 {
		scale = 1
	}
	d, err := comparePixels(want, got, maskRects(rects, scale), pixelTolerance)
	if errors.Is(err, errSizeMismatch) {
		return checkResult{Status: "fail", Detail: err.Error(), Path: c.rel(actual)}
	}
	if err != nil {
		return checkResult{Status: "error", Detail: err.Error()}
	}
	changed := d.Changed
	r := checkResult{Status: "ok", Changed: &changed}
	if changed > 0 {
		diff := strings.TrimSuffix(actual, ".png") + ".diff.png"
		if err := writePNG(diff, d.Image); err != nil {
			return checkResult{Status: "error", Detail: err.Error()}
		}
		if changed > s.threshold() {
			r.Status, r.Path = "diff", c.rel(diff)
		}
	}
	return r
}

// compareAX records or compares one accessibility tree as text. The golden is kept whole; the
// comparison masks both trees with this run's regions (maskAX) and diffs what is left.
func (c *checker) compareAX(ctx context.Context, s *CheckScene, size Size, cmd *AppCommand, actual string, res snapshotResult) checkResult {
	golden := filepath.Join(goldenDir(c.o.goldens, c.o.release, s.Name, size), cmd.Name+".ax.txt")
	if c.o.record {
		return c.record(actual, golden)
	}
	if _, err := os.Stat(golden); errors.Is(err, os.ErrNotExist) {
		return checkResult{Status: "new", Path: c.rel(actual)}
	}
	rects, err := maskRegions(cmd, res)
	if err != nil {
		return checkResult{Status: "error", Detail: err.Error()}
	}
	base := strings.TrimSuffix(actual, ".ax.txt")
	masked := map[string]string{golden: base + ".golden.masked.ax.txt", actual: base + ".masked.ax.txt"}
	for src, dst := range masked {
		b, err := os.ReadFile(src)
		if err != nil {
			return checkResult{Status: "error", Detail: err.Error()}
		}
		if err := os.WriteFile(dst, []byte(maskAX(string(b), rects)), 0o644); err != nil {
			return checkResult{Status: "error", Detail: err.Error()}
		}
	}
	diff, err := unifiedDiff(ctx, masked[golden], masked[actual])
	if err != nil {
		return checkResult{Status: "error", Detail: err.Error()}
	}
	if diff == "" {
		return checkResult{Status: "ok"}
	}
	path := strings.TrimSuffix(actual, ".txt") + ".diff"
	if err := os.WriteFile(path, []byte(diff), 0o644); err != nil {
		return checkResult{Status: "error", Detail: err.Error()}
	}
	return checkResult{Status: "fail", Detail: "tree differs", Path: c.rel(path)}
}

// axFrame matches the end of an ax line: its value, when it has one, its frame and its state,
// ` value="+21 Hz" (1383,270 41×14) enabled`. The frame is in points from the window's top-left
// corner, as the regions are. A value's quotes and backslashes are escaped, so the value ends at
// the first bare quote.
var axFrame = regexp.MustCompile(`(?: value="(?:[^"\\]|\\.)*")? \((-?[0-9.]+),(-?[0-9.]+) ([0-9.]+)×([0-9.]+)\)( (?:enabled|disabled)\n?)$`)

// maskAX hides what a live region shows in an ax tree: an element whose frame lies inside one of
// rects (to within a point) has its value and its frame replaced by <masked>, and a masked line
// the same as the one before it is dropped, so a log that gained a row or a figure that moved
// reads the same. Lines without a frame are kept as they are.
func maskAX(tree string, rects []Rect) string {
	var out []string
	prev := ""
	for _, line := range strings.SplitAfter(tree, "\n") {
		if line == "" {
			continue
		}
		m := axFrame.FindStringSubmatchIndex(line)
		if m == nil || len(rects) == 0 {
			out, prev = append(out, line), ""
			continue
		}
		var f [4]float64
		for i := range f {
			f[i], _ = strconv.ParseFloat(line[m[2+2*i]:m[3+2*i]], 64)
		}
		if !insideAny(Rect{X: f[0], Y: f[1], Width: f[2], Height: f[3]}, rects) {
			out, prev = append(out, line), ""
			continue
		}
		hidden := line[:m[0]] + " value=<masked> (<masked>)" + line[m[10]:]
		if hidden == prev {
			continue
		}
		out, prev = append(out, hidden), hidden
	}
	return strings.Join(out, "")
}

// insideAny reports whether r lies inside one of rects, to within a point at each edge.
func insideAny(r Rect, rects []Rect) bool {
	const slack = 1
	for _, m := range rects {
		if r.X >= m.X-slack && r.Y >= m.Y-slack &&
			r.X+r.Width <= m.X+m.Width+slack && r.Y+r.Height <= m.Y+m.Height+slack {
			return true
		}
	}
	return false
}

// checkExpect checks each expected path in a state result, in path order. Item is the path.
func checkExpect(result json.RawMessage, expect map[string]any) []checkResult {
	var doc any
	if len(result) > 0 {
		dec := json.NewDecoder(bytes.NewReader(result))
		dec.UseNumber()
		if err := dec.Decode(&doc); err != nil {
			return []checkResult{{Status: "error", Item: "-", Detail: "the state's result: " + err.Error()}}
		}
	}
	paths := make([]string, 0, len(expect))
	for p := range expect {
		paths = append(paths, p)
	}
	slices.Sort(paths)
	var out []checkResult
	for _, p := range paths {
		want := expect[p]
		got, found := lookup(doc, p)
		r := checkResult{Status: "ok", Item: p, Detail: scalarString(got)}
		switch {
		case !found:
			r.Status, r.Detail = "fail", "got nothing want "+scalarString(want)
		case !sameScalar(got, want):
			r.Status, r.Detail = "fail", "got "+scalarString(got)+" want "+scalarString(want)
		}
		out = append(out, r)
	}
	return out
}

// lookup follows a dotted path through decoded JSON: a part names an object's key, or a
// position in an array counted from 0.
func lookup(doc any, path string) (any, bool) {
	cur := doc
	for _, part := range strings.Split(path, ".") {
		switch v := cur.(type) {
		case map[string]any:
			next, ok := v[part]
			if !ok {
				return nil, false
			}
			cur = next
		case []any:
			i, err := strconv.Atoi(part)
			if err != nil || i < 0 || i >= len(v) {
				return nil, false
			}
			cur = v[i]
		default:
			return nil, false
		}
	}
	return cur, true
}

// sameScalar compares a JSON value with a YAML scalar: numbers by value, strings, booleans and
// null as themselves. An object or an array is never the same as a scalar.
func sameScalar(got, want any) bool {
	if n, ok := got.(json.Number); ok {
		g, err := n.Float64()
		if err != nil {
			return false
		}
		switch w := want.(type) {
		case int:
			return g == float64(w)
		case float64:
			return g == w
		}
		return false
	}
	switch w := want.(type) {
	case string, bool, nil:
		return got == w
	}
	return false
}

// scalarString prints a value as JSON does, compactly.
func scalarString(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprint(v)
	}
	return string(b)
}

func sleepFor(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// openApp starts the app with `open -g -n -a`: a new instance, in the background, with only the
// environment given. -ApplePersistenceIgnoreState keeps a saved window from being restored.
func openApp(ctx context.Context, l appLaunch) error {
	args := []string{"-g", "-n", "-a", l.app, "--stdout", l.output, "--stderr", l.output}
	for _, kv := range l.env {
		args = append(args, "--env", kv)
	}
	args = append(args, "--args", "-ApplePersistenceIgnoreState", "YES")
	if b, err := exec.CommandContext(ctx, "open", args...).CombinedOutput(); err != nil {
		return fmt.Errorf("open %s: %w: %s; build it with: make app-bundle", l.app, err, strings.TrimSpace(string(b)))
	}
	return nil
}

// processAlive reports whether the process exists; signal 0 checks without sending anything.
func processAlive(pid int) bool { return syscall.Kill(pid, 0) == nil }

func killProcess(pid int) { _ = syscall.Kill(pid, syscall.SIGKILL) } // gone already is fine

// findAppPID finds the process whose environment holds this control directory, from
// `ps -E`, which shows the environment of the user's own processes on macOS.
func findAppPID(ctx context.Context, control string) int {
	out, err := exec.CommandContext(ctx, "ps", "-axww", "-E", "-o", "pid=,command=").Output()
	if err != nil {
		return 0
	}
	return pidWithEnv(out, "LEYLINE_APP_CONTROL="+control)
}

// pidWithEnv picks the pid of the first `ps -E` line that holds the variable whole. ps joins
// arguments and variables with spaces and quotes nothing, so a path with spaces cannot be split
// into fields; instead the variable must follow a space and be followed by a space or the end of
// the line.
func pidWithEnv(ps []byte, kv string) int {
	for _, line := range strings.Split(string(ps), "\n") {
		line = strings.TrimSpace(line)
		pidText, rest, ok := strings.Cut(line, " ")
		if !ok || !holdsWhole(" "+rest, " "+kv) {
			continue
		}
		if pid, err := strconv.Atoi(pidText); err == nil {
			return pid
		}
	}
	return 0
}

// holdsWhole reports whether s contains sub followed by a space or the end of s.
func holdsWhole(s, sub string) bool {
	for i := 0; ; {
		j := strings.Index(s[i:], sub)
		if j < 0 {
			return false
		}
		end := i + j + len(sub)
		if end == len(s) || s[end] == ' ' {
			return true
		}
		i += j + 1
	}
}

// listChecks prints one row per check scene: its name, sizes and commands.
func listChecks(f *CheckFile, w io.Writer) {
	fmt.Fprintf(w, "%-22s %-22s %s\n", "SCENE", "SIZES", "APP")
	for i := range f.Scenes {
		s := &f.Scenes[i]
		var sizes, cmds []string
		for _, z := range s.sizes() {
			sizes = append(sizes, z.String())
		}
		for j := range s.App {
			cmds = append(cmds, s.App[j].Cmd)
		}
		fmt.Fprintf(w, "%-22s %-22s %s\n", s.Name, strings.Join(sizes, ","), strings.Join(cmds, " "))
	}
}
