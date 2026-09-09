package cli

import (
	"context"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// secondRTLSDR is an available dongle beside the built-in one, so a test can
// hold two captures at once.
func secondRTLSDR() *leylinev1.DeviceDescriptor {
	d := fakedaemon.HeldRTLSDR()
	d.State = leylinev1.DeviceState_AVAILABLE
	d.GainElements = []*leylinev1.GainElement{{Name: "TUNER", MaxDb: 49.6, SupportsAuto: true, ValidDb: fakedaemon.R820TGains}}
	delete(d.Features, "held_externally")
	return d
}

// An explicit --channel and --capture that name different captures is a usage
// error naming both ids; agreeing selectors still work.
func TestSetChannelCaptureDisagree(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{ExtraDevices: []*leylinev1.DeviceDescriptor{secondRTLSDR()}})
	st, _ := c.State(context.Background())
	if len(st.Devices) != 2 {
		t.Fatalf("want 2 devices, got %d", len(st.Devices))
	}
	ctx := context.Background()
	var caps []*leylinev1.Capture
	for i, hz := range []uint64{146_520_000, 101_100_000} {
		cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[i].DeviceId, CenterHz: hz})
		if err != nil {
			t.Fatal(err)
		}
		caps = append(caps, cap)
	}
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: caps[0].CaptureId, BandwidthHz: 12_500, Mode: leylinev1.DemodMode_NFM, Persistent: true})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = run(t, ctx, sock, "set", "squelch", "-40", "--channel", ch.ChannelId, "--capture", caps[1].CaptureId)
	if exitCode(err) != ExitUsage {
		t.Fatalf("disagreeing selectors: exit %d (%v), want %d", exitCode(err), err, ExitUsage)
	}
	for _, want := range []string{ch.ChannelId, caps[0].CaptureId, caps[1].CaptureId} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("message lacks %q: %v", want, err)
		}
	}
	if st, _ = c.State(ctx); !leyline.SquelchOff(st.Channels[0].SquelchDb) {
		t.Fatalf("write must not reach the daemon: %v", st.Channels[0])
	}
	mustRun(t, sock, "set", "squelch", "-40", "--channel", ch.ChannelId, "--capture", caps[0].CaptureId)
	if st, _ = c.State(ctx); st.Channels[0].SquelchDb != -40 {
		t.Fatalf("agreeing selectors: %v", st.Channels[0])
	}
}

// A channel whose offset puts its absolute frequency below zero renders as
// "?" instead of a wrapped-around uint64.
func TestChannelFreqLabelNegative(t *testing.T) {
	st := &leylinev1.GetStateResponse{
		Captures: []*leylinev1.Capture{{CaptureId: "cap_1", CenterHz: 1_000_000}},
		Channels: []*leylinev1.Channel{
			{ChannelId: "chan_neg", CaptureId: "cap_1", OffsetHz: -1_500_000, Mode: leylinev1.DemodMode_NFM},
			{ChannelId: "chan_ok", CaptureId: "cap_1", OffsetHz: 100_000, Mode: leylinev1.DemodMode_NFM},
			{ChannelId: "chan_orphan", CaptureId: "cap_gone", OffsetHz: 0, Mode: leylinev1.DemodMode_NFM},
		},
	}
	neg, ok, orphan := st.Channels[0], st.Channels[1], st.Channels[2]
	if got := channelFreqLabel(st, neg); got != "?" {
		t.Errorf("negative: %q", got)
	}
	if got := channelFreqLabel(st, orphan); got != "?" {
		t.Errorf("orphan: %q", got)
	}
	if got := channelFreqLabel(st, ok); got != "1.100 MHz" {
		t.Errorf("positive: %q", got)
	}
	if got := channelSummary(st, neg); !strings.HasPrefix(got, "? NFM, chan_neg") {
		t.Errorf("channelSummary: %q", got)
	}
	if got := orientChannelLine(st, neg); !strings.HasPrefix(got, "? NFM, ") {
		t.Errorf("orientChannelLine: %q", got)
	}
	ev := &leylinev1.Event{Body: &leylinev1.Event_Channel{Channel: neg}}
	if got := eventLine(ev, st); strings.Contains(got, "Hz") || !strings.Contains(got, "channel chan_neg") {
		t.Errorf("eventLine must omit a nonsense frequency: %q", got)
	}
	ev = &leylinev1.Event{Body: &leylinev1.Event_Channel{Channel: ok}}
	if got := eventLine(ev, st); !strings.Contains(got, " 1.100 MHz ") {
		t.Errorf("eventLine: %q", got)
	}
}
