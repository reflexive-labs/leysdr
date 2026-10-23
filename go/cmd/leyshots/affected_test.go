// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A glob with a / matches the path from app/Sources, one without the file's name anywhere.
func TestMatchesAny(t *testing.T) {
	for _, c := range []struct {
		glob, rel string
		want      bool
	}{
		{"SidebarView.swift", "LeylineApp/SidebarView.swift", true},
		{"Sidebar*.swift", "LeylineClient/Sidebar.swift", true},
		{"LeylineApp/*.swift", "LeylineApp/Theme.swift", true},
		{"LeylineApp/*.swift", "LeylineClient/Bands.swift", false},
		{"bands.json", "LeylineClient/Resources/bands.json", true},
		{"LeylineClient/*", "LeylineClient/Resources/bands.json", false},
		{"Sidebar.swift", "LeylineApp/SidebarView.swift", false},
	} {
		if got := matchesAny([]string{c.glob}, c.rel); got != c.want {
			t.Errorf("%s on %s: %v", c.glob, c.rel, got)
		}
	}
	if validGlobs([]string{"a["}) == nil || validGlobs([]string{"/abs.swift"}) == nil || validGlobs([]string{"x/*.swift"}) != nil {
		t.Error("validGlobs")
	}
}

// git runs git in dir with no global or system configuration.
func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"}, args...)...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL="+os.DevNull, "GIT_CONFIG_NOSYSTEM=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

