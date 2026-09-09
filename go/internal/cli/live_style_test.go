package cli

import (
	"bytes"
	"math"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// liveStyles are the two renders every screen is compared in: the same
// glyphs and width, differing only in ink.
func liveStyles() (plain, styled ui.Style) {
	return ui.Style{Unicode: true, Width: 80}, ui.Style{Color: true, Unicode: true, Width: 80}
}

// liveState is a channel on a capture, as the daemon would report it.
func liveState(squelch float64, mode leylinev1.DemodMode) (*leylinev1.GetStateResponse, *leylinev1.Channel, *leylinev1.Capture) {
	cap := &leylinev1.Capture{
		CaptureId: "cap_01M2257VDP6ZQQV9R1YPQPBWBE",
		DeviceId:  "dev_01M2257AN365W1XNJGZ8YJM4P6",
		CenterHz:  146_520_000,
		Gains:     []*leylinev1.GainState{{Element: "TUNER", Db: 7.7}},
	}
	ch := &leylinev1.Channel{
		ChannelId:   "chan_01M225GXKWABV4EK85ENCD6T9N",
		CaptureId:   cap.CaptureId,
		OffsetHz:    100_000,
		Mode:        mode,
		BandwidthHz: 12_500,
		SquelchDb:   squelch,
		State:       leylinev1.ChannelState_CHANNEL_ACTIVE,
	}
	st := &leylinev1.GetStateResponse{
		Devices:  []*leylinev1.DeviceDescriptor{{DeviceId: cap.DeviceId, Model: "Generic RTL2832U (R820T)"}},
		Captures: []*leylinev1.Capture{cap},
		Channels: []*leylinev1.Channel{ch},
	}
	return st, ch, cap
}

// TestBannerSurvivesColourOff renders the live banner twice: the words, the
// device, the squelch sentence and the two hint lines are identical with the
// ink stripped.
func TestBannerSurvivesColourOff(t *testing.T) {
	plain, styled := liveStyles()
	render := func(st ui.Style, note string) string {
		s := &session{
			app:         &App{Style: st},
			device:      &leylinev1.DeviceDescriptor{Model: "Generic RTL2832U (R820T)"},
			capture:     &leylinev1.Capture{Gains: []*leylinev1.GainState{{Element: "TUNER", Auto: true}}},
			squelchNote: note,
		}
		o := &tuneOptions{freq: 146_520_000, mode: leylinev1.DemodMode_NFM, band: leyline.BandFor(146_520_000), squelch: math.NaN()}
		return s.banner(o)
	}
	for _, note := range []string{"", "Squelch auto → -80 dBFS (10 dB above the band's noise floor, -90 dBFS)."} {
		want, got := render(plain, note), render(styled, note)
		if got == want {
			t.Errorf("note %q: a coloured style left the banner unstyled", note)
		}
		if ui.Strip(got) != want {
			t.Errorf("note %q:\n Strip(styled) = %q\n plain         = %q", note, ui.Strip(got), want)
		}
		for _, line := range strings.Split(strings.TrimRight(want, "\n"), "\n") {
			if ui.Visible(line) > 80 {
				t.Errorf("banner line is %d columns: %q", ui.Visible(line), line)
			}
		}
	}
	// The words the docs and the goldens pin are still there, and each fact
	// is on its own line.
	lines := strings.Split(strings.TrimRight(render(plain, ""), "\n"), "\n")
	if len(lines) != 5 {
		t.Fatalf("banner should be one fact per line, got %d:\n%s", len(lines), strings.Join(lines, "\n"))
	}
	for i, want := range []string{"Listening to 146.520 MHz (NFM, 2 m amateur)", "gain auto", "Squelch off.", "Ctrl-C stops.", "From another terminal: ley set squelch -50"} {
		if !strings.Contains(lines[i], want) {
			t.Errorf("banner line %d = %q, want it to carry %q", i+1, lines[i], want)
		}
	}
}

// TestConfirmLineSurvivesColourOff renders a set confirmation twice, and
// pins the shape the line took on: old → new, and no repeated channel id.
func TestConfirmLineSurvivesColourOff(t *testing.T) {
	plain, styled := liveStyles()
	// The pre-write channel had no squelch; the state carries the new one.
	st, ch, cap := liveState(-40, leylinev1.DemodMode_NFM)
	before := &leylinev1.Channel{ChannelId: ch.ChannelId, CaptureId: ch.CaptureId, OffsetHz: ch.OffsetHz, Mode: ch.Mode, BandwidthHz: ch.BandwidthHz, SquelchDb: math.NaN()}
	ev := &leylinev1.Event{}
	want := confirmLine(plain, st, "squelch", "", ev, before, cap)
	got := confirmLine(styled, st, "squelch", "", ev, before, cap)
	if got == want {
		t.Fatal("a coloured style left the confirmation unstyled")
	}
	if ui.Strip(got) != want {
		t.Fatalf("Strip(styled) = %q, want %q", ui.Strip(got), want)
	}
	if w := "squelch off (audio always on) → -40 dBFS on 146.620 MHz NFM (channel 1)"; want != w {
		t.Fatalf("confirmation = %q, want %q", want, w)
	}
	if strings.Contains(want, ch.ChannelId) {
		t.Errorf("the channel id is not repeated in a confirmation: %q", want)
	}
	// gain is the radio's, whichever channel the command addressed.
	gain := confirmLine(plain, st, "gain", "", ev, ch, cap)
	if w := "gain 7.7 dB on the radio (TUNER)"; !strings.Contains(gain, "on the radio (TUNER)") || strings.Contains(gain, "channel") {
		t.Errorf("gain confirmation = %q, want the radio scope like %q", gain, w)
	}
	// An unknown or unchanged previous value falls back to today's shape.
	same := confirmLine(plain, st, "mode", "", ev, ch, cap)
	if !strings.HasPrefix(same, "mode → NFM on ") {
		t.Errorf("unchanged value should not print an arrow from itself: %q", same)
	}
}

// TestSettingsViewSurvivesColourOff renders `ley set` with no arguments
// twice, and keeps the label vocabulary the set subcommands are named after.
func TestSettingsViewSurvivesColourOff(t *testing.T) {
	plain, styled := liveStyles()
	render := func(sty ui.Style) string {
		buf := &bytes.Buffer{}
		st, ch, cap := liveState(math.NaN(), leylinev1.DemodMode_NFM)
		s := &session{app: &App{Stdout: buf, Style: sty}, state: st}
		if err := showSettings(s, ch, cap); err != nil {
			t.Fatal(err)
		}
		return buf.String()
	}
	want, got := render(plain), render(styled)
	if got == want {
		t.Fatal("a coloured style left the settings view unstyled")
	}
	if ui.Strip(got) != want {
		t.Fatalf("Strip(styled) = %q, want %q", ui.Strip(got), want)
	}
	for _, label := range []string{"frequency", "mode", "bandwidth", "squelch", "gain", "volume"} {
		if !strings.Contains(want, "  "+label+" ") {
			t.Errorf("settings view lost the %q label:\n%s", label, want)
		}
	}
	// The three objects are named, so a gain change is not read as a
	// channel change.
	for _, group := range []string{"on the radio", "through the speakers"} {
		if !strings.Contains(want, group+"\n") {
			t.Errorf("settings view lacks the %q group:\n%s", group, want)
		}
	}
}
