// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/ui"
)

// scopeTone is one window of a sine, as a tap delivers it: amplitude and DC
// offset are the two things the trace and the header are read for.
func scopeTone(hz, rate float64, n int, amp, dc float64) []float32 {
	out := make([]float32, n)
	for i := range out {
		out[i] = float32(dc + amp*math.Sin(2*math.Pi*hz*float64(i)/rate))
	}
	return out
}

// scopeTestFrame is a 40 ms window of a 100 Hz tone at 4.8 kHz: four cycles,
// the same picture the design doc describes for a PL tone on the demod tap.
func scopeTestFrame() scopeFrame {
	return scopeFrame{
		samples: scopeTone(100, 4800, 192, 0.8, 0),
		tap:     leylinev1.AudioTap_TAP_AUDIO, windowMs: 40, scale: 1,
		peakDbfs: -2, rmsDbfs: -5, tuningHz: math.NaN(), what: "145.230 MHz NFM",
	}
}

// scopeTraceCols is the trace width the goldens below were drawn at; the views
// under test are sized to it plus the level axis beside it, which at full
// scale is "+1" and the axis column.
const scopeTraceCols = 32

var scopeFullGutter = scopeFull.labelWidth() + 1

// peakRuns counts the runs of columns the trace reaches row into: one per
// cycle of the tone, which is what ties the picture to the number beside it.
func peakRuns(row string) int {
	runs, inRun := 0, false
	for _, r := range row {
		switch {
		case r == ' ' || r == rune(brailleBase):
			inRun = false
		case !inRun:
			runs, inRun = runs+1, true
		}
	}
	return runs
}

// The trace of a 100 Hz tone in a 40 ms window, in both alphabets: four
// cycles, drawn from the lowest sample in a column to the highest so the
// stroke stays joined.
const (
	scopeToneBraille = `⠀⢀⡀⠀⠀⠀⠀⠀⠀⢀⡀⠀⠀⠀⠀⠀⠀⢀⡀⠀⠀⠀⠀⠀⠀⢀⡀
⠀⡎⠹⡀⠀⠀⠀⠀⠀⡎⠹⡀⠀⠀⠀⠀⠀⡎⠹⡀⠀⠀⠀⠀⠀⡎⠹⡀
⢸⠀⠀⢃⠀⠀⠀⠀⢸⠀⠀⢃⠀⠀⠀⠀⢸⠀⠀⢃⠀⠀⠀⠀⢸⠀⠀⢃
⡇⠀⠀⠸⡀⠀⠀⠀⡇⠀⠀⠸⡀⠀⠀⠀⡇⠀⠀⠸⡀⠀⠀⠀⡇⠀⠀⠸⡀
⠁⠀⠀⠀⡇⠀⠀⢰⠁⠀⠀⠀⡇⠀⠀⢰⠁⠀⠀⠀⡇⠀⠀⢰⠁⠀⠀⠀⡇⠀⠀⢰
⠀⠀⠀⠀⢸⠀⠀⡌⠀⠀⠀⠀⢸⠀⠀⡌⠀⠀⠀⠀⢸⠀⠀⡌⠀⠀⠀⠀⢸⠀⠀⡌
⠀⠀⠀⠀⠀⢇⣰⠁⠀⠀⠀⠀⠀⢇⣰⠁⠀⠀⠀⠀⠀⢇⣰⠁⠀⠀⠀⠀⠀⢇⣰⠁
⠀⠀⠀⠀⠀⠈⠁⠀⠀⠀⠀⠀⠀⠈⠁⠀⠀⠀⠀⠀⠀⠈⠁⠀⠀⠀⠀⠀⠀⠈⠁`

	scopeToneASCII = ` __      __      __      __
 -"_     -"_     -"_     -"_
-  -    -  -    -  -    -  -
-  "_   -  "_   -  "_   -  "_
"   -  -"   -  -"   -  -"   -  -
    -  -    -  -    -  -    -  -
     --"     --"     --"     --"
     ""      ""      ""      ""`
)

