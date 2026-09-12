// SPDX-License-Identifier: Apache-2.0

package ui

import "testing"

// env builds a LookupEnv over a map, distinguishing unset from empty.
func env(kv map[string]string) func(string) (string, bool) {
	return func(name string) (string, bool) {
		v, ok := kv[name]
		return v, ok
	}
}

// tty is the baseline: an interactive terminal on both streams with a normal
// TERM, so each row below is exactly the rule it names.
func tty(kv map[string]string) Options {
	if kv == nil {
		kv = map[string]string{}
	}
	if _, ok := kv["TERM"]; !ok {
		kv["TERM"] = "xterm-256color"
	}
	return Options{StdoutTTY: true, StderrTTY: true, LookupEnv: env(kv)}
}

// TestColorChain walks every row of section 2 of docs/cli-style.md, in order.
func TestColorChain(t *testing.T) {
	tests := []struct {
		name string
		o    Options
		want bool
	}{
		{"1 machine stdout", withMachine(tty(nil)), false},
		{"1 machine leaves stderr alone", stderrOf(withMachine(tty(nil))), true},
		{"2 color=never beats a terminal", withColor(tty(nil), "never"), false},
		{"2 color=always beats a pipe", withColor(Options{LookupEnv: env(map[string]string{"TERM": "xterm"})}, "always"), true},
		{"2 color=always beats NO_COLOR", withColor(tty(map[string]string{"NO_COLOR": "1"}), "always"), true},
		{"2 color=never beats CLICOLOR_FORCE", withColor(tty(map[string]string{"CLICOLOR_FORCE": "1"}), "never"), false},
		{"2 color=auto falls through", withColor(tty(nil), "auto"), true},
		{"3 NO_COLOR off", tty(map[string]string{"NO_COLOR": "1"}), false},
		{"3 NO_COLOR empty is not set", tty(map[string]string{"NO_COLOR": ""}), true},
		{"4 CLICOLOR_FORCE on without a tty", Options{LookupEnv: env(map[string]string{"CLICOLOR_FORCE": "1"})}, true},
		{"4 CLICOLOR_FORCE=0 is not force", Options{LookupEnv: env(map[string]string{"CLICOLOR_FORCE": "0", "TERM": "xterm"})}, false},
		{"4 CLICOLOR_FORCE beats CLICOLOR=0", tty(map[string]string{"CLICOLOR_FORCE": "1", "CLICOLOR": "0"}), true},
		{"5 CLICOLOR=0 off", tty(map[string]string{"CLICOLOR": "0"}), false},
		{"5 CLICOLOR=1 falls through to the tty", tty(map[string]string{"CLICOLOR": "1"}), true},
		{"6 TERM=dumb off", tty(map[string]string{"TERM": "dumb"}), false},
		{"6 TERM empty off", tty(map[string]string{"TERM": ""}), false},
		{"6 TERM unset off", Options{StdoutTTY: true, LookupEnv: env(map[string]string{})}, false},
		{"7 stdout tty on", tty(nil), true},
		{"7 stdout pipe off", Options{StderrTTY: true, LookupEnv: env(map[string]string{"TERM": "xterm"})}, false},
		{"7 stderr tty on", stderrOf(Options{StderrTTY: true, LookupEnv: env(map[string]string{"TERM": "xterm"})}), true},
		{"7 stderr pipe off", stderrOf(Options{StdoutTTY: true, LookupEnv: env(map[string]string{"TERM": "xterm"})}), false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Resolve(tc.o).Color; got != tc.want {
				t.Fatalf("Resolve(%+v).Color = %v, want %v", tc.o, got, tc.want)
			}
		})
	}
}

func withMachine(o Options) Options { o.Machine = true; return o }
func stderrOf(o Options) Options    { o.Stderr = true; return o }

func withColor(o Options, v string) Options {
	o.Color = v
	return o
}

