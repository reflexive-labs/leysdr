// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// TestStoredWritesWhileOutOfCapture mirrors the daemon's rule: bandwidth,
// mode and squelch writes on an OUT_OF_CAPTURE channel are stored, not
// rejected, and take effect when the capture retunes back over the channel.
// Only the offset-independent bound (0 < bandwidth <= capture rate) is checked.
func TestStoredWritesWhileOutOfCapture(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 100_000_000})
	if err != nil {
		t.Fatal(err)
	}
	// +1 MHz fits a 2.4 MSPS capture (|offset| + bw/2 <= Fs/2) but not a 1.024 MSPS one.
	// The fake keeps offsets relative to the centre across retunes, so the rate is the
	// lever that moves a channel out of (and back into) the capture here.
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cp.CaptureId, OffsetHz: 1_000_000, Mode: leylinev1.DemodMode_NFM})
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
	if n := write(&leylinev1.ParamWrite{TargetId: cp.CaptureId, Param: &leylinev1.ParamWrite_CaptureSampleRate{CaptureSampleRate: 1_024_000}}); n != 1 {
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
	if n := write(&leylinev1.ParamWrite{TargetId: cp.CaptureId, Param: &leylinev1.ParamWrite_CaptureSampleRate{CaptureSampleRate: 2_400_000}}); n != 1 {
		t.Fatalf("rate restore applied = %d", n)
	}
	got = channel()
	if got.State != leylinev1.ChannelState_CHANNEL_ACTIVE || got.BandwidthHz != 8_000 || got.Mode != leylinev1.DemodMode_AM || got.SquelchDb != -60 {
		t.Errorf("re-entered channel = %v", got)
	}
}

// gainOf returns the capture's state for one gain element.
func gainOf(t *testing.T, c *leyline.Client, capID, element string) *leylinev1.GainState {
	t.Helper()
	for _, cp := range mustState(t, c).Captures {
		if cp.CaptureId != capID {
			continue
		}
		for _, g := range cp.Gains {
			if g.Element == element {
				return g
			}
		}
	}
	t.Fatalf("capture %s has no %s gain", capID, element)
	return nil
}

// Turning automatic gain off asks for a manual level without naming one, so the daemon puts back
// the level the client last set by hand; an element nothing has ever set lands mid-range rather
// than at the minimum, which would deafen the radio.
func TestGainAutoOffRestoresTheManualLevel(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 100_000_000})
	if err != nil {
		t.Fatal(err)
	}
	el := st.Devices[0].GainElements[0]
	gain := func(g *leylinev1.GainWrite) *leylinev1.ParamWrite {
		g.Element = el.Name
		return &leylinev1.ParamWrite{TargetId: cp.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: g}}
	}
	// Nothing set by hand yet: off means mid-range.
	if _, err := c.WriteParams(ctx, gain(&leylinev1.GainWrite{Value: &leylinev1.GainWrite_Auto{Auto: false}})); err != nil {
		t.Fatal(err)
	}
	got := gainOf(t, c, cp.CaptureId, el.Name)
	mid := el.ValidDb[len(el.ValidDb)/2]
	if got.Auto || got.Db != mid {
		t.Errorf("auto off with no manual level = %v, want %g dB manual", got, mid)
	}
	// A level set by hand survives a trip through automatic gain.
	manual := el.ValidDb[2]
	if _, err := c.WriteParams(ctx, gain(&leylinev1.GainWrite{Value: &leylinev1.GainWrite_Db{Db: manual}})); err != nil {
		t.Fatal(err)
	}
	if _, err := c.WriteParams(ctx, gain(&leylinev1.GainWrite{Value: &leylinev1.GainWrite_Auto{Auto: true}})); err != nil {
		t.Fatal(err)
	}
	if got := gainOf(t, c, cp.CaptureId, el.Name); !got.Auto {
		t.Fatalf("auto on = %v", got)
	}
	if _, err := c.WriteParams(ctx, gain(&leylinev1.GainWrite{Value: &leylinev1.GainWrite_Auto{Auto: false}})); err != nil {
		t.Fatal(err)
	}
	if got := gainOf(t, c, cp.CaptureId, el.Name); got.Auto || got.Db != manual {
		t.Errorf("auto off after a manual level = %v, want %g dB", got, manual)
	}
}

// A GainWrite with neither a level nor an auto flag says nothing: the element exists, so the
// refusal is about the argument's shape rather than the name.
func TestGainWriteNeedsAValue(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 100_000_000})
	if err != nil {
		t.Fatal(err)
	}
	el := st.Devices[0].GainElements[0]
	before := gainOf(t, c, cp.CaptureId, el.Name)
	evCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	start := mustState(t, c)
	events, _, err := c.Events(evCtx, leyline.ScopeSince(leyline.CaptureScope(cp.CaptureId), start.EventSeq))
	if err != nil {
		t.Fatal(err)
	}
	sum, err := c.WriteParams(ctx, &leylinev1.ParamWrite{Tag: 3, TargetId: cp.CaptureId, Param: &leylinev1.ParamWrite_Gain{
		Gain: &leylinev1.GainWrite{Element: el.Name},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if sum.WritesApplied != 0 {
		t.Errorf("summary = %v", sum)
	}
	deadline := time.After(2 * time.Second)
	for {
		select {
		case ev := <-events:
			r := ev.GetWriteRejected()
			if r == nil || r.Tag != 3 {
				continue
			}
			if r.Error.GetCode() != leyline.CodeInvalidArgument || r.Error.GetMessage() != "gain value is required" {
				t.Errorf("rejection = %v", r.Error)
			}
			if got := gainOf(t, c, cp.CaptureId, el.Name); got.Auto != before.Auto || got.Db != before.Db {
				t.Errorf("gain moved on a refused write: %v", got)
			}
			return
		case <-deadline:
			t.Fatal("no WriteRejected for a gain write with no value")
		}
	}
}

// A write that names no element lands on the first the device lists, the rule the contract states
// and the daemon applies; the confirmed state comes back under that element's name.
func TestGainWriteWithAnEmptyElementIsTheFirst(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 100_000_000})
	if err != nil {
		t.Fatal(err)
	}
	el := st.Devices[0].GainElements[0]
	level := el.ValidDb[3]
	w := &leylinev1.ParamWrite{TargetId: cp.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: &leylinev1.GainWrite{Value: &leylinev1.GainWrite_Db{Db: level}}}}
	sum, err := c.WriteParams(ctx, w)
	if err != nil {
		t.Fatal(err)
	}
	if sum.WritesApplied != 1 {
		t.Fatalf("applied %d writes, want 1", sum.WritesApplied)
	}
	if got := gainOf(t, c, cp.CaptureId, el.Name); got.Auto || got.Db != level {
		t.Errorf("empty element = %v, want %s at %g dB manual", got, el.Name, level)
	}
}
