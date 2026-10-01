// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"encoding/binary"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

func setupCaptureChannel(t *testing.T, c *leyline.Client) (*leylinev1.Capture, *leylinev1.Channel) {
	t.Helper()
	ctx := t.Context()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_000_000})
	if err != nil {
		t.Fatal(err)
	}
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cp.CaptureId, OffsetHz: 520_000, Mode: leylinev1.DemodMode_NFM})
	if err != nil {
		t.Fatal(err)
	}
	return cp, ch
}

func TestWriteParams(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	cp, ch := setupCaptureChannel(t, c)
	evCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	start := mustState(t, c)
	// From the snapshot's seq, so a write applied before the watcher registers is replayed rather
	// than missed.
	events, _, err := c.Events(evCtx, leyline.ScopeSince(leyline.CaptureScope(cp.CaptureId), start.EventSeq))
	if err != nil {
		t.Fatal(err)
	}
	before := time.Now().UnixNano()
	sum, err := c.WriteParams(ctx,
		&leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: -60}},
		&leylinev1.ParamWrite{Tag: 2, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: -40}}, // coalesced: last wins
		&leylinev1.ParamWrite{Tag: 3, TargetId: cp.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: &leylinev1.GainWrite{Element: "TUNER", Value: &leylinev1.GainWrite_Db{Db: 28.3}}}},
		&leylinev1.ParamWrite{Tag: 4, TargetId: cp.CaptureId, Param: &leylinev1.ParamWrite_CenterHz{CenterHz: 5}},                                                                          // rejected
		&leylinev1.ParamWrite{Tag: 5, TargetId: cp.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: &leylinev1.GainWrite{Element: "LNA", Value: &leylinev1.GainWrite_Auto{Auto: true}}}}, // rejected
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
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	cp, ch := setupCaptureChannel(t, c)
	sub, err := c.SubscribeFFT(ctx, cp.CaptureId, 1000, 30, leylinev1.FftBinFormat_DB_U8)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()
	d := sub.Descriptor
	if d.GetFft().GetBins() != 1024 || d.GetFft().GetBinFormat() != leylinev1.FftBinFormat_DB_U8 || d.CenterHz != cp.CenterHz || d.SpanHz != cp.SampleRate || !d.GetGrpc() {
		t.Fatalf("descriptor = %v", d)
	}
	// Ladder parity with the engine: requests round *up* (300 -> 512, 1500 -> 2048), capped at 16384.
	for _, tc := range []struct{ req, want uint32 }{{300, 512}, {1024, 1024}, {1500, 2048}, {9000, 16384}, {16384, 16384}, {100000, 16384}} {
		s2, err := c.SubscribeFFT(ctx, cp.CaptureId, tc.req, 30, leylinev1.FftBinFormat_DB_U8)
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
	if len(f.Payload) != 1024 || f.Seq != 3 || f.Time.GetCaptureId() != cp.CaptureId {
		t.Errorf("frame = seq %d len %d time %v", f.Seq, len(f.Payload), f.Time)
	}
	peak := int((float64(ch.OffsetHz)/float64(cp.SampleRate) + 0.5) * 1024)
	if f.Payload[peak] < 140 || f.Payload[10] > 60 {
		t.Errorf("no peak at channel offset: bin[%d]=%d floor=%d", peak, f.Payload[peak], f.Payload[10])
	}
	// Non-live start is UNIMPLEMENTED.
	_, err = c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cp.CaptureId}, Kind: leylinev1.StreamKind_FFT,
		Start: &leylinev1.StreamPosition{Position: &leylinev1.StreamPosition_AtHostTimeNs{AtHostTimeNs: 1}},
	})
	if leyline.Code(err) != leyline.CodeUnimplemented {
		t.Errorf("want UNIMPLEMENTED, got %v", err)
	}
}

