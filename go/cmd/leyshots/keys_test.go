// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

const keysScenes = `repo: x/y
scenes:
  - asset: table-a.png
    kind: table
    alt: A table.
    table: {source: a.csv}
  - asset: term-b.png
    kind: terminal
    alt: A terminal.
    fixtures: [{name: scene_x}]
    bookmarks: a.csv
    terminal: {cols: 80, rows: 10, panes: [{command: ley scan}]}
  - asset: icon-c.png
    kind: icon
    alt: An icon.
`

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// A key file is rewritten only when an input changes, so make sees a new mtime only then; a
// scene that leaves scenes.yaml takes its key with it.
func TestWriteKeysOnlyWhenChanged(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "a.csv"), "Location,Name\n1,Calling\n")
	writeFile(t, filepath.Join(dir, "scenes.yaml"), keysScenes)
	keys := filepath.Join(dir, "keys")
	writeFile(t, filepath.Join(keys, "gone.key"), "sha256 0\n")
	gen := `{"seed":1}`
	plan := func(ref FixtureRef) ([]byte, error) { return []byte(ref.Name + gen), nil }
	f, err := Load(filepath.Join(dir, "scenes.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	write := func(src string) []string {
		t.Helper()
		changed, err := writeKeys(keys, f, plan, src)
		if err != nil {
			t.Fatal(err)
		}
		return changed
	}
	if got := write("src1"); !slices.Equal(got, []string{"table-a", "term-b", "icon-c"}) {
		t.Errorf("first write changed %v", got)
	}
	if _, err := os.Stat(filepath.Join(keys, "gone.key")); !os.IsNotExist(err) {
		t.Errorf("the key of a scene no longer in scenes.yaml is still there: %v", err)
	}
	// Back-date every key, so a rewrite shows as a newer mtime.
	past := time.Now().Add(-time.Hour).Truncate(time.Second)
	mtimes := func() map[string]time.Time {
		t.Helper()
		m := map[string]time.Time{}
		for _, n := range []string{"table-a", "term-b", "icon-c"} {
			st, err := os.Stat(filepath.Join(keys, n+".key"))
			if err != nil {
				t.Fatal(err)
			}
			m[n] = st.ModTime()
		}
		return m
	}
	backdate := func() {
		t.Helper()
		for _, n := range []string{"table-a", "term-b", "icon-c"} {
			if err := os.Chtimes(filepath.Join(keys, n+".key"), past, past); err != nil {
				t.Fatal(err)
			}
		}
	}
	backdate()
	if got := write("src1"); len(got) != 0 {
		t.Errorf("unchanged inputs rewrote %v", got)
	}
	for n, m := range mtimes() {
		if !m.Equal(past) {
			t.Errorf("%s.key was touched with nothing changed", n)
		}
	}

	writeFile(t, filepath.Join(dir, "a.csv"), "Location,Name\n1,Calling\n2,Net\n")
	if got := write("src1"); !slices.Equal(got, []string{"table-a", "term-b"}) {
		t.Errorf("a CSV edit changed %v, want the two scenes that read it", got)
	}
	m := mtimes()
	if m["table-a"].Equal(past) || m["term-b"].Equal(past) || !m["icon-c"].Equal(past) {
		t.Errorf("after the CSV edit the mtimes are %v", m)
	}

	backdate()
	if got := write("src2"); !slices.Equal(got, []string{"term-b"}) {
		t.Errorf("a leyfix source change changed %v, want only the scene with a fixture", got)
	}
	gen = `{"seed":2}`
	if got := write("src2"); !slices.Equal(got, []string{"term-b"}) {
		t.Errorf("a generator record change changed %v", got)
	}

	f.Scenes[0].Table.Rows = 5
	if got := write("src2"); !slices.Equal(got, []string{"table-a"}) {
		t.Errorf("a scene edit changed %v", got)
	}
	key, err := os.ReadFile(filepath.Join(keys, "term-b.key"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"sha256 ", "\nscene term-b.png ", "\nfile a.csv ", "\nfixture scene_x ", "\nleyfix-source src2\n"} {
		if !strings.Contains(string(key), want) {
			t.Errorf("term-b.key has no %q:\n%s", want, key)
		}
	}
}

// The generated rules list every image, and each image depends on its key and its kind's sources
// and takes only its own scene.
func TestMakefileRules(t *testing.T) {
	var b strings.Builder
	if err := writeMakefile(&b, loadScenes(t)); err != nil {
		t.Fatal(err)
	}
	mk := b.String()
	for _, want := range []string{
		"SHOTS_ASSETS := \\\n\t$(SHOTS_OUT)/app-radio-2m.png \\\n",
		"SHOTS_ASSETS_APP := \\\n\t$(SHOTS_OUT)/app-radio-2m.png \\\n",
		"SHOTS_ASSETS_ICON := \\\n\t$(SHOTS_OUT)/app-icon-1024.png\n",
		"\n$(SHOTS_OUT)/app-radio-2m.png: $(SHOTS_OUT)/keys/app-radio-2m.key $(SHOTS_DEPS_APP)\n\t$(SHOTS_RUN) --only app-radio-2m.png\n",
		"\n$(SHOTS_OUT)/chirp-csv-before.png: $(SHOTS_OUT)/keys/chirp-csv-before.key $(SHOTS_DEPS_TABLE)\n\t$(SHOTS_RUN) --only chirp-csv-before.png\n",
		"\n$(SHOTS_OUT)/ways-sync.png: $(SHOTS_OUT)/keys/ways-sync.key $(SHOTS_DEPS_COMPOSITE)\n",
		"\n$(SHOTS_OUT)/notification-same.png: $(SHOTS_OUT)/keys/notification-same.key $(SHOTS_DEPS_SCREEN)\n",
	} {
		if !strings.Contains(mk, want) {
			t.Errorf("the rules have no %q:\n%s", want, mk)
		}
	}
	if n, want := strings.Count(mk, "\t$(SHOTS_RUN) --only "), len(loadScenes(t).Scenes); n != want {
		t.Errorf("%d recipes for %d scenes", n, want)
	}
}

// leyfixSourceDirs is every package of this module that leyfix is built from, but the generated
// contract.
func TestLeyfixSourceDirs(t *testing.T) {
	out, err := exec.Command("go", "list", "-deps", "-f", "{{if not .Standard}}{{.ImportPath}}{{end}}", "../leyfix").Output()
	if err != nil {
		t.Skipf("go list: %v", err)
	}
	const mod = "github.com/reflexive-labs/leysdr/"
	var want []string
	for _, p := range strings.Fields(string(out)) {
		if strings.HasPrefix(p, mod) && !strings.HasPrefix(p, mod+"go/gen/") {
			want = append(want, strings.TrimPrefix(p, mod))
		}
	}
	slices.Sort(want)
	got := slices.Sorted(slices.Values(leyfixSourceDirs))
	if !slices.Equal(got, want) {
		t.Errorf("leyfixSourceDirs is %v\nleyfix is built from %v", got, want)
	}
}

// The leyfix source hash moves with a generator source and not with its tests.
func TestLeyfixSourceHash(t *testing.T) {
	root := t.TempDir()
	for _, d := range leyfixSourceDirs {
		writeFile(t, filepath.Join(root, d, "a.go"), "package a\n")
		writeFile(t, filepath.Join(root, d, "a_test.go"), "package a\n")
	}
	h1, err := leyfixSourceHash(root)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(root, "go/pkg/iqfile/a_test.go"), "package a // changed\n")
	if h, _ := leyfixSourceHash(root); h != h1 {
		t.Error("a test file changed the hash")
	}
	writeFile(t, filepath.Join(root, "go/pkg/iqfile/a.go"), "package a // changed\n")
	if h, _ := leyfixSourceHash(root); h == h1 {
		t.Error("a source change left the hash as it was")
	}
	if _, err := leyfixSourceHash(t.TempDir()); err == nil {
		t.Error("an empty root hashed")
	}
	if h, err := leyfixSourceHash("../../.."); err != nil || len(h) != 64 {
		t.Errorf("the checkout's hash is %q, %v", h, err)
	}
}

