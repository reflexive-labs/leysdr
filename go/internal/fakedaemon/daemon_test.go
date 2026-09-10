package fakedaemon_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/testutil"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// harness starts a fake daemon on a temp UDS and dials it.
func harness(t *testing.T, opts fakedaemon.Options) (*leyline.Client, string) {
	t.Helper()
	sock := testutil.SocketPath(t, "d.sock")
	ctx, cancel := context.WithCancel(context.Background())
	d := fakedaemon.New(opts)
	served := make(chan error, 1)
	go func() { served <- d.Serve(ctx, sock) }()
	c, err := leyline.Dial(ctx, sock, leyline.WithKind("cli"), leyline.WithLabel("test"))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	// Wait for the listener.
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := c.State(ctx); err == nil || time.Now().After(deadline) {
			if err != nil {
				t.Fatalf("daemon never came up: %v", err)
			}
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Cleanup(func() {
		_ = c.Close()
		cancel()
		<-served
	})
	return c, sock
}

func TestStateAndDevices(t *testing.T) {
	c, sock := harness(t, fakedaemon.Options{})
	st, err := c.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Devices) != 1 || st.Devices[0].Driver != "rtlsdr" {
		t.Fatalf("expected one rtlsdr device, got %v", st.Devices)
	}
	if st.Daemon.GetSocketPath() != sock || st.Daemon.GetVersion() == "" || st.Daemon.GetPid() == 0 {
		t.Errorf("bad daemon info: %v", st.Daemon)
	}
	dev := st.Devices[0]
	if len(dev.GainElements) != 1 || dev.GainElements[0].Name != "TUNER" || !dev.GainElements[0].SupportsAuto || len(dev.GainElements[0].ValidDb) == 0 {
		t.Errorf("bad gain element: %v", dev.GainElements)
	}
	if leyline.FindCapture(st, dev.DeviceId) != nil || leyline.CurrentChannel(st, c.ClientID()) != nil {
		t.Error("fresh daemon should have no capture/channel")
	}
}

