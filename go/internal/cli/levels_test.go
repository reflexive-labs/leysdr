package cli

import (
	"context"
	"encoding/json"
	"math"
	"strconv"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/ui"
)

// levelsTestFrame is one still of the meter with every band at a level of its
// own: a ramp across the bands so the picture shows the scale as well as the
// ladders, a cap 6 dB over each bar, and a master pair from the daemon.
func levelsTestFrame(v *levelsView) levelsFrame {
	f := levelsFrame{
		bands: make([]levelsBar, len(v.bands)),
		rms:   newLevelsBar(), peak: newLevelsBar(),
		rmsDb: -18, peakDb: -9, tap: leylinev1.AudioTap_TAP_DEMOD,
		what: "147.435 MHz NFM", squelchOpen: true, squelchKnown: true,
	}
	for i := range f.bands {
		db := -58 + float64(i)*6
		f.bands[i] = levelsBar{db: db, cap: db + 6}
	}
	f.rms = levelsBar{db: f.rmsDb, cap: f.rmsDb + 3}
	f.peak = levelsBar{db: f.peakDb, cap: f.peakDb + 3}
	return f
}

// The still frame, in both alphabets: nine ladders climbing the scale with
// their caps over them, the dark segments under the unlit part, the -18 dBFS
// horizon dashed across, and the master pair beyond its gap with the daemon's
// numbers under it. Strip the styling and the two pictures are the same
// screen, which is the guide's identity rule.
const (
	levelsStillUnicode = `147.435 MHz NFM  tap demod  squelch open
  0 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
 -6 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ━━━     ░░░   ━━━
    │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ━━━   ▃▃▃     ░░░   ▅▅▅
-12 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ███     ━━━   ███
-18 │░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ━━━ ─ ▆▆▆ ─ ███ ─ ─ ▂▂▂ ─ ███
    │░░░   ░░░   ░░░   ░░░   ░░░   ━━━   ▂▂▂   ███   ███     ███   ███
-24 │░░░   ░░░   ░░░   ░░░   ━━━   ░░░   ███   ███   ███     ███   ███
-30 │░░░   ░░░   ░░░   ━━━   ▁▁▁   ███   ███   ███   ███     ███   ███
-40 │░░░   ░░░   ━━━   ▁▁▁   ███   ███   ███   ███   ███     ███   ███
    │░░░   ━━━   ▂▂▂   ███   ███   ███   ███   ███   ███     ███   ███
-50 │━━━   ▂▂▂   ███   ███   ███   ███   ███   ███   ███     ███   ███
-60 │▃▃▃   ███   ███   ███   ███   ███   ███   ███   ███     ███   ███
    ──────────────────────────────────────────────────────────│─────│────
     63    125   250   500   1k    2k    4k    8k    16k Hz  rms  peak
                                                             -18   -9  dBFS
`
	levelsStillASCII = `147.435 MHz NFM  tap demod  squelch open
  0 |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
 -6 |...   ...   ...   ...   ...   ...   ...   ...   ===     ...   ===
    |...   ...   ...   ...   ...   ...   ...   ===   ---     ...   +++
-12 |...   ...   ...   ...   ...   ...   ...   ...   %%%     ===   %%%
-18 |... - ... - ... - ... - ... - ... - === - *** - %%% - - ::: - %%%
    |...   ...   ...   ...   ...   ===   :::   %%%   %%%     %%%   %%%
-24 |...   ...   ...   ...   ===   ...   %%%   %%%   %%%     %%%   %%%
-30 |...   ...   ...   ===   ...   %%%   %%%   %%%   %%%     %%%   %%%
-40 |...   ...   ===   ...   %%%   %%%   %%%   %%%   %%%     %%%   %%%
    |...   ===   :::   %%%   %%%   %%%   %%%   %%%   %%%     %%%   %%%
-50 |===   :::   %%%   %%%   %%%   %%%   %%%   %%%   %%%     %%%   %%%
-60 |---   %%%   %%%   %%%   %%%   %%%   %%%   %%%   %%%     %%%   %%%
    ----------------------------------------------------------|-----|----
     63    125   250   500   1k    2k    4k    8k    16k Hz  rms  peak
                                                             -18   -9  dBFS
`
)