// A publish without --only refreshes what changed since the latest release and is in tmp/shots.
func TestRefreshSet(t *testing.T) {
	cur := &Manifest{Shots: []Shot{
		{Asset: "a.png", PNGSHA256: "1"},
		{Asset: "b.png", PNGSHA256: "2"},
		{Asset: "c.png", PNGSHA256: "3"},
		{Asset: "d.png", PNGSHA256: "4"},
		{Asset: "e.png", PNGSHA256: "5"},
	}}
	prev := &Manifest{Shots: []Shot{
		{Asset: "a.png", PNGSHA256: "1"},
		{Asset: "b.png", PNGSHA256: "old"},
		{Asset: "d.png"},
		{Asset: "e.png", PNGSHA256: "old"},
	}}
	exists := func(a string) bool { return a != "e.png" }
	if got := refreshSet(cur, prev, exists); !slices.Equal(got, []string{"b.png", "c.png", "d.png"}) {
		t.Errorf("refresh %v, want the changed b, the new c and d with no hash in the release", got)
	}
	if got := refreshSet(cur, cur, exists); len(got) != 0 {
		t.Errorf("an unchanged set refreshes %v", got)
	}
	retitled := &Manifest{Shots: []Shot{{Asset: "a.png", PNGSHA256: "1", Alt: "The icon. Simulated signals."}}}
	fixed := &Manifest{Shots: []Shot{{Asset: "a.png", PNGSHA256: "1", Alt: "The icon."}}}
	if got := refreshSet(fixed, retitled, exists); !slices.Equal(got, []string{"a.png"}) {
		t.Errorf("a shot whose alt text changed refreshes %v, want it", got)
	}
	if got := refreshSet(cur, &Manifest{}, exists); len(got) != 4 {
		t.Errorf("a first release refreshes %v", got)
	}
}

// The released manifest keeps the source PNG's hash from the run, whatever oxipng makes of it.
func TestMergeKeepsSourceHash(t *testing.T) {
	cur := &Manifest{Shots: []Shot{{Asset: "a.png", PNGSHA256: "src"}}}
	m, err := merge(&Manifest{}, cur, []string{"a.png"}, "shots-2026-10-04")
	if err != nil {
		t.Fatal(err)
	}
	if s, _ := m.get("a.png"); s.PNGSHA256 != "src" || s.Tag != "shots-2026-10-04" {
		t.Errorf("merged %+v", s)
	}
}
