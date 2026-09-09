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
	if len([]rune(u.Ramp)) != 9 || len([]rune(a.Ramp)) != 9 {
		t.Fatalf("ramp lengths = %d/%d, want 9 each (empty plus eight levels)", len([]rune(u.Ramp)), len([]rune(a.Ramp)))
	}
	if []rune(u.Ramp)[0] != ' ' || []rune(a.Ramp)[0] != ' ' {
		t.Error("both ramps must start blank")
	}
	if u.Absent != "-" || a.Absent != "-" {
		t.Error("the absent value is - in both alphabets")
	}
	for _, r := range append([]rune(u.Ramp), u.BarFull, u.BarEmpty, u.Marker, u.Rule, u.RuleHeavy) {
		if w := runeWidth(r); w != 1 {
			t.Errorf("glyph %q measures %d columns, want 1", r, w)
		}
	}
	if strings.ContainsAny(u.TreeBranch+u.TreeLast+u.TreeTrunk, "\t\n") {
		t.Error("tree glyphs must not contain whitespace control characters")
	}
}

// TestInkLeavesLayoutAlone guards the two things a styling library is prone
// to do to text on its way through: convert tabs, and pad a block to its
// widest line. An inked table header meets tabwriter after this, which counts
// its own columns.
func TestInkLeavesLayoutAlone(t *testing.T) {
	s := Style{Color: true, Unicode: true}
	for _, m := range inkMethods {
		if got := Strip(m.fn(s, "MODEL\tSTATE\tID")); got != "MODEL\tSTATE\tID" {
			t.Errorf("%s changed a tabbed header: %q", m.name, got)
		}
		if got := Strip(m.fn(s, "a\nbbb\n\nc")); got != "a\nbbb\n\nc" {
			t.Errorf("%s changed a multi-line block: %q", m.name, got)
		}
	}
}

// TestBoxFrames covers the frame in both alphabets: it is glyphs, so it
// survives colour being off, and it measures content by visible width.
func TestBoxFrames(t *testing.T) {
	for _, tc := range []struct {
		name  string
		style Style
		top   string
	}{
		{"unicode", Style{Unicode: true}, "╭"},
		{"ascii", Style{}, "+"},
		{"inked", Style{Color: true, Unicode: true}, "╭"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			content := "146.520 MHz"
			if tc.style.Color {
				content = tc.style.Ok(content)
			}
			lines := strings.Split(tc.style.Box(content+"\nnfm"), "\n")
			if len(lines) != 4 {
				t.Fatalf("Box drew %d lines, want 4", len(lines))
			}
			if !strings.HasPrefix(lines[0], tc.top) {
				t.Errorf("top line = %q, want it to start with %q", lines[0], tc.top)
			}
			want := len("146.520 MHz") + BoxPadding
			for _, line := range lines {
				if got := Visible(line); got != want {
					t.Errorf("line %q measures %d columns, want %d", Strip(line), got, want)
				}
			}
			if strings.Contains(Strip(lines[0]), "\x1b") || (!tc.style.Color && strings.Contains(lines[0], "\x1b")) {
				t.Errorf("the frame emitted SGR of its own: %q", lines[0])
			}
			if !strings.Contains(Strip(lines[1]), "146.520 MHz") {
				t.Errorf("content line = %q, want the framed text", Strip(lines[1]))
			}
		})
	}
	if got := (Style{Unicode: true}).RuleHeavy(3); got != "━━━" {
		t.Errorf("RuleHeavy(3) = %q, want three heavy rule glyphs", got)
	}
	if got := (Style{}).RuleHeavy(3); got != "===" {
		t.Errorf("ASCII RuleHeavy(3) = %q, want ===", got)
	}
	if got := (Style{}).RuleHeavy(0); got != "" {
		t.Errorf("RuleHeavy(0) = %q, want the empty string", got)
	}
}
