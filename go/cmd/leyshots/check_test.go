// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const checksPath = "../../../app/checks/scenes.yaml"

func solid(w, h int, c color.RGBA) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetRGBA(x, y, c)
		}
	}
	return img
}

var (
	ground = color.RGBA{R: 0x10, G: 0x12, B: 0x14, A: 0xff}
	ink    = color.RGBA{R: 0xe0, G: 0xe0, B: 0xe0, A: 0xff}
)

func TestComparePixels(t *testing.T) {
	base := solid(20, 10, ground)
	// A small shift in every channel is within the tolerance.
	near := solid(20, 10, color.RGBA{R: 0x12, G: 0x10, B: 0x17, A: 0xff})
	if d, err := comparePixels(base, near, nil, pixelTolerance); err != nil || d.Changed != 0 {
		t.Errorf("within tolerance: %v, %v", d, err)
	}
	// An anti-aliased edge (ground, one blended column, ink) moved by one pixel is not a change.
	mid := color.RGBA{R: 0x78, G: 0x79, B: 0x7a, A: 0xff}
	edge := func(at int) *image.RGBA {
		img := solid(20, 10, ground)
		for y := 0; y < 10; y++ {
			img.SetRGBA(at, y, mid)
			for x := at + 1; x < 20; x++ {
				img.SetRGBA(x, y, ink)
			}
		}
		return img
	}
	if d, err := comparePixels(edge(10), edge(11), nil, pixelTolerance); err != nil || d.Changed != 0 {
		t.Errorf("a one-pixel shift of an anti-aliased edge: %.2f %%, %v", d.Changed, err)
	}
	// A 1 px stripe pattern, inverted, changes every pixel; a colour found next door is no excuse.
	stripes := func(phase int) *image.RGBA {
		img := solid(20, 10, ground)
		for y := 0; y < 10; y++ {
			for x := phase; x < 20; x += 2 {
				img.SetRGBA(x, y, ink)
			}
		}
		return img
	}
	if d, err := comparePixels(stripes(0), stripes(1), nil, pixelTolerance); err != nil || d.Changed != 100 {
		t.Errorf("inverted stripes: %.2f %%, %v", d.Changed, err)
	}
	// One glyph for another: an L becomes a T in a 5 × 5 cell, and the 14 pixels that differ count.
	glyph := func(rows ...string) *image.RGBA {
		img := solid(20, 10, ground)
		for y, row := range rows {
			for x, c := range row {
				if c == '#' {
					img.SetRGBA(5+x, 2+y, ink)
				}
			}
		}
		return img
	}
	l := glyph("#....", "#....", "#....", "#....", "#####")
	tee := glyph("#####", "..#..", "..#..", "..#..", "..#..")
	if d, err := comparePixels(l, tee, nil, pixelTolerance); err != nil || d.Changed != 100*14.0/200 {
		t.Errorf("a changed glyph: %.2f %%, %v", d.Changed, err)
	}
	// A thin line drawn on the plain ground is a change: 10 of 200 pixels.
	line := solid(20, 10, ground)
	for y := 0; y < 10; y++ {
		line.SetRGBA(5, y, ink)
	}
	d, err := comparePixels(base, line, nil, pixelTolerance)
	if err != nil || d.Changed != 5 {
		t.Fatalf("a new line: %.2f %%, %v", d.Changed, err)
	}
	if got := d.Image.RGBAAt(5, 3); got != (color.RGBA{R: 0xff, A: 0xff}) {
		t.Errorf("a changed pixel is drawn %v, not red", got)
	}
	if got := d.Image.RGBAAt(0, 0); got.R < 0xc0 || got.R == 0xff {
		t.Errorf("an unchanged pixel is drawn %v, not faded", got)
	}
	// Masked away, the line does not count, the denominator shrinks, and the mask is grey.
	d, err = comparePixels(base, line, []image.Rectangle{image.Rect(4, 0, 6, 10)}, pixelTolerance)
	if err != nil || d.Changed != 0 {
		t.Errorf("a masked line: %.2f %%, %v", d.Changed, err)
	}
	if got := d.Image.RGBAAt(5, 3); got != (color.RGBA{R: 0x80, G: 0x80, B: 0x80, A: 0xff}) {
		t.Errorf("a masked pixel is drawn %v, not grey", got)
	}
	_, err = comparePixels(base, solid(20, 11, ground), nil, pixelTolerance)
	if !errors.Is(err, errSizeMismatch) || err.Error() != "size 20x11 vs 20x10" {
		t.Errorf("a size mismatch: %v", err)
	}
}