func TestAudioStream(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
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
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	cp, _ := setupCaptureChannel(t, c)
	subscribe := func(format leylinev1.SampleFormat, rate uint64) (*leyline.Subscription, error) {
		return c.Subscribe(ctx, &leylinev1.SubscribeRequest{
			Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cp.CaptureId},
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
		{leylinev1.SampleFormat_CF32, cp.SampleRate},
		{leylinev1.SampleFormat_SAMPLE_FORMAT_UNSPECIFIED, cp.SampleRate},
	} {
		sub, err := subscribe(tc.format, tc.rate)
		if err != nil {
			t.Fatalf("format %v rate %d: %v", tc.format, tc.rate, err)
		}
		iq := sub.Descriptor.GetIq()
		if iq.GetFormat() != leylinev1.SampleFormat_CF32 || iq.GetSampleRate() != cp.SampleRate {
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
		{leylinev1.SampleFormat_CF32, cp.SampleRate / 2},
		{leylinev1.SampleFormat_SAMPLE_FORMAT_UNSPECIFIED, 1_000_000},
	} {
		if _, err := subscribe(tc.format, tc.rate); leyline.Code(err) != leyline.CodeInvalidArgument {
			t.Errorf("format %v rate %d: want INVALID_ARGUMENT, got %v", tc.format, tc.rate, err)
		}
	}
	// No params at all is the same as UNSPECIFIED/0.
	sub, err := c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cp.CaptureId}, Kind: leylinev1.StreamKind_IQ,
	})
	if err != nil {
		t.Fatal(err)
	}
	if sub.GetIq().GetFormat() != leylinev1.SampleFormat_CF32 || sub.GetIq().GetSampleRate() != cp.SampleRate {
		t.Errorf("bare request: descriptor %v", sub.GetIq())
	}
}

func TestPresenceReaping(t *testing.T) {
	c, sock := harness(t, fakedaemon.Options{PresenceGrace: 100 * time.Millisecond})
	ctx := t.Context()
	// Unary calls keep a client present for one grace period, so poll from a
	// second identity that owns nothing.
	poller, err := leyline.Dial(ctx, sock, leyline.WithClientID(leyline.NewID("cli_")))
	if err != nil {
		t.Fatal(err)
	}
	defer poller.Close()
	cp, ch := setupCaptureChannel(t, c)
	persistent, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cp.CaptureId, OffsetHz: -100_000, Persistent: true})
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
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
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
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: dev.DeviceId, CenterHz: 146_520_000})
	if err != nil || cp.SampleRate != 250_000 {
		t.Fatalf("capture = %v, %v", cp, err)
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
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	cp, _ := setupCaptureChannel(t, c)
	req := &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cp.CaptureId},
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
	if got := sub.Err(); got != first { //nolint:errorlint // Err must return the very same value again
		t.Errorf("Err() = %v then %v; it must be repeatable", first, got)
	}
}

// One reader per subscription, as the daemon's stream registry claims it: two Stream calls on one
// id would hand out two frame sequences that both start at seq 1. The claim is released when the
// reader goes, so a client whose Stream RPC dropped can come back to the same subscription.
func TestStreamHasOneReaderAtATime(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	cp, _ := setupCaptureChannel(t, c)
	desc, err := c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cp.CaptureId},
		Kind:   leylinev1.StreamKind_FFT,
		Params: &leylinev1.SubscribeRequest_Fft{Fft: &leylinev1.FftParams{Bins: 256, RowsPerSecond: 50}},
	})
	if err != nil {
		t.Fatal(err)
	}
	ref := &leylinev1.StreamRef{StreamId: desc.StreamId}
	read := func(c2 context.Context) error {
		st, err := c.Bulk.Stream(c2, ref)
		if err != nil {
			return err
		}
		_, err = st.Recv()
		return err
	}
	readerCtx, dropReader := context.WithCancel(ctx)
	if err := read(readerCtx); err != nil {
		t.Fatalf("first reader: %v", err)
	}
	if err := read(ctx); leyline.Code(err) != leyline.CodeFailedPrecondition {
		t.Errorf("a second reader must be refused with FAILED_PRECONDITION, got %v", err)
	}
	// The reader's RPC drops (a client that went away, not an Unsubscribe): the subscription is
	// claimable again, and the fresh grace is what eventually reaps it if nobody comes back.
	dropReader()
	deadline := time.Now().Add(3 * time.Second)
	for {
		err := read(ctx)
		if err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("the subscription never became claimable again: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// A malformed gain level is refused before the element's table is searched: every comparison in
// the snap is false for a NaN, so the write would otherwise be reported applied at the first entry
// in the table -- 0 dB on this radio, the lowest gain.
func TestGainWriteMustBeFinite(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	cp, _ := setupCaptureChannel(t, c)
	before := mustState(t, c).Captures[0].Gains[0].Db
	evCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	start := mustState(t, c)
	events, _, err := c.Events(evCtx, leyline.ScopeSince(leyline.CaptureScope(cp.CaptureId), start.EventSeq))
	if err != nil {
		t.Fatal(err)
	}
	nan := &leylinev1.ParamWrite{Tag: 9, TargetId: cp.CaptureId, Param: &leylinev1.ParamWrite_Gain{
		Gain: &leylinev1.GainWrite{Element: "TUNER", Value: &leylinev1.GainWrite_Db{Db: math.NaN()}},
	}}
	if _, err := c.WriteParams(ctx, nan); err != nil {
		t.Fatal(err)
	}
	timeout := time.After(2 * time.Second)
	for {
		select {
		case ev := <-events:
			if r := ev.GetWriteRejected(); r != nil && r.Tag == 9 {
				if r.Error.GetCode() != leyline.CodeInvalidArgument {
					t.Errorf("a NaN gain is INVALID_ARGUMENT, got %v", r.Error)
				}
				if got := mustState(t, c).Captures[0].Gains[0].Db; got != before {
					t.Errorf("a refused gain write must not move the radio: %v -> %v", before, got)
				}
				return
			}
		case <-timeout:
			t.Fatal("no rejection for the NaN gain")
		}
	}
}

// A gap is a report of samples that were actually lost. This reader subscribes to IQ -- big
// enough frames that a pause fills the transport's window -- stops reading for long enough that
// the fake has to displace frames it built, and then reads on: the first frame after the loss
// carries a Gap whose bounds are the samples between the last frame it got and this one.
func TestGapMarksWhatWasLost(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_000_000})
	if err != nil {
		t.Fatal(err)
	}
	desc, err := c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cp.CaptureId},
		Kind:   leylinev1.StreamKind_IQ,
		Policy: leylinev1.DeliveryPolicy_GAP_MARKED,
	})
	if err != nil {
		t.Fatal(err)
	}
	// The raw stub, not the client library: its pump would read the frames this test is trying
	// not to read.
	stream, err := c.Bulk.Stream(ctx, &leylinev1.StreamRef{StreamId: desc.StreamId})
	if err != nil {
		t.Fatal(err)
	}
	first, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(time.Second)
	deadline := time.Now().Add(5 * time.Second)
	prev := first
	for time.Now().Before(deadline) {
		f, err := stream.Recv()
		if err != nil {
			t.Fatalf("stream ended: %v", err)
		}
		if f.Gap == nil {
			if f.Seq != prev.Seq+1 {
				t.Fatalf("frame %d followed %d with no gap", f.Seq, prev.Seq)
			}
			prev = f
			continue
		}
		if f.Gap.FromSample >= f.Gap.ToSample || f.Gap.ToSample != f.Time.SampleIndex {
			t.Fatalf("gap %v does not bound the frame at %d", f.Gap, f.Time.SampleIndex)
		}
		if f.Seq <= prev.Seq+1 {
			t.Fatalf("a gap on frame %d, which followed %d: nothing was lost", f.Seq, prev.Seq)
		}
		return
	}
	t.Fatal("no gap arrived for a reader that stopped reading")
}

