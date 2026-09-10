package fakedaemon_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func setupCaptureChannel(t *testing.T, c *leyline.Client) (*leylinev1.Capture, *leylinev1.Channel) {
	t.Helper()
	ctx := context.Background()
	st := mustState(t, c)
	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_000_000})
	if err != nil {
		t.Fatal(err)
	}
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cap.CaptureId, OffsetHz: 520_000, Mode: leylinev1.DemodMode_NFM})
	if err != nil {
		t.Fatal(err)
	}
	return cap, ch
}

func TestWriteParams(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	cap, ch := setupCaptureChannel(t, c)
	evCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	events, _, err := c.Events(evCtx, leyline.CaptureScope(cap.CaptureId))
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond)
	before := time.Now().UnixNano()
	sum, err := c.WriteParams(ctx,
		&leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: -60}},
		&leylinev1.ParamWrite{Tag: 2, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: -40}}, // coalesced: last wins
		&leylinev1.ParamWrite{Tag: 3, TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: &leylinev1.GainWrite{Element: "TUNER", Value: &leylinev1.GainWrite_Db{Db: 28.3}}}},
		&leylinev1.ParamWrite{Tag: 4, TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_CenterHz{CenterHz: 5}},                                                                          // rejected
		&leylinev1.ParamWrite{Tag: 5, TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: &leylinev1.GainWrite{Element: "LNA", Value: &leylinev1.GainWrite_Auto{Auto: true}}}}, // rejected
	)
	if err != nil {
		t.Fatal(err)
	}
	if sum.WritesReceived != 5 || sum.WritesApplied != 2 {
		t.Errorf("summary = %v", sum)
	}
	st := mustState(t, c)
	gotCap, gotCh := leyline.FindCapture(st, ""), leyline.CurrentChannel(st, c.ClientID())
	if gotCh.SquelchDb != -40 {
		t.Errorf("squelch = %v", gotCh.SquelchDb)
	}
	if gotCap.Gains[0].Db != 28.0 || gotCap.Gains[0].Auto {
		t.Errorf("gain not snapped/applied: %v", gotCap.Gains)
	}
	if gotCap.Activity.LastInteractiveWriteNs < before {
		t.Errorf("last_interactive_write_ns not updated: %d", gotCap.Activity.LastInteractiveWriteNs)
	}
	rejected := map[uint64]string{}
	timeout := time.After(2 * time.Second)
	for len(rejected) < 2 {
		select {
		case ev := <-events:
			if r := ev.GetWriteRejected(); r != nil {
				rejected[r.Tag] = r.Error.GetCode()
			}
		case <-timeout:
			t.Fatalf("rejections seen: %v", rejected)
		}
	}
	if rejected[4] != leyline.CodeFreqOutOfRange || rejected[5] != leyline.CodeGainElementUnknown {
		t.Errorf("rejections = %v", rejected)
	}
}

func TestFFTStream(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	cap, ch := setupCaptureChannel(t, c)
	sub, err := c.SubscribeFFT(ctx, cap.CaptureId, 1000, 30, leylinev1.FftBinFormat_DB_U8)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()
	d := sub.Descriptor
	if d.GetFft().GetBins() != 1024 || d.GetFft().GetBinFormat() != leylinev1.FftBinFormat_DB_U8 || d.CenterHz != cap.CenterHz || d.SpanHz != cap.SampleRate || !d.GetGrpc() {
		t.Fatalf("descriptor = %v", d)
	}
	// Ladder parity with the engine: requests round *up* (300 -> 512, 1500 -> 2048), capped at 16384.
	for _, tc := range []struct{ req, want uint32 }{{300, 512}, {1024, 1024}, {1500, 2048}, {9000, 16384}, {16384, 16384}, {100000, 16384}} {
		s2, err := c.SubscribeFFT(ctx, cap.CaptureId, tc.req, 30, leylinev1.FftBinFormat_DB_U8)
		if err != nil {
			t.Fatal(err)
		}
		if got := s2.Descriptor.GetFft().GetBins(); got != tc.want {
			t.Errorf("bins %d: got %d want %d", tc.req, got, tc.want)
		}
		s2.Close()
	}
	var frames []*leylinev1.Frame
	timeout := time.After(3 * time.Second)
	for len(frames) < 3 {
		select {
		case f, ok := <-sub.Frames:
			if !ok {
				t.Fatalf("stream ended: %v", sub.Err())
			}
			frames = append(frames, f)
		case <-timeout:
			t.Fatalf("got %d frames", len(frames))
		}
	}
	f := frames[2]
	if len(f.Payload) != 1024 || f.Seq != 3 || f.Time.GetCaptureId() != cap.CaptureId {
		t.Errorf("frame = seq %d len %d time %v", f.Seq, len(f.Payload), f.Time)
	}
	peak := int((float64(ch.OffsetHz)/float64(cap.SampleRate) + 0.5) * 1024)
	if f.Payload[peak] < 140 || f.Payload[10] > 60 {
		t.Errorf("no peak at channel offset: bin[%d]=%d floor=%d", peak, f.Payload[peak], f.Payload[10])
	}
	// Non-live start is UNIMPLEMENTED.
	_, err = c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cap.CaptureId}, Kind: leylinev1.StreamKind_FFT,
		Start: &leylinev1.StreamPosition{Position: &leylinev1.StreamPosition_AtHostTimeNs{AtHostTimeNs: 1}},
	})
	if leyline.Code(err) != leyline.CodeUnimplemented {
		t.Errorf("want UNIMPLEMENTED, got %v", err)
	}
}