// Regions in points map to pixels at the snapshot's scale, rounded outward.
func TestMaskRects(t *testing.T) {
	got := maskRects([]Rect{{X: 10.5, Y: 52, Width: 100, Height: 20.25}}, 2)
	if want := image.Rect(21, 104, 221, 145); len(got) != 1 || got[0] != want {
		t.Errorf("maskRects = %v, want %v", got, want)
	}
}

func TestGoldenDir(t *testing.T) {
	got := goldenDir("/g", majorMinor("26.6.2\n"), "radio-2m", Size{Width: 1440, Height: 820})
	if want := "/g/26.6-" + runtime.GOARCH + "/radio-2m/1440x820"; got != want {
		t.Errorf("goldenDir = %q, want %q", got, want)
	}
	if majorMinor("27") != "27.0" {
		t.Errorf("majorMinor(27) = %q", majorMinor("27"))
	}
}

func TestCheckExpect(t *testing.T) {
	result := json.RawMessage(`{"tuned_hz":146520000,"mode":"NFM","inspector":true,"sel":null,
		"notices":["Imported 5"],"channel":{"id":"chan_1","squelch_db":-45.5}}`)
	got := checkExpect(result, map[string]any{
		"tuned_hz": 146520000, "mode": "NFM", "inspector": true, "sel": nil,
		"notices.0": "Imported 5", "channel.squelch_db": -45.5,
		"channel.id": "chan_2", "zoom": 4, "channel": "x",
	})
	var lines []string
	for _, r := range got {
		lines = append(lines, r.Status+" "+r.Item+" "+r.Detail)
	}
	want := []string{
		`fail channel got {"id":"chan_1","squelch_db":-45.5} want "x"`,
		`fail channel.id got "chan_1" want "chan_2"`,
		`ok channel.squelch_db -45.5`,
		`ok inspector true`,
		`ok mode "NFM"`,
		`ok notices.0 "Imported 5"`,
		`ok sel null`,
		`ok tuned_hz 146520000`,
		`fail zoom got nothing want 4`,
	}
	if strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Errorf("checkExpect:\n%s\nwant\n%s", strings.Join(lines, "\n"), strings.Join(want, "\n"))
	}
}

func TestPidWithEnv(t *testing.T) {
	ps := []byte("  12 /bin/zsh HOME=/x\n 345 /A.app/Contents/MacOS/LeylineApp -ApplePersistenceIgnoreState YES LEYLINE_APP_CONTROL=/r/control LEYLINE_SOCKET=/s\n")
	if got := pidWithEnv(ps, "LEYLINE_APP_CONTROL=/r/control"); got != 345 {
		t.Errorf("pid %d", got)
	}
	if got := pidWithEnv(ps, "LEYLINE_APP_CONTROL=/r/con"); got != 0 {
		t.Errorf("a prefix matched pid %d", got)
	}
	// A checkout under a path with spaces: the variable is matched whole, not field by field.
	spaced := []byte(" 40 /A.app/LeylineApp LEYLINE_APP_CONTROL=/My Repo/run/control2 X=1\n" +
		" 41 /A.app/LeylineApp LEYLINE_APP_CONTROL=/My Repo/run/control\n")
	if got := pidWithEnv(spaced, "LEYLINE_APP_CONTROL=/My Repo/run/control"); got != 41 {
		t.Errorf("a path with spaces: pid %d", got)
	}
}

// The checked-in scenes parse and keep to the protocol's fields.
func TestChecksFile(t *testing.T) {
	f, err := LoadChecks(checksPath)
	if err != nil {
		t.Fatal(err)
	}
	sel, err := f.Select([]string{"radio-2m", "goto-bookmark"})
	if err != nil || len(sel) != 2 {
		t.Fatalf("Select: %v", err)
	}
	if got := sel[0].sizes(); len(got) != 1 || got[0] != defaultCheckSize {
		t.Errorf("radio-2m sizes %v", got)
	}
	if _, err := f.Select([]string{"radio"}); err == nil {
		t.Error("an unknown scene should be refused")
	}
	// The bookmarks are the site scene's.
	if _, err := os.Stat(f.Path(sel[0].Bookmarks)); err != nil {
		t.Error(err)
	}
}