func TestLifecycleAndEvents(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	st, _ := c.State(ctx)
	devID := st.Devices[0].DeviceId

	evCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	events, errs, err := c.Events(evCtx, nil)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond) // let the watcher register

	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: devID, CenterHz: 146_520_000})
	if err != nil {
		t.Fatal(err)
	}
	if cap.SampleRate != 2_400_000 || cap.State != leylinev1.CaptureState_CAPTURE_ACTIVE || len(cap.Gains) != 1 {
		t.Errorf("bad capture: %v", cap)
	}
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cap.CaptureId, OffsetHz: 25_000, Mode: leylinev1.DemodMode_NFM})
	if err != nil {
		t.Fatal(err)
	}
	if ch.BandwidthHz != 12_500 || ch.Owner.GetClientId() != c.ClientID() {
		t.Errorf("bad channel: %v", ch)
	}
	sink, err := c.Control.AttachSink(ctx, &leylinev1.AttachSinkRequest{ChannelId: ch.ChannelId, Sink: &leylinev1.Sink{Kind: &leylinev1.Sink_SystemAudio{SystemAudio: &leylinev1.SystemAudioSink{}}}})
	if err != nil {
		t.Fatal(err)
	}
	st, _ = c.State(ctx)
	if got := leyline.FindCapture(st, devID); got == nil || got.Activity.LiveAudioSinks != 1 {
		t.Errorf("capture activity not updated: %v", got)
	}
	if got := leyline.CurrentChannel(st, c.ClientID()); got == nil || got.ChannelId != ch.ChannelId {
		t.Errorf("CurrentChannel = %v", got)
	}
	if st.Devices[0].State != leylinev1.DeviceState_IN_USE {
		t.Errorf("device should be IN_USE")
	}

	// Every event so far must be attributed to us and carry full state.
	var seen []*leylinev1.Event
	var lastSeq uint64
	timeout := time.After(2 * time.Second)
	for len(seen) < 6 {
		select {
		case ev := <-events:
			if ev.Seq <= lastSeq {
				t.Errorf("seq not increasing: %d after %d", ev.Seq, lastSeq)
			}
			lastSeq = ev.Seq
			if ev.CausedBy.GetClientId() != c.ClientID() || ev.CausedBy.GetKind() != "cli" || ev.CausedBy.GetLabel() != "test" {
				t.Errorf("bad attribution: %v", ev.CausedBy)
			}
			seen = append(seen, ev)
		case err := <-errs:
			t.Fatalf("event stream ended: %v", err)
		case <-timeout:
			t.Fatalf("only %d events", len(seen))
		}
	}
	var sawChannel bool
	for _, ev := range seen {
		if e := ev.GetChannel(); e != nil && e.ChannelId == ch.ChannelId && e.Mode == leylinev1.DemodMode_NFM && e.CaptureId == cap.CaptureId {
			sawChannel = true
		}
	}
	if !sawChannel {
		t.Error("no full-state channel event")
	}

	if _, err := c.Control.DetachSink(ctx, &leylinev1.DetachSinkRequest{SinkId: sink.SinkId}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Control.DestroyChannel(ctx, &leylinev1.DestroyChannelRequest{ChannelId: ch.ChannelId}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Control.DestroyCapture(ctx, &leylinev1.DestroyCaptureRequest{CaptureId: cap.CaptureId}); err != nil {
		t.Fatal(err)
	}
	st, _ = c.State(ctx)
	if len(st.Captures)+len(st.Channels)+len(st.Sinks) != 0 || st.Devices[0].State != leylinev1.DeviceState_AVAILABLE {
		t.Errorf("state not empty after teardown: %v", st)
	}
	if _, err := c.Control.DestroyChannel(ctx, &leylinev1.DestroyChannelRequest{ChannelId: ch.ChannelId}); leyline.Code(err) != leyline.CodeChannelNotFound {
		t.Errorf("expected CHANNEL_NOT_FOUND, got %v", err)
	}
}

func TestErrorMapping(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	st, _ := c.State(ctx)
	devID := st.Devices[0].DeviceId

	_, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: devID, CenterHz: 10_000})
	var le *leyline.Error
	if !errors.As(err, &le) {
		t.Fatalf("errors.As failed for %T %v", err, err)
	}
	if le.Code != leyline.CodeFreqOutOfRange || le.Target != devID || le.Message == "" {
		t.Errorf("bad mapped error: %+v", le)
	}
	if st, ok := status.FromError(err); !ok || st.Code() != codes.InvalidArgument {
		t.Errorf("gRPC status not preserved: %v", err)
	}
	_, err = c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: devID, CenterHz: 100_000_000, SampleRate: 123})
	if leyline.Code(err) != leyline.CodeRateUnsupported {
		t.Errorf("want RATE_UNSUPPORTED, got %v", err)
	}
	if _, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: devID, CenterHz: 100_000_000}); err != nil {
		t.Fatal(err)
	}
	_, err = c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: devID, CenterHz: 100_000_000})
	if leyline.Code(err) != leyline.CodeDeviceBusy {
		t.Errorf("want DEVICE_BUSY, got %v", err)
	}
	cap := leyline.FindCapture(mustState(t, c), devID)
	_, err = c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cap.CaptureId, OffsetHz: 1_500_000})
	if leyline.Code(err) != leyline.CodeOffsetOutOfCapture {
		t.Errorf("want OFFSET_OUT_OF_CAPTURE, got %v", err)
	}
	// Scan jobs are implemented; the durable half of the service is not.
	_, err = c.Jobs.GetTranscript(ctx, &leylinev1.TranscriptRequest{})
	if leyline.Code(err) != leyline.CodeUnimplemented {
		t.Errorf("want UNIMPLEMENTED, got %v", err)
	}
	_, err = c.Jobs.GetScan(ctx, &leylinev1.ScanRef{ScanId: "scan_NOPE"})
	if leyline.Code(err) != leyline.CodeScanNotFound {
		t.Errorf("want SCAN_NOT_FOUND, got %v", err)
	}
	// Fallback: no trailer, only the "CODE: message" convention.
	fb := leyline.FromStatus(status.Error(codes.NotFound, "SINK_NOT_FOUND: no such sink"))
	if fb.Code != leyline.CodeSinkNotFound || fb.Message != "no such sink" {
		t.Errorf("fallback parse: %+v", fb)
	}
	if fb := leyline.FromStatus(status.Error(codes.Unimplemented, "nope")); fb.Code != leyline.CodeUnimplemented {
		t.Errorf("gRPC-code fallback: %+v", fb)
	}
	if leyline.Code(nil) != "" {
		t.Error("Code(nil) should be empty")
	}
}