func TestLevelsStillFrame(t *testing.T) {
	for _, tc := range []struct {
		name   string
		st     ui.Style
		golden string
	}{
		{"unicode", ui.Style{Unicode: true}, levelsStillUnicode},
		{"ascii", ui.Style{}, levelsStillASCII},
	} {
		t.Run(tc.name, func(t *testing.T) {
			v := newLevelsView(tc.st, 80, levelsHeight, false, false)
			if got := v.render(levelsTestFrame(v)); got != tc.golden {
				t.Errorf("the meter differs from the golden\n--- want\n%s\n--- got\n%s", tc.golden, got)
			}
		})
	}
	// Colour is ink over the same screen and never a different one.
	v := newLevelsView(ui.Style{Unicode: true, Color: true, Profile: ui.ProfileTrueColor}, 80, levelsHeight, false, false)
	if got := ui.Strip(v.render(levelsTestFrame(v))); got != levelsStillUnicode {
		t.Errorf("the inked meter strips to a different picture\n--- want\n%s\n--- got\n%s", levelsStillUnicode, got)
	}
}

// A shut squelch is passing nothing, so the ladders are drawn unlit whatever
// the spectrum behind them says and the header says which. Both alphabets,
// because a person reading the ASCII screen has the same question.
const (
	levelsClosedUnicode = `147.435 MHz NFM  tap demod  squelch closed
  0 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
 -6 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
    │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-12 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-18 │░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ─ ░░░ ─ ░░░
    │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-24 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-30 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-40 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
    │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-50 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-60 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
    ──────────────────────────────────────────────────────────│─────│────
     63    125   250   500   1k    2k    4k    8k    16k Hz  rms  peak
                                                             -18   -9  dBFS
`
	levelsClosedASCII = `147.435 MHz NFM  tap demod  squelch closed
  0 |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
 -6 |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
    |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
-12 |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
-18 |... - ... - ... - ... - ... - ... - ... - ... - ... - - ... - ...
    |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
-24 |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
-30 |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
-40 |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
    |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
-50 |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
-60 |...   ...   ...   ...   ...   ...   ...   ...   ...     ...   ...
    ----------------------------------------------------------|-----|----
     63    125   250   500   1k    2k    4k    8k    16k Hz  rms  peak
                                                             -18   -9  dBFS
`
)

func TestLevelsSquelchClosedDrawsNothingLit(t *testing.T) {
	for _, tc := range []struct {
		name   string
		st     ui.Style
		golden string
	}{
		{"unicode", ui.Style{Unicode: true}, levelsClosedUnicode},
		{"ascii", ui.Style{}, levelsClosedASCII},
	} {
		t.Run(tc.name, func(t *testing.T) {
			v := newLevelsView(tc.st, 80, levelsHeight, false, false)
			f := levelsTestFrame(v)
			f.squelchOpen = false
			if got := v.render(f); got != tc.golden {
				t.Errorf("the shut-squelch meter differs from the golden\n--- want\n%s\n--- got\n%s", tc.golden, got)
			}
		})
	}
	// A squelch nobody has reported yet is not a shut one: until the daemon's
	// first meter the bands are drawn as they are measured.
	v := newLevelsView(ui.Style{Unicode: true}, 80, levelsHeight, false, false)
	f := levelsTestFrame(v)
	f.squelchOpen, f.squelchKnown = false, false
	if got := v.render(f); strings.Contains(got, "squelch") || got == levelsClosedUnicode {
		t.Errorf("an unreported squelch drew the shut picture:\n%s", got)
	}
}

// A shut squelch moves nothing: the bars stay where the last open row left
// them rather than following the noise the detector is still putting out, and
// a snapshot is the row as measured, with no cap over it.
func TestLevelsFrameAdvance(t *testing.T) {
	const dt = 50 * time.Millisecond
	f := levelsFrame{bands: []levelsBar{newLevelsBar()}, rms: newLevelsBar(), peak: newLevelsBar()}
	f.rmsDb, f.peakDb = -20, -12
	f.squelchOpen, f.squelchKnown = true, true
	f.advance([]float64{-30}, dt, true)
	if f.bands[0].db != -30 || f.rms.db != -20 {
		t.Fatalf("an open row left the bars at %.1f/%.1f, want -30 and -20", f.bands[0].db, f.rms.db)
	}
	f.squelchOpen = false
	f.advance([]float64{-10}, dt, true)
	if f.bands[0].db != -30 || f.bands[0].cap != -30 {
		t.Errorf("a shut squelch moved the bar to %.1f/%.1f, want it left at -30", f.bands[0].db, f.bands[0].cap)
	}
	// A still has no ballistics at all: the level, and no cap hanging over it.
	f.squelchOpen = true
	f.advance([]float64{-45}, dt, false)
	if f.bands[0].db != -45 || f.bands[0].cap != scopeMinDbfs {
		t.Errorf("the still drew %.1f with a cap at %.1f, want -45 and no cap", f.bands[0].db, f.bands[0].cap)
	}
	// An overload is a fact about the row, so a still says so too.
	f.advance([]float64{0.5}, dt, false)
	if f.bands[0].over <= 0 {
		t.Errorf("a still of a band at full scale does not light OVER")
	}
}

