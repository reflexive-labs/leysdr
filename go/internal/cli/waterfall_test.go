// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"math"
	"math/rand"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// waterfallBins is one row: a noise floor with an optional carrier.
func waterfallBins(n, carrier int, carrierDb float64, seed int64) []float64 {
	r := rand.New(rand.NewSource(seed))
	bins := make([]float64, n)
	for i := range bins {
		bins[i] = -90 + r.Float64()*6
	}
	if carrier >= 0 {
		for i := carrier - 4; i <= carrier+4 && i < n; i++ {
			if i >= 0 {
				bins[i] = carrierDb
			}
		}
	}
	return bins
}

func newTestWaterfall(st ui.Style, width int, mark uint64) *waterfallView {
	v := newWaterfallView(st, width, mark)
	v.centerHz, v.spanHz = fixtureCenterHz, fixtureSpanHz
	return v
}

// The style guide's first principle: colour and glyphs are redundant emphasis,
// so stripping the ink gives back the plain screen character for character.
// A waterfall carries level by hue, which is why the cell must also carry it as
// a texture -- with colour off the map has to still be readable.
func TestWaterfallStripsToPlain(t *testing.T) {
	bins := waterfallBins(1024, 512, -30, 3)
	for _, width := range []int{40, 80, 160} {
		for _, uni := range []bool{false, true} {
			plainV := newTestWaterfall(ui.Style{Unicode: uni, Width: width}, width, 146_620_000)
			inkV := newTestWaterfall(ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: uni, Width: width}, width, 146_620_000)
			cols := plainV.cols(len(bins))
			plainV.setScale(columnLevels(bins, cols))
			inkV.setScale(columnLevels(bins, cols))
			for i := 0; i < 3; i++ {
				plain := plainV.row(bins, float64(i))
				styled := inkV.row(bins, float64(i))
				if ui.Strip(styled) != plain {
					t.Errorf("width %d unicode %v row %d:\n plain  %q\n styled %q", width, uni, i, plain, ui.Strip(styled))
				}
			}
			all := append(plainV.header(cols), plainV.axis(cols)...)
			all = append(all, plainV.key()...)
			for _, l := range all {
				if ui.Strip(l) == "" && l != "" {
					t.Errorf("width %d: a line that is only ink: %q", width, l)
				}
			}
		}
	}
}

// Every line fits the resolved width, at both extremes and in both alphabets.
func TestWaterfallFitsWidth(t *testing.T) {
	bins := waterfallBins(1024, 700, -20, 5)
	for _, width := range []int{40, 80, 160} {
		for _, uni := range []bool{false, true} {
			v := newTestWaterfall(ui.Style{Unicode: uni, Width: width}, width, 146_620_000)
			cols := v.cols(len(bins))
			v.setScale(columnLevels(bins, cols))
			lines := append([]string{}, v.header(cols)...)
			lines = append(lines, v.key()...)
			lines = append(lines, v.axis(cols)...)
			lines = append(lines, v.row(bins, 1), v.gapRow(7))
			for _, l := range lines {
				if got := ui.Visible(l); got > width {
					t.Errorf("width %d unicode %v: a line of %d columns: %q", width, uni, got, ui.Strip(l))
				}
			}
		}
	}
}

// A dropped row draws its own line. Delivery is GAP_MARKED, and a gap that is
// not drawn compresses time: a transmission would look shorter than it was,
// and transmission length is what this view shows.
func TestWaterfallDrawsAGap(t *testing.T) {
	v := newTestWaterfall(ui.Style{Unicode: true, Width: 80}, 80, 0)
	got := ui.Strip(v.gapRow(7))
	if !strings.Contains(got, "7 rows") || !strings.Contains(got, "lost") {
		t.Errorf("a gap must say how many rows went missing, got %q", got)
	}
	if one := ui.Strip(v.gapRow(1)); !strings.Contains(one, "1 row ") {
		t.Errorf("one row is singular, got %q", one)
	}
}

// The scale is chosen once and held. If it moved, the same signal would change
// shade because something else on the band got louder, and two rows could not
// be compared.
func TestWaterfallScaleIsHeld(t *testing.T) {
	v := newTestWaterfall(ui.Style{Unicode: true, Width: 80}, 80, 0)
	quiet := waterfallBins(1024, -1, 0, 7)
	cols := v.cols(len(quiet))
	v.setScale(columnLevels(quiet, cols))
	first := v.floor
	if math.IsNaN(first) {
		t.Fatal("the first row must choose a floor")
	}
	loud := waterfallBins(1024, 512, 0, 8)
	for i := range loud {
		loud[i] += 40
	}
	v.setScale(columnLevels(loud, cols))
	if v.floor != first {
		t.Errorf("the floor moved from %v to %v", first, v.floor)
	}
}

