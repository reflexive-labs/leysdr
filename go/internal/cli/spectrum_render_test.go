package cli

import (
	"math"
	"math/rand"
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/ui"
)

// spectrumFixture is a deterministic FFT row: a noise floor near -90 dBFS with
// a carrier at one bin, which is the shape every chart assertion here is about.
func spectrumFixture(n int, carrier int, carrierDb float64) []float64 {
	r := rand.New(rand.NewSource(7))
	bins := make([]float64, n)
	for i := range bins {
		bins[i] = -90 + r.Float64()*6
	}
	if carrier >= 0 && carrier < n {
		bins[carrier] = carrierDb
		if carrier > 0 {
			bins[carrier-1] = carrierDb - 30
		}
		if carrier+1 < n {
			bins[carrier+1] = carrierDb - 30
		}
	}
	return bins
}

const (
	fixtureCenterHz = 146_520_000
	fixtureSpanHz   = 2_400_000
)

// renderFixture draws one row through a fresh view.
func renderFixture(t *testing.T, st ui.Style, width int, mark uint64, hold bool, bins []float64) string {
	t.Helper()
	v := newSpectrumView(st, width, mark, hold, false)
	peaks := loudestBins(bins, fixtureCenterHz, fixtureSpanHz, spectrumPeaks, medianDb(bins)+peakAboveFloorDb)
	return v.render(bins, peaks, medianDb(bins), fixtureCenterHz, fixtureSpanHz) + v.nextStep(peaks)
}

// The mechanical proof of the style guide's first principle: colour and glyphs
// are redundant emphasis, so stripping the ink must give back the plain screen
// character for character.
func TestSpectrumStyledStripsToPlain(t *testing.T) {
	bins := spectrumFixture(1024, 640, -21)
	for _, width := range []int{40, 80, 160} {
		for _, mark := range []uint64{0, 146_620_000} {
			for _, unicode := range []bool{false, true} {
				plain := renderFixture(t, ui.Style{Unicode: unicode, Width: width}, width, mark, true, bins)
				styled := renderFixture(t, ui.Style{Color: true, Unicode: unicode, Width: width}, width, mark, true, bins)
				if got := ui.Strip(styled); got != plain {
					t.Errorf("width %d mark %d unicode %v: styled and plain differ\nplain:\n%s\nstripped:\n%s", width, mark, unicode, plain, got)
				}
				if !strings.Contains(styled, "\x1b[") {
					t.Errorf("width %d: nothing was inked at all", width)
				}
			}
		}
	}
}

// Every line of the chart fits the resolved width, in either alphabet, at the
// narrow, ordinary and wide ends of the clamp.
func TestSpectrumFitsWidth(t *testing.T) {
	bins := spectrumFixture(1024, 640, -21)
	for _, width := range []int{ui.MinWidth, 50, 72, ui.DefaultWidth, 120, ui.MaxWidth} {
		for _, st := range []ui.Style{{Width: width}, {Color: true, Unicode: true, Width: width}} {
			text := renderFixture(t, st, width, 146_620_000, false, bins)
			for _, l := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
				if w := ui.Visible(l); w > width {
					t.Errorf("width %d unicode %v: line of %d columns: %q", width, st.Unicode, w, ui.Strip(l))
				}
			}
		}
	}
}

// `ley spectrum 146.62` used to render byte-identically to a bare
// `ley spectrum`: the frequency the user typed was invisible.
func TestSpectrumMarksTheRequestedFrequency(t *testing.T) {
	bins := spectrumFixture(1024, 640, -21)
	st := ui.Style{Unicode: true, Width: 80}
	bare := renderFixture(t, st, 80, 0, false, bins)
	asked := renderFixture(t, st, 80, 146_620_000, false, bins)
	if bare == asked {
		t.Fatal("the frequency the user asked for must show on the chart")
	}
	if !strings.Contains(asked, "▲") || !strings.Contains(asked, "146.620 MHz") {
		t.Fatalf("no marker under the asked-for frequency:\n%s", asked)
	}
	// Off the band on screen: no marker, and certainly no panic.
	if off := renderFixture(t, st, 80, 99_000_000, false, bins); strings.Contains(off, "▲") {
		t.Fatalf("a frequency outside the band must not be marked:\n%s", off)
	}
	// ASCII keeps the meaning with the fallback glyph.
	if a := renderFixture(t, ui.Style{Width: 80}, 80, 146_620_000, false, bins); !strings.Contains(a, "^ 146.620 MHz") {
		t.Fatalf("ascii marker:\n%s", a)
	}
}