// A tone must draw as a tone: four cycles of a 100 Hz sine in a 40 ms window,
// in both alphabets. The golden holds the picture; the run counts hold the
// reason it is the right one, so a renderer that drew a plausible but wrong
// wave would fail even if someone updated the golden.
func TestScopeTraceDrawsTheTone(t *testing.T) {
	f := scopeTestFrame()
	for _, tc := range []struct {
		name   string
		st     ui.Style
		golden string
	}{
		{"braille", ui.Style{Unicode: true}, scopeToneBraille},
		{"ascii", ui.Style{}, scopeToneASCII},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rows := newScopeView(tc.st, scopeTraceCols+scopeFullGutter, scopeFull, false).trace(f.samples, f.scale)
			if len(rows) != scopeHeight {
				t.Fatalf("trace is %d rows, want %d", len(rows), scopeHeight)
			}
			if got, want := strings.Join(rows, "\n"), tc.golden; got != want {
				t.Errorf("trace differs from the golden\n--- want\n%s\n--- got\n%s", want, got)
			}
			if got := peakRuns(rows[0]); got != 4 {
				t.Errorf("top row has %d runs, want one per cycle (4):\n%s", got, rows[0])
			}
			if got := peakRuns(rows[len(rows)-1]); got != 4 {
				t.Errorf("bottom row has %d runs, want one per cycle (4):\n%s", got, rows[len(rows)-1])
			}
		})
	}
}

// The trigger's whole job: the same tone, reached at any phase of the stream,
// draws the same picture. The free-running comparison is what makes this a
// test of the trigger rather than of the sine.
func TestScopeTriggerHoldsAToneStill(t *testing.T) {
	v := newScopeView(ui.Style{Unicode: true}, scopeTraceCols+scopeFullGutter, scopeFull, false)
	window := 192
	var triggered, free string
	for i, shift := range []int{0, 7, 19, 31, 44} {
		buf := scopeTone(100, 4800, 2*window+shift, 0.8, 0.02)[shift:]
		start := scopeTrigger(buf, window)
		got := strings.Join(v.trace(buf[start:start+window], 1), "\n")
		last := strings.Join(v.trace(buf[len(buf)-window:], 1), "\n")
		if i == 0 {
			triggered, free = got, last
			continue
		}
		if got != triggered {
			t.Errorf("shift %d: the triggered trace moved\n--- want\n%s\n--- got\n%s", shift, triggered, got)
		}
		if last != free {
			free = ""
		}
	}
	if free != "" {
		t.Error("every free-running window drew the same picture; this test is not measuring the trigger")
	}
}

// A signal that does not repeat has no trigger point, and pretending it does
// would hold a picture still that is not.
func TestScopeTriggerFreeRunsOnNoise(t *testing.T) {
	buf := make([]float32, 512)
	for i := range buf {
		buf[i] = float32(math.Sin(float64(i)*1.7) * math.Sin(float64(i)*0.31))
	}
	if got, want := scopeTrigger(buf, 256), 256; got != want {
		t.Errorf("scopeTrigger on noise = %d, want the newest window at %d", got, want)
	}
}

// The three numbers the header and the JSON row carry, against a sine whose
// levels are arithmetic: a half-scale tone peaks at -6 dBFS and has -9 dBFS
// of it on average.
func TestScopeStats(t *testing.T) {
	peak, rms, dc := scopeStats(scopeTone(100, 4800, 480, 0.5, 0))
	if math.Abs(peak+6.02) > 0.1 {
		t.Errorf("peak = %.2f dBFS, want -6.02", peak)
	}
	if math.Abs(rms+9.02) > 0.1 {
		t.Errorf("rms = %.2f dBFS, want -9.02", rms)
	}
	if math.Abs(dc) > 0.001 {
		t.Errorf("dc = %.4f, want a tone centred on the axis to read 0", dc)
	}
	// The offset the demod tap carries is the number the tuning error is read
	// from, so it is measured over the window rather than assumed away.
	if _, _, dc := scopeStats(scopeTone(100, 4800, 480, 0.5, 0.02)); math.Abs(dc-0.02) > 0.001 {
		t.Errorf("dc = %.4f, want 0.02", dc)
	}
	// Silence has no level, and a row carrying negative infinity is not JSON.
	if peak, rms, dc := scopeStats(make([]float32, 64)); peak != scopeMinDbfs || rms != scopeMinDbfs || dc != 0 {
		t.Errorf("silence reads %.1f/%.1f/%.3f dBFS, want the scale to stop at %d", peak, rms, dc, scopeMinDbfs)
	}
}