// Persistence negotiation, which is where the daemon refuses rather than guesses: the level scale
// is the client's to state, and the answers it does make (bins off the ladder, level count, decay,
// frame rate) are the ones a reader decodes the payload with.
func TestPersistenceNegotiation(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_000_000})
	if err != nil {
		t.Fatal(err)
	}
	// A scale nobody stated: refused, because a histogram on the wrong one is not obviously wrong
	// to look at.
	_, err = c.SubscribePersistence(ctx, cp.CaptureId, 256, 32, -90, 0, 20, 2)
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("range_db 0: want INVALID_ARGUMENT, got %v", err)
	}
	if _, err := c.SubscribePersistence(ctx, cp.CaptureId, 256, 1, -90, 50, 20, 2); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("1 level: want INVALID_ARGUMENT, got %v", err)
	}
	if _, err := c.SubscribePersistence(ctx, cp.CaptureId, 256, 512, -90, 50, 20, 2); leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("512 levels: want INVALID_ARGUMENT, got %v", err)
	}
	// Defaults and clamps: 0 bins is 256, 0 levels is 32, an absurd half-life is bounded, and the
	// bin count comes off the same ladder the FFT uses.
	sub, err := c.SubscribePersistence(ctx, cp.CaptureId, 300, 0, -90, 50, 1e9, 2)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()
	p := sub.Descriptor.GetPersistence()
	if p.GetBins() != 512 || p.GetLevels() != 32 || p.GetHalfLifeSeconds() != 3600 || p.GetRowsPerSecond() != 2 {
		t.Fatalf("descriptor = %v", p)
	}
	if sub.Descriptor.CenterHz != cp.CenterHz || sub.Descriptor.SpanHz != cp.SampleRate {
		t.Errorf("persistence carries the band it covers: %v", sub.Descriptor)
	}
	// The frames are counts, one uint16 per (bin, level), and they grow: the noise floor is seen
	// again and again, so the bucket it lands in climbs frame over frame.
	var first, second []uint16
	timeout := time.After(5 * time.Second)
	for second == nil {
		select {
		case f, ok := <-sub.Frames:
			if !ok {
				t.Fatalf("stream ended: %v", sub.Err())
			}
			h, ok := leyline.DecodePersistence(f.Payload, int(p.GetBins()), int(p.GetLevels()))
			if !ok {
				t.Fatalf("payload of %d bytes does not decode as %dx%d counts", len(f.Payload), p.GetBins(), p.GetLevels())
			}
			if first == nil {
				first = h.Counts
			} else {
				second = h.Counts
			}
		case <-timeout:
			t.Fatal("no persistence frames")
		}
	}
	if sumCounts(first) == 0 {
		t.Fatal("the first frame counted nothing")
	}
	if sumCounts(second) <= sumCounts(first) {
		t.Errorf("counts must accumulate: %d then %d", sumCounts(first), sumCounts(second))
	}
	// A channel is not a band: persistence reads the radio, and a channel source is refused.
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cp.CaptureId, OffsetHz: 0})
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_ChannelId{ChannelId: ch.ChannelId},
		Kind:   leylinev1.StreamKind_PERSISTENCE,
		Params: &leylinev1.SubscribeRequest_Persistence{Persistence: &leylinev1.PersistenceParams{Bins: 256, Levels: 32, FloorDb: -90, RangeDb: 50}},
	})
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("channel-scoped persistence: want INVALID_ARGUMENT, got %v", err)
	}
}

