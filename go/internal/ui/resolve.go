package ui

import (
	"os"
	"strconv"
	"strings"
)

// Width bounds. A zero or errored ioctl means "unknown", not "narrow" (a pty
// with no winsize reports success with zero columns), and a 300-column chart
// is worse than a 120-column one.
const (
	// MinWidth is the narrowest layout the renderers target.
	MinWidth = 40
	// MaxWidth caps the widest, so a maximised window does not stretch a
	// chart past the eye.
	MaxWidth = 160
	// DefaultWidth is the width assumed when nothing reports one.
	DefaultWidth = 80
)

// Options is everything Resolve needs to decide one stream's style. It
// carries the environment lookup and the two isatty results rather than
// reading them, so the whole capability model is testable without a pty.
type Options struct {
	// Stderr resolves the style for stderr rather than stdout.
	Stderr bool
	// Color is the --color flag: "always", "never", or "auto"/"" for the
	// chain below. Any other value is treated as auto; the flag's own
	// validation belongs to the caller.
	Color string
	// ASCII is the --ascii flag: force the ASCII glyph set.
	ASCII bool
	// Width is --width for the verbs that have one; 0 when unset.
	Width int
	// Machine reports that stdout carries machine output (--json, a bulk
	// row stream, or --format bin). It turns stdout's colour off before any
	// renderer exists; stderr may still colour.
	Machine bool
	// StdoutTTY and StderrTTY are the isatty results for the two streams.
	StdoutTTY, StderrTTY bool
	// StdoutWidth and StderrWidth are TIOCGWINSZ on the two streams, 0 when
	// unknown.
	StdoutWidth, StderrWidth int
	// StdoutHeight is the terminal's row count, 0 when unknown. Unlike width
	// it is not clamped and has no flag: nothing lays out to a height, and the
	// one caller that needs it is deciding whether a block it already sized
	// can be redrawn in place at all.
	StdoutHeight int
	// LookupEnv resolves environment variables; nil means os.LookupEnv.
	LookupEnv func(string) (string, bool)
}

// Resolve applies the colour, width and unicode chains of section 2 of
// docs/cli-style.md and returns the style for the stream o names.
func Resolve(o Options) Style {
	color := resolveColor(o)
	return Style{
		Color:   color,
		Profile: resolveProfile(o, color),
		Unicode: resolveUnicode(o),
		Width:   resolveWidth(o),
		// The stderr style shares stdout's height: the only consumer draws to
		// one screen, and a block that will not fit does not fit either way.
		Height: o.StdoutHeight,
	}
}

// resolveProfile reports the colour depth the level ramp may use. It is
// decided from the same per-stream answer the colour chain already gave, and
// from the environment only: querying the terminal for its capabilities
// writes to it and reads stdin as a side effect.
func resolveProfile(o Options, color bool) Profile {
	if !color {
		return ProfileNone
	}
	if v, _ := o.lookup("COLORTERM"); strings.EqualFold(v, "truecolor") || strings.EqualFold(v, "24bit") {
		return ProfileTrueColor
	}
	term, _ := o.lookup("TERM")
	switch {
	case strings.Contains(term, "direct"):
		return ProfileTrueColor
	case strings.Contains(term, "256color"):
		return ProfileANSI256
	}
	return ProfileANSI
}

// resolveColor is the colour chain, first match wins.
func resolveColor(o Options) bool {
	env := o.lookup
	if !o.Stderr && o.Machine {
		return false
	}
	switch o.Color {
	case "never":
		return false
	case "always":
		return true
	}
	if v, ok := env("NO_COLOR"); ok && v != "" {
		return false
	}
	if v, ok := env("CLICOLOR_FORCE"); ok && v != "" && v != "0" {
		return true
	}
	if v, ok := env("CLICOLOR"); ok && v == "0" {
		return false
	}
	if term, _ := env("TERM"); term == "" || term == "dumb" {
		return false
	}
	if o.Stderr {
		return o.StderrTTY
	}
	return o.StdoutTTY
}

// resolveWidth is the width chain, first match wins, clamped to
// [MinWidth, MaxWidth].
func resolveWidth(o Options) int {
	w := 0
	switch {
	case o.Width > 0:
		w = o.Width
	default:
		if cols, ok := o.lookup("COLUMNS"); ok {
			if n, err := strconv.Atoi(strings.TrimSpace(cols)); err == nil && n > 0 {
				w = n
			}
		}
	}
	if w == 0 {
		w = o.StdoutWidth
	}
	if w == 0 {
		w = o.StderrWidth
	}
	if w == 0 {
		w = DefaultWidth
	}
	if w < MinWidth {
		return MinWidth
	}
	if w > MaxWidth {
		return MaxWidth
	}
	return w
}

// resolveUnicode reports whether the locale says the terminal reads UTF-8;
// --ascii always wins.
func resolveUnicode(o Options) bool {
	if o.ASCII {
		return false
	}
	for _, name := range [...]string{"LC_ALL", "LC_CTYPE", "LANG"} {
		if v, ok := o.lookup(name); ok && strings.Contains(strings.ToUpper(v), "UTF-8") {
			return true
		}
	}
	return false
}

// lookup reads one environment variable through the caller's hook.
func (o Options) lookup(name string) (string, bool) {
	if o.LookupEnv == nil {
		return os.LookupEnv(name)
	}
	return o.LookupEnv(name)
}