// The scale is frozen for the run: a quieter frame must not move it, and a
// louder one moves it once and says so.
func TestSpectrumScaleIsFrozen(t *testing.T) {
	v := newSpectrumView(ui.Style{Width: 80}, 80, 0, true, false)
	bins := spectrumFixture(1024, 640, -30)
	v.render(bins, nil, medianDb(bins), fixtureCenterHz, fixtureSpanHz)
	top, bottom := v.top, v.bottom
	if v.note() != "" {
		t.Fatal("the first frame chooses the scale, it does not re-scale")
	}
	quiet := spectrumFixture(1024, 640, -60)
	v.render(quiet, nil, medianDb(quiet), fixtureCenterHz, fixtureSpanHz)
	if v.top != top || v.bottom != bottom || v.note() != "" {
		t.Fatalf("a quieter frame must not contract the scale: %v..%v", v.bottom, v.top)
	}
	loud := spectrumFixture(1024, 640, -5)
	v.render(loud, nil, medianDb(loud), fixtureCenterHz, fixtureSpanHz)
	if v.top <= top {
		t.Fatalf("a louder frame must raise the top: %v then %v", top, v.top)
	}
	if !strings.Contains(v.note(), "scale now") {
		t.Fatalf("a re-scale must be visible, got %q", v.note())
	}
}

// noiseFrame is one frame of a band with nothing on it: a fresh draw of the
// same noise every time, which is what a receiver on a quiet band delivers.
func noiseFrame(seed int64, n int) []float64 {
	r := rand.New(rand.NewSource(seed))
	bins := make([]float64, n)
	for i := range bins {
		bins[i] = -90 + r.Float64()*6
	}
	return bins
}

// traceCells counts the chart's thin-line cells. The max-hold trace and the
// floor rule share a glyph, so the trace is measured by what it adds to the
// same frames drawn without it.
func traceCells(text string) int {
	return strings.Count(ui.Strip(text), "─")
}

// The max-hold trace keeps what has been seen, and only --watch asks for it.
func TestSpectrumMaxHold(t *testing.T) {
	st := ui.Style{Unicode: true, Width: 80}
	loud := spectrumFixture(1024, 200, -21)
	quiet := spectrumFixture(1024, -1, 0)
	v := newSpectrumView(st, 80, 0, true, false)
	v.render(loud, nil, medianDb(loud), fixtureCenterHz, fixtureSpanHz)
	text := v.render(quiet, nil, medianDb(quiet), fixtureCenterHz, fixtureSpanHz)
	one := newSpectrumView(st, 80, 0, false, false)
	one.render(loud, nil, medianDb(loud), fixtureCenterHz, fixtureSpanHz)
	bare := one.render(quiet, nil, medianDb(quiet), fixtureCenterHz, fixtureSpanHz)
	if traceCells(text) <= traceCells(bare) {
		t.Fatalf("the carrier that has gone should leave a hold trace:\n%s", text)
	}
	if strings.Contains(text, "░") {
		t.Fatalf("the hold is a thin line, not a filled block:\n%s", text)
	}
}

// The hold decays toward the live trace and is drawn only where it stands
// clear of it, so tens of frames of noise leave no ceiling. The running
// maximum this replaced ended up drawing the whole band as a wall above the
// live trace, which is what made a quiet band look busy.
func TestSpectrumMaxHoldDecaysOnNoise(t *testing.T) {
	st := ui.Style{Unicode: true, Width: 80}
	v := newSpectrumView(st, 80, 0, true, false)
	loud := spectrumFixture(1024, 200, -21)
	v.render(loud, nil, medianDb(loud), fixtureCenterHz, fixtureSpanHz)
	var text string
	var last []float64
	for seed := int64(1); seed <= 60; seed++ {
		last = noiseFrame(seed, 1024)
		text = v.render(last, nil, medianDb(last), fixtureCenterHz, fixtureSpanHz)
	}
	one := newSpectrumView(st, 80, 0, false, false)
	bare := one.render(last, nil, medianDb(last), fixtureCenterHz, fixtureSpanHz)
	if traceCells(text) > traceCells(bare) {
		t.Fatalf("noise must not accumulate into a held ceiling (%d line cells against %d):\n%s", traceCells(text), traceCells(bare), text)
	}
}

