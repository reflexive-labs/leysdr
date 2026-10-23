// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
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
	scenes := `shared: [Theme.swift]
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

	// Nothing changed: nothing runs, and that is not a failure.
	out, err := run("")
	if err != nil || !strings.Contains(out, ": 0 changed under app/Sources and app/checks, 0 scenes affected") || strings.Contains(out, "checked") {
		t.Fatalf("no change: %v\n%s", err, out)
	}

	// A commit on the branch, an uncommitted edit of a script and an untracked file no scene
	// covers; a change outside app/ is not looked at.
	writeFile(t, filepath.Join(root, "app/Sources/LeylineApp/SidebarView.swift"), "// sidebar, changed\n")
	writeFile(t, filepath.Join(root, "go/main.go"), "package main // changed\n")
	git(t, root, "commit", "-q", "-am", "sidebar")
	writeFile(t, filepath.Join(root, "app/checks/assistant/hello.script"), "{\"text\": \"hello\"}\n")
	writeFile(t, filepath.Join(root, "app/Sources/LeylineClient/Fresh.swift"), "// new\n")
	out, err = run("")
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	base := git(t, root, "rev-parse", "--short", "main")
	expectOutput(t, out,
		"since "+base+": 3 changed under app/Sources and app/checks, 2 scenes affected",
		"affected rows: SidebarView.swift",
		"affected talk: hello.script",
		"uncovered: app/Sources/LeylineClient/Fresh.swift",
		"ok       rows 1440x820 state#1 tuned_hz",
		"ok       talk 1440x820 state#1 tuned_hz",
		"2 checked: 2 ok; ",
	)

	// --base HEAD leaves the commit out: the script and the untracked file are what changed.
	out, _ = run("HEAD")
	if !strings.Contains(out, ": 2 changed under") || strings.Contains(out, "affected rows") || !strings.Contains(out, "affected talk") {
		t.Errorf("--base HEAD:\n%s", out)
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

	// A base that is not a commit is refused in words.
	if _, err := run("no-such-ref"); err == nil || !strings.Contains(err.Error(), "--base no-such-ref") {
		t.Errorf("a bad base: %v", err)
	}
}
