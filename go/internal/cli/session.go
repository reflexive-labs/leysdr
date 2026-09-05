package cli

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// confirmTimeout bounds how long verbs wait for the daemon's confirming event.
const confirmTimeout = 2 * time.Second

// tuneOptions are the flags shared by `tune` and `play`.
type tuneOptions struct {
	freq uint64
	// captureCenter, when non-zero, is the centre used for a new capture
	// (play: the file's centre, since a playback device tunes nowhere else).
	captureCenter uint64
	mode          leylinev1.DemodMode
	bw            uint32
	device        string
	rate          uint64
	squelch       float64 // NaN = off
	noAudio       bool
	persistent    bool
	volume        float64
}

// session is one tune lifecycle: the capture (created or reused), the channel
// and the optional system-audio sink, plus the open event stream that keeps
// the non-persistent channel alive.
type session struct {
	app            *App
	client         *leyline.Client
	state          *leylinev1.GetStateResponse
	device         *leylinev1.DeviceDescriptor
	capture        *leylinev1.Capture
	createdCapture bool
	channel        *leylinev1.Channel
	sink           *leylinev1.Sink
	events         <-chan *leylinev1.Event
	eventErrs      <-chan error
	cancelEvents   context.CancelFunc
}

// pickDevice chooses --device, else the first non-file device, else the first.
func pickDevice(state *leylinev1.GetStateResponse, id string) (*leylinev1.DeviceDescriptor, error) {
	if len(state.Devices) == 0 {
		return nil, errors.New("no devices available")
	}
	if id != "" {
		for _, d := range state.Devices {
			if d.DeviceId == id {
				return d, nil
			}
		}
		return nil, fmt.Errorf("device %s not found", id)
	}
	for _, d := range state.Devices {
		if d.Driver != "file" && d.State != leylinev1.DeviceState_DISCONNECTED {
			return d, nil
		}
	}
	return state.Devices[0], nil
}

// covers reports whether freq±bw/2 lies inside the capture's span.
func covers(cap *leylinev1.Capture, freq uint64, bw uint32) bool {
	half := float64(cap.SampleRate) / 2
	lo := float64(freq) - float64(bw)/2
	hi := float64(freq) + float64(bw)/2
	c := float64(cap.CenterHz)
	return lo >= c-half && hi <= c+half
}

// open dials, snapshots state and opens the daemon-scoped event stream. The
// event stream is opened before any mutation so every confirmation is seen.
func openSession(ctx context.Context, app *App) (*session, error) {
	c, err := app.dial(ctx)
	if err != nil {
		return nil, app.notRunning(err)
	}
	st, err := c.State(ctx)
	if err != nil {
		c.Close()
		return nil, app.notRunning(err)
	}
	ectx, cancel := context.WithCancel(ctx)
	events, errs, err := c.Events(ectx, nil)
	if err != nil {
		cancel()
		c.Close()
		return nil, err
	}
	return &session{app: app, client: c, state: st, events: events, eventErrs: errs, cancelEvents: cancel}, nil
}

// close tears down the event stream and connection.
func (s *session) close() {
	s.cancelEvents()
	s.client.Close()
}

// awaitEvent drains events until pred returns true or the timeout elapses.
// Because a WatchEvents stream may register on the daemon slightly after the
// client opened it, the daemon's state is also re-read periodically and offered
// to pred as synthetic (caused_by-less) events; reconnect-by-GetState is the
// documented recovery path for missed events.
func (s *session) awaitEvent(ctx context.Context, pred func(*leylinev1.Event) bool) (*leylinev1.Event, error) {
	timer := time.NewTimer(confirmTimeout)
	defer timer.Stop()
	poll := time.NewTicker(250 * time.Millisecond)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
			return nil, errors.New("timed out waiting for the daemon's confirming event")
		case <-poll.C:
			st, err := s.client.State(ctx)
			if err != nil {
				continue
			}
			s.state = st
			for _, ev := range stateEvents(st) {
				s.apply(ev)
				if pred(ev) {
					return ev, nil
				}
			}
		case ev, ok := <-s.events:
			if !ok {
				return nil, fmt.Errorf("event stream ended: %w", <-s.eventErrs)
			}
			s.apply(ev)
			if pred(ev) {
				return ev, nil
			}
		}
	}
}