// The scale is a meter's: 6 dB a row where a voice lives, 10 dB a row down to
// the floor, held whatever the signal does. The marks are what a person reads
// a bar against, so each of them must land on a row of its own at the default
// height.
func TestLevelsScaleIsAMetersNotACharts(t *testing.T) {
	if got := levelsFrac(levelsTopDb); got != 1 {
		t.Errorf("full scale is %.3f of the height, want 1", got)
	}
	if got := levelsFrac(levelsFloorDb); got != 0 {
		t.Errorf("the floor is %.3f of the height, want 0", got)
	}
	// Four 6 dB rows from 0 to -24 and 3.6 ten dB rows below it: seven and a
	// half of the meter's own rows in all, so -24 sits a little under halfway.
	for _, tc := range []struct {
		db, want float64
	}{
		{0, 1},
		{-6, 6.6 / 7.6},
		{-12, 5.6 / 7.6},
		{-18, 4.6 / 7.6},
		{-24, 3.6 / 7.6},
		{-34, 2.6 / 7.6},
		{-60, 0},
	} {
		if got := levelsFrac(tc.db); math.Abs(got-tc.want) > 0.001 {
			t.Errorf("levelsFrac(%g) = %.4f, want %.4f", tc.db, got, tc.want)
		}
	}
	// A level past either end is drawn at the end rather than off the picture.
	if got := levelsFrac(12); got != 1 {
		t.Errorf("levelsFrac(+12) = %.3f, want the top of the scale", got)
	}
	if got := levelsFrac(-200); got != 0 {
		t.Errorf("levelsFrac(-200) = %.3f, want the floor", got)
	}
	v := newLevelsView(ui.Style{Unicode: true}, 80, levelsHeight, false, false)
	seen := map[int]float64{}
	for _, m := range levelsMarks {
		r := v.markRow(m)
		if prev, dup := seen[r]; dup {
			t.Errorf("%g dBFS and %g dBFS share row %d", prev, m, r)
		}
		seen[r] = m
	}
	if got, want := v.markRow(0), 0; got != want {
		t.Errorf("0 dBFS is on row %d, want the top row", got)
	}
	if got, want := v.markRow(levelsFloorDb), levelsHeight-1; got != want {
		t.Errorf("%g dBFS is on row %d, want the bottom row %d", levelsFloorDb, got, want)
	}
	// The horizon is a row of its own, not the one -12 or -24 is written on.
	if r := v.markRow(levelsHorizonDb); r == v.markRow(-12) || r == v.markRow(-24) {
		t.Errorf("the -18 dBFS horizon shares a row with its neighbours (row %d)", r)
	}
}

// Ballistics shape the bars and nothing else: instant attack, a slow release,
// and a cap that hangs before it falls.
func TestLevelsBallistics(t *testing.T) {
	const frame = 50 * time.Millisecond
	b := newLevelsBar()
	b.update(-20, frame)
	if b.db != -20 || b.cap != -20 {
		t.Fatalf("after one frame the bar is at %.1f/%.1f, want -20 both: attack is instant", b.db, b.cap)
	}
	// Release is 20 dB a second: a second of silence takes the bar down 20 dB
	// and no further than the level it is following.
	for range 20 {
		b.update(-60, frame)
	}
	if math.Abs(b.db+40) > 0.01 {
		t.Errorf("a second after the sound stopped the bar is at %.2f dB, want -40 (20 dB a second)", b.db)
	}
	if b.cap != -20 {
		t.Errorf("the cap is at %.2f dB a second after the peak, want it still hanging at -20", b.cap)
	}
	// It hangs for a second and a half and then falls at 10 dB a second, so
	// another second leaves it half a second's fall below where it hung.
	for range 20 {
		b.update(-60, frame)
	}
	if math.Abs(b.cap+25) > 0.01 {
		t.Errorf("the cap is at %.2f dB, want -25: 1.5 s of hold then 10 dB a second", b.cap)
	}
	// A louder row takes both up at once, wherever they were.
	b.update(-3, frame)
	if b.db != -3 || b.cap != -3 {
		t.Errorf("a louder row left the bar at %.1f/%.1f, want -3 both", b.db, b.cap)
	}
	// Full scale latches OVER for two seconds, because a flash too short to
	// read is the same as no warning at all.
	b.update(0.5, frame)
	if b.over != levelsOverHold {
		t.Errorf("a row at full scale latched %v of OVER, want %v", b.over, levelsOverHold)
	}
	for range 39 {
		b.update(-20, frame)
	}
	if b.over <= 0 {
		t.Errorf("OVER went out after %v, want it to hold %v", 39*frame, levelsOverHold)
	}
	b.update(-20, frame)
	if b.over != 0 {
		t.Errorf("OVER is still lit %v after the overload, want it out", levelsOverHold)
	}
}