func TestAudioStream(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	_, ch := setupCaptureChannel(t, c)
	for _, tc := range []struct {
		format leylinev1.AudioSampleFormat
		rate   uint32
		want   int
	}{
		// Engine parity: every mode produces the channelizer's r2 (48 kHz at 2.4 MSPS).
		{leylinev1.AudioSampleFormat_S16, 0, 48000 / 50 * 2},
		{leylinev1.AudioSampleFormat_F32, 48000, 48000 / 50 * 4},
	} {
		sub, err := c.SubscribeAudio(ctx, ch.ChannelId, tc.rate, tc.format)
		if err != nil {
			t.Fatal(err)
		}
		a := sub.Descriptor.GetAudio()
		select {
		case f := <-sub.Frames:
			if len(f.Payload) != tc.want || a.GetFormat() != tc.format {
				t.Errorf("format %v rate %d: payload %d want %d (desc %v)", tc.format, tc.rate, len(f.Payload), tc.want, a)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("no audio frame")
		}
		if err := sub.Close(); err != nil {
			t.Errorf("close: %v", err)
		}
	}
	// No resampling: a rate other than the channel's is refused, never upgraded (engine parity).
	if _, err := c.SubscribeAudio(ctx, ch.ChannelId, 16000, leylinev1.AudioSampleFormat_S16); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("want INVALID_ARGUMENT for a 16 kHz request, got %v", err)
	}
	_, err := c.Bulk.Unsubscribe(ctx, &leylinev1.StreamRef{StreamId: "strm_nope"})
	if leyline.Code(err) != leyline.CodeStreamNotFound {
		t.Errorf("want STREAM_NOT_FOUND, got %v", err)
	}
}

func TestIQStreamContract(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	cap, _ := setupCaptureChannel(t, c)
	subscribe := func(format leylinev1.SampleFormat, rate uint64) (*leyline.Subscription, error) {
		return c.Subscribe(ctx, &leylinev1.SubscribeRequest{
			Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cap.CaptureId},
			Kind:   leylinev1.StreamKind_IQ,
			Params: &leylinev1.SubscribeRequest_Iq{Iq: &leylinev1.IqParams{SampleRate: rate, Format: format}},
		})
	}
	// Engine parity (StreamRegistry.subscribe): UNSPECIFIED/CF32 and rate 0/native are accepted and
	// always served as CF32 at the capture rate.
	for _, tc := range []struct {
		format leylinev1.SampleFormat
		rate   uint64
	}{
		{leylinev1.SampleFormat_SAMPLE_FORMAT_UNSPECIFIED, 0},
		{leylinev1.SampleFormat_CF32, 0},
		{leylinev1.SampleFormat_CF32, cap.SampleRate},
		{leylinev1.SampleFormat_SAMPLE_FORMAT_UNSPECIFIED, cap.SampleRate},
	} {
		sub, err := subscribe(tc.format, tc.rate)
		if err != nil {
			t.Fatalf("format %v rate %d: %v", tc.format, tc.rate, err)
		}
		iq := sub.Descriptor.GetIq()
		if iq.GetFormat() != leylinev1.SampleFormat_CF32 || iq.GetSampleRate() != cap.SampleRate {
			t.Errorf("format %v rate %d: descriptor %v", tc.format, tc.rate, iq)
		}
		if err := sub.Close(); err != nil {
			t.Errorf("close: %v", err)
		}
	}
	// Anything else is refused, never downgraded or resampled.
	for _, tc := range []struct {
		format leylinev1.SampleFormat
		rate   uint64
	}{
		{leylinev1.SampleFormat_CS8, 0},
		{leylinev1.SampleFormat_CS16, 0},
		{leylinev1.SampleFormat_CF32, cap.SampleRate / 2},
		{leylinev1.SampleFormat_SAMPLE_FORMAT_UNSPECIFIED, 1_000_000},
	} {
		if _, err := subscribe(tc.format, tc.rate); leyline.Code(err) != leyline.CodeInvalidArgument {
			t.Errorf("format %v rate %d: want INVALID_ARGUMENT, got %v", tc.format, tc.rate, err)
		}
	}
	// No params at all is the same as UNSPECIFIED/0.
	sub, err := c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cap.CaptureId}, Kind: leylinev1.StreamKind_IQ,
	})
	if err != nil {
		t.Fatal(err)
	}
	if sub.GetIq().GetFormat() != leylinev1.SampleFormat_CF32 || sub.GetIq().GetSampleRate() != cap.SampleRate {
		t.Errorf("bare request: descriptor %v", sub.GetIq())
	}
}

