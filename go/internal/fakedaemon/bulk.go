package fakedaemon

import (
	"context"
	"fmt"
	"math"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// FFTLadder is the fixed power-of-two bin-count set the fake serves from
// (the engine's DefaultSpectrumLadder sizes).
var FFTLadder = []uint32{256, 512, 1024, 2048, 4096, 8192, 16384}

// Stream-plane limits.
const (
	maxFFTRows     = 30.0
	defaultFFTRows = 10.0
	readerReapWait = 10 * time.Second
)

type stream struct {
	id        string
	captureID string
	channelID string
	desc      *leylinev1.StreamDescriptor

	closeOnce sync.Once
	closed    chan struct{}
	reading   bool
}

func (s *stream) close() { s.closeOnce.Do(func() { close(s.closed) }) }

// audioRate is the channel's native audio rate for a capture running at fs,
// derived from the engine's channelizer plan (engine-internals.md): stage 1
// decimates to r1 = fs/D1 (>= 240 kHz), stage 2 to r2 = r1/D2 (~48 kHz).
// Every mode (WFM included, whose audio is decimated from r1 to r2) produces
// r2; exactly 48 000 at 2.4 MSPS.
func audioRate(fs uint64) uint32 {
	return uint32(math.Round(audioRateHz(fs)))
}

// audioRateHz is r2 before it is rounded to a whole Hz. Boundaries the engine derives from r2 --
// the widest narrow-mode bandwidth, say -- have to be computed from the exact rate, or a capture
// rate whose r2 is fractional puts the daemon and the fake a fraction of a hertz apart.
func audioRateHz(fs uint64) float64 {
	if fs == 0 {
		return 48_000
	}
	d1 := fs / 240_000
	if d1 < 1 {
		d1 = 1
	}
	r1 := float64(fs) / float64(d1)
	d2 := math.Round(r1 / 48_000)
	if d2 < 1 {
		d2 = 1
	}
	return r1 / d2
}

// nearestLadder rounds a request up to the next ladder size (capped at the
// largest), matching the engine's DefaultSpectrumLadder.roundBins.
func nearestLadder(bins uint32) uint32 {
	if bins == 0 {
		return 1024
	}
	for _, b := range FFTLadder {
		if b >= bins {
			return b
		}
	}
	return FFTLadder[len(FFTLadder)-1]
}

// Subscribe implements Bulk: answers with the authoritative descriptor. v0
// rules: GRPC only (SHM_RING downgraded), LIVE only, LATEST_WINS default.
func (b bulkSvc) Subscribe(ctx context.Context, req *leylinev1.SubscribeRequest) (*leylinev1.StreamDescriptor, error) {
	d := b.d
	d.touchUnary(clientFrom(ctx))
	if p := req.GetStart(); p != nil && p.Position != nil {
		if _, live := p.Position.(*leylinev1.StreamPosition_Live); !live {
			return nil, fail(ctx, errorf(leyline.CodeUnimplemented, "", "non-live stream start is not implemented in v0"))
		}
	}
	policy := req.GetPolicy()
	if policy == leylinev1.DeliveryPolicy_DELIVERY_POLICY_UNSPECIFIED {
		policy = leylinev1.DeliveryPolicy_LATEST_WINS
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	s := &stream{id: newID("strm_"), closed: make(chan struct{})}
	desc := &leylinev1.StreamDescriptor{
		StreamId:  s.id,
		Kind:      req.GetKind(),
		Policy:    policy,
		Transport: &leylinev1.StreamDescriptor_Grpc{Grpc: true},
	}
	var c *capture
	switch src := req.GetSource().(type) {
	case *leylinev1.SubscribeRequest_CaptureId:
		c = d.captures[src.CaptureId]
		if c == nil {
			return nil, fail(ctx, errorf(leyline.CodeCaptureNotFound, src.CaptureId, "no such capture"))
		}
	case *leylinev1.SubscribeRequest_ChannelId:
		ch := d.channels[src.ChannelId]
		if ch == nil {
			return nil, fail(ctx, errorf(leyline.CodeChannelNotFound, src.ChannelId, "no such channel"))
		}
		s.channelID = ch.ChannelId
		c = d.captures[ch.CaptureId]
		// Ahead of the audio negotiation, which reads the capture's rate: a channel outliving its
		// capture must answer CAPTURE_NOT_FOUND rather than panic inside the handler.
		if c == nil {
			return nil, fail(ctx, errorf(leyline.CodeCaptureNotFound, ch.CaptureId, "channel has no capture"))
		}
		if req.GetKind() == leylinev1.StreamKind_AUDIO {
			a := req.GetAudio()
			rate := audioRate(c.GetSampleRate())
			// No resampling in v0 (engine parity): only the channel's own rate is served.
			if a.GetSampleRate() != 0 && a.GetSampleRate() != rate {
				return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, ch.ChannelId,
					fmt.Sprintf("audio sample_rate %d unavailable; channel produces %d Hz (request 0 to accept it)", a.GetSampleRate(), rate)))
			}
			format := a.GetFormat()
			if format == leylinev1.AudioSampleFormat_AUDIO_SAMPLE_FORMAT_UNSPECIFIED {
				format = leylinev1.AudioSampleFormat_S16
			}
			desc.Params = &leylinev1.StreamDescriptor_Audio{Audio: &leylinev1.AudioParams{SampleRate: rate, Format: format}}
		}
	default:
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "source is required"))
	}
	// Nothing flows from a capture whose radio has gone -- a playback file that ran out, an
	// unplugged dongle: the daemon has no source to read and ends the streams it had, so a fresh
	// subscription is refused rather than served frames from a stopped timebase.
	if c.State != leylinev1.CaptureState_CAPTURE_ACTIVE {
		return nil, fail(ctx, errorf(leyline.CodeDeviceDetached, c.CaptureId, "the capture is detached; there is nothing to stream"))
	}
	s.captureID = c.CaptureId
	desc.CenterHz, desc.SpanHz = c.CenterHz, c.SampleRate
	switch req.GetKind() {
	case leylinev1.StreamKind_FFT:
		if s.channelID != "" {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, s.channelID, "FFT streams are capture-scoped"))
		}
		f := req.GetFft()
		rows := f.GetRowsPerSecond()
		if rows <= 0 {
			rows = defaultFFTRows
		}
		if rows > maxFFTRows {
			rows = maxFFTRows
		}
		format := f.GetBinFormat()
		if format == leylinev1.FftBinFormat_FFT_BIN_FORMAT_UNSPECIFIED {
			format = leylinev1.FftBinFormat_DB_F32
		}
		desc.Params = &leylinev1.StreamDescriptor_Fft{Fft: &leylinev1.FftParams{Bins: nearestLadder(f.GetBins()), BinFormat: format, RowsPerSecond: rows}}
	case leylinev1.StreamKind_IQ:
		// v0 IQ contract (engine parity with StreamRegistry.subscribe): raw CF32 at the capture's
		// native rate only. Anything else is refused rather than silently overridden.
		iq := req.GetIq()
		if format := iq.GetFormat(); format != leylinev1.SampleFormat_SAMPLE_FORMAT_UNSPECIFIED && format != leylinev1.SampleFormat_CF32 {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, c.CaptureId,
				fmt.Sprintf("iq format %v unavailable; v0 serves CF32 only (request UNSPECIFIED or CF32)", format)))
		}
		if rate := iq.GetSampleRate(); rate != 0 && rate != c.SampleRate {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, c.CaptureId,
				fmt.Sprintf("iq sample_rate %d unavailable; capture runs at %d Hz (request 0 to accept it)", rate, c.SampleRate)))
		}
		desc.Params = &leylinev1.StreamDescriptor_Iq{Iq: &leylinev1.IqParams{SampleRate: c.SampleRate, Format: leylinev1.SampleFormat_CF32}}
	case leylinev1.StreamKind_AUDIO:
		if s.channelID == "" {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, c.CaptureId, "audio streams are channel-scoped"))
		}
	case leylinev1.StreamKind_DECODED:
		return nil, fail(ctx, errorf(leyline.CodeUnimplemented, "", "decoded streams are not implemented in v0"))
	default:
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "stream kind is required"))
	}
	s.desc = desc
	d.streams[s.id] = s
	time.AfterFunc(readerReapWait, func() { d.reapStream(s.id) })
	return proto.Clone(desc).(*leylinev1.StreamDescriptor), nil
}

// reapStream drops a subscription nobody has started reading.
func (d *Daemon) reapStream(id string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if s := d.streams[id]; s != nil && !s.reading {
		s.close()
		delete(d.streams, id)
	}
}

// Unsubscribe implements Bulk.
func (b bulkSvc) Unsubscribe(ctx context.Context, ref *leylinev1.StreamRef) (*leylinev1.Empty, error) {
	d := b.d
	d.touchUnary(clientFrom(ctx))
	d.mu.Lock()
	defer d.mu.Unlock()
	s := d.streams[ref.GetStreamId()]
	if s == nil {
		return nil, fail(ctx, errorf(leyline.CodeStreamNotFound, ref.GetStreamId(), "no such stream"))
	}
	s.close()
	delete(d.streams, s.id)
	return &leylinev1.Empty{}, nil
}