func mustState(t *testing.T, c *leyline.Client) *leylinev1.GetStateResponse {
	t.Helper()
	st, err := c.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return st
}

// TestAttachSinkVolumePresence pins the proto3-presence contract for
// SystemAudioSink.volume: absent means full (1.0), an explicit 0 means muted,
// and anything outside 0..1 is INVALID_ARGUMENT.
func TestAttachSinkVolumePresence(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	st, _ := c.State(ctx)
	devID := st.Devices[0].DeviceId
	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: devID, CenterHz: 100_000_000})
	if err != nil {
		t.Fatal(err)
	}
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cap.CaptureId, OffsetHz: 25_000, Mode: leylinev1.DemodMode_NFM})
	if err != nil {
		t.Fatal(err)
	}
	attach := func(sa *leylinev1.SystemAudioSink) (*leylinev1.Sink, error) {
		return c.Control.AttachSink(ctx, &leylinev1.AttachSinkRequest{ChannelId: ch.ChannelId, Sink: &leylinev1.Sink{Kind: &leylinev1.Sink_SystemAudio{SystemAudio: sa}}})
	}

	absent, err := attach(&leylinev1.SystemAudioSink{})
	if err != nil {
		t.Fatal(err)
	}
	if sa := absent.GetSystemAudio(); sa.Volume == nil || *sa.Volume != 1 {
		t.Errorf("absent volume should default to 1.0, got %v", sa)
	}
	muted, err := attach(&leylinev1.SystemAudioSink{Volume: proto.Float64(0)})
	if err != nil {
		t.Fatal(err)
	}
	if sa := muted.GetSystemAudio(); sa.Volume == nil || *sa.Volume != 0 {
		t.Errorf("explicit 0 should stay muted, got %v", sa)
	}
	if _, err := attach(&leylinev1.SystemAudioSink{Volume: proto.Float64(1.5)}); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("want INVALID_ARGUMENT for volume 1.5, got %v", err)
	}
	// The state mirror carries presence too.
	st = mustState(t, c)
	for _, s := range st.Sinks {
		if s.GetSystemAudio().Volume == nil {
			t.Errorf("sink %s lost its volume presence in GetState", s.SinkId)
		}
	}
}

// TestWriteAwaitsWatcher: with the option set, a write sent before the
// client's WatchEvents stream exists is held until it registers, so the
// WriteRejected it produces reaches the stream instead of being lost.
func TestWriteAwaitsWatcher(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{WriteAwaitsWatcher: true})
	ctx := context.Background()
	st, _ := c.State(ctx)
	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 100_000_000})
	if err != nil {
		t.Fatal(err)
	}
	bad := &leylinev1.ParamWrite{Tag: 7, TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: &leylinev1.GainWrite{Element: "nope", Value: &leylinev1.GainWrite_Db{Db: 20}}}}
	summary := make(chan *leylinev1.WriteSummary, 1)
	go func() {
		sum, err := c.WriteParams(ctx, bad)
		if err != nil {
			t.Errorf("WriteParams: %v", err)
		}
		summary <- sum
	}()
	// The write is held: the summary must not arrive before the watcher exists.
	select {
	case sum := <-summary:
		t.Fatalf("write applied before a watcher registered: %v", sum)
	case <-time.After(150 * time.Millisecond):
	}
	evCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	events, _, err := c.Events(evCtx, nil)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case sum := <-summary:
		if sum.GetWritesReceived() != 1 || sum.GetWritesApplied() != 0 {
			t.Fatalf("summary: %v", sum)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("write never released after the watcher registered")
	}
	deadline := time.After(2 * time.Second)
	for {
		select {
		case ev := <-events:
			if r, ok := ev.Body.(*leylinev1.Event_WriteRejected); ok {
				if r.WriteRejected.Tag != 7 || r.WriteRejected.Error.GetCode() != leyline.CodeGainElementUnknown {
					t.Fatalf("rejection: %v", r.WriteRejected)
				}
				return
			}
		case <-deadline:
			t.Fatal("WriteRejected never reached the watcher")
		}
	}
}

