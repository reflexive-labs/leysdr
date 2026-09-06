package cli

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// confirmTimeout bounds how long verbs wait for the daemon's confirming event.
const confirmTimeout = 2 * time.Second

// tuneOptions are the settings shared by `tune` and `play`, after parsing.
type tuneOptions struct {
	freq uint64
	// input is the frequency as the user typed it (for hints on errors).
	input string
	// captureCenter, when non-zero, is the centre used for a new capture
	// (play: the file's centre, since a playback device tunes nowhere else).
	captureCenter uint64
	mode          leylinev1.DemodMode
	// modeReason is the one-line rationale when the mode was inferred ("" when explicit).
	modeReason string
	band       *leyline.Band
	bw         uint32
	device     string
	rate       uint64
	squelch    float64 // NaN = off (unless squelchAuto)
	// squelchAuto asks for a threshold measured from the capture's spectrum.
	squelchAuto bool
	noAudio     bool
	persistent  bool
	volume      float64
	// retune allows moving a shared capture even when other channels ride on it.
	retune bool
	// gain, when non-empty, is applied to the capture once it exists ("auto" or dB).
	gain string
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
	// squelchNote is the banner's squelch sentence once the channel exists.
	squelchNote string
}

// noDeviceChecklist is what to try when the daemon lists no radios.
const noDeviceChecklist = `no radio found. Check, in order:
  1. the SDR is plugged in (try another USB port or cable)
  2. rtl_test sees it (or the vendor's own test tool)
  3. nothing else has it open (SDR apps, another daemon)
  4. ley daemon logs, for driver errors`

// pickDevice chooses --device (a full id, id prefix, row number or frequency),
// else the first non-file device, else the first.
func pickDevice(state *leylinev1.GetStateResponse, sel string) (*leylinev1.DeviceDescriptor, error) {
	if len(state.Devices) == 0 {
		return nil, errors.New(noDeviceChecklist)
	}
	if sel != "" {
		return leyline.ResolveDevice(state, sel)
	}
	for _, d := range state.Devices {
		if d.Driver != "file" && d.State != leylinev1.DeviceState_DISCONNECTED {
			return d, nil
		}
	}
	return state.Devices[0], nil
}

// friendlyError carries a plain-words message while keeping the daemon error
// (and so its machine code) reachable through errors.As/Unwrap.
type friendlyError struct {
	msg   string
	cause error
}

func (e *friendlyError) Error() string { return e.msg }
func (e *friendlyError) Unwrap() error { return e.cause }

