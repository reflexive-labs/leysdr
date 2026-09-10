package fakedaemon

import (
	"context"
	"fmt"
	"io"
	"math"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// coalesceTick mirrors the Swift WriteCoalescer's 20 ms apply cadence.
const coalesceTick = 20 * time.Millisecond

type writeKey struct {
	target string
	param  string
	elem   string // gain element, for gain writes
}

func keyOf(w *leylinev1.ParamWrite) writeKey {
	k := writeKey{target: w.TargetId, param: fmt.Sprintf("%T", w.Param)}
	if g, ok := w.Param.(*leylinev1.ParamWrite_Gain); ok && g.Gain != nil {
		k.elem = g.Gain.Element
	}
	return k
}

// WriteParams implements Control: last value per (target, param) is applied
// every tick; invalid writes become WriteRejected events tagged for the client.
func (d *Daemon) WriteParams(srv grpc.ClientStreamingServer[leylinev1.ParamWrite, leylinev1.WriteSummary]) error {
	ctx := srv.Context()
	ci := clientFrom(ctx)
	done := d.streamOpened(ctx)
	defer done()

	pending := map[writeKey]*leylinev1.ParamWrite{}
	order := []writeKey{}
	var received, applied uint64
	awaited := !d.opts.WriteAwaitsWatcher
	flush := func() {
		if len(pending) == 0 {
			return
		}
		if !awaited {
			d.awaitWatcher(ctx, ci.ClientId)
			awaited = true
		}
		d.mu.Lock()
		for _, k := range order {
			if w, ok := pending[k]; ok && d.applyLocked(ci, w) {
				applied++
			}
		}
		d.mu.Unlock()
		pending = map[writeKey]*leylinev1.ParamWrite{}
		order = order[:0]
	}

	recv := make(chan *leylinev1.ParamWrite)
	recvErr := make(chan error, 1)
	go func() {
		for {
			w, err := srv.Recv()
			if err != nil {
				recvErr <- err
				return
			}
			select {
			case recv <- w:
			case <-ctx.Done():
				return
			}
		}
	}()
	ticker := time.NewTicker(coalesceTick)
	defer ticker.Stop()
	for {
		select {
		case w := <-recv:
			received++
			k := keyOf(w)
			if _, ok := pending[k]; !ok {
				order = append(order, k)
			}
			pending[k] = w
		case <-ticker.C:
			flush()
		case err := <-recvErr:
			flush()
			if err != io.EOF {
				return nil
			}
			return srv.SendAndClose(&leylinev1.WriteSummary{WritesReceived: received, WritesApplied: applied})
		case <-ctx.Done():
			flush()
			return nil
		}
	}
}

// awaitWatcher blocks until client has a registered WatchEvents stream, the
// context ends or Options.WatcherWait elapses (Options.WriteAwaitsWatcher).
func (d *Daemon) awaitWatcher(ctx context.Context, client string) {
	wait := d.opts.WatcherWait
	if wait == 0 {
		wait = 2 * time.Second
	}
	deadline := time.Now().Add(wait)
	for {
		d.mu.Lock()
		found := false
		for w := range d.watchers {
			if w.client == client {
				found = true
				break
			}
		}
		d.mu.Unlock()
		if found || ctx.Err() != nil || time.Now().After(deadline) {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Millisecond):
		}
	}
}

func (d *Daemon) rejectLocked(ci *leylinev1.ClientInfo, tag uint64, e *leyline.Error) bool {
	d.emit(ci, &leylinev1.WriteRejected{Tag: tag, Error: &leylinev1.ErrorDetail{Code: e.Code, Message: e.Message, Target: e.Target}})
	return false
}