// Bands are sums of bins in power corrected for the window, which is the only
// way to add levels: two equal bins carry twice the energy of one and read
// 3 dB over it, and a tone standing alone in a band reads as itself.
func TestLevelsBandSumsInPower(t *testing.T) {
	const binHz = 10.0
	// A row of a hundred bins at -90 dB with a -20 dB tone at 500 Hz, drawn as
	// the daemon's Hann window leaves it: the peak bin at the tone's own level
	// and a quarter of the power in each neighbour.
	row := make([]float64, 100)
	for i := range row {
		row[i] = -90
	}
	row[49], row[50], row[51] = -26.02, -20, -26.02
	bands := levelsBands([]float64{500}, levelsOctaveEdge)
	// The band runs 354 to 707 Hz: the tone plus 35 bins of floor, which the
	// tone stands 55 dB clear of. Its three bins add to one and a half times
	// its power, which is what the window correction takes back out.
	if got := levelsBandDb(row, binHz, bands[0]); math.Abs(got+20) > 0.1 {
		t.Errorf("the 500 Hz band reads %.2f dB, want the tone's -20", got)
	}
	// Two equal bins in one band are twice the energy: 3 dB over either, less
	// the 1.76 dB the window spread them by.
	flat := make([]float64, 100)
	for i := range flat {
		flat[i] = -120
	}
	flat[50], flat[51] = -40, -40
	if got := levelsBandDb(flat, binHz, bands[0]); math.Abs(got+38.75) > 0.01 {
		t.Errorf("two equal bins read %.2f dB, want -38.75 (3 dB over either, 1.76 dB off for the window)", got)
	}
	// A band narrower than a bin still has a level: the bin its centre falls
	// in, because a blank bar would read as silence rather than as a row too
	// coarse to split.
	narrow := levelsBands([]float64{63}, levelsThirdEdge)
	if got := levelsBandDb(row, 40, narrow[0]); math.Abs(got+91.76) > 0.01 {
		t.Errorf("a band narrower than a bin reads %.2f dB, want the corrected bin's -91.76", got)
	}
	// And it is corrected like every other band, so a run of bands too narrow
	// to split does not step against the wider ones beside them on one floor.
	// 63 and 100 each hold one bin of the 23 Hz row; 80 falls between the two
	// and borrows the nearer one.
	third := levelsBands([]float64{63, 80, 100}, levelsThirdEdge)
	for i := 1; i < len(third); i++ {
		a, b := levelsBandDb(flat, 23, third[i-1]), levelsBandDb(flat, 23, third[i])
		if math.Abs(a-b) > 0.01 {
			t.Errorf("on a flat floor the %s and %s bands read %.2f and %.2f dB, want no step between them",
				levelsBandLabel(third[i-1].centerHz), levelsBandLabel(third[i].centerHz), a, b)
		}
	}
	// Digital silence has no level, and a row carrying negative infinity is
	// not JSON.
	if got := levelsBandDb(make([]float64, 8), 0, bands[0]); got != scopeMinDbfs {
		t.Errorf("a row with no bin spacing reads %.2f, want the scale to stop at %d", got, scopeMinDbfs)
	}
}

