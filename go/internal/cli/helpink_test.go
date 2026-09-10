package cli

import (
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/internal/ui"
)

// styledHelpApp is helpApp's terminal twin: same width, same lack of a
// daemon, but stdout is a terminal so help takes ink.
func styledHelpApp() *App {
	return &App{
		IsTTY:     func() bool { return true },
		TermWidth: func() int { return 80 },
		LookupEnv: func(name string) (string, bool) {
			if name == "TERM" {
				return "xterm-256color", true
			}
			return "", false
		},
	}
}

// TestHelpStyledStripsToGolden is the promise the help treatment makes: on a
// terminal every screen takes ink, and stripping the ink gives back exactly
// the piped screen the goldens hold. Nothing moves, so no golden changes.
func TestHelpStyledStripsToGolden(t *testing.T) {
	old := Version
	Version = "0.0.0-test"
	t.Cleanup(func() { Version = old })

	check := func(name string, args ...string) {
		t.Helper()
		plain, _, err := runApp(t, helpApp(), args...)
		if err != nil {
			t.Fatalf("ley %s: %v", strings.Join(args, " "), err)
		}
		styled, _, err := runApp(t, styledHelpApp(), args...)
		if err != nil {
			t.Fatalf("ley %s (tty): %v", strings.Join(args, " "), err)
		}
		if styled == plain {
			t.Errorf("%s: a terminal got no ink", name)
		}
		if got := ui.Strip(styled); got != plain {
			t.Errorf("%s: Strip(styled) differs from the piped screen\n--- piped\n%s\n--- stripped\n%s", name, plain, got)
		}
	}
	check("root", "--help")
	for _, path := range visibleVerbs(t) {
		check(strings.Join(path, " "), append(append([]string{}, path...), "--help")...)
	}
	for _, tp := range topics {
		check("help "+tp.name, "help", tp.name)
	}
}

// TestHelpInkTargets pins what takes ink and what does not: the group
// headings and the left column, never the prose, and Cobra's scaffolding
// dimmed rather than removed.
func TestHelpInkTargets(t *testing.T) {
	out, _, err := runApp(t, styledHelpApp(), "--help")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"\x1b[1mListening:\x1b[0m",             // a group heading
		"  \x1b[1mtune\x1b[0m        Listen",   // a verb name
		"  \x1b[1msquelch\x1b[0m      Muting",  // a topic name
		"\x1b[2mUsage:\x1b[0m",                 // Cobra's scaffolding
		"\x1b[2m  ley [flags]\x1b[0m",          // ... and its body
		"  \x1b[36mley devices\x1b[0m",         // an example command
		"\x1b[2m# is my radio visible?\x1b[0m", // ... and its comment
		"\x1b[2mUse \"ley [command] --help\"",  // the footer
	} {
		if !strings.Contains(out, want) {
			t.Errorf("root help lacks %q", want)
		}
	}
	// The opening prose is left alone: it is a paragraph, not a key.
	if !strings.HasPrefix(out, "ley drives the Leyline daemon") {
		t.Errorf("the opening prose took ink:\n%s", out[:120])
	}
}

// TestHelpFlagInk: the flag name is the key, its type and default are not.
func TestHelpFlagInk(t *testing.T) {
	out, _, err := runApp(t, styledHelpApp(), "tune", "--help")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"\x1b[1m--volume\x1b[0m \x1b[2mstring\x1b[0m",
		"\x1b[2m(default \"1\")\x1b[0m",
		"\x1b[1m-h, --help\x1b[0m",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("tune --help lacks %q", want)
		}
	}
	// A flag's default must not be printed twice.
	if strings.Contains(ui.Strip(out), "(default: full)") {
		t.Error("--volume still states its default twice")
	}
}

// TestHelpKeysNeedAColumn: a lone line that happens to hold a double space
// is prose (the sample meter line in `ley help squelch`), not a key.
func TestHelpKeysNeedAColumn(t *testing.T) {
	out, _, err := runApp(t, styledHelpApp(), "help", "squelch")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "\x1b[1m146.520 MHz NFM\x1b[0m") {
		t.Error("the sample meter line was read as a key column")
	}
	for _, want := range []string{"  \x1b[1mauto\x1b[0m   measure", "  \x1b[36mley set squelch -45\x1b[0m"} {
		if !strings.Contains(out, want) {
			t.Errorf("help squelch lacks %q", want)
		}
	}
}

// TestStyleHelpIsIdentityWhenPlain: the whole treatment is one function, and
// with colour off it is the identity -- which is what keeps every golden and
// every piped consumer safe.
func TestStyleHelpIsIdentityWhenPlain(t *testing.T) {
	text := "Usage:\n  ley [flags]\n\nListening:\n  tune        Listen\n"
	if got := styleHelp(ui.Style{}, text); got != text {
		t.Errorf("styleHelp with no colour changed the text:\n%q", got)
	}
	if got := styleHelp(ui.Style{Unicode: true, Width: 40}, text); got != text {
		t.Errorf("styleHelp without colour changed the text:\n%q", got)
	}
}
