package fakedaemon

import (
	"context"
	"encoding/binary"
	"math"
	"time"

	"google.golang.org/grpc"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// Stream implements Bulk: writes synthetic frames until the client cancels or
// the subscription is torn down. Under GAP_MARKED a frame the reader was too slow to take is
// reported as the gap its samples left behind.
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
	// One reader per subscription, as the daemon's registry claims it: two Stream calls on one id
	// would hand out two frame sequences that both start at seq 1.
	if s.reading {
		d.mu.Unlock()
		return fail(ctx, errorf(leyline.CodeFailedPrecondition, s.id, "stream already has a reader"))
	}
	s.reading = true
	d.mu.Unlock()
	// A reader that goes away leaves the subscription claimable again, on a fresh grace: a client
	// whose Stream RPC dropped has that long to come back before the daemon reaps it.
	defer func() {
		d.mu.Lock()
		s.reading = false
		d.mu.Unlock()
		time.AfterFunc(readerReapWait, func() { d.reapStream(s.id) })
	}()
	done := d.streamOpened(ctx)
	defer done()

	var interval time.Duration
	switch p := s.desc.Params.(type) {
	case *leylinev1.StreamDescriptor_Fft:
		interval = time.Duration(float64(time.Second) / p.Fft.RowsPerSecond)
	case *leylinev1.StreamDescriptor_Persistence:
		interval = time.Duration(float64(time.Second) / p.Persistence.RowsPerSecond)
	default:
		interval = 20 * time.Millisecond
	}
	frames := make(chan outFrame, streamBacklog)
	go d.produce(ctx, s, interval, frames)
	var lastSeq, lastEnd uint64
	for of := range frames {
		// A gap is what was actually lost. The producer numbers every frame it built, so a jump
		// in that sequence is the drop itself, and the bounds are the samples between the end of
		// the last frame this reader got and the start of this one.
		if s.desc.Policy == leylinev1.DeliveryPolicy_GAP_MARKED && lastSeq != 0 && of.frame.Seq != lastSeq+1 {
			of.frame.Gap = &leylinev1.Gap{FromSample: lastEnd, ToSample: of.frame.Time.SampleIndex}
		}
		lastSeq, lastEnd = of.frame.Seq, of.end
		if err := srv.Send(of.frame); err != nil {
			return nil
		}
	}
	return nil
}

// streamBacklog is how many built frames the fake holds for a reader that has stopped taking
// them, matching the slot count of the daemon's frame rings. A live stream is not a queue: past
// that the newest frame displaces the oldest, which is what leaves a gap to report.
const streamBacklog = 8

// outFrame is a built frame plus the sample index just past its payload, which is where the next
// frame's samples start and so where a gap would begin.
type outFrame struct {
	frame *leylinev1.Frame
	end   uint64
}

// produce builds frames on the interval and hands them to the sender, dropping the oldest when
// the reader is behind. It closes frames when the capture has nothing left to serve.
func (d *Daemon) produce(ctx context.Context, s *stream, interval time.Duration, frames chan outFrame) {
	defer close(frames)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	var seq uint64
	// A frame carries the samples since the previous tick, so its SampleTime is where that span
	// starts: the capture's position when the producer began, for the first frame.
	var prevIdx uint64
	d.mu.Lock()
	if c := d.captures[s.captureID]; c != nil {
		prevIdx = c.sampleIndex(time.Now())
	}
	d.mu.Unlock()
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.closed:
			return
		case now := <-ticker.C:
			d.mu.Lock()
			c := d.captures[s.captureID]
			var payload []byte
			var idx uint64
			if c != nil && c.State == leylinev1.CaptureState_CAPTURE_ACTIVE && c.atEOF(now) {
				// The file ran out (no loop): the device is gone from the
				// capture's point of view, exactly as the daemon reports it.
				d.fileEOFLocked(c)
			}
			// Any capture that is not active has no samples to serve, however it got there.
			if c != nil && c.State != leylinev1.CaptureState_CAPTURE_ACTIVE {
				c = nil
			}
			if c != nil {
				idx = c.sampleIndex(now)
				payload = d.renderLocked(s, c, now)
			}
			d.mu.Unlock()
			if c == nil {
				return
			}
			seq++
			of := outFrame{
				frame: &leylinev1.Frame{
					StreamId: s.id, Seq: seq,
					Time:    &leylinev1.SampleTime{CaptureId: c.CaptureId, SampleIndex: prevIdx},
					Payload: payload,
				},
				end: idx,
			}
			prevIdx = idx
			select {
			case frames <- of:
			default:
				// Latest wins: the frame nobody has taken yet is the one to lose.
				select {
				case <-frames:
				default:
				}
				select {
				case frames <- of:
				default:
				}
			}
		}
	}
}

// fileEOFLocked is the end of a non-looping playback file: the device goes
// DISCONNECTED and its capture CAPTURE_DETACHED (both stay in state, as after
// a USB unplug; DestroyCapture / DetachFileDevice clean up). Open bulk streams
// on the capture end; channels and sinks are kept.
func (d *Daemon) fileEOFLocked(c *capture) {
	by := &leylinev1.ClientInfo{ClientId: "daemon", Kind: "daemon", Label: "playback"}
	c.State = leylinev1.CaptureState_CAPTURE_DETACHED
	if dev := d.devices[c.DeviceId]; dev != nil {
		dev.State = leylinev1.DeviceState_DISCONNECTED
		d.emit(by, dev)
	}
	d.emit(by, c.Capture)
	for sid, s := range d.streams {
		if s.captureID == c.CaptureId {
			s.close()
			delete(d.streams, sid)
		}
	}
}