func sumCounts(h []uint16) int {
	var n int
	for _, c := range h {
		n += int(c)
	}
	return n
}

// Accumulation is answered and applied. A snapshot row is one look; a mean or a max is built from
// the looks the descriptor states, and a max reads higher than a snapshot of the same band --
// which is why a view hunting bursts asks for one.
func TestFFTAccumulation(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_000_000})
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := c.SubscribeFFT(ctx, cp.CaptureId, 256, 10, leylinev1.FftBinFormat_DB_F32)
	if err != nil {
		t.Fatal(err)
	}
	defer snapshot.Close()
	if p := snapshot.Descriptor.GetFft(); p.GetLooksPerRow() != 1 || p.GetAccumulation() != leylinev1.FftAccumulation_ROW_SNAPSHOT {
		t.Errorf("snapshot descriptor = %v", p)
	}
	maxSub, err := c.SubscribeFFTAccumulated(ctx, cp.CaptureId, 256, 10, leylinev1.FftBinFormat_DB_F32, leylinev1.FftAccumulation_ROW_MAX)
	if err != nil {
		t.Fatal(err)
	}
	defer maxSub.Close()
	if p := maxSub.Descriptor.GetFft(); p.GetLooksPerRow() != 64 || p.GetAccumulation() != leylinev1.FftAccumulation_ROW_MAX {
		t.Fatalf("max descriptor = %v", p)
	}
	if median(t, firstRow(t, maxSub)) <= median(t, firstRow(t, snapshot)) {
		t.Error("the max of 64 looks should not read below one look of the same floor")
	}
	// looks_per_row is the daemon's answer, never a request.
	_, err = c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: cp.CaptureId},
		Kind:   leylinev1.StreamKind_FFT,
		Params: &leylinev1.SubscribeRequest_Fft{Fft: &leylinev1.FftParams{Bins: 256, LooksPerRow: 4}},
	})
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("looks_per_row as a request: want INVALID_ARGUMENT, got %v", err)
	}
}

func firstRow(t *testing.T, sub *leyline.Subscription) []float64 {
	t.Helper()
	select {
	case f, ok := <-sub.Frames:
		if !ok {
			t.Fatalf("stream ended: %v", sub.Err())
		}
		return leyline.DecodeFFTBins(f.Payload, sub.Descriptor.GetFft().GetBinFormat())
	case <-time.After(5 * time.Second):
		t.Fatal("no row")
		return nil
	}
}

func median(t *testing.T, row []float64) float64 {
	t.Helper()
	if len(row) == 0 {
		t.Fatal("empty row")
	}
	sorted := append([]float64(nil), row...)
	sort.Float64s(sorted)
	return sorted[len(sorted)/2]
}

