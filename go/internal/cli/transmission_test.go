package cli

import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/dpup/leysdr/go/internal/fakedaemon"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
)

// Only the close edge of a squelch transition carries a summary. An open edge
// describes a transmission that has not finished, so it has no duration and no
// final peak, and a client must be able to tell that apart from a transmission
// that really was zero samples long.
func TestClosedTransmissionOnlyOnTheCloseEdge(t *testing.T) {
	const rate = 2_400_000
	for _, tc := range []struct {
		name string
		sq   *leylinev1.SquelchTransition
		want bool
	}{
		{"nil", nil, false},
		{"open edge", &leylinev1.SquelchTransition{Open: true, DurationSamples: 0}, false},
		{"open edge with a stale duration", &leylinev1.SquelchTransition{Open: true, DurationSamples: 99}, false},
		{"close edge, nothing measured", &leylinev1.SquelchTransition{Open: false, DurationSamples: 0}, false},
		{"close edge", &leylinev1.SquelchTransition{Open: false, DurationSamples: rate}, true},
	} {
		if _, got := closedTransmission(tc.sq, rate); got != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}

// The duration arrives in capture samples because that is the rate SampleTime
// counts in and the only rate a client is guaranteed to know.
func TestClosedTransmissionConvertsWithTheCaptureRate(t *testing.T) {
	sq := &leylinev1.SquelchTransition{DurationSamples: 3_600_000, PeakSnrDb: 26, PeakAudioDbfs: -7}
	got, ok := closedTransmission(sq, 2_400_000)
	if !ok {
		t.Fatal("a close edge with a duration is a transmission")
	}
	if math.Abs(got.seconds-1.5) > 1e-9 {
		t.Errorf("3.6 M samples at 2.4 MSPS is 1.5 s, got %v", got.seconds)
	}
	// An unknown capture rate costs the duration and nothing else: reporting a
	// wrong number of seconds would be worse than reporting none.
	blind, ok := closedTransmission(sq, 0)
	if !ok {
		t.Fatal("an unknown rate does not stop it being a transmission")
	}
	if !math.IsNaN(blind.seconds) {
		t.Errorf("want NaN seconds without a capture rate, got %v", blind.seconds)
	}
	if blind.peakSNR != 26 || blind.peakDbfs != -7 {
		t.Errorf("the levels do not depend on the rate: %+v", blind)
	}
	if fmtDuration(blind.seconds) != "-" {
		t.Errorf("an unknown duration renders as the absent glyph, got %q", fmtDuration(blind.seconds))
	}
}

func TestFmtDuration(t *testing.T) {
	for _, tc := range []struct {
		in   float64
		want string
	}{
		{0.4, "0.4 s"},
		{12.35, "12.3 s"},
		{59.9, "59.9 s"},
		{60, "1:00.0"},
		{125.4, "2:05.4"},
		{math.NaN(), "-"},
		{math.Inf(1), "-"},
		{-1, "-"},
	} {
		if got := fmtDuration(tc.in); got != tc.want {
			t.Errorf("fmtDuration(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// The style guide's first principle, mechanically: stripping the ink gives back
// the plain screen character for character.
func TestTransmissionStyledStripsToPlain(t *testing.T) {
	for _, tr := range []transmission{
		{seconds: 4.2, peakSNR: 26, peakDbfs: -4},
		{seconds: math.NaN(), peakSNR: math.NaN(), peakDbfs: math.NaN()},
		{seconds: 90, peakSNR: 8, peakDbfs: math.Inf(-1)},
	} {
		plain := tr.render(ui.Style{})
		styled := tr.render(ui.Style{Color: true, Unicode: true, Profile: ui.ProfileTrueColor})
		if ui.Strip(styled) != plain {
			t.Errorf("styled != plain for %+v:\n plain  %q\n styled %q", tr, plain, ui.Strip(styled))
		}
		if strings.Contains(plain, "\x1b") {
			t.Errorf("the plain render carries an escape: %q", plain)
		}
	}
}

// A meter that has not warmed up reports NaN SNR, and a digitally silent
// interval reports -inf. Neither may be printed as a number.
func TestTransmissionOmitsUnmeasuredValues(t *testing.T) {
	tr := transmission{seconds: 2, peakSNR: math.NaN(), peakDbfs: math.Inf(-1)}
	got := tr.render(ui.Style{})
	if strings.Contains(got, "NaN") || strings.Contains(got, "Inf") {
		t.Errorf("unmeasured values must be omitted, got %q", got)
	}
	if !strings.Contains(got, "2.0 s") {
		t.Errorf("the duration is still reported: %q", got)
	}
}

// End to end: a transmission that ends while ley tune is running is reported to
// the person, on stderr, above the live meter. The fake daemon's synthetic
// power swells through the threshold, so both edges happen within a few
// hundred milliseconds at this meter interval.
func TestTuneReportsAFinishedTransmission(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	stdout, errOut := liveTune(t, sock, "transmission", "tune", "146.52", "--no-audio", "--squelch", "-50")
	if !strings.Contains(errOut, "transmission") {
		t.Fatalf("a finished transmission is reported on stderr:\n%s", errOut)
	}
	// It is prose, so it belongs to the person, not to a script's stdout.
	if strings.Contains(stdout, "transmission") {
		t.Fatalf("the transmission log belongs on stderr:\n%s", stdout)
	}
	// The line must carry a duration, not just the word.
	if !strings.Contains(errOut, " s") {
		t.Fatalf("want a duration in the transmission line:\n%s", errOut)
	}
}
