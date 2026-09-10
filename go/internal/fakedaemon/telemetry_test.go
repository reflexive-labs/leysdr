package fakedaemon_test

import (
	"context"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// detections opens a DETECTION-only subscription in the given scope and returns a channel of the
// centre frequencies it sees.
func detections(t *testing.T, ctx context.Context, c *leyline.Client, sub *leylinev1.TelemetrySubscription) <-chan uint64 {
	t.Helper()
	sub.Types = []leylinev1.TelemetryType{leylinev1.TelemetryType_DETECTION}
	msgs, _, err := c.WatchTelemetry(ctx, sub)
	if err != nil {
		t.Fatal(err)
	}
	out := make(chan uint64, 64)
	go func() {
		for m := range msgs {
			if d := m.GetDetection(); d != nil {
				select {
				case out <- d.CenterHz:
				default:
				}
			}
		}
		close(out)
	}()
	return out
}

// A scan runs on one radio, and a subscriber scoped to another one is not looking at it: the
// daemon's job hub filters detections by the capture the sweep leased, and so does the fake.
func TestDetectionsFollowTheSubscriptionScope(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	st := mustState(t, c)
	swept, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_000_000})
	if err != nil {
		t.Fatal(err)
	}
	// A second radio, so there is a capture the sweep has nothing to do with.
	path := writeRecording(t, t.TempDir(), "other", 250_000, `{"sample_rate": 250000, "center_hz": 100000000}`)
	dev, err := c.Control.AttachFileDevice(ctx, &leylinev1.AttachFileDeviceRequest{Path: path, Loop: true})
	if err != nil {
		t.Fatal(err)
	}
	elsewhere, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: dev.DeviceId, CenterHz: 100_000_000})
	if err != nil {
		t.Fatal(err)
	}
	onSwept := detections(t, ctx, c, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_CaptureId{CaptureId: swept.CaptureId},
	})
	onOther := detections(t, ctx, c, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_CaptureId{CaptureId: elsewhere.CaptureId},
	})
	if _, err := c.Jobs.StartJob(ctx, &leylinev1.StartJobRequest{Config: &leylinev1.StartJobRequest_Scan{
		Scan: &leylinev1.ScanConfig{Range: &leylinev1.FrequencyRange{MinHz: 145_000_000, MaxHz: 147_000_000}, DwellMs: 20},
	}}); err != nil {
		t.Fatal(err)
	}
	select {
	case hz := <-onSwept:
		if hz == 0 {
			t.Errorf("detection without a frequency")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the capture the sweep runs on saw no detections")
	}
	select {
	case hz := <-onOther:
		t.Errorf("a capture the sweep never touched was told about %d Hz", hz)
	case <-time.After(300 * time.Millisecond):
	}
}

// Options.MeterInterval has no upper bound, and a cadence slower than a second still has to land on
// a tick. Any tick at all proves the handler survived.
func TestSlowMeterIntervalStillTicks(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{MeterInterval: 1200 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	setupCaptureChannel(t, c)
	msgs, _, err := c.WatchTelemetry(ctx, &leylinev1.TelemetrySubscription{})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case m, ok := <-msgs:
		if !ok {
			t.Fatal("telemetry ended without a message")
		}
		if m.GetMeter() == nil && m.GetActivity() == nil {
			t.Errorf("first message = %v", m)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no telemetry at a 1.2 s cadence")
	}
}
