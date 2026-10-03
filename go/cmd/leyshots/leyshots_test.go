// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"image"
	"image/color"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/reflexive-labs/leysdr/go/pkg/iqfile"
)

const (
	scenesPath = "../../../site/shots/scenes.yaml"
	planPath   = "../../../docs/plans/site-shots.md"
)

func loadScenes(t *testing.T) *File {
	t.Helper()
	f, err := Load(scenesPath)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

// Every image in the plan's Assets table has a scene, and every scene is in the table.
func TestScenesCoverThePlan(t *testing.T) {
	plan, err := os.ReadFile(planPath)
	if err != nil {
		t.Fatal(err)
	}
	section := string(plan)
	start := strings.Index(section, "## Assets")
	if start < 0 {
		t.Fatal("the plan has no Assets section")
	}
	section = section[start:]
	if end := strings.Index(section[3:], "\n## "); end >= 0 {
		section = section[:end+3]
	}
	var want []string
	for _, m := range regexp.MustCompile("(?m)^\\| `([a-z0-9-]+\\.png)` \\|").FindAllStringSubmatch(section, -1) {
		want = append(want, m[1])
	}
	if len(want) < 10 {
		t.Fatalf("read only %d assets from the plan's table: %v", len(want), want)
	}
	var got []string
	for _, s := range loadScenes(t).Scenes {
		got = append(got, s.Asset)
	}
	sort.Strings(want)
	sort.Strings(got)
	if !slices.Equal(got, want) {
		t.Errorf("scenes.yaml has %v\nthe plan lists %v", got, want)
	}
}

// The scenes file parses, and its scenes keep the plan's rules:
// only app scenes shift the clock, every app scene has a stage with a window, and every alt text
// is a sentence the manifest can append to.
func TestScenesFile(t *testing.T) {
	f := loadScenes(t)
	if f.Repo != "reflexive-labs/leysdr" {
		t.Errorf("repo %q", f.Repo)
	}
	for _, s := range f.Scenes {
		if s.Clock != "" && s.Kind != kindApp {
			t.Errorf("%s: a %s scene sets clock", s.Asset, s.Kind)
		}
		if s.Stage != nil && (s.Stage.Window == nil || s.Stage.Settle <= 0) {
			t.Errorf("%s: a stage needs a window and a settle time", s.Asset)
		}
		if !strings.HasSuffix(strings.TrimSpace(s.Alt), ".") {
			t.Errorf("%s: alt text %q does not end a sentence", s.Asset, s.Alt)
		}
	}
	sel, err := f.Select([]string{"scan-2m", "ways-sync.png"})
	if err != nil || len(sel) != 2 || sel[0].Asset != "scan-2m.png" || sel[1].Asset != "ways-sync.png" {
		t.Errorf("Select: %v, %v", sel, err)
	}
	if _, err := f.Select([]string{"scan-2"}); err == nil {
		t.Error("an unknown scene should be refused")
	}
}

func TestLoadRejects(t *testing.T) {
	cases := map[string]string{
		"unknown kind":     "kind: photo\n    alt: A.",
		"clock off app":    "kind: terminal\n    alt: A.\n    clock: \"19:42\"\n    fixtures: [{name: x}]\n    terminal: {cols: 80, rows: 10, panes: [{command: ley}]}",
		"unknown region":   "kind: app\n    alt: A.\n    fixtures: [{name: x}]\n    stage: {settle: 1}\n    crop: {regions: [dock]}",
		"split missing":    "kind: terminal\n    alt: A.\n    fixtures: [{name: x}]\n    terminal: {cols: 80, rows: 10, panes: [{command: a}, {command: b}]}",
		"unknown field":    "kind: icon\n    alt: A.\n    colour: red",
		"no alt":           "kind: icon",
		"step both":        "kind: terminal\n    alt: A.\n    fixtures: [{name: x}]\n    steps: [{ley: [stop], wait: 2}]\n    terminal: {cols: 80, rows: 10, panes: [{command: a}]}",
		"bad place":        "kind: app\n    alt: A.\n    fixtures: [{name: x}]\n    stage: {settle: 1, place: map}\n    crop: {regions: [window]}",
		"app sans fixture": "kind: app\n    alt: A.\n    stage: {settle: 1}\n    crop: {regions: [window]}",
	}
	for name, body := range cases {
		path := filepath.Join(t.TempDir(), "scenes.yaml")
		if err := os.WriteFile(path, []byte("repo: a/b\nscenes:\n  - asset: x.png\n    "+body+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := Load(path); err == nil {
			t.Errorf("%s: loaded", name)
		}
	}
}

// The stage file carries the keys docs/dev/app.md, "Staged runs" lists, with import_chirp made
// absolute and unset keys left out.
func TestStageJSON(t *testing.T) {
	f := loadScenes(t)
	sel, err := f.Select([]string{"sidebar-chirp-import", "library-net"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := stageJSON(f, sel[0].Stage)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	if p, _ := m["import_chirp"].(string); !filepath.IsAbs(p) || !strings.HasSuffix(p, "site/shots/chirp-100.csv") {
		t.Errorf("import_chirp %q", m["import_chirp"])
	}
	for _, k := range []string{"window", "place", "inspector", "expanded_band", "settle"} {
		if _, ok := m[k]; !ok {
			t.Errorf("stage has no %s: %s", k, b)
		}
	}
	if _, ok := m["select_part"]; ok {
		t.Errorf("an unset select_part was written: %s", b)
	}
	if w := m["window"].(map[string]any); w["width"] != 1440.0 || w["height"] != 820.0 {
		t.Errorf("window %v", w)
	}
	b, _ = stageJSON(f, sel[1].Stage)
	if !strings.Contains(string(b), `"select_part": 0`) || !strings.Contains(string(b), `"place": "library"`) {
		t.Errorf("library stage: %s", b)
	}
}

func TestCrop(t *testing.T) {
	r := &Regions{WindowNumber: 7, Regions: map[string]Rect{
		"window":    {0, 0, 1440, 820},
		"waterfall": {260, 300, 880, 520},
		"inspector": {1140, 52, 300, 768},
	}}
	got, err := cropRect(&Crop{Regions: []string{"window"}}, r)
	if err != nil || got != (Rect{0, 0, 1440, 820}) {
		t.Errorf("window: %+v %v", got, err)
	}
	got, _ = cropRect(&Crop{Regions: []string{"waterfall", "inspector"}}, r)
	if got != (Rect{260, 52, 1180, 768}) {
		t.Errorf("union: %+v", got)
	}
	got, _ = cropRect(&Crop{Regions: []string{"waterfall", "inspector"}, Size: &Size{480, 300}, Anchor: "top-right"}, r)
	if got != (Rect{960, 52, 480, 300}) {
		t.Errorf("top-right box: %+v", got)
	}
	got, _ = cropRect(&Crop{Regions: []string{"inspector"}, Size: &Size{100, 100}, Anchor: "center"}, r)
	if got != (Rect{1240, 386, 100, 100}) {
		t.Errorf("centred box: %+v", got)
	}
	if _, err := cropRect(&Crop{Regions: []string{"library"}}, r); err == nil || !strings.Contains(err.Error(), "library") {
		t.Errorf("a missing region: %v", err)
	}

	// A Retina capture is twice the window's points; the crop scales with it and rounds out.
	bounds := image.Rect(0, 0, 2880, 1640)
	if px := pixelRect(Rect{1140, 52, 300, 768}, r.Regions["window"], bounds); px != image.Rect(2280, 104, 2880, 1640) {
		t.Errorf("inspector at 2×: %v", px)
	}
	if px := pixelRect(Rect{10.25, 0.5, 20, 10}, r.Regions["window"], bounds); px != image.Rect(20, 1, 61, 21) {
		t.Errorf("fractional points round outward: %v", px)
	}
	if px := pixelRect(Rect{1400, 800, 100, 100}, r.Regions["window"], bounds); px != image.Rect(2800, 1600, 2880, 1640) {
		t.Errorf("clipped to the image: %v", px)
	}
	if px := pixelRect(Rect{100, 100, 50, 50}, r.Regions["window"], image.Rect(0, 0, 1440, 820)); px != image.Rect(100, 100, 150, 150) {
		t.Errorf("at 1×: %v", px)
	}
}

func TestCropAndCompositePNG(t *testing.T) {
	dir := t.TempDir()
	src := image.NewRGBA(image.Rect(0, 0, 40, 20))
	src.Set(30, 10, color.RGBA{255, 0, 0, 255})
	out := filepath.Join(dir, "crop.png")
	if err := cropPNG(src, image.Rect(20, 5, 40, 15), out); err != nil {
		t.Fatal(err)
	}
	img, err := readPNG(out)
	if err != nil {
		t.Fatal(err)
	}
	if img.Bounds() != image.Rect(0, 0, 20, 10) {
		t.Fatalf("crop is %v", img.Bounds())
	}
	if r, _, _, _ := img.At(10, 5).RGBA(); r != 0xffff {
		t.Error("the crop lost the pixel at (30, 10)")
	}
	c := composite([]image.Image{src, img}, 32)
	if c.Bounds() != image.Rect(0, 0, 32+40+32+20+32, 32+20+32) {
		t.Errorf("composite is %v", c.Bounds())
	}
	if c.At(0, 0) != groundColour {
		t.Errorf("the ground is %v", c.At(0, 0))
	}
}

func writeTestPNG(t *testing.T, path string, w, h int) {
	t.Helper()
	if err := writePNG(path, image.NewRGBA(image.Rect(0, 0, w, h))); err != nil {
		t.Fatal(err)
	}
}

func TestManifestMergeAndValidate(t *testing.T) {
	prev := &Manifest{Shots: []Shot{
		{Asset: "a.png", Width: 10, Height: 10, Scale: 2, Alt: altText("A."), Tag: "shots-2026-09-01"},
		{Asset: "b.png", Width: 10, Height: 10, Scale: 2, Alt: altText("B."), Tag: "shots-2026-09-01"},
	}}
	cur := &Manifest{Shots: []Shot{
		{Asset: "a.png", Width: 20, Height: 20, Scale: 2, Alt: altText("A again.")},
		{Asset: "c.png", Width: 30, Height: 30, Scale: 2, Alt: altText("C.")},
	}}
	m, err := merge(prev, cur, []string{"c.png"}, "shots-2026-10-03")
	if err != nil {
		t.Fatal(err)
	}
	var assets []string
	for _, s := range m.Shots {
		assets = append(assets, s.Asset+"@"+s.Tag)
	}
	want := []string{"a.png@shots-2026-09-01", "b.png@shots-2026-09-01", "c.png@shots-2026-10-03"}
	if !slices.Equal(assets, want) {
		t.Errorf("merged %v, want %v: a run's a.png was not asked for and stays as published", assets, want)
	}
	if _, err := merge(prev, cur, []string{"d.png"}, "t"); err == nil {
		t.Error("refreshing an image the run did not take should be refused")
	}

	dir := t.TempDir()
	writeTestPNG(t, filepath.Join(dir, "a.png"), 10, 10)
	writeTestPNG(t, filepath.Join(dir, "b.png"), 10, 10)
	writeTestPNG(t, filepath.Join(dir, "c.png"), 30, 30)
	if err := m.validate(dir); err != nil {
		t.Errorf("a matching release: %v", err)
	}
	writeTestPNG(t, filepath.Join(dir, "b.png"), 12, 10)
	writeTestPNG(t, filepath.Join(dir, "stray.png"), 1, 1)
	m.Shots[0].Alt = "A."
	err = m.validate(dir)
	for _, want := range []string{"b.png is 12×10", "stray.png", "a.png's alt text"} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("validate should report %q: %v", want, err)
		}
	}

	path := filepath.Join(dir, "shots.json")
	if err := m.write(path); err != nil {
		t.Fatal(err)
	}
	back, err := readManifest(path)
	if err != nil || len(back.Shots) != 3 || back.Shots[2].Tag != "shots-2026-10-03" {
		t.Errorf("round trip: %+v %v", back, err)
	}
	if empty, err := readManifest(filepath.Join(dir, "none.json")); err != nil || len(empty.Shots) != 0 {
		t.Errorf("a missing manifest is empty: %+v %v", empty, err)
	}
}

func TestReleaseTags(t *testing.T) {
	day := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	at := func(h int) time.Time { return day.Add(time.Duration(h) * time.Hour) }
	rels := []release{
		{TagName: "v0.1.0", CreatedAt: at(5)},
		{TagName: "shots-2026-10-03", CreatedAt: at(1)},
		{TagName: "shots-2026-10-03-2", CreatedAt: at(2)},
		{TagName: "shots-2026-09-30", CreatedAt: at(-72)},
	}
	if got := latestShots(rels); got != "shots-2026-10-03-2" {
		t.Errorf("latest %q", got)
	}
	if got := nextTag(day, rels); got != "shots-2026-10-03-3" {
		t.Errorf("next %q", got)
	}
	if got := nextTag(day.AddDate(0, 0, 1), rels); got != "shots-2026-10-04" {
		t.Errorf("next day %q", got)
	}
	if got := latestShots(rels[:1]); got != "" {
		t.Errorf("no shots release, got %q", got)
	}
	notes := releaseNotes(&Manifest{Shots: []Shot{{Asset: "a.png"}, {Asset: "b.png", Width: 4, Height: 2, Commit: "abc1234"}}}, []string{"b.png"}, "shots-2026-09-30")
	if !strings.Contains(notes, "- b.png (4×2, commit abc1234)") || !strings.Contains(notes, "Carried forward from shots-2026-09-30: a.png.") {
		t.Errorf("notes:\n%s", notes)
	}
}

func TestAltText(t *testing.T) {
	if got := altText("The window\n  on 2 m."); got != "The window on 2 m. Simulated signals." {
		t.Errorf("%q", got)
	}
	if got := altText("Done. Simulated signals."); got != "Done. Simulated signals." {
		t.Errorf("appended twice: %q", got)
	}
}

// Two panes side by side: each where tmux put it, the rule in the column between them, and the
// page sized for the window.
func TestTerminalHTML(t *testing.T) {
	term := &Terminal{Cols: 120, Rows: 14, Split: "horizontal", Panes: []Pane{{Command: "a"}, {Command: "b"}}}
	panes := []paneCapture{
		{Left: 0, Top: 0, Width: 59, Height: 14, Text: "left"},
		{Left: 60, Top: 0, Width: 60, Height: 14, Text: "right"},
	}
	page, err := terminalHTML("ways-terminal", term, panes, func(s string) (string, error) {
		return "<pre class=\"term\">" + s + "</pre>", nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"<title>ways-terminal</title>",
		"--bg:#090B0C;--fg:#9BA1A6;--bold:#E7E9EA;--green:#2FB6A3",
		`font:13px/16px ui-monospace,"SF Mono",Menlo,monospace`,
		".screen{position:relative;padding:16px;width:120ch;height:224px}",
		`<div class="pane" style="left:calc(16px + 0ch);top:16px;width:59ch;height:224px"><pre class="term">left</pre></div>`,
		`<div class="pane" style="left:calc(16px + 60ch);top:16px;width:60ch;height:224px"><pre class="term">right</pre></div>`,
		`<div class="rule" style="left:calc(16px + 59.5ch);top:16px;width:1px;height:224px"></div>`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("the page lacks %s\n%s", want, page)
		}
	}
	if strings.Count(page, `class="rule"`) != 1 {
		t.Errorf("one rule between two panes:\n%s", page)
	}
	stacked := []paneCapture{{Left: 0, Top: 0, Width: 80, Height: 11}, {Left: 0, Top: 12, Width: 80, Height: 12}}
	page, _ = terminalHTML("x", &Terminal{Cols: 80, Rows: 24}, stacked, func(string) (string, error) { return "", nil })
	if !strings.Contains(page, `<div class="rule" style="left:calc(16px + 0ch);top:200px;width:80ch;height:1px"></div>`) {
		t.Errorf("a stacked split's rule:\n%s", page)
	}
	if w := terminalWidthPt(100); w != 812 {
		t.Errorf("100 columns are %.0f pt wide", w)
	}
}

func TestTableHTML(t *testing.T) {
	csv := "Location,Name,Frequency,Mode\n0,Calling,146.520000,NFM\n1,APRS,144.390000,NFM\n2,<b>,1,FM\n"
	page, err := tableHTML("t", &Table{Source: "x.csv", Rows: 2, Columns: []string{"Name", "Frequency"}}, strings.NewReader(csv))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"<tr><th>Name</th><th>Frequency</th></tr>",
		"<tr><td>Calling</td><td>146.520000</td></tr>",
		"<tr><td>…</td><td>…</td></tr>",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("the table lacks %s\n%s", want, page)
		}
	}
	if strings.Contains(page, "&lt;b&gt;") || strings.Contains(page, "Location") {
		t.Errorf("rows or columns past the limit were drawn:\n%s", page)
	}
	page, _ = tableHTML("t", &Table{Source: "x.csv"}, strings.NewReader(csv))
	if !strings.Contains(page, "<td>&lt;b&gt;</td>") || strings.Contains(page, "…") {
		t.Errorf("the whole table, escaped:\n%s", page)
	}
	if _, err := tableHTML("t", &Table{Source: "x.csv", Columns: []string{"Power"}}, strings.NewReader(csv)); err == nil {
		t.Error("a missing column should be an error")
	}
	// The real CSV has every column the scene asks for.
	f := loadScenes(t)
	sel, _ := f.Select([]string{"chirp-csv-before"})
	src, err := os.Open(f.Path(sel[0].Table.Source))
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()
	if _, err := tableHTML("chirp", sel[0].Table, src); err != nil {
		t.Error(err)
	}
}

func TestCacheDir(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if got := cacheDir("darwin", env(nil), "/Users/a"); got != "/Users/a/Library/Caches/leyline-shots/iq" {
		t.Error(got)
	}
	if got := cacheDir("linux", env(map[string]string{"XDG_CACHE_HOME": "/c"}), "/home/a"); got != "/c/leyline-shots/iq" {
		t.Error(got)
	}
	if got := cacheDir("linux", env(nil), "/home/a"); got != "/home/a/.cache/leyline-shots/iq" {
		t.Error(got)
	}
}

// A cached fixture is reused only when its sidecar matches the dry run and its samples are all
// there.
func TestFixtureCurrent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "scene_x.cu8")
	want := &iqfile.Sidecar{
		Format: iqfile.FormatCU8, SampleRate: 1000, CenterHz: 146e6, Samples: 50, Label: "L",
		Generator: json.RawMessage(`{"seed":1,"signals":[{"type":"nfm_voice"}]}`),
	}
	if current(path, want) {
		t.Fatal("a missing fixture is current")
	}
	if err := iqfile.WriteSidecar(path, &iqfile.Sidecar{
		Format: want.Format, SampleRate: want.SampleRate, CenterHz: want.CenterHz, Samples: want.Samples, Label: "L",
		Generator: json.RawMessage(`{"signals": [{"type": "nfm_voice"}], "seed": 1}`),
	}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, 100), 0o644); err != nil {
		t.Fatal(err)
	}
	if !current(path, want) {
		t.Error("a matching fixture, keys in another order, is not current")
	}
	changed := *want
	changed.Generator = json.RawMessage(`{"seed":2,"signals":[{"type":"nfm_voice"}]}`)
	if current(path, &changed) {
		t.Error("a fixture from another seed is current")
	}
	if err := os.WriteFile(path, make([]byte, 98), 0o644); err != nil {
		t.Fatal(err)
	}
	if current(path, want) {
		t.Error("a truncated fixture is current")
	}
	if got := leyfixArgs(FixtureRef{Name: "same_alert", Rate: 960000, Duration: 10}, "/c"); !slices.Equal(got,
		[]string{"generate", "--out", "/c", "--only", "same_alert", "--rate", "960000", "--duration", "10"}) {
		t.Errorf("leyfix args %v", got)
	}
}