// A sweep whose client vanished ends the way a cancel does: what it found is stored first and the
// terminal event goes out last, so a client that reads the scan when it sees CANCELLED reads the
// part that ran rather than an empty one.
func TestPresenceDropEndsASweepLikeACancel(t *testing.T) {
	c, sock := harness(t, fakedaemon.Options{PresenceGrace: 100 * time.Millisecond})
	ctx := t.Context()
	// A second identity to watch with: the owner must make no calls, or it stays present.
	watcher, err := leyline.Dial(ctx, sock, leyline.WithClientID(leyline.NewID("cli_")))
	if err != nil {
		t.Fatal(err)
	}
	defer watcher.Close()
	job, err := c.Jobs.StartJob(ctx, &leylinev1.StartJobRequest{Config: &leylinev1.StartJobRequest_Scan{
		Scan: &leylinev1.ScanConfig{Range: &leylinev1.FrequencyRange{MinHz: 145_000_000, MaxHz: 147_000_000}, DwellMs: 50},
	}})
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		j, err := watcher.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.JobId})
		if err != nil {
			t.Fatal(err)
		}
		if j.State == leylinev1.JobState_CANCELLED {
			if !strings.Contains(j.StatusDetail, "stopped in step ") || !strings.Contains(j.StatusDetail, " found") {
				t.Errorf("detail = %q", j.StatusDetail)
			}
			sc, err := watcher.Jobs.GetScan(ctx, &leylinev1.ScanRef{ScanId: strings.TrimPrefix(job.ResultUris[0], "ley://scans/")})
			if err != nil {
				t.Fatal(err)
			}
			if sc.CompletedAtNs == 0 {
				t.Error("the scan was still unfinished when the terminal event went out")
			}
			return
		}
		if j.State != leylinev1.JobState_RUNNING {
			t.Fatalf("state = %v (%s)", j.State, j.StatusDetail)
		}
		if time.Now().After(deadline) {
			t.Fatal("the sweep outlived its client")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// Cancelling a sweep that has already finished is not an error and not a change: the job stays
// completed, with the detail it ended on.
func TestCancelLeavesAFinishedJobAlone(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	job, err := c.Jobs.StartJob(ctx, &leylinev1.StartJobRequest{Config: &leylinev1.StartJobRequest_Scan{
		Scan: &leylinev1.ScanConfig{Range: &leylinev1.FrequencyRange{MinHz: 145_000_000, MaxHz: 147_000_000}, DwellMs: 20},
	}})
	if err != nil {
		t.Fatal(err)
	}
	var done *leylinev1.Job
	for deadline := time.Now().Add(10 * time.Second); done == nil; {
		j, err := c.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.JobId})
		if err != nil {
			t.Fatal(err)
		}
		if j.State == leylinev1.JobState_COMPLETED {
			done = j
			break
		}
		if j.State != leylinev1.JobState_RUNNING {
			t.Fatalf("state = %v (%s)", j.State, j.StatusDetail)
		}
		if time.Now().After(deadline) {
			t.Fatal("the sweep never finished")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !strings.Contains(done.StatusDetail, " found in ") {
		t.Errorf("completed detail = %q", done.StatusDetail)
	}
	got, err := c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: job.JobId})
	if err != nil {
		t.Fatal(err)
	}
	if got.State != leylinev1.JobState_COMPLETED || got.StatusDetail != done.StatusDetail {
		t.Errorf("cancel rewrote a finished job: %v", got)
	}
}

// f32Payload decodes an F32 audio payload; the taps are compared as numbers,
// because two payloads rendered a moment apart never match byte for byte.
func f32Payload(t *testing.T, b []byte) []float64 {
	t.Helper()
	if len(b)%4 != 0 || len(b) == 0 {
		t.Fatalf("payload of %d bytes is not F32 samples", len(b))
	}
	out := make([]float64, len(b)/4)
	for i := range out {
		out[i] = float64(math.Float32frombits(binary.LittleEndian.Uint32(b[i*4:])))
	}
	return out
}

// toneLevel is the amplitude of hz in x, by correlation (a Goertzel filter would be
// cheaper but needs more explanation).
func toneLevel(x []float64, hz, rate float64) float64 {
	var re, im float64
	for i, v := range x {
		ph := 2 * math.Pi * hz * float64(i) / rate
		re += v * math.Cos(ph)
		im += v * math.Sin(ph)
	}
	return 2 * math.Hypot(re, im) / float64(len(x))
}

func mean(x []float64) float64 {
	var s float64
	for _, v := range x {
		s += v
	}
	return s / float64(len(x))
}

func firstAudioFrame(t *testing.T, sub *leyline.Subscription) []float64 {
	t.Helper()
	select {
	case f := <-sub.Frames:
		return f32Payload(t, f.Payload)
	case <-time.After(2 * time.Second):
		t.Fatal("no audio frame")
	}
	return nil
}