// stateEvents renders a state snapshot as synthetic full-state events.
func stateEvents(st *leylinev1.GetStateResponse) []*leylinev1.Event {
	out := make([]*leylinev1.Event, 0, len(st.Captures)+len(st.Channels)+len(st.Sinks))
	for _, c := range st.Captures {
		out = append(out, &leylinev1.Event{Seq: st.EventSeq, Body: &leylinev1.Event_Capture{Capture: c}})
	}
	for _, c := range st.Channels {
		out = append(out, &leylinev1.Event{Seq: st.EventSeq, Body: &leylinev1.Event_Channel{Channel: c}})
	}
	for _, c := range st.Sinks {
		out = append(out, &leylinev1.Event{Seq: st.EventSeq, Body: &leylinev1.Event_Sink{Sink: c}})
	}
	return out
}

// apply folds a full-state event into the local mirror (invariant 6: events
// carry whole objects, so the mirror is a straight replace).
func (s *session) apply(ev *leylinev1.Event) {
	switch b := ev.Body.(type) {
	case *leylinev1.Event_Capture:
		replaceCapture(s.state, b.Capture)
		if s.capture != nil && s.capture.CaptureId == b.Capture.CaptureId {
			s.capture = b.Capture
		}
	case *leylinev1.Event_Channel:
		replaceChannel(s.state, b.Channel)
		if s.channel != nil && s.channel.ChannelId == b.Channel.ChannelId {
			s.channel = b.Channel
		}
	case *leylinev1.Event_Sink:
		if s.sink != nil && s.sink.SinkId == b.Sink.SinkId {
			s.sink = b.Sink
		}
	}
}

// mine reports whether the event was caused by this process.
func (s *session) mine(ev *leylinev1.Event) bool {
	return ev.CausedBy != nil && ev.CausedBy.ClientId == s.client.ClientID()
}

func replaceCapture(st *leylinev1.GetStateResponse, c *leylinev1.Capture) {
	for i, x := range st.Captures {
		if x.CaptureId == c.CaptureId {
			st.Captures[i] = c
			return
		}
	}
	st.Captures = append(st.Captures, c)
}

func replaceChannel(st *leylinev1.GetStateResponse, c *leylinev1.Channel) {
	for i, x := range st.Channels {
		if x.ChannelId == c.ChannelId {
			st.Channels[i] = c
			return
		}
	}
	st.Channels = append(st.Channels, c)
}

// ensureCapture reuses the device's capture when it covers freq±bw/2, retunes
// it (WriteParams center_hz) when it exists but does not, and creates one
// otherwise. It returns after the capture state is confirmed.
func (s *session) ensureCapture(ctx context.Context, o *tuneOptions) error {
	if cap := leyline.FindCapture(s.state, s.device.DeviceId); cap != nil {
		s.capture = cap
		if covers(cap, o.freq, o.bw) {
			return nil
		}
		if !s.app.JSON {
			fmt.Fprintf(s.app.Stdout, "retuning capture %s from %s to %s\n", cap.CaptureId, leyline.FormatFrequency(cap.CenterHz), leyline.FormatFrequency(o.freq))
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_CenterHz{CenterHz: o.freq}}
		sum, err := s.client.WriteParams(ctx, w)
		if err != nil {
			return err
		}
		rejected := sum.GetWritesApplied() < sum.GetWritesReceived()
		ev, err := s.awaitEvent(ctx, func(ev *leylinev1.Event) bool {
			switch b := ev.Body.(type) {
			case *leylinev1.Event_Capture:
				return !rejected && b.Capture.CaptureId == cap.CaptureId && b.Capture.CenterHz == o.freq
			case *leylinev1.Event_WriteRejected:
				return s.mine(ev) && b.WriteRejected.Tag == 1
			}
			return false
		})
		if err != nil {
			if rejected {
				return fmt.Errorf("retune to %s rejected (no reason observed)", leyline.FormatFrequency(o.freq))
			}
			return err
		}
		if r, ok := ev.Body.(*leylinev1.Event_WriteRejected); ok {
			return fmt.Errorf("retune rejected: %s: %s", r.WriteRejected.Error.GetCode(), r.WriteRejected.Error.GetMessage())
		}
		return nil
	}
	center := o.freq
	if o.captureCenter != 0 {
		center = o.captureCenter
	}
	cap, err := s.client.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: s.device.DeviceId, CenterHz: center, SampleRate: o.rate})
	if err != nil {
		if leyline.Code(err) != leyline.CodeDeviceBusy {
			return err
		}
		// Another client is creating (or has just created) this device's capture; wait for it
		// to appear in the state and then reuse or retune it like any existing capture.
		deadline := time.Now().Add(5 * time.Second)
		for {
			st, serr := s.client.State(ctx)
			if serr != nil {
				return serr
			}
			s.state = st
			if leyline.FindCapture(st, s.device.DeviceId) != nil {
				return s.ensureCapture(ctx, o)
			}
			if time.Now().After(deadline) {
				return err
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(100 * time.Millisecond):
			}
		}
	}
	s.capture = cap
	s.createdCapture = true
	replaceCapture(s.state, cap)
	return nil
}

