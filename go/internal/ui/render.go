package ui

import "strings"

// Pad returns text padded with spaces to n visible columns, measuring the
// text as a terminal does: SGR bytes count nothing, wide runes count two.
// Text already at or past n is returned unchanged, so a table never loses a
// value to its own column width.
func (s Style) Pad(text string, n int) string {
	w := Visible(text)
	if w >= n {
		return text
	}
	return text + strings.Repeat(" ", n-w)
}

// Truncate shortens text to n visible columns, ending it with the glyph
// set's ellipsis when anything was cut. Escape sequences are carried through
// and closed with a reset, so a truncated cell never leaks its ink into the
// rest of the line. n at or below zero yields the empty string.
func (s Style) Truncate(text string, n int) string {
	if n <= 0 {
		return ""
	}
	if Visible(text) <= n {
		return text
	}
	ell := s.Glyphs().Ellipsis
	room := n - Visible(ell)
	if room < 0 {
		// Too narrow for the marker: cut hard rather than overflow.
		ell, room = "", n
	}
	cut, _ := truncateVisible(text, room)
	if hasEscape(cut) {
		return cut + sgrReset + ell
	}
	return cut + ell
}

// Bar renders a level meter width columns wide, filled in proportion to frac
// (clamped to [0, 1]; a NaN reads as empty). It carries no ink: the caller
// decides what the level means.
func (s Style) Bar(frac float64, width int) string {
	if width <= 0 {
		return ""
	}
	g := s.Glyphs()
	filled := int(clamp01(frac)*float64(width) + 0.5)
	if filled > width {
		filled = width
	}
	return strings.Repeat(string(g.BarFull), filled) + strings.Repeat(string(g.BarEmpty), width-filled)
}

// Ramp returns the one spectrum column that stands for frac, from blank at or
// below zero to full at or above one (a NaN reads as blank).
func (s Style) Ramp(frac float64) string {
	r := []rune(s.Glyphs().Ramp)
	top := len(r) - 1
	i := int(clamp01(frac)*float64(top) + 0.5)
	if i > top {
		i = top
	}
	return string(r[i])
}

// Rule returns a horizontal rule width columns wide: a section separator, or
// the noise floor under a spectrum.
func (s Style) Rule(width int) string {
	if width <= 0 {
		return ""
	}
	return strings.Repeat(string(s.Glyphs().Rule), width)
}

// RuleHeavy is Rule drawn with weight: the separator for a break a blank
// line and a light rule cannot carry, such as the top of a framed chart.
func (s Style) RuleHeavy(width int) string {
	if width <= 0 {
		return ""
	}
	return strings.Repeat(string(s.Glyphs().RuleHeavy), width)
}

// clamp01 folds a fraction into [0, 1]; anything that is not a number (NaN
// fails every comparison) reads as zero.
func clamp01(f float64) float64 {
	if f >= 1 {
		return 1
	}
	if f > 0 {
		return f
	}
	return 0
}
