package ui

import (
	"strings"
	"testing"
)

// inkMethods is every ink role, named for the failure message.
var inkMethods = []struct {
	name string
	fn   func(Style, string) string
}{
	{"Label", Style.Label},
	{"Muted", Style.Muted},
	{"Ok", Style.Ok},
	{"Warn", Style.Warn},
	{"Err", Style.Err},
	{"Cmd", Style.Cmd},
}

// TestZeroStyleIsIdentity is principle 2: the default path is the plain path.
func TestZeroStyleIsIdentity(t *testing.T) {
	var s Style
	const text = "ACTIVE chan_01H"
	for _, m := range inkMethods {
		if got := m.fn(s, text); got != text {
			t.Errorf("zero Style.%s(%q) = %q, want the identity", m.name, text, got)
		}
	}
	if got := s.Pad(text, 4); got != text {
		t.Errorf("Pad below width = %q, want %q", got, text)
	}
	if got := s.Truncate(text, 40); got != text {
		t.Errorf("Truncate within width = %q, want %q", got, text)
	}
	if g := s.Glyphs(); g.Rule != '-' || g.TreeLast != "\\-" || string(g.Ramp) != " .:-=+*#%" {
		t.Errorf("zero Style.Glyphs() = %+v, want the ASCII set", g)
	}
	if s.Width != 0 {
		t.Errorf("zero Style.Width = %d, want 0 (unknown)", s.Width)
	}
}

// TestInkStripsToPlain is principle 1's mechanical proof for the package
// itself: ink adds SGR and nothing else.
func TestInkStripsToPlain(t *testing.T) {
	s := Style{Color: true, Unicode: true}
	const text = "146.520 MHz"
	for _, m := range inkMethods {
		styled := m.fn(s, text)
		if styled == text {
			t.Errorf("%s emitted no SGR with Color:true", m.name)
		}
		if got := Strip(styled); got != text {
			t.Errorf("Strip(%s(%q)) = %q, want %q", m.name, text, got, text)
		}
		if got := Visible(styled); got != len(text) {
			t.Errorf("Visible(%s(...)) = %d, want %d", m.name, got, len(text))
		}
	}
	if got := s.Label(""); got != "" {
		t.Errorf("Label(\"\") = %q, want the empty string unstyled", got)
	}
}

func TestGlyphsAlphabets(t *testing.T) {
	u := Style{Unicode: true}.Glyphs()
	a := Style{}.Glyphs()
	if len(u.Ramp) != 9 || len(a.Ramp) != 9 {
		t.Fatalf("ramp lengths = %d/%d, want 9 each (empty plus eight levels)", len(u.Ramp), len(a.Ramp))
	}
	if u.Ramp[0] != ' ' || a.Ramp[0] != ' ' {
		t.Error("both ramps must start blank")
	}
	if u.Absent != "-" || a.Absent != "-" {
		t.Error("the absent value is - in both alphabets")
	}
	for _, r := range append(append([]rune{}, u.Ramp...), u.BarFull, u.BarEmpty, u.Marker, u.Rule) {
		if w := runeWidth(r); w != 1 {
			t.Errorf("glyph %q measures %d columns, want 1", r, w)
		}
	}
	if strings.ContainsAny(u.TreeBranch+u.TreeLast+u.TreeTrunk, "\t\n") {
		t.Error("tree glyphs must not contain whitespace control characters")
	}
}