// applyLocked applies one write to the live object and emits its full state.
// Returns false (after emitting WriteRejected) when the write is invalid.
func (d *Daemon) applyLocked(ci *leylinev1.ClientInfo, w *leylinev1.ParamWrite) bool {
	if d.opts.RejectWrites != nil {
		if e := d.opts.RejectWrites(w); e != nil {
			return d.rejectLocked(ci, w.Tag, e)
		}
	}
	interactive := ci.Kind != "job"
	touch := func(c *capture) {
		if interactive {
			c.Activity.LastInteractiveWriteNs = time.Now().UnixNano()
		}
	}
	switch p := w.Param.(type) {
	case *leylinev1.ParamWrite_CenterHz, *leylinev1.ParamWrite_CaptureSampleRate, *leylinev1.ParamWrite_Gain:
		c := d.captures[w.TargetId]
		if c == nil {
			return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeCaptureNotFound, w.TargetId, "no such capture"))
		}
		dev := d.devices[c.DeviceId]
		// A sweep is the only thing tuning the radio it owns: a retune, a rate change or a gain
		// write aimed at its capture waits for it, as the daemon's refuseIfSwept does. (Gain
		// because the lease pins it, so every dB the scan reports is one sensitivity.)
		if d.sweeping != "" && d.sweeping == c.DeviceId {
			return d.rejectLocked(ci, w.Tag, sweptError(c.CaptureId))
		}
		switch p := p.(type) {
		case *leylinev1.ParamWrite_CenterHz:
			if dev == nil || !inRange(dev, p.CenterHz) {
				return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeFreqOutOfRange, w.TargetId, fmt.Sprintf("%d Hz is outside the device tuning range", p.CenterHz)))
			}
			c.CenterHz = p.CenterHz
		case *leylinev1.ParamWrite_CaptureSampleRate:
			if dev == nil || !rateOK(dev, p.CaptureSampleRate) {
				return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeRateUnsupported, w.TargetId, fmt.Sprintf("%d sps is not a supported sample rate", p.CaptureSampleRate)))
			}
			c.SampleRate = p.CaptureSampleRate
			c.Anchor.SampleRate = p.CaptureSampleRate
		case *leylinev1.ParamWrite_Gain:
			if e := d.applyGainLocked(c, dev, p.Gain, w.TargetId); e != nil {
				return d.rejectLocked(ci, w.Tag, e)
			}
		}
		touch(c)
		d.emit(ci, c.Capture)
		d.recheckChannelsLocked(ci, c)
		return true
	case *leylinev1.ParamWrite_OffsetHz, *leylinev1.ParamWrite_BandwidthHz, *leylinev1.ParamWrite_Mode, *leylinev1.ParamWrite_SquelchDb:
		ch := d.channels[w.TargetId]
		if ch == nil {
			return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeChannelNotFound, w.TargetId, "no such channel"))
		}
		c := d.captures[ch.CaptureId]
		switch p := p.(type) {
		case *leylinev1.ParamWrite_OffsetHz:
			if c != nil && !channelFits(c, p.OffsetHz, ch.BandwidthHz) {
				return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeOffsetOutOfCapture, w.TargetId, fmt.Sprintf("offset %d Hz falls outside the capture bandwidth", p.OffsetHz)))
			}
			ch.OffsetHz = p.OffsetHz
		case *leylinev1.ParamWrite_BandwidthHz:
			// Mirrors the daemon: bandwidth (like mode and squelch) is stored even while the
			// channel is OUT_OF_CAPTURE and applied on re-entry, so it is not checked against the
			// current offset. Only the offset-independent bound applies: 0 < bw <= capture rate.
			if p.BandwidthHz == 0 {
				return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeInvalidArgument, w.TargetId, "bandwidth must be > 0"))
			}
			if c != nil && uint64(p.BandwidthHz) > c.SampleRate {
				return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeInvalidArgument, w.TargetId, fmt.Sprintf("bandwidth %d Hz is wider than the %d sps capture", p.BandwidthHz, c.SampleRate)))
			}
			if e := checkBandwidth(c, ch.Mode, p.BandwidthHz, w.TargetId); e != nil {
				return d.rejectLocked(ci, w.Tag, e)
			}
			ch.BandwidthHz = p.BandwidthHz
		case *leylinev1.ParamWrite_Mode:
			if p.Mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED || leylinev1.DemodMode_name[int32(p.Mode)] == "" {
				return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeModeUnsupported, w.TargetId, fmt.Sprintf("demodulator %v is not available", p.Mode)))
			}
			// A channel is re-planned on every write, so a mode that cannot carry the bandwidth
			// it already has is refused rather than quietly filtered narrower.
			if e := checkBandwidth(c, p.Mode, ch.BandwidthHz, w.TargetId); e != nil {
				return d.rejectLocked(ci, w.Tag, e)
			}
			ch.Mode = p.Mode
		case *leylinev1.ParamWrite_SquelchDb:
			if !math.IsNaN(p.SquelchDb) && (p.SquelchDb > 0 || p.SquelchDb < -200) {
				return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeInvalidArgument, w.TargetId, "squelch must be a dBFS value <= 0 or NaN"))
			}
			ch.SquelchDb = p.SquelchDb
		}
		if c != nil {
			touch(c)
			d.emit(ci, c.Capture)
		}
		d.emit(ci, ch)
		return true
	case *leylinev1.ParamWrite_SinkVolume:
		s := d.sinks[w.TargetId]
		sa, ok := s.GetKind().(*leylinev1.Sink_SystemAudio)
		if s == nil || !ok {
			return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeSinkNotFound, w.TargetId, "no such system-audio sink"))
		}
		if p.SinkVolume < 0 || p.SinkVolume > 1 {
			return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeInvalidArgument, w.TargetId, "volume must be within 0..1"))
		}
		sa.SystemAudio.Volume = proto.Float64(p.SinkVolume)
		d.emit(ci, s)
		return true
	default:
		return d.rejectLocked(ci, w.Tag, errorf(leyline.CodeInvalidArgument, w.TargetId, "param is required"))
	}
}