// The band labels are the centres an equaliser writes, not the numbers a
// computer would.
func TestLevelsBandLabels(t *testing.T) {
	for _, tc := range []struct{ hz, want string }{
		{"63", "63"}, {"1000", "1k"}, {"1250", "1.25k"}, {"16000", "16k"},
	} {
		hz, _ := strconv.ParseFloat(tc.hz, 64)
		if got := levelsBandLabel(hz); got != tc.want {
			t.Errorf("levelsBandLabel(%s) = %q, want %q", tc.hz, got, tc.want)
		}
	}
}

// What the width takes away, in the order the design gives: the third-octave
// set needs a hundred columns, a narrow screen keeps the six bands speech
// lives in, and the master pair loses its words before it loses its numbers.
func TestLevelsWidthRules(t *testing.T) {
	st := ui.Style{Unicode: true}
	if n := len(newLevelsView(st, 120, levelsHeight, true, false).bands); n != len(levelsThirdHz) {
		t.Errorf("120 columns drew %d bands, want the %d third-octave ones", n, len(levelsThirdHz))
	}
	if n := len(newLevelsView(st, 90, levelsHeight, true, false).bands); n != len(levelsOctaveHz) {
		t.Errorf("90 columns drew %d bands with --bands third, want the %d octaves", n, len(levelsOctaveHz))
	}
	if n := len(newLevelsView(st, 40, levelsHeight, false, false).bands); n != len(levelsNarrowHz) {
		t.Errorf("40 columns drew %d bands, want the %d speech bands", n, len(levelsNarrowHz))
	}
	for _, tc := range []struct {
		width int
		lines int
		want  string
	}{
		{80, 2, "rms"},
		{levelsWordsCols - 1, 1, "-18"},
	} {
		v := newLevelsView(st, tc.width, levelsHeight, false, false)
		got := v.labels(levelsTestFrame(v))
		if len(got) != tc.lines {
			t.Errorf("at %d columns the master pair takes %d label lines, want %d:\n%s",
				tc.width, len(got), tc.lines, strings.Join(got, "\n"))
			continue
		}
		if lines := strings.Join(got, "\n"); !strings.Contains(lines, tc.want) {
			t.Errorf("at %d columns the labels are %q, want them to carry %q", tc.width, lines, tc.want)
		}
	}
	// Every picture stays inside the width it was given, whatever it drops.
	for _, width := range []int{40, 44, 60, 80, 100, 120, 160} {
		v := newLevelsView(st, width, levelsHeight, true, false)
		for _, line := range strings.Split(v.render(levelsTestFrame(v)), "\n") {
			if w := ui.Visible(line); w > width {
				t.Errorf("at %d columns a line is %d wide: %q", width, w, line)
			}
		}
	}
}

// Against the daemon: the bare verb is one still of the bands the fake's
// channel carries, and the header says what is being measured. The demod tap
// has the sub-audible tone in the 125 Hz band, where a 100 Hz PL falls.
func TestLevelsMetersTheDaemonsBands(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, context.Background(), sock, "levels", "145.23", "--tap", "demod")
	if err != nil {
		t.Fatalf("ley levels: %v\nstdout: %s\nstderr: %s", err, out, errOut)
	}
	for _, want := range []string{"145.230 MHz NFM", "tap demod", "squelch open", "PL 100.0 Hz", "rms", "peak", "dBFS"} {
		if !strings.Contains(out, want) {
			t.Errorf("the meter does not say %q:\n%s", want, out)
		}
	}
	if n := strings.Count(out, "tap demod"); n != 1 {
		t.Errorf("the bare verb drew %d frames, want the one still:\n%s", n, out)
	}
	// A still is not a live meter, so nothing counts frames under it.
	if strings.Contains(out, "frame ") {
		t.Errorf("the still carries a live meter's status line:\n%s", out)
	}
	if !strings.Contains(errOut, "metering 145.230 MHz NFM: the demod tap.") {
		t.Errorf("the prose on stderr does not say what is being metered:\n%s", errOut)
	}
}

// --watch is the meter itself: it keeps drawing until --count says stop, and
// the prose says what is happening and how to end it.
func TestLevelsWatchKeepsDrawing(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, context.Background(), sock, "levels", "145.23", "--watch", "--count", "3")
	if err != nil {
		t.Fatalf("ley levels --watch: %v\nstdout: %s\nstderr: %s", err, out, errOut)
	}
	if n := strings.Count(out, "tap audio"); n != 3 {
		t.Errorf("--count 3 drew %d frames:\n%s", n, out)
	}
	if !strings.Contains(errOut, "20 rows a second. Ctrl-C stops") {
		t.Errorf("the prose on stderr does not say the meter is live:\n%s", errOut)
	}
}

