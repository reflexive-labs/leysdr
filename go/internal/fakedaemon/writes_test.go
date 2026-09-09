package fakedaemon_test

import (
	"context"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
)

// TestStoredWritesWhileOutOfCapture mirrors the daemon's FU-2 rule: bandwidth,
// mode and squelch writes on an OUT_OF_CAPTURE channel are stored, not
// rejected, and take effect when the capture retunes back over the channel.
// Only the offset-independent bound (0 < bandwidth <= capture rate) is checked.
func TestStoredWritesWhileOutOfCapture(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	st := mustState(t, c)
	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 100_000_000})
	if err != nil {
		t.Fatal(err)
	}
	// +1 MHz fits a 2.4 MSPS capture (|offset| + bw/2 <= Fs/2) but not a 1.024 MSPS one.
	// The fake keeps offsets relative to the centre across retunes, so the rate is the
	// lever that moves a channel out of (and back into) the capture here.
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cap.CaptureId, OffsetHz: 1_000_000, Mode: leylinev1.DemodMode_NFM})
	if err != nil {
		t.Fatal(err)
	}
	write := func(w *leylinev1.ParamWrite) uint64 {
		t.Helper()
		sum, err := c.WriteParams(ctx, w)
		if err != nil {
			t.Fatalf("WriteParams: %v", err)
		}
		return sum.WritesApplied
	}
	channel := func() *leylinev1.Channel {
		t.Helper()
		for _, got := range mustState(t, c).Channels {
			if got.ChannelId == ch.ChannelId {
				return got
			}
		}
		t.Fatalf("channel %s vanished", ch.ChannelId)
		return nil
	}

	// Narrow the capture: the channel goes OUT_OF_CAPTURE.
	if n := write(&leylinev1.ParamWrite{TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_CaptureSampleRate{CaptureSampleRate: 1_024_000}}); n != 1 {
		t.Fatalf("rate change applied = %d", n)
	}
	if got := channel(); got.State != leylinev1.ChannelState_OUT_OF_CAPTURE {
		t.Fatalf("state after rate change = %v", got.State)
	}

	// Bandwidth, mode and squelch are stored while out.
	if n := write(&leylinev1.ParamWrite{TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_BandwidthHz{BandwidthHz: 8_000}}); n != 1 {
		t.Errorf("bandwidth while out: applied = %d, want 1", n)
	}
	if n := write(&leylinev1.ParamWrite{TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_Mode{Mode: leylinev1.DemodMode_AM}}); n != 1 {
		t.Errorf("mode while out: applied = %d, want 1", n)
	}
	if n := write(&leylinev1.ParamWrite{TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: -60}}); n != 1 {
		t.Errorf("squelch while out: applied = %d, want 1", n)
	}
	got := channel()
	if got.State != leylinev1.ChannelState_OUT_OF_CAPTURE || got.BandwidthHz != 8_000 || got.Mode != leylinev1.DemodMode_AM || got.SquelchDb != -60 || got.OffsetHz != 1_000_000 {
		t.Errorf("stored config = %v", got)
	}

	// The offset-independent bound still applies while out; a rejected write leaves the stored config alone.
	if n := write(&leylinev1.ParamWrite{TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_BandwidthHz{BandwidthHz: 1_024_001}}); n != 0 {
		t.Errorf("bandwidth wider than the capture: applied = %d, want 0", n)
	}
	if n := write(&leylinev1.ParamWrite{TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_BandwidthHz{BandwidthHz: 0}}); n != 0 {
		t.Errorf("zero bandwidth: applied = %d, want 0", n)
	}
	// An offset write while out is still validated against the current capture.
	if n := write(&leylinev1.ParamWrite{TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_OffsetHz{OffsetHz: -2_000_000}}); n != 0 {
		t.Errorf("offset outside the capture: applied = %d, want 0", n)
	}
	if got := channel(); got.BandwidthHz != 8_000 || got.OffsetHz != 1_000_000 || got.State != leylinev1.ChannelState_OUT_OF_CAPTURE {
		t.Errorf("rejected writes changed the channel: %v", got)
	}

	// Widen the capture again: active with the stored bandwidth/mode/squelch.
	if n := write(&leylinev1.ParamWrite{TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_CaptureSampleRate{CaptureSampleRate: 2_400_000}}); n != 1 {
		t.Fatalf("rate restore applied = %d", n)
	}
	got = channel()
	if got.State != leylinev1.ChannelState_CHANNEL_ACTIVE || got.BandwidthHz != 8_000 || got.Mode != leylinev1.DemodMode_AM || got.SquelchDb != -60 {
		t.Errorf("re-entered channel = %v", got)
	}
}
