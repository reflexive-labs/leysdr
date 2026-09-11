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

// Stream-plane limits: what the ladder will serve, and the answers a persistence subscription
// gets where it named nothing. A row rate below the floor would stretch the interval past
// anything a reader waits for, and a half-life outside its range cannot be turned into a whole
// number of rows.
const (
	maxFFTRows     = 30.0
	defaultFFTRows = 10.0
	readerReapWait = 10 * time.Second
	// An audio spectrum is read as a meter rather than scrolled, so it is served no faster than
	// the eye follows a bar.
	maxAudioSpectrumRows = 20.0

	minRowsPerSecond = 0.1
	// The rate the histogram accumulates at, which is as fast as the ladder goes: it wants every
	// row it can get, where a person reads a couple of frames a second.
	ladderRowsPerSecond    = maxFFTRows
	defaultPersistRows     = 2.0
	defaultPersistBins     = 256
	defaultPersistLevels   = 32
	maxPersistLevels       = 256
	defaultHalfLifeSecs    = 20.0
	minHalfLifeSeconds     = 0.1
	maxHalfLifeSeconds     = 3600.0
	snapshotLooksPerRow    = 1
	accumulatedLooksPerRow = 64
)

type stream struct {
	id        string
	captureID string
	channelID string
	desc      *leylinev1.StreamDescriptor

	closeOnce sync.Once
	closed    chan struct{}
	reading   bool
	// The histogram behind a PERSISTENCE stream, built on the first frame and owned by the one
	// goroutine that produces frames for this subscription.
	phosphor *persistence
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

// roundRate clamps a requested row rate the way the ladder does. A non-positive or non-finite
// request means "as fast as allowed".
func roundRate(rowsPerSecond float64) float64 {
	if math.IsNaN(rowsPerSecond) || math.IsInf(rowsPerSecond, 0) || rowsPerSecond <= 0 {
		return maxFFTRows
	}
	return math.Min(math.Max(rowsPerSecond, minRowsPerSecond), maxFFTRows)
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
			tap := a.GetTap()
			switch tap {
			case leylinev1.AudioTap_TAP_AUDIO:
			case leylinev1.AudioTap_TAP_DEMOD:
				// A raw-IQ channel runs no detector, so there is no stage before the audio
				// conditioning to tap; serving silence would look like a quiet band.
				if ch.Mode == leylinev1.DemodMode_RAW_IQ {
					return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, ch.ChannelId,
						"the demod tap needs a demodulator; this channel is raw IQ"))
				}
			default:
				return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, ch.ChannelId,
					fmt.Sprintf("unknown AudioTap %d", tap)))
			}
			desc.Params = &leylinev1.StreamDescriptor_Audio{Audio: &leylinev1.AudioParams{SampleRate: rate, Format: format, Tap: tap}}
		}
	default:
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "source is required"))
	}
	s.captureID = c.CaptureId
	desc.CenterHz, desc.SpanHz = c.CenterHz, c.SampleRate
	switch req.GetKind() {
	case leylinev1.StreamKind_FFT:
		f := req.GetFft()
		rows := defaultFFTRows
		if f.GetRowsPerSecond() > 0 {
			rows = roundRate(f.GetRowsPerSecond())
		}
		format := f.GetBinFormat()
		if format == leylinev1.FftBinFormat_FFT_BIN_FORMAT_UNSPECIFIED {
			format = leylinev1.FftBinFormat_DB_F32
		}
		// looks_per_row is an answer, never a request: a client asking for a look count would be
		// asking the daemon to spend CPU it does not own.
		if f.GetLooksPerRow() != 0 {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "looks_per_row is answered by the daemon; leave it 0"))
		}
		// A channel source asks for the spectrum of that channel's audio rather than the radio's:
		// one transform per row over 0 Hz to half the audio rate, which is where the descriptor's
		// centre and span put the bins.
		if s.channelID != "" {
			ch := d.channels[s.channelID]
			if ch.Mode == leylinev1.DemodMode_RAW_IQ {
				return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, s.channelID,
					"an audio spectrum needs a demodulator; this channel is raw IQ"))
			}
			tap := f.GetTap()
			if tap != leylinev1.AudioTap_TAP_AUDIO && tap != leylinev1.AudioTap_TAP_DEMOD {
				return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, s.channelID,
					fmt.Sprintf("unknown AudioTap %d", tap)))
			}
			rate := audioRate(c.GetSampleRate())
			desc.CenterHz, desc.SpanHz = uint64(rate/4), uint64(rate/2)
			desc.Params = &leylinev1.StreamDescriptor_Fft{Fft: &leylinev1.FftParams{
				Bins: nearestLadder(f.GetBins()), BinFormat: format,
				RowsPerSecond: math.Min(rows, maxAudioSpectrumRows),
				Accumulation:  leylinev1.FftAccumulation_ROW_SNAPSHOT,
				LooksPerRow:   snapshotLooksPerRow, Tap: tap,
			}}
			break
		}
		acc := f.GetAccumulation()
		switch acc {
		case leylinev1.FftAccumulation_FFT_ACCUMULATION_UNSPECIFIED, leylinev1.FftAccumulation_ROW_SNAPSHOT:
			acc = leylinev1.FftAccumulation_ROW_SNAPSHOT
		case leylinev1.FftAccumulation_ROW_MEAN, leylinev1.FftAccumulation_ROW_MAX:
		default:
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", fmt.Sprintf("unknown FftAccumulation %d", acc)))
		}
		// A snapshot row is one periodogram; an accumulated row is however many the ladder can
		// take across the interval, up to its cap, which is the number the descriptor states.
		looks := uint32(snapshotLooksPerRow)
		if acc != leylinev1.FftAccumulation_ROW_SNAPSHOT {
			looks = accumulatedLooksPerRow
		}
		desc.Params = &leylinev1.StreamDescriptor_Fft{Fft: &leylinev1.FftParams{
			Bins: nearestLadder(f.GetBins()), BinFormat: format, RowsPerSecond: rows,
			Accumulation: acc, LooksPerRow: looks,
		}}
	case leylinev1.StreamKind_PERSISTENCE:
		if s.channelID != "" {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, s.channelID, "persistence streams are capture-scoped"))
		}
		pp := req.GetPersistence()
		// The scale is the client's to state. A daemon-chosen one would have to appear in the
		// descriptor before any row had arrived, and a histogram on the wrong scale is not
		// obviously wrong to look at, so this is refused rather than defaulted.
		if !(pp.GetRangeDb() > 0) {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "",
				"persistence needs range_db > 0 and a floor_db; take an FFT row first to find the floor"))
		}
		levels := int(pp.GetLevels())
		if levels == 0 {
			levels = defaultPersistLevels
		}
		if levels < 2 || levels > maxPersistLevels {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "",
				fmt.Sprintf("persistence levels must be 2...%d, got %d", maxPersistLevels, levels)))
		}
		wantBins := pp.GetBins()
		if wantBins == 0 {
			wantBins = defaultPersistBins
		}
		bins := nearestLadder(wantBins)
		emitRows := defaultPersistRows
		if pp.GetRowsPerSecond() > 0 {
			emitRows = roundRate(pp.GetRowsPerSecond())
		}
		halfLife := defaultHalfLifeSecs
		if pp.GetHalfLifeSeconds() > 0 {
			halfLife = math.Min(math.Max(pp.GetHalfLifeSeconds(), minHalfLifeSeconds), maxHalfLifeSeconds)
		}
		desc.Params = &leylinev1.StreamDescriptor_Persistence{Persistence: &leylinev1.PersistenceParams{
			Bins: bins, Levels: uint32(levels), FloorDb: pp.GetFloorDb(), RangeDb: pp.GetRangeDb(),
			HalfLifeSeconds: halfLife, RowsPerSecond: emitRows,
		}}
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