// The meter waits on its own rows and nothing else: a daemon whose meter
// telemetry is minutes apart still draws bands at the row rate, with the
// squelch line blank until the first meter says what it is doing.
func TestLevelsWatchDrawsBeforeTheFirstMeter(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: time.Minute})
	start := time.Now()
	out, _, err := run(t, context.Background(), sock, "levels", "145.23", "--watch", "--count", "3")
	if err != nil {
		t.Fatalf("ley levels --watch: %v\nstdout: %s", err, out)
	}
	if n := strings.Count(out, "tap audio"); n != 3 {
		t.Errorf("--count 3 drew %d frames without a meter to wait on:\n%s", n, out)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Errorf("three frames took %v, so the meter is waiting on telemetry rather than on rows", d)
	}
	if strings.Contains(out, "squelch open") || strings.Contains(out, "squelch closed") {
		t.Errorf("the header claims a squelch state no meter has reported:\n%s", out)
	}
}

// A squelch shut over the fake's signal: the header says so and every ladder
// is unlit, because the spectrum still arriving behind a shut squelch is not
// sound anybody heard.
func TestLevelsSquelchClosedAgainstTheDaemon(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, context.Background(), sock, "levels", "145.23", "--tap", "demod", "--squelch", "-10")
	if err != nil {
		t.Fatalf("ley levels --squelch -10: %v\nstdout: %s\nstderr: %s", err, out, errOut)
	}
	if !strings.Contains(out, "squelch closed") {
		t.Errorf("the header does not say the squelch is shut:\n%s", out)
	}
	// The ASCII ladder lights ':' through '%' and caps with '='; unlit is '.'.
	if strings.ContainsAny(out, ":%#*+=") {
		t.Errorf("a ladder is lit behind a shut squelch:\n%s", out)
	}
}

// --json is the daemon's own numbers, one object per row, before any of the
// ballistics that shape the bars.
func TestLevelsJSONRows(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "--json", "levels", "145.23", "--tap", "demod", "--watch", "--count", "8")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 8 {
		t.Fatalf("--count 8 printed %d rows:\n%s", len(lines), out)
	}
	metered := 0
	for i, line := range lines {
		var row LevelsRow
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			t.Fatalf("row %d is not JSON (%v): %q", i, err, line)
		}
		if row.Tap != "demod" || len(row.Bands) != len(levelsOctaveHz) {
			t.Fatalf("row %d = tap %q with %d bands, want the demod tap and %d", i, row.Tap, len(row.Bands), len(levelsOctaveHz))
		}
		for j, b := range row.Bands {
			if b.CenterHz != levelsOctaveHz[j] {
				t.Errorf("row %d band %d is centred %g Hz, want %g", i, j, b.CenterHz, levelsOctaveHz[j])
			}
			if math.IsNaN(b.Db) || b.Db <= scopeMinDbfs {
				t.Errorf("row %d band %g Hz has no level: %v", i, b.CenterHz, b.Db)
			}
		}
		// The fake's channel carries a 1 kHz stand-in for the voice and a
		// 100 Hz PL on the demod tap: those two bands stand clear of the rest.
		loudest, at := math.Inf(-1), 0.0
		for _, b := range row.Bands {
			if b.Db > loudest {
				loudest, at = b.Db, b.CenterHz
			}
		}
		if at != 1000 {
			t.Errorf("row %d is loudest in the %g Hz band, want 1 kHz", i, at)
		}
		if pl := row.Bands[1]; pl.CenterHz != 125 || pl.Db < row.Bands[2].Db {
			t.Errorf("row %d has no PL standing in the 125 Hz band: %+v", i, row.Bands)
		}
		// The master pair is the daemon's meter, which a row that arrived
		// before the first one has nothing to say about.
		if row.RmsDbfs == nil || row.PeakDbfs == nil {
			continue
		}
		metered++
		if *row.PeakDbfs < *row.RmsDbfs {
			t.Errorf("row %d master pair = rms %.1f peak %.1f, want the peak at or over the rms", i, *row.RmsDbfs, *row.PeakDbfs)
		}
	}
	if metered == 0 {
		t.Errorf("no row carried the daemon's meter:\n%s", out)
	}
	// Without --watch the row the still would have been drawn from is the
	// whole output, and it says what the squelch was doing.
	snap := mustRun(t, sock, "--json", "levels", "145.23", "--tap", "demod")
	if n := strings.Count(strings.TrimSpace(snap), "\n"); n != 0 {
		t.Fatalf("the bare verb printed %d rows, want the one:\n%s", n+1, snap)
	}
	var row LevelsRow
	if err := json.Unmarshal([]byte(snap), &row); err != nil {
		t.Fatalf("the snapshot row is not JSON (%v): %q", err, snap)
	}
	if row.SquelchOpen == nil || !*row.SquelchOpen {
		t.Errorf("the snapshot row does not carry the open squelch: %s", snap)
	}
}