// friendly rewrites the daemon errors a newcomer is likely to hit into one
// sentence that says what to do next. input/hz describe the frequency the
// user asked for (hz 0 when none). Other errors pass through unchanged.
func (s *session) friendly(err error, input string, hz uint64) error {
	if err == nil {
		return nil
	}
	var fe *friendlyError
	if errors.As(err, &fe) {
		return err
	}
	switch leyline.Code(err) {
	case leyline.CodeDeviceBusy:
		return &friendlyError{msg: "the radio is busy: another client holds it; ley state shows who, and ley tune reuses a capture when the frequency fits", cause: err}
	case leyline.CodeFreqOutOfRange:
		var ranges []*leylinev1.FrequencyRange
		model := "this device"
		if s.device != nil {
			ranges, model = s.device.TuningRanges, s.device.Model
		}
		msg := fmt.Sprintf("%s is outside what %s can tune (%s)", leyline.FormatFrequency(hz), model, leyline.FormatRanges(ranges))
		if hint := leyline.FrequencyHint(input, hz, ranges); hint != "" {
			msg += "; " + hint
		}
		return &friendlyError{msg: msg, cause: err}
	case leyline.CodePlatformUnsupported:
		return &friendlyError{msg: "system audio is not available on this host; use --no-audio, or stream the audio with ley --json (see ley help scripting)", cause: err}
	}
	return err
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
		if err := s.checkRange(o.input, o.freq); err != nil {
			return err
		}
		if n := s.activeChannels(cap.CaptureId); n > 0 && !o.retune {
			return fmt.Errorf("the radio is on %s with %s listening; retuning to %s would silence %s. Add --retune to move it anyway, or free %s with: ley stop --all",
				leyline.FormatFrequency(cap.CenterHz), plural(n, "channel"), leyline.FormatFrequency(o.freq), themOrIt(n), themOrIt(n))
		}
		s.say("retuning capture %s from %s to %s\n", cap.CaptureId, leyline.FormatFrequency(cap.CenterHz), leyline.FormatFrequency(o.freq))
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_CenterHz{CenterHz: o.freq}}
		sum, err := s.client.WriteParams(ctx, w)
		if err != nil {
			return s.friendly(err, o.input, o.freq)
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
			return s.friendly(rejectedError(r.WriteRejected), o.input, o.freq)
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
			return s.friendly(err, o.input, o.freq)
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
				return s.friendly(err, o.input, o.freq)
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

// checkRange mirrors the daemon's tuning-range check for the session's device
// so an impossible frequency fails with the friendly message before a write
// is attempted (the daemon remains the authority; it rejects anything the
// mirror lets through). Devices with unknown ranges are not checked.
func (s *session) checkRange(input string, hz uint64) error {
	if s.device == nil || len(s.device.TuningRanges) == 0 || leyline.InRanges(hz, s.device.TuningRanges) {
		return nil
	}
	return s.friendly(&leyline.Error{
		Code: leyline.CodeFreqOutOfRange, Target: s.device.DeviceId,
		Message: fmt.Sprintf("%d Hz is outside the device tuning range", hz),
	}, input, hz)
}

// activeChannels counts the ACTIVE channels riding on a capture in the mirror.
func (s *session) activeChannels(captureID string) int {
	n := 0
	for _, ch := range s.state.GetChannels() {
		if ch.CaptureId == captureID && ch.State == leylinev1.ChannelState_CHANNEL_ACTIVE {
			n++
		}
	}
	return n
}

// plural renders "1 channel" / "2 channels".
func plural(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", n, noun)
}

func themOrIt(n int) string {
	if n == 1 {
		return "it"
	}
	return "them"
}

// applyGain writes --gain to the capture's first gain element and waits for
// the confirming capture event so the banner shows the value the daemon
// settled on (the daemon snaps to the element's table, as set.go mirrors).
func (s *session) applyGain(ctx context.Context, o *tuneOptions) error {
	if o.gain == "" {
		return nil
	}
	db, auto, err := leyline.ParseGain(o.gain)
	if err != nil {
		return fmt.Errorf("--gain: %w", err)
	}
	if len(s.device.GainElements) == 0 {
		return fmt.Errorf("--gain: %s reports no gain stages; leave --gain off", deviceName(s.device))
	}
	el := s.device.GainElements[0]
	tol := 1.0
	if !auto {
		if err := leyline.CheckGain(db, el); err != nil {
			return fmt.Errorf("--gain: %w", err)
		}
		db, tol = snapGain(el, db)
	}
	g := &leylinev1.GainWrite{Element: el.Name}
	if auto {
		g.Value = &leylinev1.GainWrite_Auto{Auto: true}
	} else {
		g.Value = &leylinev1.GainWrite_Db{Db: db}
	}
	w := &leylinev1.ParamWrite{Tag: 3, TargetId: s.capture.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: g}}
	if _, err := s.client.WriteParams(ctx, w); err != nil {
		return fmt.Errorf("--gain: %w", err)
	}
	ev, err := s.awaitEvent(ctx, func(ev *leylinev1.Event) bool {
		switch b := ev.Body.(type) {
		case *leylinev1.Event_Capture:
			if b.Capture.CaptureId != s.capture.CaptureId {
				return false
			}
			for _, gs := range b.Capture.Gains {
				if gs.Element == el.Name && (auto && gs.Auto || !auto && !gs.Auto && math.Abs(gs.Db-db) <= tol) {
					return true
				}
			}
		case *leylinev1.Event_WriteRejected:
			return s.mine(ev) && b.WriteRejected.Tag == 3
		}
		return false
	})
	if err != nil {
		return fmt.Errorf("--gain: %w", err)
	}
	if r, ok := ev.Body.(*leylinev1.Event_WriteRejected); ok {
		return fmt.Errorf("--gain: %w", rejectedError(r.WriteRejected))
	}
	return nil
}

// rejectedError turns a WriteRejected event into a *leyline.Error so callers
// can key on its code like any RPC failure.
func rejectedError(r *leylinev1.WriteRejected) error {
	return &leyline.Error{Code: r.GetError().GetCode(), Message: r.GetError().GetMessage(), Target: r.GetError().GetTarget()}
}

// say prints prose to stdout in human mode and to stderr under --json, so
// stdout stays NDJSON-only for scripts.
func (s *session) say(format string, args ...any) {
	if s.app.JSON {
		fmt.Fprintf(s.app.Stderr, format, args...)
		return
	}
	fmt.Fprintf(s.app.Stdout, format, args...)
}