// The DC offset is a tuning error only where the detector's output is
// frequency, and only on the tap that has not had it removed. It is the
// daemon's own full scale it is measured against, so a 12.5 kHz channel and a
// 25 kHz one read the same offset as different errors.
func TestScopeTuningHz(t *testing.T) {
	for _, tc := range []struct {
		name        string
		fullScaleHz uint32
		dc          float64
		want        float64
	}{
		{"a narrow NFM channel", 2_500, 0.02, 50},
		{"a 25 kHz NFM channel", 5_000, 0.02, 100},
		{"WFM", 75_000, -0.01, -750},
	} {
		if got := scopeTuningHz(leylinev1.AudioTap_TAP_DEMOD, tc.fullScaleHz, tc.dc); math.Abs(got-tc.want) > 0.001 {
			t.Errorf("%s at %g of full scale = %.2f Hz, want %.0f", tc.name, tc.dc, got, tc.want)
		}
	}
	// The audio tap has had the offset taken out of it, and a tap whose
	// samples are amplitude has no deviation to scale one by.
	for _, tc := range []struct {
		name        string
		tap         leylinev1.AudioTap
		fullScaleHz uint32
	}{
		{"the audio tap", leylinev1.AudioTap_TAP_AUDIO, 2_500},
		{"an amplitude mode", leylinev1.AudioTap_TAP_DEMOD, 0},
	} {
		if got := scopeTuningHz(tc.tap, tc.fullScaleHz, 0.02); !math.IsNaN(got) {
			t.Errorf("%s reported a tuning error of %.2f Hz", tc.name, got)
		}
	}
}

// The deviation the descriptor answers is what the views read; a daemon that
// left it at zero on an FM mode is answered from the channel by the same
// rule, and an amplitude mode has none either way.
func TestScopeFullScaleHz(t *testing.T) {
	ch := &leylinev1.Channel{Mode: leylinev1.DemodMode_NFM, BandwidthHz: 25_000}
	if got := scopeFullScaleHz(&leylinev1.AudioParams{FullScaleDeviationHz: 2_500}, ch); got != 2_500 {
		t.Errorf("the descriptor said 2500 Hz and the view read %d", got)
	}
	if got := scopeFullScaleHz(&leylinev1.AudioParams{}, ch); got != 5_000 {
		t.Errorf("a descriptor without a deviation on a 25 kHz NFM channel = %d Hz, want 5000", got)
	}
	am := &leylinev1.Channel{Mode: leylinev1.DemodMode_AM, BandwidthHz: 10_000}
	if got := scopeFullScaleHz(&leylinev1.AudioParams{}, am); got != 0 {
		t.Errorf("AM has no deviation, and the view read %d Hz", got)
	}
}

// The header is the daemon's claim, drawn beside the picture: the tone its
// sub-audible detector reports, and the DC offset of the demod tap read as a
// tuning error. The view measures neither.
func TestScopeDemodHeaderCarriesTheDaemonsTone(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, context.Background(), sock, "scope", "145.23", "--tap", "demod", "--count", "12")
	if err != nil {
		t.Fatalf("ley scope: %v\nstdout: %s\nstderr: %s", err, out, errOut)
	}
	// The channel is 12.5 kHz wide and cannot carry more than 2.5 kHz of
	// deviation, which is what full scale on its detector is worth, so the
	// tap's 0.02 offset reads as 50 Hz.
	for _, want := range []string{"145.230 MHz NFM", "tap demod", "window 40 ms", "full scale ±2.5 kHz", "tuning +50 Hz"} {
		if !strings.Contains(out, want) {
			t.Errorf("the header does not say %q:\n%s", want, out)
		}
	}
	if want := "PL 100.0 Hz (measured 100.12 Hz, 18 dB, confidence 0.9)"; !strings.Contains(out, want) {
		t.Errorf("the header never carried the daemon's tone %q:\n%s", want, out)
	}
	if !strings.Contains(errOut, "drawing 145.230 MHz NFM: the demod tap") {
		t.Errorf("the prose on stderr does not say what is being drawn:\n%s", errOut)
	}
}

