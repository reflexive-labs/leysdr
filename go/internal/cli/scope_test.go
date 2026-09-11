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
		tap:     leylinev1.AudioTap_TAP_AUDIO, windowMs: 40,
		peakDbfs: -2, rmsDbfs: -5, tuningHz: math.NaN(), what: "145.230 MHz NFM",
	}
}

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
			rows := newScopeView(tc.st, 32).trace(f.samples)
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
	v := newScopeView(ui.Style{Unicode: true}, 32)
	window := 192
	var triggered, free string
	for i, shift := range []int{0, 7, 19, 31, 44} {
		buf := scopeTone(100, 4800, 2*window+shift, 0.8, 0.02)[shift:]
		start := scopeTrigger(buf, window)
		got := strings.Join(v.trace(buf[start:start+window]), "\n")
		last := strings.Join(v.trace(buf[len(buf)-window:]), "\n")
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
// frequency, and only on the tap that has not had it removed.
func TestScopeTuningHz(t *testing.T) {
	if got := scopeTuningHz(leylinev1.DemodMode_NFM, leylinev1.AudioTap_TAP_DEMOD, 0.02); math.Abs(got-100) > 0.001 {
		t.Errorf("NFM demod tap at 0.02 full scale = %.2f Hz, want 100", got)
	}
	if got := scopeTuningHz(leylinev1.DemodMode_WFM, leylinev1.AudioTap_TAP_DEMOD, -0.01); math.Abs(got+750) > 0.001 {
		t.Errorf("WFM demod tap at -0.01 full scale = %.2f Hz, want -750", got)
	}
	for _, tc := range []struct {
		mode leylinev1.DemodMode
		tap  leylinev1.AudioTap
	}{
		{leylinev1.DemodMode_NFM, leylinev1.AudioTap_TAP_AUDIO},
		{leylinev1.DemodMode_AM, leylinev1.AudioTap_TAP_DEMOD},
		{leylinev1.DemodMode_USB, leylinev1.AudioTap_TAP_DEMOD},
	} {
		if got := scopeTuningHz(tc.mode, tc.tap, 0.02); !math.IsNaN(got) {
			t.Errorf("%v on the %s tap reported a tuning error of %.2f Hz", tc.mode, scopeTapName(tc.tap), got)
		}
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
	for _, want := range []string{"145.230 MHz NFM", "tap demod", "window 40 ms", "tuning +100 Hz"} {
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