// Peaks are a detection list, not a padded top five: noise alone yields none,
// and one carrier yields exactly one entry with its margin above the floor.
func TestSpectrumPeaksAreHonest(t *testing.T) {
	noise := spectrumFixture(4096, -1, 0)
	floor := medianDb(noise)
	if peaks := loudestBins(noise, fixtureCenterHz, fixtureSpanHz, spectrumPeaks, floor+peakAboveFloorDb); len(peaks) != 0 {
		t.Fatalf("noise alone must not read as peaks: %+v", peaks)
	}
	bins := spectrumFixture(1024, 640, -21)
	floor = medianDb(bins)
	peaks := loudestBins(bins, fixtureCenterHz, fixtureSpanHz, spectrumPeaks, floor+peakAboveFloorDb)
	if len(peaks) != 1 {
		t.Fatalf("one carrier is one peak, not its shoulders too: %+v", peaks)
	}
	text := renderFixture(t, ui.Style{Width: 80}, 80, 0, false, bins)
	margin := fmtDb(peaks[0].Db-floor) + " dB above the floor"
	if !strings.Contains(text, margin) {
		t.Fatalf("want %q in:\n%s", margin, text)
	}
	if !strings.Contains(text, "tune with: ley tune "+megahertz(peaks[0].CenterHz)) {
		t.Fatalf("a one-shot ends with the command that acts on it:\n%s", text)
	}
	quiet := renderFixture(t, ui.Style{Width: 80}, 80, 0, false, noise)
	if !strings.Contains(quiet, "nothing above the floor") || strings.Contains(quiet, "tune with") {
		t.Fatalf("a quiet band says so and offers nothing to tune:\n%s", quiet)
	}
}

// The frequency axis names round numbers, as many as the width can label.
func TestSpectrumTicks(t *testing.T) {
	lo, hi := spectrumEdges(fixtureCenterHz, fixtureSpanHz)
	narrow := spectrumTicks(lo, hi, 30)
	wide := spectrumTicks(lo, hi, 150)
	if len(narrow) == 0 || len(wide) <= len(narrow) {
		t.Fatalf("tick count should grow with width: %d then %d", len(narrow), len(wide))
	}
	for _, ts := range [][]spectrumTick{narrow, wide} {
		for _, tk := range ts {
			if tk.hz%100_000 != 0 {
				t.Errorf("tick %d is not a round frequency", tk.hz)
			}
			if tk.hz < lo || tk.hz > hi {
				t.Errorf("tick %d is outside the band %d..%d", tk.hz, lo, hi)
			}
		}
	}
	if s := niceStep(1234); s != 2000 {
		t.Errorf("niceStep(1234) = %v, want 2000", s)
	}
}

// A chart of an empty row is still a chart: no panic, no NaN on screen.
func TestSpectrumEmptyRow(t *testing.T) {
	text := renderFixture(t, ui.Style{Width: 80}, 80, 0, false, nil)
	if strings.Contains(text, "NaN") || strings.Contains(text, "+Inf") {
		t.Fatalf("an empty row must not print arithmetic:\n%s", text)
	}
}

// Machine output stays out of styling's reach whatever the flags say, and
// binary records refuse to go to a terminal at all.
func TestSpectrumAndFFTMachineOutput(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	listening(t, c)
	for _, args := range [][]string{
		{"--json", "--color", "always", "spectrum", "--bins", "256"},
		{"--color", "always", "fft", "--count", "1", "--bins", "256"},
	} {
		if out := mustRun(t, sock, args...); strings.Contains(out, "\x1b") {
			t.Errorf("%v put an escape byte on stdout: %q", args, out)
		}
	}
	// A terminal gets a refusal with the redirect, not a screenful of binary.
	_, _, err := runApp(t, ttyApp(sock), "fft", "--format", "bin", "--count", "1")
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "redirect it") {
		t.Fatalf("--format bin on a terminal: exit %d %v", exitCode(err), err)
	}
	// Piped, it still writes its records byte for byte.
	if out := mustRun(t, sock, "fft", "--format", "bin", "--count", "1", "--bins", "256"); !strings.HasPrefix(out, FFTMagic) {
		t.Fatalf("piped --format bin must be unchanged, got %q", out[:min(16, len(out))])
	}
}

// megahertz writes what a person types back into ley.
func TestMegahertz(t *testing.T) {
	for hz, want := range map[uint64]string{146_624_000: "146.624", 101_100_000: "101.1", 162_550_000: "162.55", 7_000_000: "7"} {
		if got := megahertz(hz); got != want {
			t.Errorf("megahertz(%d) = %q, want %q", hz, got, want)
		}
	}
}