// createChannel creates the demod channel at freq relative to the capture and
// applies the initial squelch: an explicit level, or the measured one when
// the run asked for auto (a failed measurement leaves squelch off and says so).
func (s *session) createChannel(ctx context.Context, o *tuneOptions) error {
	offset := int64(o.freq) - int64(s.capture.CenterHz)
	ch, err := s.client.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{
		CaptureId: s.capture.CaptureId, OffsetHz: offset, BandwidthHz: o.bw, Mode: o.mode, Persistent: o.persistent,
	})
	if err != nil {
		return s.friendly(err, o.input, o.freq)
	}
	s.channel = ch
	replaceChannel(s.state, ch)
	if o.squelchAuto {
		db, floor, err := s.measureSquelch(ctx, s.capture, ch.BandwidthHz)
		if err != nil {
			s.squelchNote = fmt.Sprintf("Squelch auto: %v; squelch stays off (set one with: ley set squelch -40).", err)
			return nil
		}
		o.squelch = db
		s.squelchNote = fmt.Sprintf("Squelch auto → %.0f dBFS (10 dB above the band's noise floor, %.0f dBFS).", db, floor)
	}
	if !math.IsNaN(o.squelch) {
		w := &leylinev1.ParamWrite{Tag: 2, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: o.squelch}}
		if _, err := s.client.WriteParams(ctx, w); err != nil {
			return err
		}
	}
	return nil
}

// squelchProbeTimeout bounds the wait for the spectrum row auto squelch needs.
const squelchProbeTimeout = 2 * time.Second

// measureSquelch derives a squelch threshold from one FFT row of the capture:
// the row's median bin is the noise floor per bin (a median is presentation,
// the spectrum itself is the daemon's), scaled to the channel bandwidth with
// 10·log10(bw / bin width); the threshold sits 10 dB above that. It returns
// an error when no row arrives within squelchProbeTimeout so callers can
// leave squelch off and say so.
func (s *session) measureSquelch(ctx context.Context, cap *leylinev1.Capture, bw uint32) (threshold, floor float64, err error) {
	sctx, cancel := context.WithTimeout(ctx, squelchProbeTimeout)
	defer cancel()
	sub, err := s.client.SubscribeFFT(sctx, cap.CaptureId, 2048, 10, leylinev1.FftBinFormat_DB_F32)
	if err != nil {
		return 0, 0, fmt.Errorf("no spectrum available (%v)", err)
	}
	defer sub.Close()
	var fr *leylinev1.Frame
	select {
	case f, ok := <-sub.Frames:
		if !ok {
			return 0, 0, fmt.Errorf("spectrum stream ended before a row arrived")
		}
		fr = f
	case <-sctx.Done():
		return 0, 0, fmt.Errorf("no spectrum row arrived within %s", squelchProbeTimeout)
	}
	u8 := sub.Descriptor.GetFft().GetBinFormat() == leylinev1.FftBinFormat_DB_U8
	vals := decodeBins(fr.Payload, u8)
	if len(vals) == 0 {
		return 0, 0, fmt.Errorf("spectrum row in an unexpected format")
	}
	median := medianDb(vals)
	binWidth := float64(cap.SampleRate) / float64(len(vals))
	floor = median + 10*math.Log10(float64(bw)/binWidth)
	return math.Round(floor + 10), floor, nil
}

// attachAudio attaches a system_audio sink; PLATFORM_UNSUPPORTED is reported
// as a warning rather than an error so headless hosts can still tune.
func (s *session) attachAudio(ctx context.Context, o *tuneOptions) error {
	sink, err := s.client.Control.AttachSink(ctx, &leylinev1.AttachSinkRequest{
		ChannelId: s.channel.ChannelId,
		Sink:      &leylinev1.Sink{Kind: &leylinev1.Sink_SystemAudio{SystemAudio: &leylinev1.SystemAudioSink{Volume: proto.Float64(o.volume)}}},
	})
	if err != nil {
		if leyline.Code(err) == leyline.CodePlatformUnsupported {
			fmt.Fprintln(s.app.Stderr, "warning: system audio is not available on this host; continuing without audio (ley --json tune streams meters; see ley help scripting)")
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

// meterLine renders the in-place status line in plain words: the signal
// level and whether audio is passing. OPEN/CLOSED live in --json only.
func meterLine(freq uint64, mode leylinev1.DemodMode, m *leylinev1.Meter) string {
	gate := "muted, waiting for a signal"
	if m.SquelchOpen {
		gate = "audio"
	}
	return fmt.Sprintf("%s %s  signal %.0f dBFS  %s", leyline.FormatFrequency(freq), strings.ToUpper(leyline.ModeName(mode)), m.PowerDbfs, gate)
}

// gainString renders a capture's first gain element as "gain auto" / "gain 29.7 dB".
func gainString(cap *leylinev1.Capture) string {
	if cap == nil || len(cap.Gains) == 0 {
		return "no gain control"
	}
	g := cap.Gains[0]
	if g.Auto {
		return "gain auto"
	}
	return fmt.Sprintf("gain %.1f dB", g.Db)
}
