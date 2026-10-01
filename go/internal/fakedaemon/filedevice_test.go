// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// writeRecording writes <dir>/<name>.cf32 holding samples CF32 samples and its sidecar.
func writeRecording(t *testing.T, dir, name string, samples int, sidecar string) string {
	t.Helper()
	path := filepath.Join(dir, name+".cf32")
	if err := os.WriteFile(path, make([]byte, samples*8), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".json"), []byte(sidecar), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestAttachFileDeviceValidation: the fake opens the pair like the daemon's
// FilePlaybackDevice and answers with its codes.
func TestAttachFileDeviceValidation(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	dir := t.TempDir()
	attach := func(path string) error {
		_, err := c.Control.AttachFileDevice(ctx, &leylinev1.AttachFileDeviceRequest{Path: path})
		return err
	}

	// No sidecar beside the samples: the daemon cannot stat it (DEVICE_IO).
	lonely := filepath.Join(dir, "lonely.cf32")
	_ = os.WriteFile(lonely, make([]byte, 64), 0o644)
	if err := attach(lonely); leyline.Code(err) != leyline.CodeDeviceIO {
		t.Errorf("missing sidecar: want DEVICE_IO, got %v", err)
	}
	// A directory is not a regular file.
	if err := attach(dir); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("directory: want INVALID_ARGUMENT, got %v", err)
	}
	// Out-of-range sample_rate and malformed JSON are INVALID_ARGUMENT.
	slow := writeRecording(t, dir, "slow", 8, `{"sample_rate": 500, "center_hz": 100000000}`)
	if err := attach(slow); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("sample_rate 500: want INVALID_ARGUMENT, got %v", err)
	}
	fast := writeRecording(t, dir, "fast", 8, `{"sample_rate": 100000001, "center_hz": 100000000}`)
	if err := attach(fast); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("sample_rate 100000001: want INVALID_ARGUMENT, got %v", err)
	}
	broken := writeRecording(t, dir, "broken", 8, `{"sample_rate": `)
	if err := attach(broken); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("malformed sidecar: want INVALID_ARGUMENT, got %v", err)
	}
	// Sidecar without samples: the IQ file is the missing member (DEVICE_IO).
	_ = os.WriteFile(filepath.Join(dir, "nosamples.json"), []byte(`{"sample_rate": 250000, "center_hz": 100000000}`), 0o644)
	if err := attach(filepath.Join(dir, "nosamples.cf32")); leyline.Code(err) != leyline.CodeDeviceIO {
		t.Errorf("missing IQ file: want DEVICE_IO, got %v", err)
	}
	// A good pair, named by its sidecar, resolves to the samples and reports its length.
	good := writeRecording(t, dir, "good", 25_000, `{"sample_rate": 250000, "center_hz": 146520000}`)
	dev, err := c.Control.AttachFileDevice(ctx, &leylinev1.AttachFileDeviceRequest{Path: filepath.Join(dir, "good.json"), Loop: true})
	if err != nil {
		t.Fatalf("good pair: %v", err)
	}
	if dev.Serial != filepath.Base(good) || dev.SampleRates[0] != 250_000 || dev.Features["duration_s"].GetNumber() != 0.1 {
		t.Errorf("descriptor = %v", dev)
	}
}

// TestFileDeviceEOFDetaches: without loop, the stream loop stops at the file's
// last sample and reports the device DISCONNECTED and the capture CAPTURE_DETACHED,
// the way the daemon does when a FilePlaybackDevice hits EOF.
func TestFileDeviceEOFDetaches(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	const rate, samples = 100_000, 15_000 // 150 ms of playback
	path := writeRecording(t, t.TempDir(), "short", samples, `{"sample_rate": 100000, "center_hz": 146520000}`)
	dev, err := c.Control.AttachFileDevice(ctx, &leylinev1.AttachFileDeviceRequest{Path: path, Loop: false})
	if err != nil {
		t.Fatal(err)
	}
	evCtx, cancelEvents := context.WithCancel(ctx)
	defer cancelEvents()
	events, _, err := c.Events(evCtx, nil)
	if err != nil {
		t.Fatal(err)
	}
	capt, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: dev.DeviceId, CenterHz: 146_520_000})
	if err != nil {
		t.Fatal(err)
	}
	sub, err := c.SubscribeFFT(ctx, capt.CaptureId, 256, 50, leylinev1.FftBinFormat_DB_U8)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()
	var frames int
	var last uint64
	deadline := time.After(2 * time.Second)
	for open := true; open; {
		select {
		case fr, ok := <-sub.Frames:
			if !ok {
				open = false
				break
			}
			frames++
			last = fr.Time.GetSampleIndex()
		case <-deadline:
			t.Fatalf("stream still open after 2 s (%d frames)", frames)
		}
	}
	if frames == 0 || last > samples {
		t.Errorf("frames = %d, last sample index = %d (file holds %d)", frames, last, samples)
	}
	st := mustState(t, c)
	if got := leyline.FindCapture(st, dev.DeviceId); got == nil || got.State != leylinev1.CaptureState_CAPTURE_DETACHED {
		t.Errorf("capture after EOF = %v", got)
	}
	var devState leylinev1.DeviceState
	for _, d := range st.Devices {
		if d.DeviceId == dev.DeviceId {
			devState = d.State
		}
	}
	if devState != leylinev1.DeviceState_DISCONNECTED {
		t.Errorf("device after EOF = %v", devState)
	}
	// The detach is announced as full-state events like everything else.
	var sawDev, sawCap bool
	for timeout := time.After(2 * time.Second); !sawDev || !sawCap; {
		select {
		case ev := <-events:
			if d := ev.GetDevice(); d != nil && d.DeviceId == dev.DeviceId && d.State == leylinev1.DeviceState_DISCONNECTED {
				sawDev = true
			}
			if cp := ev.GetCapture(); cp != nil && cp.CaptureId == capt.CaptureId && cp.State == leylinev1.CaptureState_CAPTURE_DETACHED {
				sawCap = true
			}
		case <-timeout:
			t.Fatalf("EOF events not seen: device %v capture %v", sawDev, sawCap)
		}
	}
	// A detached capture still negotiates a stream: the daemon's registry asks whether the capture
	// exists, not what state it is in, and a stream with no source behind it has no frames.
	if _, err := c.SubscribeFFT(ctx, capt.CaptureId, 256, 50, leylinev1.FftBinFormat_DB_U8); err != nil {
		t.Errorf("subscribing to a detached capture: %v", err)
	}
	if _, err := c.Control.DetachFileDevice(ctx, &leylinev1.DetachFileDeviceRequest{DeviceId: dev.DeviceId}); err != nil {
		t.Fatal(err)
	}
	if st := mustState(t, c); len(st.Captures) != 0 {
		t.Errorf("captures after detach = %v", st.Captures)
	}
}