// Column levels carry the loudest bin they cover: a carrier must not average
// away into the noise when the band is folded into 70-odd columns.
func TestSpectrumColumnLevels(t *testing.T) {
	bins := spectrumFixture(1024, 640, -21)
	cols := columnLevels(bins, 70)
	if len(cols) != 70 {
		t.Fatalf("want 70 columns, got %d", len(cols))
	}
	best := math.Inf(-1)
	for _, c := range cols {
		best = math.Max(best, c)
	}
	if best != -21 {
		t.Fatalf("the carrier should survive folding, got %v", best)
	}
}

// renderFramed draws one row through a view that asked for the frame, which it
// keeps or drops on the style and the width alone.
func renderFramed(t *testing.T, st ui.Style, width int, bins []float64) string {
	t.Helper()
	v := newSpectrumView(st, width, 0, false, true)
	peaks := loudestBins(bins, fixtureCenterHz, fixtureSpanHz, spectrumPeaks, medianDb(bins)+peakAboveFloorDb)
	return v.render(bins, peaks, medianDb(bins), fixtureCenterHz, fixtureSpanHz)
}

// spectrumRamp is a row that climbs from the noise floor to a carrier, so the
// chart has a level for most of the ramp's steps to ink.
func spectrumRamp(n int) []float64 {
	bins := make([]float64, n)
	for i := range bins {
		bins[i] = -90 + 70*float64(i)/float64(n-1)
	}
	return bins
}

// inkRuns is every inked run of text in a rendered screen, as SGR parameters
// and the text they cover.
func inkRuns(text string) map[string][]string {
	runs := map[string][]string{}
	for _, part := range strings.Split(text, "\x1b[")[1:] {
		i := strings.Index(part, "m")
		if i < 0 {
			continue
		}
		params, rest := part[:i], part[i+1:]
		if params == "0" {
			continue
		}
		if j := strings.Index(rest, "\x1b"); j >= 0 {
			rest = rest[:j]
		}
		runs[params] = append(runs[params], rest)
	}
	return runs
}

// levelSGR is the parameters Level emits for one point of the ramp.
func levelSGR(st ui.Style, frac float64) string {
	s := st.Level(frac, "x")
	return strings.TrimSuffix(strings.SplitN(s, "x", 2)[0], "m")[len("\x1b["):]
}

// Every column is inked by its own level, so a band that climbs from the noise
// floor to a carrier reads by hue as well as by height. The three-band
// Muted/plain/Ok inking this replaced collapsed to plain across most of a live
// band.
func TestSpectrumColoursByLevel(t *testing.T) {
	st := ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: true, Width: 80}
	text := renderFixture(t, st, 80, 0, false, spectrumRamp(1024))
	colours := map[string]bool{}
	for params := range inkRuns(text) {
		if strings.HasPrefix(params, "38;2;") {
			colours[params] = true
		}
	}
	if len(colours) < 5 {
		t.Fatalf("a band that climbs 70 dB should take several ramp inks, got %d:\n%s", len(colours), text)
	}
	// The ends of the ramp are the ends of the scale: the floor is cold, the
	// loudest column is hot.
	cold, hot := levelSGR(st, 0), levelSGR(st, 1)
	if cold == hot {
		t.Fatal("the ramp must ink the floor and the peak differently")
	}
	for _, want := range []string{cold, hot} {
		if _, ok := inkRuns(text)[want]; !ok {
			t.Errorf("no run inked %q in:\n%s", want, text)
		}
	}
	// Colour off is still a chart: the block ramp does the same job.
	if plain := renderFixture(t, ui.Style{Unicode: true, Width: 80}, 80, 0, false, spectrumRamp(1024)); strings.Contains(plain, "\x1b") {
		t.Errorf("colour off must emit no ink:\n%q", plain)
	}
}