// The audio tap is what the speakers get: the same channel, with neither the
// sub-audible tone nor the offset the demod tap carries.
func TestScopeAudioTapHasNoTuningError(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "scope", "145.23", "--count", "3")
	if !strings.Contains(out, "tap audio") {
		t.Errorf("the header does not name the audio tap:\n%s", out)
	}
	if strings.Contains(out, "tuning ") {
		t.Errorf("the audio tap has no tuning error to report:\n%s", out)
	}
}

// A raw-IQ channel runs no detector, so the daemon refuses the demod tap and
// the sentence a person reads is the daemon's own.
func TestScopeDemodTapRefusedOnRawIQ(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, _, err := run(t, context.Background(), sock, "scope", "146.52", "--mode", "raw", "--tap", "demod", "--count", "1")
	if exitCode(err) != 1 {
		t.Fatalf("ley scope --mode raw --tap demod: exit %d (%v), want 1", exitCode(err), err)
	}
	if !strings.Contains(err.Error(), "the demod tap needs a demodulator; this channel is raw IQ") {
		t.Errorf("want the daemon's sentence, got: %v", err)
	}
	if out != "" {
		t.Errorf("a refused subscription draws nothing, got:\n%s", out)
	}
}

// --json is the frame's statistics and nothing else: the samples are `ley
// listen --format json`, and a row here that carried them would be a second,
// slower way to say the same thing.
func TestScopeJSONRows(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "--json", "scope", "145.23", "--tap", "demod", "--count", "12")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 12 {
		t.Fatalf("--count 12 printed %d rows:\n%s", len(lines), out)
	}
	var withTone int
	for i, line := range lines {
		var raw map[string]any
		if err := json.Unmarshal([]byte(line), &raw); err != nil {
			t.Fatalf("row %d is not JSON (%v): %q", i, err, line)
		}
		if _, ok := raw["pcm"]; ok {
			t.Fatalf("row %d carries samples: %q", i, line)
		}
		var row ScopeRow
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			t.Fatalf("row %d: %v", i, err)
		}
		if row.SampleRate != 48000 || row.Tap != "demod" || row.WindowMs != 40 {
			t.Errorf("row %d = %+v, want the 48 kHz demod tap in 40 ms windows", i, row)
		}
		if row.PeakDbfs <= scopeMinDbfs || row.RmsDbfs <= scopeMinDbfs {
			t.Errorf("row %d has no level: peak %.1f rms %.1f", i, row.PeakDbfs, row.RmsDbfs)
		}
		// The demod tap carries the detector's DC offset; the daemon's is 0.02
		// of full scale, which is the tuning error the header names.
		if math.Abs(row.DC-0.02) > 0.005 {
			t.Errorf("row %d dc = %.4f, want the tap's 0.02 offset", i, row.DC)
		}
		if row.ToneHz != nil {
			withTone++
			if math.Abs(*row.ToneHz-100) > 0.5 {
				t.Errorf("row %d tone_hz = %.2f, want the daemon's 100 Hz", i, *row.ToneHz)
			}
		}
	}
	if withTone == 0 {
		t.Errorf("no row carried the daemon's tone:\n%s", out)
	}
}

// Every flag that takes a word or a range says what it accepts, and says it
// before anything reaches the daemon.
func TestScopeUsageErrors(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"scope"}, "scope needs a frequency, preset or channel id"},
		{[]string{"scope", "146.52", "--tap", "video"}, "--tap must be audio"},
		{[]string{"scope", "146.52", "--trigger", "sometimes"}, "--trigger must be auto"},
		{[]string{"scope", "146.52", "--window", "1"}, "--window must be 5..500 ms"},
		{[]string{"scope", "146.52", "--window", "900"}, "--window must be 5..500 ms"},
		{[]string{"scope", "146.52", "--rate", "60"}, "--rate must be more than 0 and at most 20"},
		{[]string{"scope", "146.52", "--scale", "loud"}, "--scale must be full, auto, or a number"},
		{[]string{"scope", "146.52", "--scale", "2"}, "--scale must be full, auto, or a number"},
		{[]string{"scope", "146.52", "--scale", "0.001"}, "--scale must be full, auto, or a number"},
		{[]string{"scope", "chan_01J", "--mode", "am"}, "--mode cannot be used with a channel id"},
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