func TestLoadChecksRejects(t *testing.T) {
	cases := map[string]string{
		"no fixtures":        "app: [{cmd: state}]",
		"no commands":        "fixtures: [{name: x}]",
		"unknown command":    "fixtures: [{name: x}]\n    app: [{cmd: click}]",
		"quit":               "fixtures: [{name: x}]\n    app: [{cmd: quit}]",
		"snapshot sans name": "fixtures: [{name: x}]\n    app: [{cmd: snapshot}]",
		"stray field":        "fixtures: [{name: x}]\n    app: [{cmd: key, keys: return, text: a}]",
		"unknown field":      "fixtures: [{name: x}]\n    app: [{cmd: state, colour: red}]",
		"stage window":       "fixtures: [{name: x}]\n    stage: {window: {width: 1, height: 1}}\n    app: [{cmd: state}]",
		"command window":     "fixtures: [{name: x}]\n    app: [{cmd: stage, stage: {window: {width: 1, height: 1}}}]",
		"bad mask":           "fixtures: [{name: x}]\n    app: [{cmd: snapshot, name: a, mask: [dock]}]",
		"expect a list":      "fixtures: [{name: x}]\n    app: [{cmd: state, expect: {a: [1]}}]",
		"name twice":         "fixtures: [{name: x}]\n    app: [{cmd: ax, name: a}, {cmd: ax, name: a}]",
		"bad size":           "fixtures: [{name: x}]\n    sizes: [{width: 0, height: 1}]\n    app: [{cmd: state}]",
		"name with a dot":    "fixtures: [{name: x}]\n    app: [{cmd: snapshot, name: a.b}]",
		"ley sans args":      "fixtures: [{name: x}]\n    app: [{cmd: ley}]",
		"ley with keys":      "fixtures: [{name: x}]\n    app: [{cmd: ley, args: [state], keys: a}]",
		"stdout on state":    "fixtures: [{name: x}]\n    app: [{cmd: state, expect_stdout: a}]",
		"bad regex":          "fixtures: [{name: x}]\n    app: [{cmd: ley, args: [state], expect_stdout: \"(\"}]",
		"empty negation":     "fixtures: [{name: x}]\n    app: [{cmd: ley, args: [state], expect_stdout: \"!\"}]",
		"ley_bg sans id":     "fixtures: [{name: x}]\n    app: [{cmd: ley_bg, args: [tune]}]",
		"ley_bg twice":       "fixtures: [{name: x}]\n    app: [{cmd: ley_bg, id: a, args: [tune]}, {cmd: ley_bg, id: a, args: [tune]}]",
		"kill unknown":       "fixtures: [{name: x}]\n    app: [{cmd: kill, id: a}]",
		"kill before start":  "fixtures: [{name: x}]\n    app: [{cmd: kill, id: a}, {cmd: ley_bg, id: a, args: [tune]}]",
		"file outside":       "fixtures: [{name: x}]\n    app: [{cmd: file, path: ../x, contains: a}]",
		"file absolute":      "fixtures: [{name: x}]\n    app: [{cmd: file, path: /etc/hosts, contains: a}]",
		"file sans contains": "fixtures: [{name: x}]\n    app: [{cmd: file, path: bookmarks.json}]",
		"negative exit":      "fixtures: [{name: x}]\n    app: [{cmd: ley, args: [state], expect_exit: -1}]",
		"daemon sans op":     "fixtures: [{name: x}]\n    app: [{cmd: daemon}]",
		"daemon restart":     "fixtures: [{name: x}]\n    app: [{cmd: daemon, op: restart}]",
		"op on ley":          "fixtures: [{name: x}]\n    app: [{cmd: ley, args: [state], op: stop}]",
	}
	for name, body := range cases {
		path := filepath.Join(t.TempDir(), "scenes.yaml")
		if err := os.WriteFile(path, []byte("scenes:\n  - name: s\n    "+body+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadChecks(path); err == nil {
			t.Errorf("%s: loaded", name)
		}
	}
}

// fakeApp plays the app's side of the command-file protocol: it writes ready.json, reads
// commands.jsonl as it grows and answers each command in out/<id>.json.
type fakeApp struct {
	mu sync.Mutex
	// shade is the grey the snapshot's middle block is drawn in; a change shows as a diff.
	shade  uint8
	state  map[string]any
	ax     string
	alive  map[int]bool
	nextID int
	// commands are the lines read, for the test to look at.
	commands []map[string]any
	envs     [][]string
}

// The fake window is 100 × 60 pt at 2×, with a waterfall region along its bottom 20 pt.
const fakeW, fakeH, fakeScale = 100, 60, 2

func (a *fakeApp) launch(ctx context.Context, l appLaunch) error {
	a.mu.Lock()
	a.nextID++
	pid := 9000 + a.nextID
	a.alive[pid] = true
	a.envs = append(a.envs, l.env)
	a.mu.Unlock()
	var control string
	for _, kv := range l.env {
		if v, ok := strings.CutPrefix(kv, "LEYLINE_APP_CONTROL="); ok {
			control = v
		}
	}
	if control == "" {
		return errors.New("no LEYLINE_APP_CONTROL")
	}
	go a.serve(ctx, control, pid)
	return nil
}

func (a *fakeApp) serve(ctx context.Context, control string, pid int) {
	writeAtomic := func(name string, b []byte) {
		tmp := filepath.Join(control, name+".tmp")
		_ = os.WriteFile(tmp, b, 0o644)
		_ = os.Rename(tmp, filepath.Join(control, name))
	}
	ready, _ := json.Marshal(map[string]any{"ok": true, "pid": pid, "window_number": 7, "scale": fakeScale, "error": ""})
	writeAtomic("ready.json", ready)
	read := 0
	for ctx.Err() == nil {
		time.Sleep(5 * time.Millisecond)
		b, err := os.ReadFile(filepath.Join(control, "commands.jsonl"))
		if err != nil || len(b) <= read {
			continue
		}
		end := bytes.LastIndexByte(b, '\n') + 1
		sc := bufio.NewScanner(bytes.NewReader(b[read:end]))
		read = end
		for sc.Scan() {
			var cmd map[string]any
			if err := json.Unmarshal(sc.Bytes(), &cmd); err != nil {
				continue
			}
			a.mu.Lock()
			a.commands = append(a.commands, cmd)
			a.mu.Unlock()
			id := int(cmd["id"].(float64))
			ans := map[string]any{"id": id, "ok": true, "error": "", "files": []string{}, "result": map[string]any{}}
			switch cmd["cmd"] {
			case "snapshot":
				name := fmt.Sprintf("out/%d.png", id)
				img := solid(fakeW*fakeScale, fakeH*fakeScale, ground)
				a.mu.Lock()
				shade := a.shade
				a.mu.Unlock()
				for y := 10; y < 30; y++ {
					for x := 20; x < 60; x++ {
						img.SetRGBA(x, y, color.RGBA{R: shade, G: shade, B: shade, A: 0xff})
					}
				}
				// The waterfall is live: never the same twice.
				for y := 80; y < 120; y++ {
					for x := 0; x < 200; x++ {
						img.SetRGBA(x, y, color.RGBA{R: uint8(time.Now().UnixNano()), A: 0xff})
					}
				}
				_ = writePNG(filepath.Join(control, name), img)
				ans["files"] = []string{name}
				ans["result"] = map[string]any{"scale": fakeScale, "width_pt": fakeW, "height_pt": fakeH, "regions": map[string]any{
					"window":    map[string]float64{"x": 0, "y": 0, "width": fakeW, "height": fakeH},
					"waterfall": map[string]float64{"x": 0, "y": 40, "width": fakeW, "height": 20},
				}}
			case "state":
				a.mu.Lock()
				ans["result"] = a.state
				a.mu.Unlock()
			case "ax":
				name := fmt.Sprintf("out/%d.ax.txt", id)
				a.mu.Lock()
				_ = os.WriteFile(filepath.Join(control, name), []byte(a.ax), 0o644)
				a.mu.Unlock()
				ans["files"] = []string{name}
			case "press":
				ans["ok"], ans["error"] = false, "no element press.me"
			case "wait":
				s, _ := cmd["seconds"].(float64)
				time.Sleep(time.Duration(s * float64(time.Second)))
			}
			b, _ := json.Marshal(ans)
			writeAtomic(filepath.Join("out", strconv.Itoa(id)+".json"), b)
			if cmd["cmd"] == "quit" {
				a.mu.Lock()
				a.alive[pid] = false
				a.mu.Unlock()
				return
			}
		}
	}
}

// The runner end to end against the fake app: record, compare clean, then a picture, a tree and a
// state that changed, and a scene with no goldens.
func TestCheckEndToEnd(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "chk", "scenes.yaml"), `scenes:
  - name: one
    fixtures: [{name: scene_2m}]
    stage: {place: radio, settle: 0.01}
    sizes: [{width: 100, height: 60}, {width: 80, height: 50}]
    app:
      - {cmd: key, keys: cmd+g}
      - {cmd: snapshot, name: initial}
      - {cmd: state, expect: {tuned_hz: 162475000, mode: NFM}}
      - {cmd: ax, name: initial}
  - name: two
    fixtures: [{name: scene_2m}]
    app:
      - {cmd: snapshot, name: initial, mask: []}
      - {cmd: press, identifier: press.me}
`)
	fake := &fakeApp{
		shade: 0x40, ax: "window\n  row band.2m\n", alive: map[int]bool{},
		state: map[string]any{"tuned_hz": 162475000, "mode": "NFM"},
	}
	var stdout bytes.Buffer
	prepared := 0
	o := checkOptions{
		runOptions: runOptions{root: dir, out: filepath.Join(dir, "checks"), app: "/A.app", stdout: &stdout, logf: t.Logf},
		checks:     filepath.Join(dir, "chk", "scenes.yaml"), goldens: filepath.Join(dir, "goldens"), release: "26.6",
		prepare: func(_ context.Context, _ *CheckFile, _ *CheckScene, run string) (*sceneDaemon, error) {
			prepared++
			if err := os.MkdirAll(run, 0o755); err != nil {
				return nil, err
			}
			return &sceneDaemon{env: []string{"LEYLINE_SOCKET=/s.sock", "LEYLINE_BOOKMARKS=/b.json", "PATH=/bin"}, stop: func() {}}, nil
		},
		launch: fake.launch,
		alive: func(pid int) bool {
			fake.mu.Lock()
			defer fake.mu.Unlock()
			return fake.alive[pid]
		},
		kill:    func(pid int) { t.Errorf("killed %d; it should have quit", pid) },
		findPID: func(context.Context, string) int { return 0 },
		grace:   2 * time.Second, poll: 5 * time.Millisecond,
	}
	run := func(only []string, record bool) (string, error) {
		stdout.Reset()
		o.only, o.record = only, record
		err := checkScenes(context.Background(), o)
		return stdout.String(), err
	}
	expectLines := func(out string, want ...string) {
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

	out, err := run([]string{"one"}, true)
	if err != nil {
		t.Fatalf("record: %v\n%s", err, out)
	}
	expectLines(out,
		"recorded one 100x60 initial              goldens/26.6-",
		"ok       one 100x60 state#3 mode         \"NFM\"",
		"ok       one 100x60 state#3 tuned_hz     162475000",
		"recorded one 100x60 initial.ax",
		"recorded one 80x50 initial ",
		"ok       one 80x50 state#3 mode",
		"ok       one 80x50 state#3 tuned_hz",
		"recorded one 80x50 initial.ax",
		"8 checked: 4 ok, 4 recorded; ",
	)
	golden := filepath.Join(dir, "goldens", "26.6-"+runtime.GOARCH, "one", "100x60", "initial.png")
	if _, err := os.Stat(golden); err != nil {
		t.Fatal(err)
	}
	if prepared != 2 || len(fake.envs) != 2 {
		t.Errorf("%d daemons and %d launches for two sizes", prepared, len(fake.envs))
	}
	// The app gets the scene's LEYLINE_ variables and the control, stage and log paths, and
	// nothing else of the runner's.
	var keys []string
	for _, kv := range fake.envs[0] {
		keys = append(keys, strings.SplitN(kv, "=", 2)[0])
	}
	if got := strings.Join(keys, " "); got != "LEYLINE_SOCKET LEYLINE_BOOKMARKS LEYLINE_APP_CONTROL LEYLINE_APP_STAGE LEYLINE_APP_LOG" {
		t.Errorf("the app's environment: %s", got)
	}
	stage, err := os.ReadFile(filepath.Join(dir, "checks", "one", "80x50", "run", "stage.json"))
	if err != nil || !strings.Contains(string(stage), `"width": 80`) || !strings.Contains(string(stage), `"place": "radio"`) {
		t.Errorf("stage.json: %s %v", stage, err)
	}
	// Ids run from 1 in each launch, and quit follows the last command.
	fake.mu.Lock()
	var cmds []string
	for _, c := range fake.commands[:5] {
		cmds = append(cmds, fmt.Sprintf("%v:%v", c["id"], c["cmd"]))
	}
	fake.mu.Unlock()
	if got := strings.Join(cmds, " "); got != "1:key 2:snapshot 3:state 4:ax 5:quit" {
		t.Errorf("commands: %s", got)
	}

	// The same app again: every picture matches, the live waterfall masked by default.
	out, err = run([]string{"one"}, false)
	if err != nil {
		t.Fatalf("compare: %v\n%s", err, out)
	}
	if !strings.HasPrefix(out, "ok       one 100x60 initial              0.00 %\n") || !strings.Contains(out, "8 checked: 8 ok; ") {
		t.Errorf("a clean compare:\n%s", out)
	}

	// The block changes shade, the tree gains a row and the radio is elsewhere.
	fake.mu.Lock()
	fake.shade, fake.ax, fake.state["tuned_hz"] = 0x90, "window\n  row band.2m\n  row band.70cm\n", 146520000
	fake.mu.Unlock()
	out, err = run([]string{"one"}, false)
	if !errors.Is(err, errChecksFailed) {
		t.Fatalf("a changed app passed: %v\n%s", err, out)
	}
	// 40 × 20 of the 200 × 80 unmasked pixels changed: 5 %.
	diffPNG := filepath.Join("checks", "one", "100x60", "initial.diff.png")
	if !strings.Contains(out, "diff     one 100x60 initial              5.00 %  ") || !strings.Contains(out, diffPNG) {
		t.Errorf("the picture's line:\n%s", out)
	}
	if !strings.Contains(out, "fail     one 100x60 state#3 tuned_hz     got 146520000 want 162475000") {
		t.Errorf("the state's line:\n%s", out)
	}
	axDiff := filepath.Join(dir, "checks", "one", "100x60", "initial.ax.diff")
	if b, err := os.ReadFile(axDiff); err != nil || !strings.Contains(string(b), "+  row band.70cm") {
		t.Errorf("the tree's diff: %s %v", b, err)
	}
	if !strings.Contains(out, "fail     one 100x60 initial.ax           tree differs  ") {
		t.Errorf("the tree's line:\n%s", out)
	}
	var summary struct {
		Counts  map[string]int `json:"counts"`
		Results []checkResult  `json:"results"`
	}
	b, err := os.ReadFile(filepath.Join(dir, "checks", "summary.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &summary); err != nil {
		t.Fatal(err)
	}
	if summary.Counts["diff"] != 2 || summary.Counts["fail"] != 4 || len(summary.Results) != 8 {
		t.Errorf("summary.json counts %v of %d results", summary.Counts, len(summary.Results))
	}

	// A scene with no goldens is new, not a failure, unless a command fails in the app. With
	// no mask, the waterfall counts.
	out, err = run([]string{"two"}, false)
	if !errors.Is(err, errChecksFailed) {
		t.Errorf("a failed press passed: %v", err)
	}
	expectLines(out,
		"new      two 1440x820 initial              checks/two/1440x820/initial.png",
		"fail     two 1440x820 press#2              the app: no element press.me",
		"2 checked: 1 new, 1 fail; ",
	)
}

// An app that never writes ready.json is reported with its log, and found and killed.
func TestCheckAppNeverReady(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "scenes.yaml"), "scenes:\n  - name: s\n    fixtures: [{name: x}]\n    app: [{cmd: state}]\n")
	var stdout bytes.Buffer
	killed := 0
	o := checkOptions{
		runOptions: runOptions{out: filepath.Join(dir, "checks"), stdout: &stdout, logf: t.Logf},
		checks:     filepath.Join(dir, "scenes.yaml"), goldens: filepath.Join(dir, "goldens"), release: "26.6",
		prepare: func(_ context.Context, _ *CheckFile, _ *CheckScene, run string) (*sceneDaemon, error) {
			return &sceneDaemon{stop: func() {}}, os.MkdirAll(run, 0o755)
		},
		launch:  func(context.Context, appLaunch) error { return nil },
		alive:   func(int) bool { return killed == 0 },
		kill:    func(pid int) { killed = pid },
		findPID: func(context.Context, string) int { return 77 },
		grace:   50 * time.Millisecond, poll: 5 * time.Millisecond,
	}
	if err := checkScenes(context.Background(), o); !errors.Is(err, errChecksFailed) {
		t.Fatalf("err = %v", err)
	}
	if !strings.Contains(stdout.String(), "error    s 1440x820 -") || !strings.Contains(stdout.String(), "app.log") {
		t.Errorf("output:\n%s", stdout.String())
	}
	if killed != 77 {
		t.Errorf("killed %d", killed)
	}

	// A ready.json caught mid-write is read again, not taken as the app's failure.
	o.launch = func(_ context.Context, l appLaunch) error {
		var control string
		for _, kv := range l.env {
			if v, ok := strings.CutPrefix(kv, "LEYLINE_APP_CONTROL="); ok {
				control = v
			}
		}
		path := filepath.Join(control, "ready.json")
		if err := os.WriteFile(path, []byte(`{"ok":tr`), 0o644); err != nil {
			return err
		}
		go func() {
			time.Sleep(20 * time.Millisecond)
			_ = os.WriteFile(path, []byte(`{"ok":true,"pid":0}`), 0o644)
			time.Sleep(20 * time.Millisecond)
			_ = os.WriteFile(filepath.Join(control, "out", "1.json"), []byte(`{"id":1,"ok":true,"result":{}}`), 0o644)
		}()
		return nil
	}
	o.grace = 2 * time.Second
	o.findPID = func(context.Context, string) int { return 0 }
	killed = 0
	stdout.Reset()
	if err := checkScenes(context.Background(), o); err != nil {
		t.Errorf("a ready.json read mid-write: %v\n%s", err, stdout.String())
	}

	// An interrupted run fails, and still says what it did.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	stdout.Reset()
	if err := checkScenes(ctx, o); !errors.Is(err, errChecksFailed) {
		t.Errorf("an interrupted run: %v", err)
	}
	if !strings.Contains(stdout.String(), "interrupted: context canceled") || !strings.Contains(stdout.String(), "checked:") {
		t.Errorf("an interrupted run's output:\n%s", stdout.String())
	}
}

