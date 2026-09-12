package cli

import (
	"context"
	"encoding/json"
	"math"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/ui"
)

// The clip the goldens below are drawn at: a pinned scale, so the picture is
// the same whatever the signal did, and a width that leaves 44 columns beside
// the gutter and the playhead.
const (
	waveformTestWidth = 50
	waveformTestScale = 0.5
)

// waveformTestFrame is one still with every case in it, oldest first: columns
// the run has not reached, a slice the squelch was shut for, a burst that
// rises and falls, the open silence after it, and a quieter burst under the
// playhead.
func waveformTestFrame(n int) waveformFrame {
	cols := make([]waveformCol, n)
	for i := range cols {
		peak, present, open := 0.0, true, true
		switch {
		case i < 6:
			present = false
		case i < 12:
			open = false
		case i < 26:
			peak = 0.45 * math.Sin(math.Pi*float64(i-12)/13)
		case i < 34:
		default:
			peak = 0.15 * math.Sin(math.Pi*float64(i-34)/9)
		}
		cols[i] = waveformCol{
			present: present, open: open, peak: peak,
			peakDbfs: scopeDbfs(peak), rmsDbfs: scopeDbfs(peak / math.Sqrt2),
		}
	}
	return waveformFrame{
		cols: cols, tap: leylinev1.AudioTap_TAP_AUDIO, what: "147.435 MHz NFM",
		seconds: 10, dc: math.NaN(), squelchOpen: true, squelchKnown: true,
	}
}

func waveformTestView(st ui.Style) *waveformView {
	return newWaveformView(st, waveformTestWidth, 10, scopeScale{fixed: waveformTestScale}, false)
}

// The still frame, in both alphabets: nothing where the run has not reached,
// a blank slice where the squelch was shut, a burst drawn symmetric about the
// centre, the rule through the open silence after it, and a quieter burst
// under the playhead. Strip the styling and the two pictures are the same
// screen, which is the guide's identity rule.
const (
	waveformStillUnicode = `147.435 MHz NFM  tap audio  10 s  scale ±0.5
squelch open
+0.5│                 ▄▄▄▄                       │
    │               ▄██████▄                     │
    │              ██████████              ▄▄    │
    │             ████████████           ██████  │
   0│            ─████████████───────────██████──│
    │              ██████████              ▀▀    │
    │               ▀██████▀                     │
-0.5│                 ▀▀▀▀                       │
    ─│────────│───────│────────│───────│────────│
     -10 s  -8 s    -6 s     -4 s    -2 s    -0 s
`
	waveformStillASCII = `147.435 MHz NFM  tap audio  10 s  scale ±0.5
squelch open
+0.5|                 ####                       |
    |               ########                     |
    |              ##########              ##    |
    |             ############           ######  |
   0|            -############-----------######--|
    |              ##########              ##    |
    |               ########                     |
-0.5|                 ####                       |
    -|--------|-------|--------|-------|--------|
     -10 s  -8 s    -6 s     -4 s    -2 s    -0 s
`
)

func TestWaveformStillFrame(t *testing.T) {
	for _, tc := range []struct {
		name   string
		st     ui.Style
		golden string
	}{
		{"unicode", ui.Style{Unicode: true}, waveformStillUnicode},
		{"ascii", ui.Style{}, waveformStillASCII},
	} {
		t.Run(tc.name, func(t *testing.T) {
			v := waveformTestView(tc.st)
			if got := v.render(waveformTestFrame(v.cols()), waveformTestScale); got != tc.golden {
				t.Errorf("the clip differs from the golden\n--- want\n%s\n--- got\n%s", tc.golden, got)
			}
		})
	}
	// Colour is ink over the same screen and never a different one.
	v := waveformTestView(ui.Style{Unicode: true, Color: true, Profile: ui.ProfileTrueColor})
	if got := ui.Strip(v.render(waveformTestFrame(v.cols()), waveformTestScale)); got != waveformStillUnicode {
		t.Errorf("the inked clip strips to a different picture\n--- want\n%s\n--- got\n%s", waveformStillUnicode, got)
	}
}