// The floor draws as blank, so an empty band shows the terminal's own
// background and only what is above the floor takes ink. That is the same
// reasoning that made ley spectrum a trace rather than a fill.
func TestWaterfallQuietBandIsMostlyBlank(t *testing.T) {
	v := newTestWaterfall(ui.Style{Unicode: true, Width: 100}, 100, 0)
	quiet := waterfallBins(1024, -1, 0, 11)
	cols := v.cols(len(quiet))
	v.setScale(columnLevels(quiet, cols))
	row := ui.Strip(v.row(quiet, 0))
	body := row[strings.IndexRune(row, '│')+len("│"):]
	inked := 0
	for _, r := range body {
		if r != ' ' {
			inked++
		}
	}
	if inked > cols/10 {
		t.Errorf("a band with nothing on it inked %d of %d cells:\n%q", inked, cols, body)
	}
	// A carrier well over the floor is unmistakable on the same scale.
	loud := waterfallBins(1024, 512, -40, 12)
	if got := ui.Strip(v.row(loud, 1)); !strings.Contains(got, "█") {
		t.Errorf("a carrier 40 dB over the floor draws at full density, got:\n%q", got)
	}
}

// The header states how much band a column covers, because that is the
// difference between a picture of a signal and a map of where energy is.
func TestWaterfallHeaderStatesColumnBandwidth(t *testing.T) {
	v := newTestWaterfall(ui.Style{Unicode: true, Width: 100}, 100, 0)
	cols := v.cols(1024)
	v.setScale(columnLevels(waterfallBins(1024, -1, 0, 13), cols))
	head := strings.Join(v.header(cols), "\n")
	if !strings.Contains(ui.Strip(head), "columns of") {
		t.Errorf("the header must say what a column covers:\n%s", ui.Strip(head))
	}
	if v.binWidthHz(cols) == 0 {
		t.Error("a column covers some bandwidth")
	}
}

// The legend is there so a reader can match a cell's shade to a dB step, so a
// swatch has to be inked exactly the way the map inks the cell it stands for.
// Dimming it shows a shade the map never draws.
func TestWaterfallKeySwatchMatchesTheMap(t *testing.T) {
	st := ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: true, Width: 80}
	v := newTestWaterfall(st, 80, 146_620_000)
	key := strings.Join(v.key(), "\n")
	g := []rune(st.Glyphs().Shade)
	for i := 1; i < len(g); i++ {
		frac := float64(i) / float64(len(g)-1)
		want := st.Level(frac, string(g[i]))
		if !strings.Contains(key, want) {
			t.Errorf("swatch %d is not the map's ink\n key  %q\n want %q", i, key, want)
		}
		if strings.Contains(key, st.Muted(want)) {
			t.Errorf("swatch %d is dimmed, so it does not match the map: %q", i, key)
		}
	}
}

// Against a daemon: waterfall asks for ROW_MAX because a burst shorter than a row must still be
// drawn, and it says so once the daemon has answered with the looks it took. The claim is the
// daemon's, not the CLI's: printing it without asking would describe DSP the client does not
// control.
func TestWaterfallSaysHowManyLooksARowIs(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, context.Background(), sock, "waterfall", "146.52", "--count", "3", "--width", "60", "--rate", "10")
	if err != nil {
		t.Fatalf("waterfall: %v\n%s\n%s", err, out, errOut)
	}
	if !strings.Contains(errOut, "each row is the loudest of 64 looks across its interval") {
		t.Errorf("waterfall should state the look count the daemon answered:\n%s", errOut)
	}
	if strings.Count(out, "\n") < 3 {
		t.Errorf("expected rows:\n%s", out)
	}
}

// `waterfall --json` is the row feed, not the map: NDJSON in the bulk-row shape
// plus the look count, and nothing drawn.
func TestWaterfallJSONRows(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, _, err := run(t, context.Background(), sock, "--json", "waterfall", "146.52", "--count", "3", "--rate", "10", "--bins", "64")
	if err != nil {
		t.Fatalf("waterfall --json: %v\n%s", err, out)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 3 {
		t.Fatalf("want 3 rows, got %d:\n%s", len(lines), out)
	}
	for _, l := range lines {
		var row WaterfallRow
		if err := json.Unmarshal([]byte(l), &row); err != nil {
			t.Fatalf("row is not JSON: %v %s", err, l)
		}
		if row.Seq == 0 || row.CenterHz == 0 || len(row.Bins) == 0 {
			t.Errorf("row is missing the bulk-row fields: %s", l)
		}
		if row.Looks != 64 {
			t.Errorf("every row carries the daemon's look count, got %d: %s", row.Looks, l)
		}
	}
	if strings.ContainsAny(ui.Strip(out), "#") {
		t.Errorf("--json must not draw the map:\n%s", out)
	}
}