// An element inside a masked region loses its value and frame, a run of masked lines that read
// the same is one line, and everything else is kept.
func TestMaskAX(t *testing.T) {
	tree := `AXWindow "Leyline" (0,0 1440×820) enabled
  AXStaticText "" value="Tuning" (1144,269 40×15) enabled
  AXStaticText "" value="+21 Hz" (1383,270 41×14) enabled
  AXStaticText "" value="2.6 kHz" (1376,293 48×14) enabled
  AXStaticText "" value="say \"hi\" (1,2 3×4) enabled" (1150,561 240×26) enabled
  AXCheckBox "Record transmissions" value="0" (1380,512 44×20) disabled
  AXGroup "" (1120,240 320×100) enabled
  AXButton "Scan band" (26,171 88×23) enabled
`
	rects := []Rect{{X: 1128, Y: 233, Width: 312, Height: 100}, {X: 1144, Y: 550, Width: 280, Height: 40}}
	want := `AXWindow "Leyline" (0,0 1440×820) enabled
  AXStaticText "" value=<masked> (<masked>) enabled
  AXCheckBox "Record transmissions" value="0" (1380,512 44×20) disabled
  AXGroup "" (1120,240 320×100) enabled
  AXButton "Scan band" (26,171 88×23) enabled
`
	if got := maskAX(tree, rects); got != want {
		t.Errorf("maskAX:\n%s\nwant\n%s", got, want)
	}
	if got := maskAX(tree, nil); got != tree {
		t.Errorf("no rects changed the tree:\n%s", got)
	}
}