func TestWidthChain(t *testing.T) {
	tests := []struct {
		name string
		o    Options
		want int
	}{
		{"flag wins", Options{Width: 100, StdoutWidth: 120, LookupEnv: env(map[string]string{"COLUMNS": "60"})}, 100},
		{"COLUMNS next", Options{StdoutWidth: 120, LookupEnv: env(map[string]string{"COLUMNS": "60"})}, 60},
		{"COLUMNS junk is skipped", Options{StdoutWidth: 120, LookupEnv: env(map[string]string{"COLUMNS": "wide"})}, 120},
		{"COLUMNS zero is skipped", Options{StdoutWidth: 120, LookupEnv: env(map[string]string{"COLUMNS": "0"})}, 120},
		{"stdout ioctl", Options{StdoutWidth: 120, StderrWidth: 90, LookupEnv: env(nil)}, 120},
		{"pty reporting zero falls through to stderr", Options{StdoutWidth: 0, StderrWidth: 90, LookupEnv: env(nil)}, 90},
		{"nothing knows: 80", Options{LookupEnv: env(nil)}, DefaultWidth},
		{"clamped up", Options{Width: 20, LookupEnv: env(nil)}, MinWidth},
		{"clamped down", Options{Width: 300, LookupEnv: env(nil)}, MaxWidth},
		{"stderr style shares the width", Options{Stderr: true, StdoutWidth: 120, LookupEnv: env(nil)}, 120},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Resolve(tc.o).Width; got != tc.want {
				t.Fatalf("Resolve(%+v).Width = %d, want %d", tc.o, got, tc.want)
			}
		})
	}
}

func TestUnicodeChain(t *testing.T) {
	tests := []struct {
		name string
		o    Options
		want bool
	}{
		{"LANG utf-8", Options{LookupEnv: env(map[string]string{"LANG": "en_US.UTF-8"})}, true},
		{"lowercase", Options{LookupEnv: env(map[string]string{"LANG": "en_US.utf-8"})}, true},
		{"LC_ALL", Options{LookupEnv: env(map[string]string{"LC_ALL": "C.UTF-8"})}, true},
		{"LC_CTYPE", Options{LookupEnv: env(map[string]string{"LC_CTYPE": "UTF-8"})}, true},
		{"C locale", Options{LookupEnv: env(map[string]string{"LANG": "C"})}, false},
		{"unset", Options{LookupEnv: env(nil)}, false},
		{"--ascii wins", Options{ASCII: true, LookupEnv: env(map[string]string{"LANG": "en_US.UTF-8"})}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Resolve(tc.o).Unicode; got != tc.want {
				t.Fatalf("Resolve(%+v).Unicode = %v, want %v", tc.o, got, tc.want)
			}
		})
	}
}

// TestResolveProfile is the depth chain for the level ramp: environment
// only, never a query to the terminal, and never any depth at all when the
// stream is not being coloured.
func TestResolveProfile(t *testing.T) {
	env := func(vars map[string]string) func(string) (string, bool) {
		return func(name string) (string, bool) {
			v, ok := vars[name]
			return v, ok
		}
	}
	for _, tc := range []struct {
		name string
		vars map[string]string
		opts Options
		want Profile
	}{
		{"truecolor", map[string]string{"TERM": "xterm-256color", "COLORTERM": "truecolor"}, Options{StdoutTTY: true}, ProfileTrueColor},
		{"24bit", map[string]string{"TERM": "xterm", "COLORTERM": "24bit"}, Options{StdoutTTY: true}, ProfileTrueColor},
		{"direct", map[string]string{"TERM": "xterm-direct"}, Options{StdoutTTY: true}, ProfileTrueColor},
		{"256", map[string]string{"TERM": "screen-256color"}, Options{StdoutTTY: true}, ProfileANSI256},
		{"plain terminal", map[string]string{"TERM": "xterm"}, Options{StdoutTTY: true}, ProfileANSI},
		{"forced", map[string]string{"TERM": "dumb"}, Options{Color: "always"}, ProfileANSI},
		{"piped", map[string]string{"TERM": "xterm-256color", "COLORTERM": "truecolor"}, Options{}, ProfileNone},
		{"NO_COLOR", map[string]string{"TERM": "xterm-256color", "NO_COLOR": "1"}, Options{StdoutTTY: true}, ProfileNone},
	} {
		t.Run(tc.name, func(t *testing.T) {
			o := tc.opts
			o.LookupEnv = env(tc.vars)
			got := Resolve(o)
			if got.Profile != tc.want {
				t.Errorf("Profile = %v, want %v", got.Profile, tc.want)
			}
			if (got.Profile != ProfileNone) != got.Color {
				t.Errorf("Profile %v disagrees with Color %v", got.Profile, got.Color)
			}
		})
	}
}