// waveformCells is what one column of a rendered clip looks like down its
// rows, which is how the rules about blank and silent slices are read.
func waveformCells(t *testing.T, v *waveformView, f waveformFrame, col int) string {
	t.Helper()
	lines := strings.Split(v.render(f, waveformTestScale), "\n")
	var b strings.Builder
	for _, l := range lines[len(lines)-3-scopeHeight : len(lines)-3] {
		r := []rune(l)
		if at := v.gutterW + col; at < len(r) {
			b.WriteRune(r[at])
		}
	}
	return b.String()
}

// A slice the squelch was shut for is blank, so a gap between transmissions
// looks like a gap; a slice that was open and silent keeps the centre rule,
// which is what tells the two apart. A column the run has not reached yet is
// blank for the same reason: nothing came through it either.
func TestWaveformBlanksAClosedSquelch(t *testing.T) {
	st := ui.Style{Unicode: true}
	v := waveformTestView(st)
	f := waveformTestFrame(v.cols())
	blank := strings.Repeat(" ", scopeHeight)
	for _, tc := range []struct {
		name string
		col  int
		want string
	}{
		{"not reached", 0, blank},
		{"squelch closed", 8, blank},
		{"open silence", 30, "    " + string(st.Glyphs().Rule) + "   "},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := waveformCells(t, v, f, tc.col); got != tc.want {
				t.Errorf("column %d draws %q, want %q", tc.col, got, tc.want)
			}
		})
	}
	// And the rule is not what a loud slice draws, or the picture would say
	// the same thing whatever came through it.
	if got := waveformCells(t, v, f, 19); strings.TrimSpace(got) == "" || strings.Contains(got, string(st.Glyphs().Rule)) {
		t.Errorf("the loudest column draws %q, want the envelope", got)
	}
}

// The demod tap's DC offset is the tuning error, and an editor's view of a
// clip shifted off its centre line says nothing the scope's trace does not say
// better: the offset comes out of the envelope and the levels both, and the
// slice still reports the offset it removed.
func TestWaveformRemovesTheDemodDC(t *testing.T) {
	var a waveformAcc
	a.start(4096, true)
	// Ten whole cycles of a tone on a 0.25 offset, so the mean is the offset.
	for i := range 480 {
		a.add(0.25 + 0.1*math.Sin(2*math.Pi*float64(i)/48))
	}
	kept, removed := a.column(false, 1.5), a.column(true, 1.5)
	if math.Abs(removed.dc-0.25) > 1e-9 {
		t.Errorf("the slice says its offset is %.4f, want 0.25", removed.dc)
	}
	if math.Abs(removed.peak-0.1) > 1e-9 {
		t.Errorf("the envelope with the offset removed is %.4f, want the tone's 0.1", removed.peak)
	}
	if math.Abs(kept.peak-0.35) > 1e-9 {
		t.Errorf("the envelope with the offset kept is %.4f, want 0.35", kept.peak)
	}
	if got, want := removed.rmsDbfs, scopeDbfs(0.1/math.Sqrt2); math.Abs(got-want) > 0.01 {
		t.Errorf("rms with the offset removed is %.2f dBFS, want %.2f", got, want)
	}
	if got, want := kept.rmsDbfs, scopeDbfs(math.Sqrt(0.25*0.25+0.005)); math.Abs(got-want) > 0.01 {
		t.Errorf("rms with the offset kept is %.2f dBFS, want %.2f", got, want)
	}
	if removed.index != 4096 || removed.seconds != 1.5 {
		t.Errorf("the slice is at sample %d, %g s in; want 4096 and 1.5", removed.index, removed.seconds)
	}
}