// createChannel creates the demod channel at freq relative to the capture and
// applies the initial squelch when one was requested.
func (s *session) createChannel(ctx context.Context, o *tuneOptions) error {
	offset := int64(o.freq) - int64(s.capture.CenterHz)
	ch, err := s.client.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{
		CaptureId: s.capture.CaptureId, OffsetHz: offset, BandwidthHz: o.bw, Mode: o.mode, Persistent: o.persistent,
	})
	if err != nil {
		return err
	}
	s.channel = ch
	replaceChannel(s.state, ch)
	if !math.IsNaN(o.squelch) {
		w := &leylinev1.ParamWrite{Tag: 2, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: o.squelch}}
		if _, err := s.client.WriteParams(ctx, w); err != nil {
			return err
		}
	}
	return nil
}

// attachAudio attaches a system_audio sink; PLATFORM_UNSUPPORTED is reported
// as a warning rather than an error so headless hosts can still tune.
func (s *session) attachAudio(ctx context.Context, o *tuneOptions) error {
	sink, err := s.client.Control.AttachSink(ctx, &leylinev1.AttachSinkRequest{
		ChannelId: s.channel.ChannelId,
		Sink:      &leylinev1.Sink{Kind: &leylinev1.Sink_SystemAudio{SystemAudio: &leylinev1.SystemAudioSink{Volume: o.volume}}},
	})
	if err != nil {
		if leyline.Code(err) == leyline.CodePlatformUnsupported {
			fmt.Fprintln(s.app.Stderr, "warning: system audio unavailable on this host; continuing without audio")
			return nil
		}
		return err
	}
	s.sink = sink
	return nil
}

// teardown destroys the channel and, when this run created the capture and
// nothing else uses it, the capture. Uses a fresh context: the run's may be
// cancelled already.
func (s *session) teardown() {
	ctx, cancel := context.WithTimeout(context.Background(), confirmTimeout)
	defer cancel()
	if s.channel != nil {
		_, _ = s.client.Control.DestroyChannel(ctx, &leylinev1.DestroyChannelRequest{ChannelId: s.channel.ChannelId})
	}
	if s.capture != nil && s.createdCapture {
		inUse := false
		for _, ch := range s.state.Channels {
			if ch.CaptureId == s.capture.CaptureId && (s.channel == nil || ch.ChannelId != s.channel.ChannelId) {
				inUse = true
			}
		}
		if !inUse {
			_, _ = s.client.Control.DestroyCapture(ctx, &leylinev1.DestroyCaptureRequest{CaptureId: s.capture.CaptureId})
		}
	}
}

// meterLine renders the in-place status line.
func meterLine(freq uint64, mode leylinev1.DemodMode, m *leylinev1.Meter) string {
	gate := "[CLOSED]"
	if m.SquelchOpen {
		gate = "[OPEN]"
	}
	snr := "--"
	if !math.IsNaN(m.SnrDb) {
		snr = fmt.Sprintf("%.0f dB", m.SnrDb)
	}
	return fmt.Sprintf("%s %s  %.1f dBFS  SNR %s  %s", leyline.FormatFrequency(freq), strings.ToUpper(leyline.ModeName(mode)), m.PowerDbfs, snr, gate)
}