// Every flag that takes a word or a range says what it accepts, and says it
// before anything reaches the daemon.
func TestLevelsUsageErrors(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"levels"}, "levels needs a frequency, preset or channel id"},
		{[]string{"levels", "146.52", "--tap", "video"}, "--tap must be audio"},
		{[]string{"levels", "146.52", "--bands", "half"}, "--bands must be octave"},
		{[]string{"levels", "146.52", "--rate", "60"}, "--rate must be more than 0 and at most 20"},
		{[]string{"levels", "146.52", "--height", "2"}, "--height must be 6..24 rows"},
		{[]string{"levels", "chan_01J", "--mode", "am"}, "--mode cannot be used with a channel id"},
	} {
		t.Run(strings.Join(tc.args, " "), func(t *testing.T) {
			out, _, err := run(t, context.Background(), sock, tc.args...)
			if exitCode(err) != ExitUsage || err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("ley %v: exit %d (%v), want exit %d saying %q", tc.args, exitCode(err), err, ExitUsage, tc.want)
			}
			if out != "" {
				t.Errorf("a refused verb draws nothing, got:\n%s", out)
			}
		})
	}
}

// A raw-IQ channel has no audio at all, and the sentence a person reads is the
// daemon's own.
func TestLevelsRefusedOnRawIQ(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, _, err := run(t, context.Background(), sock, "levels", "146.52", "--mode", "raw", "--count", "1")
	if exitCode(err) != 1 {
		t.Fatalf("ley levels --mode raw: exit %d (%v), want 1", exitCode(err), err)
	}
	if out != "" {
		t.Errorf("a refused subscription draws nothing, got:\n%s", out)
	}
}

// The terminal's height is the limit, never the choice: a meter taller than
// the screen cannot be redrawn in place.
func TestLevelsFitHeight(t *testing.T) {
	if got := levelsFitHeight(levelsHeight, 0, false); got != levelsHeight {
		t.Errorf("an unknown terminal height gave %d rows, want the %d asked for", got, levelsHeight)
	}
	if got := levelsFitHeight(levelsHeight, 40, true); got != levelsHeight {
		t.Errorf("a tall terminal gave %d rows, want the %d asked for", got, levelsHeight)
	}
	if got := levelsFitHeight(levelsHeight, 14, false); got != 14-levelsChromeRows {
		t.Errorf("a 14-row terminal gave %d rows, want %d", got, 14-levelsChromeRows)
	}
	if got := levelsFitHeight(levelsHeight, 16, true); got != 16-levelsChromeRows-levelsBorderRows {
		t.Errorf("a framed 16-row terminal gave %d rows, want %d", got, 16-levelsChromeRows-levelsBorderRows)
	}
	if got := levelsFitHeight(levelsHeight, 6, false); got != levelsMinRows {
		t.Errorf("a tiny terminal gave %d rows, want the %d-row floor", got, levelsMinRows)
	}
}

// What the clamp promises is that the whole block --watch redraws — the meter,
// its frame and the status line under it — still leaves the row of headroom a
// redraw in place needs.
func TestLevelsFitHeightLeavesRoomToRedraw(t *testing.T) {
	for _, framed := range []bool{false, true} {
		for term := levelsChromeRows + levelsBorderRows + levelsMinRows; term <= 40; term++ {
			st := ui.Style{Unicode: true, Width: 100, Height: term}
			v := newLevelsView(st, 100, levelsFitHeight(levelsHeight, term, framed), false, framed)
			f := levelsTestFrame(v)
			// The latched overload row is the tallest the meter ever draws.
			f.peak.over = 1
			lines := strings.Count(v.render(f), "\n")
			if lines+2 > term {
				t.Errorf("framed=%v term=%d: %d rows of meter plus status leave no headroom",
					framed, term, lines)
			}
		}
	}
}