// The timebase under the trace: round steps, four to eight of them, starting
// at zero and ending at the window the header states. The step table is the
// point -- an axis that marked 5.7 ms would be arithmetic, not a timebase.
func TestScopeAxisTicks(t *testing.T) {
	for _, tc := range []struct {
		windowMs int
		want     []int
	}{
		{5, []int{0, 1, 2, 3, 4, 5}},
		{10, []int{0, 2, 4, 6, 8, 10}},
		{20, []int{0, 5, 10, 15, 20}},
		{40, []int{0, 10, 20, 30, 40}},
		{100, []int{0, 20, 40, 60, 80, 100}},
		{500, []int{0, 100, 200, 300, 400, 500}},
	} {
		t.Run(fmt.Sprintf("%dms", tc.windowMs), func(t *testing.T) {
			ticks := scopeTicks(tc.windowMs, ui.DefaultWidth-scopeFullGutter)
			var got []int
			for _, tick := range ticks {
				got = append(got, tick.ms)
			}
			if !slices.Equal(got, tc.want) {
				t.Fatalf("ticks at %v ms, want %v", got, tc.want)
			}
			if len(ticks) < 4 || len(ticks) > 8 {
				t.Errorf("%d marks on the axis, want four to eight", len(ticks))
			}
			if ticks[0].col != 0 {
				t.Errorf("the axis starts at column %d, want the frame's first", ticks[0].col)
			}
			if last := ticks[len(ticks)-1]; last.col != ui.DefaultWidth-scopeFullGutter-1 {
				t.Errorf("the window length sits at column %d, want the right edge", last.col)
			}
		})
	}
}

// Both scales are on screen beside the picture, in either alphabet: the level
// down the gutter, the time along the rule beneath. The trace comes out of the
// same width they do, so a wider terminal draws a wider trace and not a wider
// gutter.
func TestScopeRenderCarriesBothScales(t *testing.T) {
	f := scopeTestFrame()
	for _, tc := range []struct {
		name string
		st   ui.Style
	}{
		{"braille", ui.Style{Unicode: true}},
		{"ascii", ui.Style{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			v := newScopeView(tc.st, ui.DefaultWidth, scopeFull, false)
			if got, want := v.cols(), ui.DefaultWidth-scopeFullGutter; got != want {
				t.Errorf("the trace is %d columns of %d, want %d beside the level axis", got, ui.DefaultWidth, want)
			}
			lines := strings.Split(strings.TrimRight(v.render(f), "\n"), "\n")
			for _, l := range lines {
				if w := ui.Visible(l); w > ui.DefaultWidth {
					t.Errorf("a line is %d columns wide: %q", w, l)
				}
			}
			// The eight trace rows sit between the header and the axis.
			rows := lines[len(lines)-2-scopeHeight : len(lines)-2]
			for row, want := range map[int]string{0: "+1", scopeHeight / 2: " 0", scopeHeight - 1: "-1"} {
				if !strings.HasPrefix(rows[row], want) {
					t.Errorf("row %d starts %q, want the gutter to read %q", row, firstRunes(rows[row], 3), want)
				}
			}
			for row, l := range rows {
				switch row {
				case 0, scopeHeight / 2, scopeHeight - 1:
				default:
					if !strings.HasPrefix(l, "  ") {
						t.Errorf("row %d names a level the scale does not stop at: %q", row, firstRunes(l, 3))
					}
				}
			}
			// The rule and its labels: full scale is the gutter's job, the
			// window length is the axis'.
			rule, labels := lines[len(lines)-2], lines[len(lines)-1]
			if !strings.Contains(rule, strings.Repeat(string(tc.st.Glyphs().Rule), 4)) {
				t.Errorf("the axis draws no rule: %q", rule)
			}
			if !strings.HasPrefix(strings.TrimLeft(labels, " "), "0 ms") || !strings.HasSuffix(labels, "40 ms") {
				t.Errorf("the labels run %q, want 0 ms to the window's 40 ms", labels)
			}
		})
	}
}

// firstRunes is the head of a line, for an error message about its gutter.
func firstRunes(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		r = r[:n]
	}
	return string(r)
}

