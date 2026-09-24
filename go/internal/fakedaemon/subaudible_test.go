// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"math"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
)

// Options.DCS puts a code on a carrier: a channel there hears SUB_AUDIBLE_DCS with the code as the
// contract carries it and nothing measured as a tone, and never the carrier's CTCSS tone, which the
// daemon suppresses while DCS is locked.
func TestDCSOptionReportsTheCode(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{
		MeterInterval: 20 * time.Millisecond,
		DCS:           map[uint64]fakedaemon.DCSCode{146_940_000: {Code: 754, Inverted: true}},
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	st := mustState(t, c)
	capt, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_900_000})
	if err != nil {
		t.Fatal(err)
	}
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: capt.CaptureId, OffsetHz: 40_000, Mode: leylinev1.DemodMode_NFM})
	if err != nil {
		t.Fatal(err)
	}
	msgs, _, err := c.WatchTelemetry(ctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_ChannelId{ChannelId: ch.ChannelId},
		Types: []leylinev1.TelemetryType{leylinev1.TelemetryType_SUB_AUDIBLE},
	})
	if err != nil {
		t.Fatal(err)
	}
	for m := range msgs {
		sa := m.GetSubAudible()
		if sa == nil {
			continue
		}
		if sa.Kind == leylinev1.SubAudibleKind_SUB_AUDIBLE_CTCSS {
			t.Fatalf("a DCS carrier reported a CTCSS tone: %v", sa)
		}
		if sa.Kind != leylinev1.SubAudibleKind_SUB_AUDIBLE_DCS {
			continue
		}
		if sa.DcsCode != 754 || !sa.DcsInverted || sa.DeviationHz != 550 || sa.Confidence <= 0 {
			t.Errorf("DCS report %v, want 754 inverted at 550 Hz with a confidence", sa)
		}
		if !math.IsNaN(sa.ToneHz) || !math.IsNaN(sa.ToneSnrDb) || sa.StandardToneHz != 0 {
			t.Errorf("a DCS report measured no tone: %v", sa)
		}
		return
	}
	t.Fatal("no DCS report within 5 s")
}