func TestAudioTaps(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_000_000})
	if err != nil {
		t.Fatal(err)
	}
	// 146.940 MHz: a carrier the fake sends a 123.0 Hz CTCSS tone on.
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cp.CaptureId, OffsetHz: 940_000, Mode: leylinev1.DemodMode_NFM})
	if err != nil {
		t.Fatal(err)
	}
	const rate = 48000.0
	taps := map[leylinev1.AudioTap][]float64{}
	for _, tap := range []leylinev1.AudioTap{leylinev1.AudioTap_TAP_AUDIO, leylinev1.AudioTap_TAP_DEMOD} {
		sub, err := c.SubscribeAudioTap(ctx, ch.ChannelId, 0, leylinev1.AudioSampleFormat_F32, tap)
		if err != nil {
			t.Fatalf("subscribe %v: %v", tap, err)
		}
		if got := sub.Descriptor.GetAudio().GetTap(); got != tap {
			t.Errorf("descriptor tap %v, want %v", got, tap)
		}
		taps[tap] = firstAudioFrame(t, sub)
		if err := sub.Close(); err != nil {
			t.Errorf("close: %v", err)
		}
	}
	// The tone the daemon reports under the voice is on the demod tap and not on
	// the audio tap, which is high-passed above it, and the demod tap carries the
	// discriminator's DC offset.
	audio, demod := taps[leylinev1.AudioTap_TAP_AUDIO], taps[leylinev1.AudioTap_TAP_DEMOD]
	if lvl := toneLevel(demod, 123, rate); lvl < 0.05 {
		t.Errorf("demod tap 123 Hz level %.3f, want the fake's tone", lvl)
	}
	if lvl := toneLevel(audio, 123, rate); lvl > 0.02 {
		t.Errorf("audio tap 123 Hz level %.3f, want no tone", lvl)
	}
	if m := mean(demod); m < 0.005 {
		t.Errorf("demod tap mean %.4f, want a DC offset", m)
	}
	if m := mean(audio); math.Abs(m) > 0.005 {
		t.Errorf("audio tap mean %.4f, want no DC", m)
	}
	// An unset tap is the audio tap, so an old subscription is unchanged.
	sub, err := c.SubscribeAudio(ctx, ch.ChannelId, 0, leylinev1.AudioSampleFormat_F32)
	if err != nil {
		t.Fatal(err)
	}
	if got := sub.Descriptor.GetAudio().GetTap(); got != leylinev1.AudioTap_TAP_AUDIO {
		t.Errorf("default tap %v, want TAP_AUDIO", got)
	}
	if lvl := toneLevel(firstAudioFrame(t, sub), 123, rate); lvl > 0.02 {
		t.Errorf("default tap 123 Hz level %.3f, want no tone", lvl)
	}
	if err := sub.Close(); err != nil {
		t.Errorf("close: %v", err)
	}
}

func TestAudioTapRefusals(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	cp, ch := setupCaptureChannel(t, c)
	// A raw-IQ channel has no detector to tap.
	raw, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{
		CaptureId: cp.CaptureId, OffsetHz: 300_000, BandwidthHz: 12_500, Mode: leylinev1.DemodMode_RAW_IQ,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.SubscribeAudioTap(ctx, raw.ChannelId, 0, leylinev1.AudioSampleFormat_F32, leylinev1.AudioTap_TAP_DEMOD)
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("want INVALID_ARGUMENT for the demod tap on a raw-IQ channel, got %v", err)
	}
	// The audio tap on the same channel is the stream ley listen already takes.
	sub, err := c.SubscribeAudio(ctx, raw.ChannelId, 0, leylinev1.AudioSampleFormat_F32)
	if err != nil {
		t.Errorf("audio tap on a raw-IQ channel: %v", err)
	} else if err := sub.Close(); err != nil {
		t.Errorf("close: %v", err)
	}
	// A tap value from a newer client is refused by name, not served as audio.
	_, err = c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_ChannelId{ChannelId: ch.ChannelId},
		Kind:   leylinev1.StreamKind_AUDIO,
		Params: &leylinev1.SubscribeRequest_Audio{Audio: &leylinev1.AudioParams{Tap: leylinev1.AudioTap(7)}},
	})
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("want INVALID_ARGUMENT for an unknown tap, got %v", err)
	}
}