// The scale the clip is fitted to is the columns' percentile, not the loudest
// of them: one squelch tail at several times full scale stays in the picture
// for as long as the window is wide, and a scale it had set would draw every
// word of the transmission around it as a flat line.
func TestWaveformBurstDoesNotOwnTheScale(t *testing.T) {
	cols := make([]waveformCol, 40)
	for i := range cols {
		cols[i] = waveformCol{present: true, open: true, peak: 0.2}
	}
	quiet := waveformPeak(cols)
	if math.Abs(quiet-0.2) > 1e-9 {
		t.Fatalf("a window of 0.2 columns fits at %.3f, want 0.2", quiet)
	}
	cols[7].peak = 4.8
	if got := waveformPeak(cols); math.Abs(got-quiet) > 1e-9 {
		t.Errorf("one burst column took the fit to %.3f, want it left at %.3f", got, quiet)
	}
	// A transmission is not a burst: once the loud columns are more than the
	// top tenth of the window, they are what the clip is drawn to.
	for i := range 8 {
		cols[i].peak = 4.8
	}
	if got := waveformPeak(cols); got != 4.8 {
		t.Errorf("a fifth of the window at 4.8 fits at %.3f, want the clip drawn to it", got)
	}
}

// The clip says what its rows are worth on a tap whose samples are frequency,
// because full scale follows the channel's bandwidth and a reader who knew
// only the mode would put the wrong deviation on a narrow one.
func TestWaveformHeaderNamesFullScale(t *testing.T) {
	v := newWaveformView(ui.Style{Unicode: true}, waveformTestWidth, 10, scopeScale{fixed: 1}, false)
	f := waveformTestFrame(v.cols())
	f.tap, f.fullScaleHz = leylinev1.AudioTap_TAP_DEMOD, 2_500
	if got := strings.Join(v.header(f, 1), "\n"); !strings.Contains(got, "full scale ±2.5 kHz") {
		t.Errorf("the demod header does not name its full scale:\n%s", got)
	}
	f.tap, f.fullScaleHz = leylinev1.AudioTap_TAP_AUDIO, 2_500
	if got := strings.Join(v.header(f, 1), "\n"); strings.Contains(got, "full scale") {
		t.Errorf("the audio tap named a deviation it does not carry:\n%s", got)
	}
}

// The timebase runs backwards from the playhead in round steps, four to eight
// of them, the newest at the right edge: an axis that marked -7.3 s would be
// arithmetic, not a timebase.
func TestWaveformAxisCountsBackFromThePlayhead(t *testing.T) {
	for _, tc := range []struct {
		seconds float64
		cols    int
		step    float64
	}{
		{2, 44, 1},
		{10, 44, 2},
		{60, 44, 15},
		{120, 44, 30},
		{10, 20, 10},
	} {
		if got := waveformTickStep(tc.seconds, tc.cols); got != tc.step {
			t.Errorf("a %g s window over %d columns steps every %g s, want %g", tc.seconds, tc.cols, got, tc.step)
		}
		ticks := waveformTicks(tc.seconds, tc.cols)
		if len(ticks) < 2 || len(ticks) > 8 {
			t.Errorf("a %g s window drew %d marks, want between 2 and 8", tc.seconds, len(ticks))
		}
		if ticks[0].text != waveformAgeLabel(tc.seconds) || ticks[0].col != 0 {
			t.Errorf("the oldest mark is %q at column %d, want %q at the left edge",
				ticks[0].text, ticks[0].col, waveformAgeLabel(tc.seconds))
		}
		last := ticks[len(ticks)-1]
		if last.text != "-0 s" || last.col != tc.cols-1 {
			t.Errorf("the newest mark is %q at column %d, want -0 s under the playhead at %d",
				last.text, last.col, tc.cols-1)
		}
		for i := 1; i < len(ticks); i++ {
			if ticks[i].col <= ticks[i-1].col {
				t.Errorf("mark %d of the %g s axis is at column %d, behind the one before it", i, tc.seconds, ticks[i].col)
			}
		}
	}
}

