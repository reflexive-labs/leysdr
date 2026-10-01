// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// styleApp is an app whose terminal answers are dictated, not detected.
func styleApp(stdoutTTY, stderrTTY bool, env map[string]string) *App {
	if _, ok := env["TERM"]; !ok {
		env["TERM"] = "xterm-256color"
	}
	return &App{
		Stdout:       &bytes.Buffer{},
		Stderr:       &bytes.Buffer{},
		IsTTY:        func() bool { return stdoutTTY },
		IsErrTTY:     func() bool { return stderrTTY },
		TermWidth:    func() int { return 100 },
		ErrTermWidth: func() int { return 100 },
		LookupEnv: func(name string) (string, bool) {
			v, ok := env[name]
			return v, ok
		},
	}
}

// TestStyleResolvedPerStream is the "colour is decided per stream" decision:
// `ley state | grep chan_` keeps coloured prose on the terminal and clean
// text in the pipe, and --json takes stdout out of reach either way.
func TestStyleResolvedPerStream(t *testing.T) {
	tests := []struct {
		name           string
		args           []string
		stdout, stderr bool
		env            map[string]string
		wantOut        bool
		wantErr        bool
	}{
		{"both terminals", []string{"version"}, true, true, nil, true, true},
		{"stdout piped", []string{"version"}, false, true, nil, false, true},
		{"both piped", []string{"version"}, false, false, nil, false, false},
		{"json spares stderr", []string{"version", "--json"}, true, true, nil, false, true},
		{"color=never", []string{"version", "--color=never"}, true, true, nil, false, false},
		{"color=always through a pipe", []string{"version", "--color=always"}, false, false, nil, true, true},
		{"NO_COLOR", []string{"version"}, true, true, map[string]string{"NO_COLOR": "1"}, false, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			env := tc.env
			if env == nil {
				env = map[string]string{}
			}
			app := styleApp(tc.stdout, tc.stderr, env)
			if err := Execute(context.Background(), app, tc.args); err != nil {
				t.Fatalf("execute: %v", err)
			}
			if app.Style.Color != tc.wantOut {
				t.Errorf("Style.Color = %v, want %v", app.Style.Color, tc.wantOut)
			}
			if app.ErrStyle.Color != tc.wantErr {
				t.Errorf("ErrStyle.Color = %v, want %v", app.ErrStyle.Color, tc.wantErr)
			}
			if app.Style.Width != 100 {
				t.Errorf("Style.Width = %d, want 100", app.Style.Width)
			}
		})
	}
}

// TestBadColorFlagIsUsage keeps the flag's own error at exit 2.
func TestBadColorFlagIsUsage(t *testing.T) {
	app := styleApp(true, true, map[string]string{})
	err := Execute(context.Background(), app, []string{"version", "--color=maybe"})
	want := ExitUsage
	if code := exitCode(err); code != want {
		t.Fatalf("exit code = %d (%v), want %d", code, err, want)
	}
}

// TestBulkStdoutIsNeverStyled is rule 4 of the style guide: the row streams
// are decided machine output before any renderer exists.
func TestBulkStdoutIsNeverStyled(t *testing.T) {
	app := styleApp(true, true, map[string]string{})
	root := NewRootCommand(app)
	for _, tc := range []struct {
		args []string
		want bool
	}{
		{[]string{"fft"}, true},
		{[]string{"listen", "146.52"}, true},
		{[]string{"listen", "146.52", "--format", "bin"}, true},
		{[]string{"spectrum"}, false},
		{[]string{"state"}, false},
		{[]string{"state", "--json"}, true},
	} {
		cmd, flags, err := root.Find(tc.args)
		if err != nil {
			t.Fatalf("find %v: %v", tc.args, err)
		}
		if err := cmd.ParseFlags(flags); err != nil {
			t.Fatalf("parse %v: %v", tc.args, err)
		}
		if got := app.machineStdout(cmd); got != tc.want {
			t.Errorf("machineStdout(%v) = %v, want %v", tc.args, got, tc.want)
		}
		app.JSON = false
	}
}

// TestTableHeaderInk styles the header row without moving a column: the
// tabwriter measures the plain text, the SGR bytes are added after.
func TestTableHeaderInk(t *testing.T) {
	render := func(a *App) string {
		buf := &bytes.Buffer{}
		a.Stdout = buf
		w := a.table()
		if _, err := w.Write([]byte("ID\tMODEL\tSTATE\n")); err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte("dev_01\tRTL-SDR v3\tAVAILABLE\n")); err != nil {
			t.Fatal(err)
		}
		if err := w.Flush(); err != nil {
			t.Fatal(err)
		}
		return buf.String()
	}
	plain := render(&App{})
	styled := render(&App{Style: ui.Style{Color: true, Unicode: true}})
	if styled == plain {
		t.Fatal("a coloured style left the header unstyled")
	}
	if got := ui.Strip(styled); got != plain {
		t.Fatalf("Strip(styled) = %q, want %q", got, plain)
	}
	head := strings.SplitN(styled, "\n", 2)[0]
	if !strings.HasPrefix(head, "\x1b[1m") {
		t.Errorf("header row is not bold: %q", head)
	}
	if strings.Count(styled, "\x1b[1m") != 1 {
		t.Errorf("ink reached past the header row: %q", styled)
	}
}