// renderLocked produces one frame payload in the negotiated format.
func (d *Daemon) renderLocked(s *stream, c *capture, now time.Time) []byte {
	switch p := s.desc.Params.(type) {
	case *leylinev1.StreamDescriptor_Fft:
		return d.renderFFTLocked(c, p.Fft, now)
	case *leylinev1.StreamDescriptor_Audio:
		return d.renderAudioLocked(s, p.Audio, now)
	case *leylinev1.StreamDescriptor_Iq:
		return renderIQ(p.Iq, now)
	case *leylinev1.StreamDescriptor_Persistence:
		return d.renderPersistenceLocked(s, c, p.Persistence, now)
	}
	return nil
}

// renderFFTLocked encodes one spectrum row in the negotiated bin format, built the way the
// subscription asked for: one periodogram under ROW_SNAPSHOT, and otherwise the looks the
// descriptor promised, spread across the row's interval.
func (d *Daemon) renderFFTLocked(c *capture, p *leylinev1.FftParams, now time.Time) []byte {
	bins := int(p.Bins)
	row := d.accumulateRowLocked(c, bins, now, p)
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

// accumulateRowLocked builds one row from as many looks as the accumulation asks for. A mean
// averages power, which steadies the floor and dilutes a burst; a max keeps the loudest look,
// which catches the burst and reads the floor a few dB high, because the maximum of N draws is
// biased upward.
func (d *Daemon) accumulateRowLocked(c *capture, bins int, now time.Time, p *leylinev1.FftParams) []float32 {
	looks := int(p.GetLooksPerRow())
	if looks <= 1 || p.GetAccumulation() == leylinev1.FftAccumulation_ROW_SNAPSHOT {
		return d.spectrumRowLocked(c, bins, now)
	}
	interval := time.Duration(float64(time.Second) / math.Max(minRowsPerSecond, p.GetRowsPerSecond()))
	step := interval / time.Duration(looks)
	row := d.spectrumRowLocked(c, bins, now)
	if p.GetAccumulation() == leylinev1.FftAccumulation_ROW_MEAN {
		power := make([]float64, bins)
		for i, v := range row {
			power[i] = math.Pow(10, float64(v)/10)
		}
		for k := 1; k < looks; k++ {
			next := d.spectrumRowLocked(c, bins, now.Add(time.Duration(k)*step))
			for i, v := range next {
				power[i] += math.Pow(10, float64(v)/10)
			}
		}
		for i := range row {
			row[i] = float32(10 * math.Log10(power[i]/float64(looks)))
		}
		return row
	}
	for k := 1; k < looks; k++ {
		next := d.spectrumRowLocked(c, bins, now.Add(time.Duration(k)*step))
		for i, v := range next {
			if v > row[i] {
				row[i] = v
			}
		}
	}
	return row
}

// spectrumRowLocked: -100 dB noise floor (±3 dB jitter) with a peak at every
// channel offset on this capture, scaled to the channel bandwidth.
func (d *Daemon) spectrumRowLocked(c *capture, bins int, now time.Time) []float32 {
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
	return row
}

// renderAudioLocked: 20 ms of a 1 kHz sine at the negotiated rate, mono. The demod
// tap carries what the detector would hand over before the audio chain cleans it up:
// the same voice, the sub-audible tone the channel's carrier is sending (the one
// SUB_AUDIBLE telemetry reports) riding under it, and a DC offset standing in for a
// tuning error. A client can tell the two taps apart by looking, which is the point
// of the view they feed.
func (d *Daemon) renderAudioLocked(s *stream, p *leylinev1.AudioParams, now time.Time) []byte {
	tone := 0.0
	if p.Tap == leylinev1.AudioTap_TAP_DEMOD {
		if ch := d.channels[s.channelID]; ch != nil {
			if c := d.captures[ch.CaptureId]; c != nil {
				tone = carrierTone(uint64(int64(c.CenterHz) + ch.OffsetHz))
			}
		}
	}
	return renderAudio(p, tone, now)
}

// renderAudio encodes one 20 ms block; toneHz > 0 adds the sub-audible tone and the
// demod tap's DC offset.
func renderAudio(p *leylinev1.AudioParams, toneHz float64, now time.Time) []byte {
	n := int(p.SampleRate / 50)
	t0 := float64(now.UnixNano()%1_000_000_000) / 1e9
	dc := 0.0
	if p.Tap == leylinev1.AudioTap_TAP_DEMOD {
		dc = demodTapDC
	}
	sample := func(i int) float64 {
		t := t0 + float64(i)/float64(p.SampleRate)
		v := 0.5 * math.Sin(2*math.Pi*1000*t)
		if toneHz > 0 {
			v += subAudibleTapLevel * math.Sin(2*math.Pi*toneHz*t)
		}
		return v + dc
	}
	if p.Format == leylinev1.AudioSampleFormat_F32 {
		out := make([]byte, n*4)
		for i := range n {
			binary.LittleEndian.PutUint32(out[i*4:], math.Float32bits(float32(sample(i))))
		}
		return out
	}
	out := make([]byte, n*2)
	for i := range n {
		binary.LittleEndian.PutUint16(out[i*2:], uint16(int16(sample(i)*32767)))
	}
	return out
}

const (
	// A CTCSS tone is sent well under the voice it rides with.
	subAudibleTapLevel = 0.1
	// The discriminator's DC offset is the tuning error; a real receiver is never
	// exactly on frequency.
	demodTapDC = 0.02
)

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
