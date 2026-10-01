// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/binary"
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
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
// four steps and 1% is far under the first. Rare but real signals are what
// the persistence display exists to show.
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

// End to end: a carrier that is always there
// and a signal that is rarely there both appear, and a frequency that has never
// carried anything stays blank.
func TestPhosphorDrawsRareAndSteadyAlike(t *testing.T) {
	const bins, levels = 64, 32
	h, ok := leyline.DecodePersistence(bandHistogram(bins, levels), bins, levels)
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
	h, _ := leyline.DecodePersistence(bandHistogram(bins, levels), bins, levels)
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
		if _, ok := leyline.DecodePersistence(tc.payload, tc.bins, tc.levels); ok {
			t.Errorf("%s: should have been rejected", tc.name)
		}
	}
	if _, ok := leyline.DecodePersistence(make([]byte, 8*4*2), 8, 4); !ok {
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

// The whole verb against a daemon: it finds the floor with an FFT row, subscribes to the
// histogram accumulated on that scale, and draws frames of it. The band the fake serves is noise
// at a steady level, so the cells at the floor are the ones that fill: a run that drew an empty
// chart would mean the counts never reached the display, which is the failure this cannot see
// from the renderer's own tests.
func TestPhosphorAgainstDaemon(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "phosphor", "146.52", "--count", "2", "--half-life", "5", "--width", "60")
	if !strings.Contains(out, "over the last 5 s") {
		t.Errorf("the header must state the half-life the daemon answered:\n%s", out)
	}
	if !strings.Contains(out, "146.520 MHz") || !strings.Contains(out, "columns of") {
		t.Errorf("phosphor header:\n%s", out)
	}
	frames := strings.Count(out, "shade is how often")
	if frames != 2 {
		t.Errorf("want 2 frames, got %d:\n%s", frames, out)
	}
	// The noise floor is the one level every bin keeps landing in, so it draws as a filled row.
	var filled bool
	for _, line := range strings.Split(ui.Strip(out), "\n") {
		if strings.Count(line, "#") > 40 {
			filled = true
		}
	}
	if !filled {
		t.Errorf("the noise floor should accumulate into a bright row:\n%s", out)
	}
}

// `phosphor --json` is the histogram itself, not the chart: one NDJSON frame
// per redraw, with the grid the daemon sent carried whole so a consumer can
// re-derive every cell the chart shades.
func TestPhosphorJSONFrames(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, _, err := run(t, t.Context(), sock, "--json", "phosphor", "146.52", "--count", "2", "--half-life", "5", "--bins", "64", "--levels", "16")
	if err != nil {
		t.Fatalf("phosphor --json: %v\n%s", err, out)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("want 2 frames, got %d:\n%s", len(lines), out)
	}
	for _, l := range lines {
		var row PersistenceRow
		if err := json.Unmarshal([]byte(l), &row); err != nil {
			t.Fatalf("frame is not JSON: %v %s", err, l)
		}
		if row.Bins == 0 || row.Levels == 0 || row.RangeDb != phosphorRangeDb {
			t.Errorf("frame is missing the scale it is measured on: %s", l)
		}
		// The counts are the wire grid: bins x levels little-endian uint16.
		if want := int(row.Bins) * int(row.Levels) * 2; len(row.Counts) != want {
			t.Fatalf("counts must be %d bytes, got %d", want, len(row.Counts))
		}
		if _, ok := leyline.DecodePersistence(row.Counts, int(row.Bins), int(row.Levels)); !ok {
			t.Errorf("counts must decode as the histogram the chart draws: %s", l)
		}
	}
	if strings.Contains(out, "shade is how often") {
		t.Errorf("--json must not draw the chart:\n%s", out)
	}
}
