// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"math"
	"regexp"
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
		{"close edge, a noise blip", &leylinev1.SquelchTransition{Open: false, DurationSamples: rate / 10}, false},
		{"close edge, just long enough", &leylinev1.SquelchTransition{Open: false, DurationSamples: rate / 4}, true},
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

// Time on air is counted from the open edge's sample time to the meter's, at
// the capture rate, in whole seconds: what a person glances at while the other
// station talks. Without an open edge there is nothing to count from.
func TestOnAirSince(t *testing.T) {
	const rate = 2_400_000
	opened := &leylinev1.SampleTime{CaptureId: "cap_a", SampleIndex: 10 * rate}
	at := func(index uint64) *leylinev1.SampleTime {
		return &leylinev1.SampleTime{CaptureId: "cap_a", SampleIndex: index}
	}
	for _, tc := range []struct {
		name   string
		opened *leylinev1.SampleTime
		now    *leylinev1.SampleTime
		rate   uint64
		want   onAir
	}{
		{"just opened", opened, at(10 * rate), rate, onAir{known: true, seconds: 0}},
		{"4.9 s in is 4 s", opened, at(10*rate + 4*rate + 2_160_000), rate, onAir{known: true, seconds: 4}},
		{"a minute and a half", opened, at(10*rate + 90*rate), rate, onAir{known: true, seconds: 90}},
		{"no open edge seen", nil, at(12 * rate), rate, onAir{}},
		{"unknown rate", opened, at(12 * rate), 0, onAir{}},
		{"meter before the edge", opened, at(9 * rate), rate, onAir{}},
		{"another capture", opened, &leylinev1.SampleTime{CaptureId: "cap_b", SampleIndex: 12 * rate}, rate, onAir{}},
	} {
		if got := onAirSince(tc.opened, tc.now, tc.rate); got != tc.want {
			t.Errorf("%s: got %+v, want %+v", tc.name, got, tc.want)
		}
	}
}

// The closed transmission's start is reconstructed from the close edge and the
// duration, and dated only through an anchor that covers it: the same capture,
// with a host time the daemon actually published.
func TestTransmissionStart(t *testing.T) {
	const rate = 2_400_000
	epoch := time.Date(2026, 9, 20, 15, 4, 0, 0, time.UTC)
	anchor := &leylinev1.CaptureAnchor{CaptureId: "cap_a", HostTimeNs: epoch.UnixNano(), SampleRate: rate}
	// Closed 12 s into the capture after 5 s open: it began at 7 s.
	sq := &leylinev1.SquelchTransition{DurationSamples: 5 * rate, PeakSnrDb: 20, PeakAudioDbfs: -10}
	closeAt := &leylinev1.SampleTime{CaptureId: "cap_a", SampleIndex: 12 * rate}

	got, ok := transmissionStart(sq, closeAt, anchor)
	if !ok {
		t.Fatal("an anchor on the same capture covers the start")
	}
	if want := epoch.Add(7 * time.Second); !got.Equal(want) {
		t.Errorf("start = %v, want %v", got, want)
	}

	for _, tc := range []struct {
		name   string
		sq     *leylinev1.SquelchTransition
		at     *leylinev1.SampleTime
		anchor *leylinev1.CaptureAnchor
	}{
		{"no anchor", sq, closeAt, nil},
		{"anchor on another capture", sq, closeAt, &leylinev1.CaptureAnchor{CaptureId: "cap_b", HostTimeNs: epoch.UnixNano(), SampleRate: rate}},
		{"undated anchor, first block not yet seen", sq, closeAt, &leylinev1.CaptureAnchor{CaptureId: "cap_a", SampleRate: rate}},
		{"anchor without a rate", sq, closeAt, &leylinev1.CaptureAnchor{CaptureId: "cap_a", HostTimeNs: epoch.UnixNano()}},
		{"duration runs past the capture's start", &leylinev1.SquelchTransition{DurationSamples: 13 * rate}, closeAt, anchor},
		{"no close time", sq, nil, anchor},
	} {
		if at, ok := transmissionStart(tc.sq, tc.at, tc.anchor); ok {
			t.Errorf("%s: want no clock, got %v", tc.name, at)
		}
	}
}

