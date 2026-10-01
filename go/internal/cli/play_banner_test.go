// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/session"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

func fileDescriptor(rates []uint64, seconds float64, loop bool) *leylinev1.DeviceDescriptor {
	d := &leylinev1.DeviceDescriptor{SampleRates: rates, Features: map[string]*leylinev1.FeatureValue{}}
	if seconds > 0 {
		d.Features["duration_s"] = &leylinev1.FeatureValue{Value: &leylinev1.FeatureValue_Number{Number: seconds}}
	}
	d.Features["loop"] = &leylinev1.FeatureValue{Value: &leylinev1.FeatureValue_Flag{Flag: loop}}
	return d
}

// play's second banner line answers "what am I listening to", where tune's
// answers "on what radio".
func TestPlayedSource(t *testing.T) {
	got := playedSource("/tmp/nfm_tone.cf32", fileDescriptor([]uint64{2_400_000}, 1.024, true))
	for _, want := range []string{"nfm_tone.cf32", "1.0 s", "2.4 MSPS", "looping"} {
		if !strings.Contains(got, want) {
			t.Errorf("want %q in %q", want, got)
		}
	}
	// The rate is how fast the file is read, not where it sits on the dial, and
	// the line above already carries a frequency.
	if strings.Contains(got, "MHz") {
		t.Errorf("a sample rate is not a frequency: %q", got)
	}
	if strings.Contains(playedSource("/tmp/x.cf32", fileDescriptor([]uint64{2_400_000}, 1, false)), "looping") {
		t.Error("a one-shot must not claim to loop")
	}
}

// A thin descriptor must not be the thing that crashes the banner.
func TestPlayedSourceSurvivesAThinDescriptor(t *testing.T) {
	for _, d := range []*leylinev1.DeviceDescriptor{
		{},
		fileDescriptor(nil, 0, false),
		fileDescriptor([]uint64{}, 0, false),
	} {
		got := playedSource("/tmp/rec.cf32", d)
		if !strings.Contains(got, "rec.cf32") {
			t.Errorf("the name always survives: %q", got)
		}
	}
}

// The "from another terminal" line must keep offering something that works: a
// file device refuses every gain write, so offering `ley set gain` there
// would suggest a command that fails.
func TestBannerSecondHintFollowsTheDevice(t *testing.T) {
	radio := &verbSession{Session: &session.Session{Capture: &leylinev1.Capture{Gains: []*leylinev1.GainState{{Db: 30}}}}}
	if got := radio.bannerSecondHint(); got != "ley set gain 30" {
		t.Errorf("a radio with gain offers it, got %q", got)
	}
	file := &verbSession{Session: &session.Session{Capture: &leylinev1.Capture{}}}
	if got := file.bannerSecondHint(); got == "ley set gain 30" {
		t.Errorf("a device with no gain must not be offered a gain write: %q", got)
	}
}

// The banner is still five lines, and stripping the ink gives back the plain
// screen character for character.
func TestPlayBannerStripsToPlain(t *testing.T) {
	s := &verbSession{
		Session:    &session.Session{Capture: &leylinev1.Capture{}},
		app:        &App{Style: ui.Style{}, ErrStyle: ui.Style{}},
		device:     &leylinev1.DeviceDescriptor{Model: "nfm_tone.cf32"},
		sourceLine: "nfm_tone.cf32, 1.0 s at 2.4 MSPS, looping",
	}
	o := &tuneOptions{freq: 146_620_000, mode: leylinev1.DemodMode_NFM, squelch: 0}
	plain := s.banner(o)
	if n := len(strings.Split(strings.TrimSuffix(plain, "\n"), "\n")); n != 5 {
		t.Errorf("the banner is five lines, got %d:\n%s", n, plain)
	}
	if !strings.Contains(plain, "Playing nfm_tone.cf32") {
		t.Errorf("want the source line:\n%s", plain)
	}
	if strings.Contains(plain, "Radio") {
		t.Errorf("play names what it plays, not the file device:\n%s", plain)
	}
	// The two styles must differ only in ink: the alphabet legitimately changes
	// glyphs (an ASCII ellipsis is "..."), and that is not what strip-to-plain
	// is about.
	for _, uni := range []bool{false, true} {
		for _, w := range []int{0, 40, 100} {
			base := ui.Style{Unicode: uni, Width: w}
			ink := ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: uni, Width: w}
			p := &verbSession{Session: &session.Session{Capture: s.Capture}, app: &App{Style: base, ErrStyle: base}, device: s.device, sourceLine: s.sourceLine}
			q := &verbSession{Session: &session.Session{Capture: s.Capture}, app: &App{Style: ink, ErrStyle: ink}, device: s.device, sourceLine: s.sourceLine}
			if got, want := ui.Strip(q.banner(o)), p.banner(o); got != want {
				t.Errorf("unicode %v width %d:\n plain  %q\n styled %q", uni, w, want, got)
			}
		}
	}
	// An unknown width is not a narrow one: piped, the source line arrives whole.
	whole := &verbSession{Session: &session.Session{Capture: s.Capture}, app: &App{Style: ui.Style{}, ErrStyle: ui.Style{}}, device: s.device, sourceLine: s.sourceLine}
	if !strings.Contains(whole.banner(o), s.sourceLine) {
		t.Errorf("an unknown width must not truncate:\n%s", whole.banner(o))
	}
}