// Every picture stays inside the width it was given, playhead included, and
// the clip never loses its gutter to a narrow screen.
func TestWaveformStaysInsideTheWidth(t *testing.T) {
	for _, width := range []int{40, 50, 80, 100, 160} {
		for _, sc := range []scopeScale{scopeFull, {auto: true}, {fixed: 0.05}} {
			// Auto reserves the widest label it could ever pick, so any step
			// of the ramp fits the gutter it drew.
			at := sc.fixed
			if sc.auto {
				at = 0.5
			}
			v := newWaveformView(ui.Style{Unicode: true}, width, 10, sc, false)
			for _, line := range strings.Split(v.render(waveformTestFrame(v.cols()), at), "\n") {
				if w := ui.Visible(line); w > width {
					t.Errorf("at %d columns a line is %d wide: %q", width, w, line)
				}
			}
		}
	}
}

// Against the daemon: the clip draws what the fake's channel carries, says
// what it is drawing, and counts the seconds back from the playhead.
func TestWaveformDrawsTheDaemonsAudio(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, context.Background(), sock, "waveform", "145.23", "--seconds", "2", "--count", "12")
	if err != nil {
		t.Fatalf("ley waveform: %v\nstdout: %s\nstderr: %s", err, out, errOut)
	}
	for _, want := range []string{"145.230 MHz NFM", "tap audio", "2 s", "scale ±", "squelch open", "-0 s"} {
		if !strings.Contains(out, want) {
			t.Errorf("the clip does not say %q:\n%s", want, out)
		}
	}
	if !strings.Contains(errOut, "drawing 145.230 MHz NFM: the audio tap") {
		t.Errorf("the prose on stderr does not say what is being drawn:\n%s", errOut)
	}
	// The demod tap sits on the detector's offset, which comes out of the clip
	// and is named where it went.
	demod := mustRun(t, sock, "waveform", "145.23", "--tap", "demod", "--seconds", "2", "--count", "12")
	if !strings.Contains(demod, "dc removed +0.02") {
		t.Errorf("the demod clip does not name the offset it removed:\n%s", demod)
	}
}

// --json is one object per column as it completes, and the columns are the
// picture's own slices: no samples, and a level for each one.
func TestWaveformJSONRows(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "--json", "waveform", "145.23", "--tap", "demod", "--seconds", "2", "--count", "8")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 8 {
		t.Fatalf("--count 8 printed %d rows:\n%s", len(lines), out)
	}
	var last WaveformRow
	for i, line := range lines {
		var raw map[string]any
		if err := json.Unmarshal([]byte(line), &raw); err != nil {
			t.Fatalf("row %d is not JSON (%v): %q", i, err, line)
		}
		if _, ok := raw["pcm"]; ok {
			t.Fatalf("row %d carries samples: %q", i, line)
		}
		var row WaveformRow
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			t.Fatalf("row %d: %v", i, err)
		}
		if row.PeakDbfs <= scopeMinDbfs || row.RmsDbfs <= scopeMinDbfs {
			t.Errorf("row %d has no level: peak %.1f rms %.1f", i, row.PeakDbfs, row.RmsDbfs)
		}
		if row.PeakDbfs < row.RmsDbfs {
			t.Errorf("row %d = peak %.1f rms %.1f, want the peak at or over the rms", i, row.PeakDbfs, row.RmsDbfs)
		}
		if !row.SquelchOpen {
			t.Errorf("row %d says the squelch was shut, but the fake's channel is passing audio", i)
		}
		if i > 0 {
			if row.SampleIndex <= last.SampleIndex || row.Seconds <= last.Seconds {
				t.Errorf("row %d is at sample %d, %g s in; row %d was at %d, %g s",
					i, row.SampleIndex, row.Seconds, i-1, last.SampleIndex, last.Seconds)
			}
		}
		last = row
	}
	// The columns are the window divided by the picture's width, so eight of
	// them are a fraction of the two seconds asked for and not the whole run.
	if last.Seconds >= 2 {
		t.Errorf("eight columns of a 2 s window covered %g s, want a fraction of it", last.Seconds)
	}
}