// The max-hold trace keeps its dim treatment now that the live trace is
// coloured: what has been is faint scaffolding, what is on the air is hue.
func TestSpectrumMaxHoldStaysDim(t *testing.T) {
	st := ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: true, Width: 80}
	v := newSpectrumView(st, 80, 0, true, false)
	loud := spectrumFixture(1024, 200, -21)
	v.render(loud, nil, medianDb(loud), fixtureCenterHz, fixtureSpanHz)
	quiet := spectrumFixture(1024, -1, 0)
	text := v.render(quiet, nil, medianDb(quiet), fixtureCenterHz, fixtureSpanHz)
	// The floor rule shares the trace's glyph and its ink, so the row under
	// test is one the same frames draw no line on without the hold.
	one := newSpectrumView(st, 80, 0, false, false)
	one.render(loud, nil, medianDb(loud), fixtureCenterHz, fixtureSpanHz)
	bare := strings.Split(one.render(quiet, nil, medianDb(quiet), fixtureCenterHz, fixtureSpanHz), "\n")
	held := false
	for i, l := range strings.Split(text, "\n") {
		if !strings.Contains(ui.Strip(l), "─") || (i < len(bare) && strings.Contains(ui.Strip(bare[i]), "─")) {
			continue
		}
		held = true
		for params, runs := range inkRuns(l) {
			for _, run := range runs {
				if strings.Contains(run, "─") && params != "2" {
					t.Errorf("the hold trace was inked %q, want the dim ink:\n%s", params, text)
				}
			}
		}
	}
	if !held {
		t.Fatalf("the carrier that has gone should leave an inked hold trace:\n%s", text)
	}
}

// The peak list carries the same ramp ink the chart gave that level, so the
// chart and the list agree about what is hot.
func TestSpectrumPeakListTakesRampInk(t *testing.T) {
	st := ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: true, Width: 80}
	bins := spectrumFixture(1024, 640, -21)
	v := newSpectrumView(st, 80, 0, false, false)
	peaks := loudestBins(bins, fixtureCenterHz, fixtureSpanHz, spectrumPeaks, medianDb(bins)+peakAboveFloorDb)
	text := v.render(bins, peaks, medianDb(bins), fixtureCenterHz, fixtureSpanHz)
	want := levelSGR(st, levelFrac(v.levelBand(peaks[0].Db)))
	line := ""
	for _, l := range strings.Split(text, "\n") {
		if strings.Contains(ui.Strip(l), "peak") {
			line = l
		}
	}
	if !strings.Contains(line, "\x1b["+want+"m"+fmtDb(peaks[0].Db)) {
		t.Errorf("the peak's level is not inked with the chart's ramp (%q):\n%q", want, line)
	}
	// The margin and the frequency stay as they were: only the level ramps.
	if !strings.Contains(ui.Strip(line), "-21 dBFS") {
		t.Errorf("stripped peak line = %q", ui.Strip(line))
	}
}

// A terminal wide enough gets the chart in a frame, with the header inside it
// and the peak list outside; a pipe, --ascii and a cramped screen do not.
func TestSpectrumFrame(t *testing.T) {
	bins := spectrumFixture(1024, 640, -21)
	st := ui.Style{Unicode: true, Width: 100}
	text := renderFramed(t, st, 100, bins)
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	if !strings.HasPrefix(lines[0], "╭") || !strings.HasSuffix(lines[0], "╮") {
		t.Fatalf("the chart is not framed:\n%s", text)
	}
	if !strings.HasPrefix(lines[1], "│") || !strings.Contains(lines[1], "146.520 MHz") {
		t.Errorf("the header belongs inside the frame, got %q", lines[1])
	}
	closed := -1
	for i, l := range lines {
		if strings.HasPrefix(l, "╰") {
			closed = i
		}
	}
	if closed < 0 || closed == len(lines)-1 {
		t.Fatalf("the frame must close above the peak list:\n%s", text)
	}
	for _, l := range lines[closed+1:] {
		if strings.Contains(l, "│") {
			t.Errorf("the peak list is outside the frame, got %q", l)
		}
	}
	// Piped, ASCII and narrow all draw the chart bare.
	for _, tc := range []struct {
		name  string
		style ui.Style
		width int
		frame bool
	}{
		{"piped", ui.Style{Unicode: true, Width: 100}, 100, false},
		{"ascii", ui.Style{Width: 100}, 100, true},
		{"narrow", ui.Style{Unicode: true, Width: spectrumFrameMinWidth - 1}, spectrumFrameMinWidth - 1, true},
	} {
		v := newSpectrumView(tc.style, tc.width, 0, false, tc.frame)
		got := v.render(bins, nil, medianDb(bins), fixtureCenterHz, fixtureSpanHz)
		if v.framed || strings.ContainsAny(got, "╭+") {
			t.Errorf("%s must not be framed:\n%s", tc.name, got)
		}
		if v.inner() != tc.width {
			t.Errorf("%s: inner width %d, want the whole %d", tc.name, v.inner(), tc.width)
		}
	}
}