// --affected against a repository: committed, uncommitted and untracked changes since the merge
// base with main pick the scenes that cover them, a shared file brings in the smoke scenes, an
// edited scene runs, a file no scene covers is named, and --base moves the comparison.
func TestCheckAffected(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	root := t.TempDir()
	scenes := `shared: [Theme.swift, Package.swift]
scenes:
  - name: rows
    smoke: true
    covers: [SidebarView.swift]
    fixtures: [{name: scene_2m}]
    app: [{cmd: state, expect: {tuned_hz: 146520000}}]
  - name: talk
    covers: [LeylineApp/Assistant*.swift]
    ai: {script: assistant/hello.script}
    fixtures: [{name: scene_2m}]
    app: [{cmd: state, expect: {tuned_hz: 146520000}}]
  - name: other
    covers: [InspectorView.swift]
    fixtures: [{name: scene_2m}]
    app: [{cmd: state, expect: {tuned_hz: 146520000}}]
`
	for name, body := range map[string]string{
		"app/Sources/LeylineApp/Theme.swift":          "// theme\n",
		"app/Package.swift":                           "// package\n",
		".gitignore":                                  "tmp/\n",
		"app/Sources/LeylineApp/SidebarView.swift":    "// sidebar\n",
		"app/Sources/LeylineApp/AssistantPanel.swift": "// panel\n",
		"app/Sources/LeylineApp/InspectorView.swift":  "// inspector\n",
		"app/checks/assistant/hello.script":           "{\"text\": \"hi\"}\n",
		"app/checks/scenes.yaml":                      scenes,
		"go/main.go":                                  "package main\n",
	} {
		writeFile(t, filepath.Join(root, name), body)
	}
	git(t, root, "init", "-q", "-b", "main")
	git(t, root, "add", ".")
	git(t, root, "commit", "-q", "-m", "first")
	git(t, root, "checkout", "-q", "-b", "work")

	fake := &fakeApp{alive: map[int]bool{}, state: map[string]any{"tuned_hz": 146520000}}
	var stdout bytes.Buffer
	run := func(base string) (string, error) {
		t.Helper()
		stdout.Reset()
		o := checkOptions{
			runOptions: runOptions{root: root, out: filepath.Join(root, "tmp", "checks"), stdout: &stdout, logf: t.Logf},
			checks:     filepath.Join(root, "app", "checks", "scenes.yaml"), goldens: filepath.Join(root, "tmp", "goldens"),
			release: "26.6", affected: true, base: base,
			prepare: func(_ context.Context, _ *CheckFile, _ *CheckScene, run string) (*sceneDaemon, error) {
				return &sceneDaemon{stop: func() {}}, os.MkdirAll(run, 0o755)
			},
			launch: fake.launch,
			alive: func(pid int) bool {
				fake.mu.Lock()
				defer fake.mu.Unlock()
				return fake.alive[pid]
			},
			kill:    func(pid int) { t.Errorf("killed %d", pid) },
			findPID: func(context.Context, string) int { return 0 },
			grace:   2 * time.Second, poll: 5 * time.Millisecond,
		}
		err := checkScenes(context.Background(), o)
		return stdout.String(), err
	}

	// Nothing changed and nothing before HEAD to compare with: an error, never a pass.
	out, err := run("")
	if err == nil || !strings.Contains(err.Error(), "HEAD has no commit before it") || strings.Contains(out, "checked") {
		t.Fatalf("no change: %v\n%s", err, out)
	}

	// A commit on the branch, an uncommitted edit of a script and an untracked file no scene
	// covers, which fails the run after the scenes have run; a change outside app/ is not
	// looked at.
	writeFile(t, filepath.Join(root, "app/Sources/LeylineApp/SidebarView.swift"), "// sidebar, changed\n")
	writeFile(t, filepath.Join(root, "go/main.go"), "package main // changed\n")
	git(t, root, "commit", "-q", "-am", "sidebar")
	writeFile(t, filepath.Join(root, "app/checks/assistant/hello.script"), "{\"text\": \"hello\"}\n")
	writeFile(t, filepath.Join(root, "app/Sources/LeylineClient/Fresh.swift"), "// new\n")
	out, err = run("")
	if !errors.Is(err, errChecksFailed) {
		t.Fatalf("an uncovered file: %v\n%s", err, out)
	}
	base := git(t, root, "rev-parse", "--short", "main")
	expectOutput(t, out,
		"since "+base+": 3 changed under app/Sources and app/checks, 2 scenes affected",
		"affected rows: SidebarView.swift",
		"affected talk: hello.script",
		"uncovered: app/Sources/LeylineClient/Fresh.swift",
		"fail     - - uncovered            no scene covers it: give the scene that checks it a covers glob, or the file a scene that reads it  app/Sources/LeylineClient/Fresh.swift",
		"ok       rows 1440x820 state#1 tuned_hz",
		"ok       talk 1440x820 state#1 tuned_hz",
		"3 checked: 2 ok, 1 fail; ",
	)
	if err := os.Remove(filepath.Join(root, "app/Sources/LeylineClient/Fresh.swift")); err != nil {
		t.Fatal(err)
	}

	// --base HEAD leaves the commit out: the script is what changed.
	out, err = run("HEAD")
	if err != nil || !strings.Contains(out, ": 1 changed under") || strings.Contains(out, "affected rows") || !strings.Contains(out, "affected talk") {
		t.Errorf("--base HEAD: %v\n%s", err, out)
	}

	// A shared file brings in the smoke scene; a scene's own lines changed bring it in, and a
	// change to a scene's covers alone does not.
	git(t, root, "add", ".")
	git(t, root, "commit", "-q", "-m", "script")
	head := git(t, root, "rev-parse", "HEAD")
	writeFile(t, filepath.Join(root, "app/Sources/LeylineApp/Theme.swift"), "// theme, changed\n")
	edited := strings.Replace(scenes, "covers: [InspectorView.swift]", "covers: [InspectorView.swift, Theme.swift]", 1)
	edited = strings.Replace(edited, "  - name: talk\n    covers: [LeylineApp/Assistant*.swift]\n",
		"  - name: talk\n    covers: [LeylineApp/Assistant*.swift]\n    sizes: [{width: 100, height: 60}]\n", 1)
	writeFile(t, filepath.Join(root, "app/checks/scenes.yaml"), edited)
	out, err = run(head)
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	expectOutput(t, out,
		"since "+head[:len(base)]+": 2 changed under app/Sources and app/checks, 3 scenes affected",
		"affected rows: Theme.swift (shared)",
		"affected talk: scenes.yaml",
		"affected other: Theme.swift (shared)",
		"ok       rows 1440x820",
		"ok       talk 100x60",
		"ok       other 1440x820",
		"3 checked: 3 ok; ",
	)

	// The package manifest is matched by its name, here shared, so it brings in the smoke scene.
	git(t, root, "add", ".")
	git(t, root, "commit", "-q", "-m", "theme")
	head = git(t, root, "rev-parse", "--short", "HEAD")
	writeFile(t, filepath.Join(root, "app/Package.swift"), "// package, changed\n")
	out, err = run(head)
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	expectOutput(t, out,
		"since "+head+": 1 changed under app/Sources and app/checks, 1 scenes affected",
		"affected rows: Package.swift (shared)",
		"ok       rows 1440x820",
		"1 checked: 1 ok; ",
	)
	git(t, root, "checkout", "-q", "--", "app/Package.swift")

	// A change no scene checks selects nothing, which is an error and not a pass: a comment in
	// scenes.yaml, and an untracked file nothing reads, named as uncovered.
	writeFile(t, filepath.Join(root, "app/checks/scenes.yaml"), edited+"# a comment\n")
	out, err = run(head)
	if err == nil || !strings.Contains(err.Error(), "--affected selected no scene: nothing a scene checks changed since "+head) || strings.Contains(out, "checked") {
		t.Errorf("a comment: %v\n%s", err, out)
	}
	writeFile(t, filepath.Join(root, "app/checks/stray.txt"), "nothing reads this\n")
	out, err = run(head)
	if err == nil || !strings.Contains(err.Error(), "no scene covers what changed") || !strings.Contains(out, "uncovered: app/checks/stray.txt") {
		t.Errorf("a stray file: %v\n%s", err, out)
	}
	if err := os.Remove(filepath.Join(root, "app/checks/stray.txt")); err != nil {
		t.Fatal(err)
	}
	git(t, root, "checkout", "-q", "--", "app/checks/scenes.yaml")

	// The work merged and committed on main, the tree clean: the merge base is HEAD, so the
	// comparison is with the commit before, and a line says so.
	git(t, root, "checkout", "-q", "main")
	git(t, root, "merge", "-q", "--ff-only", "work")
	prev := git(t, root, "rev-parse", "--short", "HEAD~1")
	out, err = run("")
	if err != nil {
		t.Fatalf("committed on main: %v\n%s", err, out)
	}
	expectOutput(t, out,
		"the base "+head+" is HEAD and nothing has changed since: comparing with the commit before, "+prev,
		"since "+prev+": 2 changed under app/Sources and app/checks, 3 scenes affected",
		"affected rows: Theme.swift (shared)",
		"affected talk: scenes.yaml",
		"affected other: Theme.swift (shared)",
		"ok       rows 1440x820",
		"ok       talk 100x60",
		"ok       other 1440x820",
		"3 checked: 3 ok; ",
	)

	// A base that is not a commit is refused in words.
	if _, err := run("no-such-ref"); err == nil || !strings.Contains(err.Error(), "--base no-such-ref") {
		t.Errorf("a bad base: %v", err)
	}
}

// --smoke with no scene marked smoke is an error, not a pass that checked nothing.
func TestCheckSmokeSelectsNothing(t *testing.T) {
	dir := t.TempDir()
	checks := filepath.Join(dir, "scenes.yaml")
	writeFile(t, checks, `scenes:
  - name: rows
    fixtures: [{name: scene_2m}]
    app: [{cmd: state, expect: {tuned_hz: 146520000}}]
`)
	var stdout bytes.Buffer
	o := checkOptions{
		runOptions: runOptions{root: dir, out: filepath.Join(dir, "out"), stdout: &stdout, logf: t.Logf},
		checks:     checks, goldens: filepath.Join(dir, "goldens"), release: "26.6", smoke: true,
	}
	err := checkScenes(context.Background(), o)
	if err == nil || !strings.Contains(err.Error(), "--smoke selected no scene: none in "+checks+" is marked smoke: true") {
		t.Errorf("--smoke with none: %v\n%s", err, stdout.String())
	}
}