// The auto scale's two jobs: fit the trace to a signal that fills a tenth of
// full scale, and then sit still for long enough that a gap between syllables
// does not resize the picture.
func TestScopeAutoScaleFitsAndHolds(t *testing.T) {
	const frame = 50 * time.Millisecond
	s := newScopeScaler(scopeScale{auto: true}, frame)
	loud := scopePeak(scopeTone(100, 4800, 192, 0.14, 0))
	if got := s.next(loud); got != 0.2 {
		t.Fatalf("a 0.14 tone drew at ±%g, want it snapped up to the 0.2 step", got)
	}
	// A hold window of the tone, so the pause arrives at a scale the window
	// agrees with rather than at one frame's word.
	for range s.size - 1 {
		s.next(loud)
	}
	// Five frames of near-silence is a quarter second, longer than the gap
	// between two syllables.
	quiet := scopePeak(scopeTone(100, 4800, 192, 0.005, 0))
	for i := range 5 {
		if got := s.next(quiet); got != 0.2 {
			t.Fatalf("frame %d of the pause drew at ±%g, want the fit held at 0.2", i, got)
		}
	}
	// It does come down, though: a scale that only ever grew would be full
	// scale again by the end of a transmission.
	for range 40 {
		s.next(quiet)
	}
	if got := s.next(quiet); got >= 0.2 {
		t.Errorf("two seconds after the tone the scale is still ±%g, want it back down", got)
	}
	// And it goes up for a signal, over the few frames it takes the loud ones
	// to outnumber the top tenth of the window.
	loudFrame := scopePeak(scopeTone(100, 4800, 192, 0.6, 0))
	var up float64
	for range 5 {
		up = s.next(loudFrame)
	}
	if up != 1 {
		t.Errorf("a quarter second of 0.6 peaks drew at ±%g, want full scale", up)
	}
}

// A burst is not a signal: the squelch tail at the end of a transmission is
// several times full scale for one frame, and a scale fitted to it would
// leave the next second of picture drawn at a size nothing in it needs.
func TestScopeAutoScaleIgnoresABurst(t *testing.T) {
	const frame = 50 * time.Millisecond
	s := newScopeScaler(scopeScale{auto: true}, frame)
	quiet := scopePeak(scopeTone(100, 4800, 192, 0.03, 0))
	// A full hold window of the signal as it stands, so the burst arrives at
	// a scale that has settled.
	var fit float64
	for range 20 {
		fit = s.next(quiet)
	}
	if fit != 0.05 {
		t.Fatalf("a 0.03 tone drew at ±%g, want it snapped up to the 0.05 step", fit)
	}
	if got := s.next(4.8); got != fit {
		t.Errorf("the burst drew at ±%g, want the picture left at ±%g and the burst clamped", got, fit)
	}
	for i := range 10 {
		if got := s.next(quiet); got != fit {
			t.Errorf("frame %d after the burst drew at ±%g, want the picture still at ±%g", i, got, fit)
		}
	}
}

// The burst is not a signal at any frame rate --rate takes: a hold window of
// a handful of frames still has to drop the loudest of them, or half the
// documented range would hand a squelch tail the whole scale.
func TestScopeAutoScaleIgnoresABurstAtSlowRates(t *testing.T) {
	for _, rate := range []float64{9, 5, 2, 1} {
		t.Run(fmt.Sprintf("%gfps", rate), func(t *testing.T) {
			s := newScopeScaler(scopeScale{auto: true}, time.Duration(float64(time.Second)/rate))
			var fit float64
			for range s.size {
				fit = s.next(0.03)
			}
			if fit != 0.05 {
				t.Fatalf("a 0.03 peak drew at ±%g, want it snapped up to the 0.05 step", fit)
			}
			if got := s.next(4.8); got != fit {
				t.Errorf("the burst drew at ±%g, want the picture left at ±%g and the burst clamped", got, fit)
			}
			if got := s.next(0.03); got != fit {
				t.Errorf("the frame after the burst drew at ±%g, want the picture still at ±%g", got, fit)
			}
		})
	}
}