// TestWatchEventsSinceSeq: a stream opened with since_seq replays the retained
// events newer than a GetState snapshot, in order and scope-filtered, before
// going live, so "GetState then WatchEvents" misses nothing.
func TestWatchEventsSinceSeq(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	st, err := c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// Two mutations after the snapshot, before any stream exists.
	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 100_000_000})
	if err != nil {
		t.Fatal(err)
	}
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cap.CaptureId, BandwidthHz: 12_500, Mode: leylinev1.DemodMode_NFM, Persistent: true})
	if err != nil {
		t.Fatal(err)
	}
	evCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	events, _, err := c.Events(evCtx, leyline.ScopeSince(nil, st.EventSeq))
	if err != nil {
		t.Fatal(err)
	}
	next := func() *leylinev1.Event {
		select {
		case ev := <-events:
			return ev
		case <-time.After(2 * time.Second):
			t.Fatal("no replayed event")
			return nil
		}
	}
	// Replay starts right after the snapshot (the device going IN_USE, then
	// the capture, then the channel), in seq order.
	first := next()
	if first.Seq != st.EventSeq+1 {
		t.Fatalf("replay should start at seq %d, got %v", st.EventSeq+1, first)
	}
	last, sawCapture, sawChannel := first.Seq, false, false
	for i := 0; i < 8 && !sawChannel; i++ {
		ev := next()
		if ev.Seq <= last {
			t.Fatalf("replayed out of order: seq %d after %d", ev.Seq, last)
		}
		last = ev.Seq
		sawCapture = sawCapture || ev.GetCapture().GetCaptureId() == cap.CaptureId
		sawChannel = ev.GetChannel().GetChannelId() == ch.ChannelId
	}
	if !sawCapture || !sawChannel {
		t.Fatalf("capture (%v) and channel (%v) creation were not both replayed", sawCapture, sawChannel)
	}
	if _, err := c.Control.DestroyChannel(ctx, &leylinev1.DestroyChannelRequest{ChannelId: ch.ChannelId}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 8; i++ {
		if ev := next(); ev.GetChannel().GetChannelId() == ch.ChannelId && ev.GetChannel().GetState() != leylinev1.ChannelState_CHANNEL_ACTIVE {
			return
		}
	}
	t.Fatal("live events did not follow the replay")
}

// TestWatchEventsSinceSeqScoped: replay honours a capture scope and seq 0 replays nothing.
func TestWatchEventsSinceSeqScoped(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	st, _ := c.State(ctx)
	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 100_000_000})
	if err != nil {
		t.Fatal(err)
	}
	evCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	live, _, err := c.Events(evCtx, nil)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-live:
		t.Fatalf("since_seq 0 must not replay: %v", ev)
	case <-time.After(100 * time.Millisecond):
	}
	scoped, _, err := c.Events(evCtx, leyline.ScopeSince(leyline.CaptureScope(cap.CaptureId), st.EventSeq))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 4; i++ {
		select {
		case ev := <-scoped:
			if ev.GetCapture().GetCaptureId() == cap.CaptureId {
				return
			}
		case <-time.After(2 * time.Second):
			t.Fatal("scoped replay delivered nothing")
		}
	}
	t.Fatal("scoped replay did not carry the capture")
}

// The destroy tombstone: a destroyed capture is emitted one last time with its
// state unset, the way Channel and Sink are, so that a client can tell it from
// an unplugged radio (CAPTURE_DETACHED, which stays in state and rebinds).
func TestDestroyCaptureEmitsTheTombstone(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	st, _ := c.State(ctx)
	devID := st.Devices[0].DeviceId

	evCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	events, errs, err := c.Events(evCtx, nil)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond) // let the watcher register

	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: devID, CenterHz: 146_520_000})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Control.DestroyCapture(ctx, &leylinev1.DestroyCaptureRequest{CaptureId: cap.CaptureId}); err != nil {
		t.Fatal(err)
	}

	timeout := time.After(2 * time.Second)
	for {
		select {
		case ev := <-events:
			cp := ev.GetCapture()
			if cp == nil || cp.CaptureId != cap.CaptureId {
				continue
			}
			switch cp.State {
			case leylinev1.CaptureState_CAPTURE_ACTIVE:
				continue
			case leylinev1.CaptureState_CAPTURE_DETACHED:
				t.Fatal("a destroy must not look like device loss")
			}
			if cp.CenterHz != cap.CenterHz {
				t.Errorf("the tombstone still carries the whole object: %v", cp)
			}
			return
		case err := <-errs:
			t.Fatalf("event stream ended: %v", err)
		case <-timeout:
			t.Fatal("no terminal capture event")
		}
	}
}
