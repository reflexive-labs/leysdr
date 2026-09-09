package fakedaemon

import (
	"encoding/binary"
	"math"
	"time"

	"google.golang.org/grpc"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// Stream implements Bulk: writes synthetic frames until the client cancels or
// the subscription is torn down. Under GAP_MARKED every 50th frame carries a Gap.
func (b bulkSvc) Stream(ref *leylinev1.StreamRef, srv grpc.ServerStreamingServer[leylinev1.Frame]) error {
	d := b.d
	ctx, stop := d.streamContext(srv.Context())
	defer stop()
	d.mu.Lock()
	s := d.streams[ref.GetStreamId()]
	if s == nil {
		d.mu.Unlock()
		return fail(ctx, errorf(leyline.CodeStreamNotFound, ref.GetStreamId(), "no such stream"))
	}
	s.reading = true
	d.mu.Unlock()
	done := d.streamOpened(ctx)
	defer done()

	var interval time.Duration
	switch p := s.desc.Params.(type) {
	case *leylinev1.StreamDescriptor_Fft:
		interval = time.Duration(float64(time.Second) / p.Fft.RowsPerSecond)
	default:
		interval = 20 * time.Millisecond
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	var seq uint64
	var lastSample uint64
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-s.closed:
			return nil
		case now := <-ticker.C:
			d.mu.Lock()
			c := d.captures[s.captureID]
			var ch *leylinev1.Channel
			if s.channelID != "" {
				ch = d.channels[s.channelID]
			}
			var payload []byte
			var idx uint64
			if c != nil {
				idx = c.sampleIndex(now)
				payload = d.renderLocked(s, c, ch, now)
			}
			d.mu.Unlock()
			if c == nil {
				return nil
			}
			seq++
			f := &leylinev1.Frame{StreamId: s.id, Seq: seq, Time: &leylinev1.SampleTime{CaptureId: c.CaptureId, SampleIndex: idx}, Payload: payload}
			if s.desc.Policy == leylinev1.DeliveryPolicy_GAP_MARKED && seq%50 == 0 {
				f.Gap = &leylinev1.Gap{FromSample: lastSample, ToSample: idx}
			}
			lastSample = idx
			if err := srv.Send(f); err != nil {
				return nil
			}
		}
	}
}

// renderLocked produces one frame payload in the negotiated format.
func (d *Daemon) renderLocked(s *stream, c *capture, ch *leylinev1.Channel, now time.Time) []byte {
	switch p := s.desc.Params.(type) {
	case *leylinev1.StreamDescriptor_Fft:
		return d.renderFFTLocked(c, p.Fft, now)
	case *leylinev1.StreamDescriptor_Audio:
		return renderAudio(p.Audio, now)
	case *leylinev1.StreamDescriptor_Iq:
		return renderIQ(p.Iq, now)
	}
	return nil
}

// renderFFTLocked: -100 dB noise floor (±3 dB jitter) with a peak at every
// channel offset on this capture, scaled to the channel bandwidth.
func (d *Daemon) renderFFTLocked(c *capture, p *leylinev1.FftParams, now time.Time) []byte {
	bins := int(p.Bins)
	row := make([]float32, bins)
	jitter := float32(now.UnixNano()%1000) / 1000
	for i := range row {
		row[i] = -100 + 3*float32(math.Sin(float64(i)*0.37+float64(jitter)*6.28))
	}
	span := float64(c.SampleRate)
	for _, ch := range d.channels {
		if ch.CaptureId != c.CaptureId {
			continue
		}
		center := (float64(ch.OffsetHz)/span + 0.5) * float64(bins)
		halfW := math.Max(1, float64(ch.BandwidthHz)/span*float64(bins)/2)
		for i := range row {
			dist := (float64(i) - center) / halfW
			if dist > -3 && dist < 3 {
				v := float32(-40 - 60*dist*dist)
				if v > row[i] {
					row[i] = v
				}
			}
		}
	}
	if p.BinFormat == leylinev1.FftBinFormat_DB_U8 {
		out := make([]byte, bins)
		for i, v := range row {
			q := math.Round(float64(v+120) * 2)
			out[i] = byte(math.Max(0, math.Min(255, q)))
		}
		return out
	}
	out := make([]byte, bins*4)
	for i, v := range row {
		binary.LittleEndian.PutUint32(out[i*4:], math.Float32bits(v))
	}
	return out
}

// renderAudio: 20 ms of a 1 kHz sine at the negotiated rate, mono.
func renderAudio(p *leylinev1.AudioParams, now time.Time) []byte {
	n := int(p.SampleRate / 50)
	t0 := float64(now.UnixNano()%1_000_000_000) / 1e9
	if p.Format == leylinev1.AudioSampleFormat_F32 {
		out := make([]byte, n*4)
		for i := range n {
			v := float32(0.5 * math.Sin(2*math.Pi*1000*(t0+float64(i)/float64(p.SampleRate))))
			binary.LittleEndian.PutUint32(out[i*4:], math.Float32bits(v))
		}
		return out
	}
	out := make([]byte, n*2)
	for i := range n {
		v := 0.5 * math.Sin(2*math.Pi*1000*(t0+float64(i)/float64(p.SampleRate)))
		binary.LittleEndian.PutUint16(out[i*2:], uint16(int16(v*32767)))
	}
	return out
}

// renderIQ: 20 ms of a complex tone at +100 kHz, CF32 interleaved.
func renderIQ(p *leylinev1.IqParams, now time.Time) []byte {
	n := int(p.SampleRate / 50)
	t0 := float64(now.UnixNano()%1_000_000_000) / 1e9
	out := make([]byte, n*8)
	for i := range n {
		ph := 2 * math.Pi * 100_000 * (t0 + float64(i)/float64(p.SampleRate))
		binary.LittleEndian.PutUint32(out[i*8:], math.Float32bits(float32(0.3*math.Cos(ph))))
		binary.LittleEndian.PutUint32(out[i*8+4:], math.Float32bits(float32(0.3*math.Sin(ph))))
	}
	return out
}