// full and a pinned scale are promises: whatever the signal does, the rows are
// worth what the gutter says they are worth.
func TestScopeFixedScalesNeverMove(t *testing.T) {
	for _, tc := range []struct {
		name  string
		scale scopeScale
		want  float64
	}{
		{"full", scopeFull, 1},
		{"pinned", scopeScale{fixed: 0.2}, 0.2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newScopeScaler(tc.scale, 50*time.Millisecond)
			for _, peak := range []float64{0.001, 0.9, 0.05} {
				if got := s.next(peak); got != tc.want {
					t.Errorf("a peak of %g drew at ±%g, want ±%g", peak, got, tc.want)
				}
			}
		})
	}
}

// What the item is for: a tenth of full scale is a dot or two high, and the
// same signal on the scale that fits it uses the whole picture.
func TestScopeScaleFillsTheRows(t *testing.T) {
	v := newScopeView(ui.Style{Unicode: true}, scopeTraceCols+scopeFullGutter, scopeScale{auto: true}, false)
	tone := scopeTone(100, 4800, 192, 0.14, 0)
	full := v.trace(tone, 1)
	fitted := v.trace(tone, 0.2)
	if drawn := scopeDrawnRows(full); drawn > 2 {
		t.Errorf("a 0.14 tone at full scale covers %d rows; this test assumes it is a sliver", drawn)
	}
	// Not quite every row: the step above the peak is the headroom that keeps
	// the trace off the rails, where a peak and a clipped peak look alike.
	if drawn := scopeDrawnRows(fitted); drawn < scopeHeight-2 {
		t.Errorf("the same tone at ±0.2 covers %d rows of %d, want most of them", drawn, scopeHeight)
	}
}

// scopeDrawnRows counts the rows a trace puts any ink in.
func scopeDrawnRows(rows []string) int {
	n := 0
	for _, r := range rows {
		if strings.TrimRight(r, " "+string(rune(brailleBase))) != "" {
			n++
		}
	}
	return n
}

// A pinned scale is a promise made in three places: the header states it, the
// gutter names it at the top and the bottom, and the JSON row carries it, so a
// picture and a row drawn from the same frame mean the same thing.
func TestScopePinnedScaleNamesItself(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "scope", "145.23", "--scale", "0.2", "--count", "3")
	for _, want := range []string{"scale ±0.2", "+0.2", "-0.2"} {
		if !strings.Contains(out, want) {
			t.Errorf("the view never says %q:\n%s", want, out)
		}
	}
	// The gutter grew by two columns; the trace, not the line, is what gives
	// them up.
	for _, l := range strings.Split(out, "\n") {
		if w := ui.Visible(l); w > ui.DefaultWidth {
			t.Errorf("a line is %d columns wide: %q", w, l)
		}
	}
	rows := mustRun(t, sock, "--json", "scope", "145.23", "--scale", "0.2", "--count", "3")
	for i, line := range strings.Split(strings.TrimSpace(rows), "\n") {
		var row ScopeRow
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			t.Fatalf("row %d: %v", i, err)
		}
		if row.Scale != 0.2 {
			t.Errorf("row %d was drawn at scale %g, want the pinned 0.2", i, row.Scale)
		}
	}
}

// A closed squelch zeroes the audio tap while the daemon's detector keeps
// reporting a tone, which reads as "the tone is there but my voice is not".
// The view says which it is, on the tap the squelch silences and nowhere else.
func TestScopeSaysTheSquelchIsClosed(t *testing.T) {
	const note = "squelch closed: the audio tap is muted;"
	sock, _ := harness(t, fakedaemon.Options{})
	// The fake's synthetic power never reaches -20 dBFS, so this squelch is
	// shut for the whole run.
	if out := mustRun(t, sock, "scope", "145.23", "--squelch", "-20", "--count", "12"); !strings.Contains(out, note) {
		t.Errorf("a muted audio tap does not say so:\n%s", out)
	}
	for _, tc := range []struct {
		name string
		args []string
	}{
		{"demod tap", []string{"scope", "145.23", "--squelch", "-20", "--tap", "demod", "--count", "12"}},
		{"squelch off", []string{"scope", "145.23", "--squelch", "off", "--count", "12"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if out := mustRun(t, sock, tc.args...); strings.Contains(out, note) {
				t.Errorf("nothing is muted here, but the view says it is:\n%s", out)
			}
		})
	}
}
