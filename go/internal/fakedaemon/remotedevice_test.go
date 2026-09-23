// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// TestAttachRTLTCPDevice: a remote radio joins the device list looking like the one
// RTLTCPDevice builds from an rtl_tcp header, and the endpoint is what identifies it.
func TestAttachRTLTCPDevice(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	dev, err := c.AttachDevice(ctx, leyline.RtlTcpSource("pi.local", 1234))
	if err != nil {
		t.Fatal(err)
	}
	if dev.Driver != "rtltcp" {
		t.Errorf("driver = %q, want rtltcp", dev.Driver)
	}
	if dev.Model != "rtl_tcp pi.local:1234 (R820T)" {
		t.Errorf("model = %q", dev.Model)
	}
	if dev.Serial != "pi.local:1234" {
		t.Errorf("serial = %q, want the endpoint", dev.Serial)
	}
	if dev.UsbLocation != "" {
		t.Errorf("usb_location = %q, want empty for a virtual device", dev.UsbLocation)
	}
	if got := dev.Features["remote"].GetText(); got != "pi.local:1234" {
		t.Errorf("remote feature = %q", got)
	}
	if len(dev.GainElements) != 1 || !reflect.DeepEqual(dev.GainElements[0].ValidDb, fakedaemon.R820TGains) {
		t.Errorf("gain elements = %v, want the R820T table", dev.GainElements)
	}
	st := mustState(t, c)
	var found bool
	for _, d := range st.Devices {
		if d.DeviceId == dev.DeviceId {
			found = true
		}
	}
	if !found {
		t.Errorf("attached device is not in the state snapshot")
	}
}

// TestAttachRTLTCPDuplicate: one endpoint is one radio, however many times a client asks.
func TestAttachRTLTCPDuplicate(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	first, err := c.AttachDevice(ctx, leyline.RtlTcpSource("pi.local", 1234))
	if err != nil {
		t.Fatal(err)
	}
	second, err := c.AttachDevice(ctx, leyline.RtlTcpSource("pi.local", 1234))
	if err != nil {
		t.Fatal(err)
	}
	if second.DeviceId != first.DeviceId {
		t.Errorf("second attach = %s, want the existing %s", second.DeviceId, first.DeviceId)
	}
	var remotes int
	for _, d := range mustState(t, c).Devices {
		if d.Driver == "rtltcp" {
			remotes++
		}
	}
	if remotes != 1 {
		t.Errorf("rtltcp devices = %d, want 1", remotes)
	}
}

// TestAttachRTLTCPUnreachable: attach connects once, and an endpoint it cannot reach is a typo,
// not a radio to remember. The refusal names the endpoint so the typo is visible.
func TestAttachRTLTCPUnreachable(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	_, err := c.AttachDevice(ctx, leyline.RtlTcpSource("nosuch.invalid", 1234))
	if leyline.Code(err) != leyline.CodeDeviceIO {
		t.Fatalf("unreachable host: want DEVICE_IO, got %v", err)
	}
	if !strings.Contains(err.Error(), "nosuch.invalid:1234") {
		t.Errorf("refusal %q does not name the endpoint", err)
	}
	for _, d := range mustState(t, c).Devices {
		if d.Driver == "rtltcp" {
			t.Errorf("a failed attach left %s behind", d.DeviceId)
		}
	}
	// A port outside 1...65535 never reaches a socket.
	if _, err := c.AttachDevice(ctx, leyline.RtlTcpSource("pi.local", 0)); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("port 0: want INVALID_ARGUMENT, got %v", err)
	}
	if _, err := c.AttachDevice(ctx, leyline.RtlTcpSource("", 1234)); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("empty host: want INVALID_ARGUMENT, got %v", err)
	}
}

// TestDetachRTLTCPDevice: detaching a remote radio takes its capture with it and announces both,
// and the device list forgets it.
func TestDetachRTLTCPDevice(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	dev, err := c.AttachDevice(ctx, leyline.RtlTcpSource("pi.local", 1234))
	if err != nil {
		t.Fatal(err)
	}
	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: dev.DeviceId, CenterHz: 146_520_000})
	if err != nil {
		t.Fatal(err)
	}
	evCtx, cancelEvents := context.WithCancel(ctx)
	defer cancelEvents()
	// Resuming from the snapshot's seq means the detach cannot slip past a stream that is still
	// being set up.
	events, _, err := c.Events(evCtx, leyline.ScopeSince(nil, mustState(t, c).EventSeq))
	if err != nil {
		t.Fatal(err)
	}
	if err := c.DetachDevice(ctx, dev.DeviceId); err != nil {
		t.Fatal(err)
	}
	sawDev, sawCap := false, false
	timeout := time.After(2 * time.Second)
	for !sawDev || !sawCap {
		select {
		case ev := <-events:
			if d := ev.GetDevice(); d != nil && d.DeviceId == dev.DeviceId && d.State == leylinev1.DeviceState_DISCONNECTED {
				sawDev = true
			}
			if cp := ev.GetCapture(); cp != nil && cp.CaptureId == cap.CaptureId {
				sawCap = true
			}
		case <-timeout:
			t.Fatalf("detach events not seen: device %v capture %v", sawDev, sawCap)
		}
	}
	st := mustState(t, c)
	for _, d := range st.Devices {
		if d.DeviceId == dev.DeviceId {
			t.Errorf("detached device %s is still listed", d.DeviceId)
		}
	}
	if len(st.Captures) != 0 {
		t.Errorf("captures after detach = %v", st.Captures)
	}
	if err := c.DetachDevice(ctx, dev.DeviceId); leyline.Code(err) != leyline.CodeDeviceNotFound {
		t.Errorf("detaching twice: want DEVICE_NOT_FOUND, got %v", err)
	}
}

// TestAttachDeviceFileSource: AttachFileDevice is sugar, so a file source goes through
// AttachDevice to the same playback device, and DetachDevice takes any hosted device away.
func TestAttachDeviceFileSource(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	path := writeRecording(t, t.TempDir(), "clip", 4096, `{"sample_rate": 100000, "center_hz": 146520000}`)
	dev, err := c.AttachDevice(ctx, leyline.FileSource(path, true))
	if err != nil {
		t.Fatal(err)
	}
	if dev.Driver != "file" {
		t.Errorf("driver = %q, want file", dev.Driver)
	}
	if got := dev.Features["loop"].GetFlag(); !got {
		t.Errorf("loop feature = %v, want true", got)
	}
	if err := c.DetachDevice(ctx, dev.DeviceId); err != nil {
		t.Fatal(err)
	}
	for _, d := range mustState(t, c).Devices {
		if d.DeviceId == dev.DeviceId {
			t.Errorf("detached file device %s is still listed", d.DeviceId)
		}
	}
	// A request with no source is invalid.
	if _, err := c.Control.AttachDevice(ctx, &leylinev1.AttachDeviceRequest{}); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("empty source: want INVALID_ARGUMENT, got %v", err)
	}
}

// TestDetachDeviceRefusesUSB: a client cannot remove a dongle in this machine's USB port.
func TestDetachDeviceRefusesUSB(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	var usb string
	for _, d := range mustState(t, c).Devices {
		if d.Driver == "rtlsdr" {
			usb = d.DeviceId
		}
	}
	if usb == "" {
		t.Fatal("the fake has no built-in USB radio to refuse")
	}
	err := c.DetachDevice(ctx, usb)
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Fatalf("detaching a USB radio: want INVALID_ARGUMENT, got %v", err)
	}
	if !strings.Contains(err.Error(), "unplug it") {
		t.Errorf("refusal %q does not say what to do instead", err)
	}
}