func (d *Daemon) applyGainLocked(c *capture, dev *leylinev1.DeviceDescriptor, g *leylinev1.GainWrite, target string) *leyline.Error {
	unknown := errorf(leyline.CodeGainElementUnknown, target, "no gain element named "+g.GetElement())
	if g == nil || dev == nil {
		return unknown
	}
	// Checked before the element is looked up, because every comparison in the snap is false for a
	// NaN and it would come back as the first entry in the table.
	if db, ok := g.Value.(*leylinev1.GainWrite_Db); ok && (math.IsNaN(db.Db) || math.IsInf(db.Db, 0)) {
		return errorf(leyline.CodeInvalidArgument, target, "gain db must be finite")
	}
	for _, el := range dev.GainElements {
		if el.Name != g.Element {
			continue
		}
		for _, gs := range c.Gains {
			if gs.Element != el.Name {
				continue
			}
			switch v := g.Value.(type) {
			case *leylinev1.GainWrite_Auto:
				// Only asking for automatic gain needs the element to offer it; turning it off is
				// what a manual dB write does anyway.
				if v.Auto && !el.SupportsAuto {
					return unknown
				}
				gs.Auto = v.Auto
			case *leylinev1.GainWrite_Db:
				gs.Auto = false
				gs.Db = leyline.SnapGain(el, v.Db)
			}
			return nil
		}
	}
	return unknown
}

// recheckChannelsLocked flips channels between ACTIVE and OUT_OF_CAPTURE after
// a capture retune or rate change.
func (d *Daemon) recheckChannelsLocked(ci *leylinev1.ClientInfo, c *capture) {
	for _, ch := range d.channels {
		if ch.CaptureId != c.CaptureId {
			continue
		}
		want := leylinev1.ChannelState_CHANNEL_ACTIVE
		if !channelFits(c, ch.OffsetHz, ch.BandwidthHz) {
			want = leylinev1.ChannelState_OUT_OF_CAPTURE
		}
		if ch.State != want {
			ch.State = want
			d.emit(ci, ch)
		}
	}
}
