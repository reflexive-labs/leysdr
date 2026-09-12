// SPDX-License-Identifier: Apache-2.0

package ui

import "testing"

const (
	bold  = "\x1b[1m"
	reset = "\x1b[0m"
)

func TestVisibleAndStrip(t *testing.T) {
	tests := []struct {
		name  string
		in    string
		plain string
		width int
	}{
		{"plain", "ACTIVE", "ACTIVE", 6},
		{"empty", "", "", 0},
		{"sgr around text", bold + "ID" + reset, "ID", 2},
		{"sgr between text", "a" + bold + "b" + reset + "c", "abc", 3},
		{"colour without reset", "\x1b[32mOK", "OK", 2},
		{"osc title", "\x1b]0;ley\atext", "text", 4},
		{"wide runes", "日本語", "日本語", 6},
		{"wide with sgr", bold + "日本" + reset + "x", "日本x", 5},
		{"combining mark", "état", "état", 4},
		{"zero width space", "a\u200bb", "a\u200bb", 2},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Strip(tc.in); got != tc.plain {
				t.Errorf("Strip(%q) = %q, want %q", tc.in, got, tc.plain)
			}
			if got := Visible(tc.in); got != tc.width {
				t.Errorf("Visible(%q) = %d, want %d", tc.in, got, tc.width)
			}
		})
	}
}

func TestPad(t *testing.T) {
	var plain Style
	styled := Style{Color: true}
	tests := []struct {
		name string
		s    Style
		in   string
		n    int
		want string
	}{
		{"pads to width", plain, "ID", 5, "ID   "},
		{"already wide enough", plain, "SERIAL", 4, "SERIAL"},
		{"exact width", plain, "ABCD", 4, "ABCD"},
		{"measures visible width", styled, bold + "ID" + reset, 5, bold + "ID" + reset + "   "},
		{"wide runes count two", plain, "日本", 6, "日本  "},
		{"negative width", plain, "x", -3, "x"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.s.Pad(tc.in, tc.n)
			if got != tc.want {
				t.Fatalf("Pad(%q, %d) = %q, want %q", tc.in, tc.n, got, tc.want)
			}
			if w := Visible(got); tc.n > 0 && w < tc.n && Visible(tc.in) < tc.n {
				t.Fatalf("Pad(%q, %d) has visible width %d", tc.in, tc.n, w)
			}
		})
	}
}

func TestTruncate(t *testing.T) {
	ascii := Style{}
	uni := Style{Unicode: true}
	tests := []struct {
		name string
		s    Style
		in   string
		n    int
		want string
	}{
		{"fits", ascii, "chan_01H", 8, "chan_01H"},
		{"ascii ellipsis", ascii, "chan_01HXYZ", 8, "chan_..."},
		{"unicode ellipsis", uni, "chan_01HXYZ", 8, "chan_01…"},
		{"too narrow for a marker", ascii, "abcdef", 2, "ab"},
		{"zero", ascii, "abc", 0, ""},
		{"wide runes stop short", uni, "日本語です", 5, "日本…"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.s.Truncate(tc.in, tc.n)
			if got != tc.want {
				t.Fatalf("Truncate(%q, %d) = %q, want %q", tc.in, tc.n, got, tc.want)
			}
			if w := Visible(got); w > tc.n && tc.n > 0 {
				t.Fatalf("Truncate(%q, %d) is %d columns wide", tc.in, tc.n, w)
			}
		})
	}
}

// TestTruncateClosesInk keeps a cut cell from leaking its colour into the
// rest of the line.
func TestTruncateClosesInk(t *testing.T) {
	s := Style{Color: true}
	got := s.Truncate(s.Muted("chan_01HXYZ"), 8)
	if Strip(got) != "chan_..." {
		t.Fatalf("Strip(%q) = %q, want %q", got, Strip(got), "chan_...")
	}
	if got[len(got)-len("...")-len(reset):len(got)-len("...")] != reset {
		t.Fatalf("truncated ink is not reset before the ellipsis: %q", got)
	}
}