// The mirror holds one anchor per capture, the newest the daemon published.
func TestCaptureAnchorFromTheMirror(t *testing.T) {
	a := &leylinev1.CaptureAnchor{CaptureId: "cap_a", HostTimeNs: 1, SampleRate: 2_400_000}
	state := &leylinev1.GetStateResponse{Captures: []*leylinev1.Capture{{CaptureId: "cap_a", Anchor: a}, {CaptureId: "cap_b"}}}
	if got := captureAnchor(state, "cap_a"); got != a {
		t.Errorf("cap_a: got %v", got)
	}
	if got := captureAnchor(state, "cap_b"); got != nil {
		t.Errorf("cap_b has no anchor yet, got %v", got)
	}
	if got := captureAnchor(state, "cap_c"); got != nil {
		t.Errorf("cap_c is not in state, got %v", got)
	}
	// An Anchor event replaces the one the Capture arrived with.
	s := &session{state: state, capture: state.Captures[0]}
	fresh := &leylinev1.CaptureAnchor{CaptureId: "cap_a", HostTimeNs: 2, SampleRate: 2_400_000}
	s.fold(&leylinev1.Event{Body: &leylinev1.Event_Anchor{Anchor: fresh}})
	if got := captureAnchor(s.state, "cap_a"); got != fresh {
		t.Errorf("after the anchor event: got %v, want the fresh anchor", got)
	}
	if s.capture.GetAnchor() != fresh {
		t.Errorf("the session's own capture keeps the fresh anchor too")
	}
}

// A dated transmission leads with its clock, in Muted ink that strips to the
// plain stamp; an undated one begins with the word, as before.
func TestTransmissionRenderStamp(t *testing.T) {
	start := time.Date(2026, 9, 20, 15, 4, 5, 0, time.Local)
	dated := transmission{seconds: 4.2, peakSNR: 26, peakDbfs: -4, start: start}
	plain := dated.render(ui.Style{})
	if want := "15:04:05  transmission  4.2 s  peak snr 26 dB  peak -4 dBFS"; plain != want {
		t.Errorf("dated line:\n got  %q\n want %q", plain, want)
	}
	styled := dated.render(ui.Style{Color: true, Unicode: true, Profile: ui.ProfileTrueColor})
	if ui.Strip(styled) != plain {
		t.Errorf("styled != plain:\n plain  %q\n styled %q", plain, ui.Strip(styled))
	}
	undated := transmission{seconds: 4.2, peakSNR: 26, peakDbfs: -4}
	if got := undated.render(ui.Style{}); !strings.HasPrefix(got, "transmission  ") {
		t.Errorf("an undated line begins with the word: %q", got)
	}
}

// End to end: the fake daemon dates its captures (the anchor's host time is the
// moment the capture was created), so a finished transmission's line carries
// the wall clock it started at, and the meter counts time on air from the
// open edge it saw.
func TestTuneDatesATransmissionAndCountsTimeOnAir(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	_, errOut := liveTune(t, sock, "transmission", "tune", "146.52", "--no-audio", "--squelch", "-50")
	stamped := regexp.MustCompile(`(?m)^\d\d:\d\d:\d\d  transmission  `)
	if !stamped.MatchString(errOut) {
		t.Errorf("the closed line leads with the start the anchor dates:\n%s", errOut)
	}
	// The squelch is open for two of the fake's four-second swell, and the
	// meter repeats itself once a second off a terminal, so a meter tick lands
	// while the squelch is open before the close edge does.
	if !strings.Contains(errOut, "on air ") {
		t.Errorf("the meter counts time on air while the squelch is open:\n%s", errOut)
	}
	if strings.Contains(errOut, "dBFS  audio") {
		t.Errorf("with the open edge seen, the meter says on air, not audio:\n%s", errOut)
	}
}