// A framed chart still fits the width it was given, in both renderings, and
// the ink is still nothing but ink.
func TestSpectrumFramedFitsWidth(t *testing.T) {
	bins := spectrumFixture(1024, 640, -21)
	for _, width := range []int{spectrumFrameMinWidth, 80, 100, ui.MaxWidth} {
		plain := renderFramed(t, ui.Style{Unicode: true, Width: width}, width, bins)
		styled := renderFramed(t, ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: true, Width: width}, width, bins)
		if got := ui.Strip(styled); got != plain {
			t.Errorf("width %d: framed styled and plain differ\nplain:\n%s\nstripped:\n%s", width, plain, got)
		}
		for _, l := range strings.Split(strings.TrimRight(styled, "\n"), "\n") {
			if w := ui.Visible(l); w > width {
				t.Errorf("width %d: framed line of %d columns: %q", width, w, ui.Strip(l))
			}
		}
		if !strings.Contains(plain, "╭") {
			t.Errorf("width %d: expected a frame:\n%s", width, plain)
		}
	}
}

// The scale tracks the data. It used to reserve 30 dB above the noise line
// whatever the row held, so a band whose loudest column was a few dB over the
// noise drew into the bottom third of the chart with 70% of the rows blank.
func TestSpectrumScaleTracksTheData(t *testing.T) {
	st := ui.Style{Unicode: true, Width: 80}
	bins := noiseFrame(3, 1024)
	for i := 500; i < 504; i++ {
		bins[i] = -70 // a bump over the noise, below the detection threshold
	}
	v := newSpectrumView(st, 80, 0, false, false)
	text := v.render(bins, nil, medianDb(bins), fixtureCenterHz, fixtureSpanHz)
	peak := math.Inf(-1)
	for _, d := range columnLevels(bins, v.cols(len(bins))) {
		peak = math.Max(peak, d)
	}
	if v.top < peak {
		t.Fatalf("the top must clear the data: %v under a peak of %v", v.top, peak)
	}
	if v.top > v.noise+25 {
		t.Fatalf("the scale must not reserve sky nothing reaches: %v over a noise line of %v", v.top, v.noise)
	}
	if frac := (peak - v.bottom) / (v.top - v.bottom); frac < 0.5 {
		t.Fatalf("the loudest column reaches %.0f%% of a %v..%v chart, which is crushed:\n%s", 100*frac, v.bottom, v.top, text)
	}
	// A dead-flat band has no peak to track and still needs rows to draw in.
	flat := make([]float64, 1024)
	for i := range flat {
		flat[i] = -80
	}
	f := newSpectrumView(st, 80, 0, false, false)
	f.render(flat, nil, medianDb(flat), fixtureCenterHz, fixtureSpanHz)
	if f.top-f.bottom < spectrumMinSpanDb {
		t.Fatalf("a flat band still needs a scale to draw in, got %v..%v", f.bottom, f.top)
	}
}

// A frame with no detection is drawn at the cold end of the ramp and says so
// in words, so the chart and the peak line never contradict each other and a
// quiet band never wears the colours of a busy one.
func TestSpectrumQuietBandReadsQuiet(t *testing.T) {
	st := ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: true, Width: 80}
	cold := levelSGR(st, 0)
	noise := noiseFrame(5, 1024)
	quiet := newSpectrumView(st, 80, 0, false, false).render(noise, nil, medianDb(noise), fixtureCenterHz, fixtureSpanHz)
	for params, runs := range inkRuns(quiet) {
		if strings.HasPrefix(params, "38;2;") && params != cold {
			t.Errorf("a band with nothing on it was inked %q (%q), want the cold end only:\n%s", params, runs, quiet)
		}
	}
	if want := "nothing above the floor; the band looks quiet"; !strings.Contains(ui.Strip(quiet), want) {
		t.Errorf("want %q in:\n%s", want, quiet)
	}
	// A band with something on it still climbs the ramp.
	bins := spectrumFixture(1024, 640, -21)
	peaks := loudestBins(bins, fixtureCenterHz, fixtureSpanHz, spectrumPeaks, medianDb(bins)+peakAboveFloorDb)
	busy := newSpectrumView(st, 80, 0, false, false).render(bins, peaks, medianDb(bins), fixtureCenterHz, fixtureSpanHz)
	hot := false
	for params := range inkRuns(busy) {
		if strings.HasPrefix(params, "38;2;") && params != cold {
			hot = true
		}
	}
	if !hot {
		t.Fatalf("a detected carrier must still ink hot:\n%s", busy)
	}
}