// Every flag that takes a word or a range says what it accepts, and says it
// before anything reaches the daemon.
func TestWaveformUsageErrors(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"waveform"}, "waveform needs a frequency, preset or channel id"},
		{[]string{"waveform", "146.52", "--tap", "video"}, "--tap must be audio"},
		{[]string{"waveform", "146.52", "--seconds", "1"}, "--seconds must be 2..120"},
		{[]string{"waveform", "146.52", "--seconds", "600"}, "--seconds must be 2..120"},
		{[]string{"waveform", "146.52", "--rate", "60"}, "--rate must be more than 0 and at most 20"},
		{[]string{"waveform", "146.52", "--scale", "loud"}, "--scale must be full, auto, or a number"},
		{[]string{"waveform", "chan_01J", "--mode", "am"}, "--mode cannot be used with a channel id"},
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

// waveformColumn is one column of the clip drawn down its rows, and the ink
// each cell carries, straight from the renderer: the glyphs are the shape of
// the envelope and the ink is the level behind it.
func waveformColumn(v *waveformView, c waveformCol, scale float64) (string, []int) {
	var b strings.Builder
	inks := make([]int, 0, scopeHeight)
	for r := range scopeHeight {
		cell, ink := v.cell(c, r, scale)
		b.WriteString(cell)
		inks = append(inks, ink)
	}
	return b.String(), inks
}

// A column is a filled shape, not a column of dots: whole cells between the
// envelope's edges, and the half of a cell an edge reaches into where it falls
// mid-cell, so the clip resolves half a row either side of the centre. ASCII
// has no half cell and draws the coarser picture with the one it has.
func TestWaveformFillsItsColumns(t *testing.T) {
	// An envelope whose edges fall in the lower half of the top cell and the
	// upper half of the bottom one, which is the case the halves are for.
	half := waveformCol{present: true, open: true, peak: waveformTestScale * 13 / 15}
	for _, tc := range []struct {
		name string
		st   ui.Style
		col  waveformCol
		want string
	}{
		{"half rows", ui.Style{Unicode: true}, half, "▄██████▀"},
		{"full scale", ui.Style{Unicode: true}, waveformCol{present: true, open: true, peak: waveformTestScale}, "████████"},
		{"ascii", ui.Style{}, half, "########"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			v := waveformTestView(tc.st)
			if got, _ := waveformColumn(v, tc.col, waveformTestScale); got != tc.want {
				t.Errorf("the column draws %q, want %q", got, tc.want)
			}
		})
	}
}

// The ink is keyed to the scale the frame is drawn at, not to full scale: the
// loudest thing on screen is hot whatever the signal is doing, so a quiet
// passage under --scale 0.1 still has colour in it.
func TestWaveformInkFollowsTheScaleOnScreen(t *testing.T) {
	v := waveformTestView(ui.Style{Unicode: true})
	col := waveformCol{present: true, open: true, peak: 0.25}
	_, hot := waveformColumn(v, col, 0.25)
	_, cold := waveformColumn(v, col, 1)
	if hot[0] != chartLevelSteps-1 {
		t.Errorf("a column at the scale takes ramp step %d, want the hot end %d", hot[0], chartLevelSteps-1)
	}
	mid := scopeHeight / 2
	if cold[mid] >= hot[0] {
		t.Errorf("the same peak inks %d at ten times the scale, want colder than %d", cold[mid], hot[0])
	}
	if cold[mid] <= 0 {
		t.Errorf("a column a quarter of the scale inks %d, want colour in it", cold[mid])
	}
	// A squelched slice is not drawn at all, so it carries no level either.
	if _, shut := waveformColumn(v, waveformCol{present: true, peak: 0.5}, waveformTestScale); shut[0] != inkPlain {
		t.Errorf("a closed slice inks %d, want the blank it draws", shut[0])
	}
}