func TestAudioSpectrumStream(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_000_000})
	if err != nil {
		t.Fatal(err)
	}
	// 146.940 MHz: a carrier the fake sends a 123.0 Hz CTCSS tone on.
	ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cp.CaptureId, OffsetHz: 940_000, Mode: leylinev1.DemodMode_NFM})
	if err != nil {
		t.Fatal(err)
	}
	rows := map[leylinev1.AudioTap][]float64{}
	for _, tap := range []leylinev1.AudioTap{leylinev1.AudioTap_TAP_AUDIO, leylinev1.AudioTap_TAP_DEMOD} {
		sub, err := c.SubscribeAudioSpectrum(ctx, ch.ChannelId, 1024, 20, leylinev1.FftBinFormat_DB_F32, tap)
		if err != nil {
			t.Fatalf("subscribe %v: %v", tap, err)
		}
		d := sub.Descriptor
		// The audio rate is 48 kHz at 2.4 MSPS, so the row runs 0 Hz to 24 kHz and the
		// descriptor centres it where every FFT reader looks for the middle of the span.
		if p := d.GetFft(); p.GetBins() != 1024 || p.GetTap() != tap || p.GetRowsPerSecond() != 20 ||
			p.GetAccumulation() != leylinev1.FftAccumulation_ROW_SNAPSHOT || p.GetLooksPerRow() != 1 {
			t.Errorf("%v descriptor params = %v", tap, p)
		}
		if d.CenterHz != 12_000 || d.SpanHz != 24_000 {
			t.Errorf("%v descriptor center/span = %d/%d, want 12000/24000", tap, d.CenterHz, d.SpanHz)
		}
		rows[tap] = firstRow(t, sub)
		if err := sub.Close(); err != nil {
			t.Errorf("close: %v", err)
		}
	}
	const binHz = 24_000.0 / 1024
	audio, demod := rows[leylinev1.AudioTap_TAP_AUDIO], rows[leylinev1.AudioTap_TAP_DEMOD]
	// The voice stand-in is on both taps at half full scale; the PL is only on the demod tap.
	for tap, row := range rows {
		if lvl := binLevel(t, row, 1000, binHz); lvl < -8 || lvl > -4 {
			t.Errorf("%v 1 kHz bin %.1f dB, want about -6", tap, lvl)
		}
	}
	if lvl := binLevel(t, demod, 123, binHz); lvl < -22 || lvl > -18 {
		t.Errorf("demod tap 123 Hz bin %.1f dB, want about -20", lvl)
	}
	if lvl := binLevel(t, audio, 123, binHz); lvl > -60 {
		t.Errorf("audio tap 123 Hz bin %.1f dB, want the floor", lvl)
	}
	// Rows come at most twenty a second however fast they are asked for, and bins round up
	// the ladder as they do for the radio.
	sub, err := c.SubscribeAudioSpectrum(ctx, ch.ChannelId, 300, 30, leylinev1.FftBinFormat_DB_U8, leylinev1.AudioTap_TAP_AUDIO)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()
	if p := sub.Descriptor.GetFft(); p.GetRowsPerSecond() != 20 || p.GetBins() != 512 || p.GetBinFormat() != leylinev1.FftBinFormat_DB_U8 {
		t.Errorf("clamped descriptor = %v", p)
	}
	// Past the cap this path serves, a request comes back at the cap; a request that names no
	// rate gets the same ten rows a second the radio's FFT answers.
	wide, err := c.SubscribeAudioSpectrum(ctx, ch.ChannelId, 16384, 0, leylinev1.FftBinFormat_DB_F32, leylinev1.AudioTap_TAP_AUDIO)
	if err != nil {
		t.Fatal(err)
	}
	defer wide.Close()
	if p := wide.Descriptor.GetFft(); p.GetBins() != 4096 || p.GetRowsPerSecond() != 10 {
		t.Errorf("capped descriptor = %v, want 4096 bins at 10 rows a second", p)
	}
}

// binLevel is the row's level at the bin a tone of hz falls in.
func binLevel(t *testing.T, row []float64, hz, binHz float64) float64 {
	t.Helper()
	i := int(math.Round(hz / binHz))
	if i < 0 || i >= len(row) {
		t.Fatalf("%.0f Hz is outside a %d-bin row", hz, len(row))
	}
	return row[i]
}