// A hold runs the one scene at its first size, then leaves the app to be driven by hand until it
// quits; the runner's own quit then takes the id after the last one sent.
func TestCheckHold(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "scenes.yaml"), `scenes:
  - name: one
    fixtures: [{name: scene_2m}]
    sizes: [{width: 100, height: 60}, {width: 80, height: 50}]
    app: [{cmd: state}]
  - name: two
    fixtures: [{name: scene_2m}]
    app: [{cmd: state}]
`)
	fake := &fakeApp{alive: map[int]bool{}, state: map[string]any{"tuned_hz": 1}}
	var stdout bytes.Buffer
	var mu sync.Mutex
	var logs []string
	o := checkOptions{
		runOptions: runOptions{out: filepath.Join(dir, "checks"), stdout: &stdout, logf: func(f string, a ...any) {
			mu.Lock()
			logs = append(logs, fmt.Sprintf(f, a...))
			mu.Unlock()
		}},
		checks: filepath.Join(dir, "scenes.yaml"), goldens: filepath.Join(dir, "goldens"), release: "26.6", hold: true,
		prepare: func(_ context.Context, _ *CheckFile, _ *CheckScene, run string) (*sceneDaemon, error) {
			return &sceneDaemon{env: []string{"LEYLINE_SOCKET=/s.sock"}, stop: func() {}}, os.MkdirAll(run, 0o755)
		},
		launch: fake.launch,
		alive: func(pid int) bool {
			fake.mu.Lock()
			defer fake.mu.Unlock()
			return fake.alive[pid]
		},
		kill:    func(pid int) { t.Errorf("killed %d; it should have quit", pid) },
		findPID: func(context.Context, string) int { return 0 },
		grace:   2 * time.Second, poll: 5 * time.Millisecond,
	}
	if err := checkScenes(context.Background(), o); err == nil || !strings.Contains(err.Error(), "--hold takes one scene") {
		t.Fatalf("a hold of two scenes: %v", err)
	}
	o.only = []string{"one"}
	done := make(chan error, 1)
	go func() { done <- checkScenes(context.Background(), o) }()

	control := filepath.Join(dir, "checks", "one", "100x60", "run", "control")
	holding := func() bool {
		mu.Lock()
		defer mu.Unlock()
		for _, l := range logs {
			if strings.HasPrefix(l, "holding one 100x60") {
				return true
			}
		}
		return false
	}
	for deadline := time.Now().Add(5 * time.Second); !holding(); time.Sleep(5 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the run never held")
		}
	}
	mu.Lock()
	all := strings.Join(logs, "\n")
	mu.Unlock()
	for _, want := range []string{"ley --socket /s.sock", `{"id":2,"cmd":"snapshot"}`, control} {
		if !strings.Contains(all, want) {
			t.Errorf("the hold's instructions lack %q:\n%s", want, all)
		}
	}
	// Driven by hand: a state, then a quit.
	f, err := os.OpenFile(filepath.Join(control, "commands.jsonl"), os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString(`{"id":2,"cmd":"state"}` + "\n" + `{"id":3,"cmd":"quit"}` + "\n")
	_ = f.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("the held run: %v\n%s", err, stdout.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the hold did not end when the app quit")
	}
	if _, err := os.Stat(filepath.Join(control, "out", "2.json")); err != nil {
		t.Errorf("the command sent by hand was not answered: %v", err)
	}
	fake.mu.Lock()
	launches, last := len(fake.envs), fake.commands[len(fake.commands)-1]
	fake.mu.Unlock()
	if launches != 1 {
		t.Errorf("%d launches; a hold runs the first size only", launches)
	}
	if last["id"].(float64) != 3 || last["cmd"] != "quit" {
		t.Errorf("the last command the app read: %v", last)
	}
	b, _ := os.ReadFile(filepath.Join(control, "commands.jsonl"))
	if !strings.HasSuffix(string(b), `{"id":4,"cmd":"quit"}`+"\n") {
		t.Errorf("the runner's quit does not follow the ids sent by hand:\n%s", b)
	}
}
