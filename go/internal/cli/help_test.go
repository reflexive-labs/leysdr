// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// -update regenerates the help snapshots:
//
//	go test ./internal/cli -run TestHelpGolden -update
var update = flag.Bool("update", false, "rewrite the golden files under testdata/help")

// helpApp is a piped, 80-column app with no daemon: help never dials.
func helpApp() *App {
	return &App{IsTTY: func() bool { return false }, TermWidth: func() int { return 80 }}
}

// visibleVerbs walks the command tree (help command included, completion
// excluded: it is Cobra's) and returns every non-hidden verb's path.
func visibleVerbs(t *testing.T) [][]string {
	t.Helper()
	root := NewRootCommand(helpApp())
	root.InitDefaultHelpCmd()
	var out [][]string
	var walk func(c *cobra.Command, path []string)
	walk = func(c *cobra.Command, path []string) {
		for _, sub := range c.Commands() {
			if sub.Hidden || sub.Name() == "completion" {
				continue
			}
			p := append(append([]string{}, path...), sub.Name())
			out = append(out, p)
			walk(sub, p)
		}
	}
	walk(root, nil)
	return out
}

func checkGolden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", "help", name+".golden")
	if *update {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s: %v (run with -update to create it)", path, err)
	}
	if string(want) != got {
		t.Errorf("%s differs from the golden file (run with -update if the change is intended)\n--- want\n%s\n--- got\n%s", name, want, got)
	}
}

// TestHelpGolden snapshots `ley --help`, every verb's --help and every
// topic, and checks that `ley help <verb>` prints exactly `ley <verb> --help`
// (set, which disables flag parsing, included).
func TestHelpGolden(t *testing.T) {
	old := Version
	Version = "0.0.0-test"
	t.Cleanup(func() { Version = old })

	out, errOut, err := runApp(t, helpApp(), "--help")
	if err != nil || errOut != "" {
		t.Fatalf("ley --help: err=%v stderr=%q", err, errOut)
	}
	checkGolden(t, "ley", out)
	if viaHelp, _, _ := runApp(t, helpApp(), "help"); viaHelp != out {
		t.Errorf("ley help differs from ley --help")
	}

	for _, path := range visibleVerbs(t) {
		name := strings.Join(path, "-")
		out, errOut, err := runApp(t, helpApp(), append(append([]string{}, path...), "--help")...)
		if err != nil || errOut != "" {
			t.Fatalf("ley %s --help: err=%v stderr=%q", strings.Join(path, " "), err, errOut)
		}
		checkGolden(t, name, out)
		// `ley help <name>` prefers a topic of that name (presets), by
		// design; every other verb's help must match its --help exactly.
		if topicByName(path[len(path)-1]) != nil {
			continue
		}
		viaHelp, _, err := runApp(t, helpApp(), append([]string{"help"}, path...)...)
		if err != nil || viaHelp != out {
			t.Errorf("ley help %s: err=%v; output differs from --help", strings.Join(path, " "), err)
		}
	}

	verbs := map[string]bool{}
	for _, path := range visibleVerbs(t) {
		if len(path) == 1 {
			verbs[path[0]] = true
		}
	}
	for _, tp := range topics {
		out, errOut, err := runApp(t, helpApp(), "help", tp.name)
		if err != nil || errOut != "" {
			t.Fatalf("ley help %s: err=%v stderr=%q", tp.name, err, errOut)
		}
		checkGolden(t, "help-"+tp.name, out)
		// A topic whose name is also a verb (presets) has no bare form: the
		// verb owns `ley presets`, and only `ley help presets` is the prose.
		if !verbs[tp.name] {
			if bare, _, err := runApp(t, helpApp(), tp.name); err != nil || bare != out {
				t.Errorf("ley %s: err=%v; output differs from ley help %s", tp.name, err, tp.name)
			}
		}
		if !strings.Contains(out, "ley ") {
			t.Errorf("help %s: no example command", tp.name)
		}
	}
}

// TestHelpMeta enforces the help conventions on every visible verb: a group
// on root verbs, a Short of at most 60 characters, a Long, an Example, and a
// description on every flag. Roadmap stubs are hidden and exempt.
func TestHelpMeta(t *testing.T) {
	root := NewRootCommand(helpApp())
	root.InitDefaultHelpCmd()
	var walk func(c *cobra.Command)
	walk = func(c *cobra.Command) {
		for _, sub := range c.Commands() {
			if sub.Hidden || sub.Name() == "completion" {
				continue
			}
			path := sub.CommandPath()
			if c == root && sub.GroupID == "" {
				t.Errorf("%s: no GroupID", path)
			}
			if sub.Short == "" || len(sub.Short) > 60 {
				t.Errorf("%s: Short must be 1..60 chars, got %d: %q", path, len(sub.Short), sub.Short)
			}
			if strings.TrimSpace(sub.Long) == "" {
				t.Errorf("%s: no Long", path)
			}
			if strings.TrimSpace(sub.Example) == "" {
				t.Errorf("%s: no Example", path)
			}
			sub.LocalFlags().VisitAll(func(f *pflag.Flag) {
				if f.Usage == "" {
					t.Errorf("%s --%s: no description", path, f.Name)
				}
			})
			walk(sub)
		}
	}
	walk(root)
	for _, g := range root.Groups() {
		found := false
		for _, sub := range root.Commands() {
			if sub.GroupID == g.ID && !sub.Hidden {
				found = true
			}
		}
		if !found {
			t.Errorf("group %q lists no visible verb", g.Title)
		}
	}
}

// TestHelpUnknown: an unknown topic or verb is a usage error that lists the
// topics and points at the command list; a verb with extra words is too.
func TestHelpUnknown(t *testing.T) {
	for _, args := range [][]string{{"help", "nonsense"}, {"help", "set", "squelch"}} {
		out, _, err := runApp(t, helpApp(), args...)
		if exitCode(err) != ExitUsage {
			t.Errorf("ley %s: exit %d, want %d (err=%v)", strings.Join(args, " "), exitCode(err), ExitUsage, err)
		}
		msg := err.Error()
		for _, want := range []string{"no command or topic named", "Topics:", "squelch", "ley --help"} {
			if !strings.Contains(msg, want) {
				t.Errorf("ley %s: message lacks %q:\n%s", strings.Join(args, " "), want, msg)
			}
		}
		if out != "" {
			t.Errorf("ley %s: stdout should be empty, got %q", strings.Join(args, " "), out)
		}
	}
	if out, _, err := runApp(t, helpApp(), "help", "SQUELCH"); err != nil || !strings.HasPrefix(out, "Squelch mutes") {
		t.Errorf("topic names are case-insensitive: err=%v out=%q", err, out)
	}
}