func TestAudioSpectrumRefusals(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	cp, ch := setupCaptureChannel(t, c)
	// A raw-IQ channel carries no audio, on either tap; the spectrum of silence would look
	// like a quiet band.
	raw, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{
		CaptureId: cp.CaptureId, OffsetHz: 300_000, BandwidthHz: 12_500, Mode: leylinev1.DemodMode_RAW_IQ,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, tap := range []leylinev1.AudioTap{leylinev1.AudioTap_TAP_AUDIO, leylinev1.AudioTap_TAP_DEMOD} {
		_, err := c.SubscribeAudioSpectrum(ctx, raw.ChannelId, 1024, 10, leylinev1.FftBinFormat_DB_F32, tap)
		if leyline.Code(err) != leyline.CodeInvalidArgument {
			t.Errorf("want INVALID_ARGUMENT for %v on a raw-IQ channel, got %v", tap, err)
		}
	}
	// A tap value from a newer client is refused by name rather than served as the audio tap.
	_, err = c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_ChannelId{ChannelId: ch.ChannelId},
		Kind:   leylinev1.StreamKind_FFT,
		Params: &leylinev1.SubscribeRequest_Fft{Fft: &leylinev1.FftParams{Bins: 1024, Tap: leylinev1.AudioTap(7)}},
	})
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("want INVALID_ARGUMENT for an unknown tap, got %v", err)
	}
	// An unset tap is the audio tap, as it is on an audio subscription.
	d, err := c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_ChannelId{ChannelId: ch.ChannelId},
		Kind:   leylinev1.StreamKind_FFT,
		Params: &leylinev1.SubscribeRequest_Fft{Fft: &leylinev1.FftParams{Bins: 1024}},
	})
	if err != nil {
		t.Fatalf("default tap: %v", err)
	}
	if got := d.GetFft().GetTap(); got != leylinev1.AudioTap_TAP_AUDIO {
		t.Errorf("default tap %v, want TAP_AUDIO", got)
	}
	// A row is one transform of one window, so an accumulation the daemon knows is answered
	// ROW_SNAPSHOT and one it does not know is refused rather than quietly ignored.
	_, err = c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_ChannelId{ChannelId: ch.ChannelId},
		Kind:   leylinev1.StreamKind_FFT,
		Params: &leylinev1.SubscribeRequest_Fft{Fft: &leylinev1.FftParams{Bins: 1024, Accumulation: leylinev1.FftAccumulation(9)}},
	})
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("want INVALID_ARGUMENT for an unknown accumulation, got %v", err)
	}
	for _, acc := range []leylinev1.FftAccumulation{
		leylinev1.FftAccumulation_ROW_SNAPSHOT, leylinev1.FftAccumulation_ROW_MEAN, leylinev1.FftAccumulation_ROW_MAX,
	} {
		d, err := c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
			Source: &leylinev1.SubscribeRequest_ChannelId{ChannelId: ch.ChannelId},
			Kind:   leylinev1.StreamKind_FFT,
			Params: &leylinev1.SubscribeRequest_Fft{Fft: &leylinev1.FftParams{Bins: 1024, Accumulation: acc}},
		})
		if err != nil {
			t.Fatalf("%v: %v", acc, err)
		}
		if got := d.GetFft().GetAccumulation(); got != leylinev1.FftAccumulation_ROW_SNAPSHOT {
			t.Errorf("%v answered %v, want ROW_SNAPSHOT", acc, got)
		}
	}
	// A persistence histogram is still the radio's alone.
	_, err = c.Bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_ChannelId{ChannelId: ch.ChannelId},
		Kind:   leylinev1.StreamKind_PERSISTENCE,
		Params: &leylinev1.SubscribeRequest_Persistence{Persistence: &leylinev1.PersistenceParams{Bins: 256, Levels: 32, FloorDb: -110, RangeDb: 60}},
	})
	if leyline.Code(err) != leyline.CodeInvalidArgument {
		t.Errorf("want INVALID_ARGUMENT for persistence on a channel, got %v", err)
	}
}

// The audio descriptor tells a client what full scale is worth in hertz, so no
// view has to hard-code a deviation: it follows an NFM channel's bandwidth, is
// broadcast's 75 kHz on WFM, and is 0 where the samples are amplitude.
func TestAudioDescriptorFullScaleDeviation(t *testing.T) {
	t.Parallel()
	c, _ := harness(t, fakedaemon.Options{})
	ctx := t.Context()
	st := mustState(t, c)
	cp, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_000_000})
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		mode leylinev1.DemodMode
		bw   uint32
		want uint32
	}{
		{leylinev1.DemodMode_NFM, 12_500, 2_500},
		{leylinev1.DemodMode_NFM, 25_000, 5_000},
		{leylinev1.DemodMode_NFM, 10_000, 2_500},
		{leylinev1.DemodMode_WFM, 200_000, 75_000},
		{leylinev1.DemodMode_AM, 10_000, 0},
		{leylinev1.DemodMode_USB, 2_800, 0},
	}
	for _, tc := range cases {
		ch, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{
			CaptureId: cp.CaptureId, OffsetHz: 940_000, Mode: tc.mode, BandwidthHz: tc.bw,
		})
		if err != nil {
			t.Fatalf("%v %d Hz: %v", tc.mode, tc.bw, err)
		}
		sub, err := c.SubscribeAudio(ctx, ch.ChannelId, 0, leylinev1.AudioSampleFormat_F32)
		if err != nil {
			t.Fatalf("subscribe %v: %v", tc.mode, err)
		}
		if got := sub.Descriptor.GetAudio().GetFullScaleDeviationHz(); got != tc.want {
			t.Errorf("%v %d Hz: full scale %d Hz, want %d", tc.mode, tc.bw, got, tc.want)
		}
		if err := sub.Close(); err != nil {
			t.Errorf("close: %v", err)
		}
	}
}