func TestPresenceReaping(t *testing.T) {
	c, sock := harness(t, fakedaemon.Options{PresenceGrace: 100 * time.Millisecond})
	ctx := context.Background()
	// Unary calls keep a client present for one grace period, so poll from a
	// second identity that owns nothing.
	poller, err := leyline.Dial(ctx, sock, leyline.WithClientID(leyline.NewID("cli_")))
	if err != nil {
		t.Fatal(err)
	}
	defer poller.Close()
	cap, ch := setupCaptureChannel(t, c)
	persistent, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cap.CaptureId, OffsetHz: -100_000, Persistent: true})
	if err != nil {
		t.Fatal(err)
	}
	evCtx, cancel := context.WithCancel(ctx)
	if _, _, err := c.Events(evCtx, nil); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	if len(mustState(t, poller).Channels) != 2 {
		t.Fatal("channel reaped while WatchEvents was open")
	}
	cancel()
	deadline := time.Now().Add(3 * time.Second)
	for {
		st := mustState(t, poller)
		if len(st.Channels) == 1 && st.Channels[0].ChannelId == persistent.ChannelId {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("non-persistent channel %s not reaped: %v", ch.ChannelId, st.Channels)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestFileDevice(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	dir := t.TempDir()
	path := filepath.Join(dir, "nfm.cf32")
	_ = os.WriteFile(path, nil, 0o644)
	_ = os.WriteFile(filepath.Join(dir, "nfm.json"), []byte(`{"sample_rate": 250000, "center_hz": 146520000}`), 0o644)
	dev, err := c.Control.AttachFileDevice(ctx, &leylinev1.AttachFileDeviceRequest{Path: path, Loop: true})
	if err != nil {
		t.Fatal(err)
	}
	if dev.Driver != "file" || dev.SampleRates[0] != 250_000 || dev.TuningRanges[0].MinHz != 146_520_000 {
		t.Errorf("descriptor = %v", dev)
	}
	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: dev.DeviceId, CenterHz: 146_520_000})
	if err != nil || cap.SampleRate != 250_000 {
		t.Fatalf("capture = %v, %v", cap, err)
	}
	if _, err := c.Control.DetachFileDevice(ctx, &leylinev1.DetachFileDeviceRequest{DeviceId: dev.DeviceId}); err != nil {
		t.Fatal(err)
	}
	st := mustState(t, c)
	if len(st.Devices) != 1 || len(st.Captures) != 0 {
		t.Errorf("state after detach = %v", st)
	}
}

// Subscribe fills in the transport and start position a v0 client needs, and the
// caller keeps the request it built — to retry with, or to log what it asked
// for. Err is repeatable, because one goroutine may drain frames while another
// asks why the stream ended.
func TestSubscribeLeavesTheRequestAloneAndErrIsRepeatable(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	cap, _ := setupCaptureChannel(t, c)
	req := &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cap.CaptureId},
		Kind:   leylinev1.StreamKind_FFT,
		Params: &leylinev1.SubscribeRequest_Fft{Fft: &leylinev1.FftParams{Bins: 1024, RowsPerSecond: 30}},
	}
	sub, err := c.Subscribe(ctx, req)
	if err != nil {
		t.Fatal(err)
	}
	if req.Transport != leylinev1.Transport_TRANSPORT_UNSPECIFIED || req.Start != nil {
		t.Errorf("Subscribe rewrote the caller's request: %v", req)
	}
	if !sub.Descriptor.GetGrpc() {
		t.Errorf("descriptor = %v, want a gRPC transport", sub.Descriptor)
	}

	// Ending the stream from this side gives Err something to hold.
	sub.Close()
	deadline := time.After(3 * time.Second)
	for open := true; open; {
		select {
		case _, open = <-sub.Frames:
		case <-deadline:
			t.Fatal("frames never closed after Close")
		}
	}
	first := sub.Err()
	if first == nil {
		t.Fatal("a cancelled stream must report why it ended")
	}
	if got := sub.Err(); got != first {
		t.Errorf("Err() = %v then %v; it must be repeatable", first, got)
	}
}
