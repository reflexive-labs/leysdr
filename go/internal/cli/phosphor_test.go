package cli

import (
	"encoding/binary"
	"math"
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/internal/ui"
)

// histogram builds a wire payload: counts[bin][level], bin-major.
func histogram(bins, levels int, fill func(bin, level int) uint16) []byte {
	out := make([]byte, bins*levels*2)
	for b := 0; b < bins; b++ {
		for l := 0; l < levels; l++ {
			binary.LittleEndian.PutUint16(out[(b*levels+l)*2:], fill(b, l))
		}
	}
	return out
}

func testPhosphor(st ui.Style, width int, mark uint64) *phosphorView {
	v := newPhosphorView(st, width, mark)
	v.centerHz, v.spanHz = fixtureCenterHz, fixtureSpanHz
	v.floorDb, v.rangeDb, v.halfLife = -90, phosphorRangeDb, 20
	return v
}

// A band where every bin sits at the noise level, except one carrier bin that
// sits high, and one bin that is high only rarely.
func bandHistogram(bins, levels int) []byte {
	return histogram(bins, levels, func(b, l int) uint16 {
		switch {
		case b == bins/2 && l == levels-2:
			return 1000 // a carrier, always there
		case b == bins/4 && l == levels-2:
			return 10 // present 1% of the time: the signal this display exists to find
		case l == 1:
			return 1000 // the noise floor
		}
		return 0
	})
}

// The reason the shading curve is logarithmic. A linear normaliser against the
// frame's peak makes a 1%-duty signal draw as blank, because the shade ramp has
// four steps and 1% is far under the first. That would defeat the entire
// feature: rare-but-real is exactly what persistence is for.
func TestPhosphorRareSignalStaysVisible(t *testing.T) {
	if got := shadeFor(10, 1000); got < 0.25 {
		t.Errorf("a 1%% signal must reach the first shade step, got %.3f", got)
	}
	if linear := 10.0 / 1000.0; linear >= 0.25 {
		t.Fatal("this test is meaningless if linear scaling would also have worked")
	}
	if got := shadeFor(1000, 1000); got != 1 {
		t.Errorf("a permanent signal is full brightness, got %v", got)
	}
	if got := shadeFor(0, 1000); got != 0 {
		t.Errorf("never seen is blank, got %v", got)
	}
	if got := shadeFor(5, 0); got != 0 {
		t.Errorf("an empty histogram is blank, got %v", got)
	}
	// Monotonic: more often is never fainter.
	prev := -1.0
	for c := uint16(0); c < 500; c += 25 {
		got := shadeFor(c, 500)
		if got < prev {
			t.Fatalf("shading must not decrease: %d gave %.3f after %.3f", c, got, prev)
		}
		prev = got
	}
}

// The whole claim of the display, end to end: a carrier that is always there
// and a signal that is rarely there both appear, and a frequency that has never
// carried anything stays blank.
func TestPhosphorDrawsRareAndSteadyAlike(t *testing.T) {
	const bins, levels = 64, 32
	h, ok := decodePersistence(bandHistogram(bins, levels), bins, levels)
	if !ok {
		t.Fatal("decode failed")
	}
	v := testPhosphor(ui.Style{Unicode: true, Width: 100}, 100, 0)
	rows := strings.Split(ui.Strip(v.render(h)), "\n")
	// The chart body is the rows carrying the level gutter.
	var body []string
	for _, r := range rows {
		if len(r) > phosphorGutter && !strings.ContainsRune(r, '─') && strings.ContainsAny(r, " ░▒▓█") {
			body = append(body, r)
		}
	}
	joined := strings.Join(body, "\n")
	if !strings.Contains(joined, "█") {
		t.Errorf("a permanent signal draws at full density:\n%s", joined)
	}
	if !strings.Contains(joined, "░") {
		t.Errorf("a rare signal draws faintly:\n%s", joined)
	}
	if !strings.Contains(joined, " ") {
		t.Errorf("a frequency that has carried nothing stays blank:\n%s", joined)
	}
}

// The style guide's first principle.
func TestPhosphorStripsToPlain(t *testing.T) {
	const bins, levels = 64, 32
	h, _ := decodePersistence(bandHistogram(bins, levels), bins, levels)
	for _, width := range []int{40, 80, 160} {
		for _, uni := range []bool{false, true} {
			plain := testPhosphor(ui.Style{Unicode: uni, Width: width}, width, fixtureCenterHz).render(h)
			styled := testPhosphor(ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: uni, Width: width}, width, fixtureCenterHz).render(h)
			if ui.Strip(styled) != plain {
				t.Errorf("width %d unicode %v:\n plain  %q\n styled %q", width, uni, plain, ui.Strip(styled))
			}
			for _, l := range strings.Split(strings.TrimRight(plain, "\n"), "\n") {
				if got := ui.Visible(l); got > width {
					t.Errorf("width %d unicode %v: a line of %d columns: %q", width, uni, got, l)
				}
			}
		}
	}
}

// A short or empty payload is a stream that has not agreed with its descriptor.
// It must be skipped, not decoded into a picture of nothing.
func TestPhosphorRejectsAShortPayload(t *testing.T) {
	for _, tc := range []struct {
		name         string
		payload      []byte
		bins, levels int
	}{
		{"empty", nil, 8, 4},
		{"one byte short", make([]byte, 8*4*2-1), 8, 4},
		{"zero bins", make([]byte, 64), 0, 4},
		{"zero levels", make([]byte, 64), 8, 0},
	} {
		if _, ok := decodePersistence(tc.payload, tc.bins, tc.levels); ok {
			t.Errorf("%s: should have been rejected", tc.name)
		}
	}
	if _, ok := decodePersistence(make([]byte, 8*4*2), 8, 4); !ok {
		t.Error("an exact payload must decode")
	}
}

// The header states the window, because "usual" means nothing without saying
// over what, and what a column covers, because that sets whether this is a
// picture of a signal or a map of where energy is.
func TestPhosphorHeaderStatesTheWindow(t *testing.T) {
	v := testPhosphor(ui.Style{Unicode: true, Width: 100}, 100, 0)
	head := ui.Strip(strings.Join(v.header(v.cols(256)), "\n"))
	if !strings.Contains(head, "over the last") {
		t.Errorf("the header must state the decay window:\n%s", head)
	}
	if !strings.Contains(head, "columns of") {
		t.Errorf("the header must say what a column covers:\n%s", head)
	}
}

func TestFmtSeconds(t *testing.T) {
	for _, tc := range []struct {
		in   float64
		want string
	}{
		{20, "20 s"},
		{59, "59 s"},
		{60, "1 min"},
		{600, "10 min"},
		{0, "-"},
		{-1, "-"},
		{math.NaN(), "-"},
	} {
		if got := fmtSeconds(tc.in); got != tc.want {
			t.Errorf("fmtSeconds(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
