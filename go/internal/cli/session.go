// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"fmt"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/bandplan"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
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
	band       *bandplan.Band
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
	// gain, when non-empty, is applied to the capture once it exists: "auto",
	// dB, or stage=dB pairs (units.ParseGains).
	gain string
}

// session is one tune lifecycle: the capture (created or reused), the channel
// and the optional system-audio sink, plus the open event stream that keeps
// the non-persistent channel alive.
type session struct {
	// subAudible remembers the last tone reported, so a heartbeat that repeats
	// it does not repeat the line.
	subAudible subAudibleTracker
	// sourceLine, when set, names what is being played instead of the radio it
	// arrives through: play's second banner line answers "what am I listening
	// to", where tune's answers "on what radio". A file device has no gain and
	// no tuning range, so the hardware line would tell the user nothing.
	sourceLine string
	// channelGone records that another client destroyed the channel this
	// session was listening to, so the closing line does not also claim to
	// have removed it.
	channelGone    bool
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
	// seq is the newest event seq folded into the mirror (the snapshot's at
	// open); older events arriving late are already reflected and are skipped.
	seq uint64
	// squelchNote is the banner's squelch sentence once the channel exists.
	squelchNote string
	// failureNote is the problem the capture's first level and the squelch
	// measurement row show (failureWords), or "": the radio clipping, or
	// nothing above the floor. A persistent tune and the MCP adapter's tune
	// tool print it beside squelchNote, because it was measured with it; they
	// have no live phase to hold a reading in.
	failureNote string
	// bandNote is what the same row shows (bandWords), or "": the one line a
	// live tune's banner carries about the band, said once at tune and never
	// again in the session (plans/app.md, M2-10). Clipping is not in it: a
	// live tune leaves that to clip, which says it once it has lasted.
	bandNote string
	// clip is the hold on the capture's CaptureLevel readings in a live tune.
	clip clipHold
	// proseToStderr forces say() to stderr even without --json, for verbs
	// whose stdout carries a stream a person never reads (listen).
	proseToStderr bool
	// freedRadio records that teardown destroyed the capture this session
	// created, so the closing line can say the radio is free.
	freedRadio bool
	// takeOverHint replaces the remedy a retune refusal ends with. Empty
	// means the verb's own ("Add --retune ..."); the MCP adapter names the
	// argument an agent has instead of a flag.
	takeOverHint string
}

// noDeviceChecklist is what to try when the daemon lists no radios.
const noDeviceChecklist = `no radio found. Check, in order:
  1. the SDR is plugged in (try another USB port or cable)
  2. rtl_test sees it (or the vendor's own test tool)
  3. nothing else has it open (SDR apps, another daemon)
  4. ley daemon logs, for driver errors`

// pickDevice chooses --device (a full id, id prefix, row number or frequency),
// else the first non-file device that is connected and not held by another
// program (rtl_tcp, SDR++: the daemon flags those held_externally), else the
// first non-file connected device, else the first.
func pickDevice(state *leylinev1.GetStateResponse, sel string) (*leylinev1.DeviceDescriptor, error) {
	if len(state.Devices) == 0 {
		return nil, errors.New(noDeviceChecklist)
	}
	if sel != "" {
		return leyline.ResolveDevice(state, sel)
	}
	var fallback *leylinev1.DeviceDescriptor
	for _, d := range state.Devices {
		if d.Driver == "file" || d.State == leylinev1.DeviceState_DISCONNECTED {
			continue
		}
		if !heldExternally(d) {
			return d, nil
		}
		if fallback == nil {
			fallback = d
		}
	}
	if fallback != nil {
		return fallback, nil
	}
	return state.Devices[0], nil
}

// heldExternally reports the daemon's held_externally feature: another
// program has the dongle open, so no capture can be created on it.
func heldExternally(d *leylinev1.DeviceDescriptor) bool {
	f, ok := d.GetFeatures()["held_externally"]
	return ok && f.GetFlag()
}

// friendlyError carries a plain-words message while keeping the daemon error
// (and so its machine code) reachable through errors.As/Unwrap.
type friendlyError struct {
	msg   string
	cause error
}

func (e *friendlyError) Error() string { return e.msg }
func (e *friendlyError) Unwrap() error { return e.cause }

// daemonMessage is the daemon's own prose for an error, without the code prefix.
func daemonMessage(err error) string {
	var le *leyline.Error
	if errors.As(err, &le) && le.Message != "" {
		return le.Message
	}
	return leyline.FromStatus(err).Message
}

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
	case leyline.CodeDeviceSweeping:
		// The daemon already said what has the radio and when it will be free. A generic
		// "another client holds it" would send the reader looking for the wrong thing.
		return &friendlyError{msg: daemonMessage(err), cause: err}
	case leyline.CodeDeviceBusy:
		if s.device != nil && heldExternally(s.device) {
			return &friendlyError{msg: fmt.Sprintf("%s is held by another program (rtl_tcp, SDR++, GQRX?): quit it, or pick another radio with --device; check with: ley devices", s.device.Model), cause: err}
		}
		return &friendlyError{msg: "the radio is busy: another client holds it; ley state shows who, and ley tune reuses a capture when the frequency fits", cause: err}
	case leyline.CodeFreqOutOfRange:
		var ranges []*leylinev1.FrequencyRange
		model := "this device"
		if s.device != nil {
			ranges, model = s.device.TuningRanges, s.device.Model
		}
		msg := fmt.Sprintf("%s is outside what %s can tune (%s)", units.FormatFrequency(hz), model, units.FormatRanges(ranges))
		if hint := frequencyHint(input, hz, ranges); hint != "" {
			msg += "; " + hint
		}
		return &friendlyError{msg: msg, cause: err}
	case leyline.CodePlatformUnsupported:
		return &friendlyError{msg: "system audio is not available on this host; use --no-audio, or stream the audio with ley --json (see ley help scripting)", cause: err}
	}
	return err
}

// open dials, snapshots state and opens the daemon-scoped event stream,
// resuming from the snapshot's seq (reconnect = GetState + resume from seq):
// the daemon replays what happened between the snapshot and the stream's
// registration, so no confirmation is missed, and both happen before any
// mutation.
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
	events, errs, err := c.Events(ectx, leyline.ScopeSince(nil, st.EventSeq))
	if err != nil {
		cancel()
		c.Close()
		return nil, err
	}
	return &session{app: app, client: c, state: st, seq: st.EventSeq, events: events, eventErrs: errs, cancelEvents: cancel}, nil
}

// drainEvents folds the event stream into the mirror in the background for
// verbs that do not read events themselves (spectrum, fft), so the stream
// keeps flowing and the mirror stays current while they run. The returned
// func stops the drain and waits for it; the mirror (state, capture,
// channel) must not be touched until it has returned.
func (s *session) drainEvents() (stop func()) {
	quit := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-quit:
				return
			case ev, ok := <-s.events:
				if !ok {
					return
				}
				s.apply(ev)
			}
		}
	}()
	return func() {
		close(quit)
		<-done
	}
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
			if st.EventSeq > s.seq {
				s.seq = st.EventSeq
			}
			for _, ev := range stateEvents(st) {
				s.fold(ev)
				if pred(ev) {
					return ev, nil
				}
			}
		case ev, ok := <-s.events:
			if !ok {
				return nil, fmt.Errorf("event stream ended: %w", <-s.eventErrs)
			}
			if s.apply(ev) && pred(ev) {
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

// apply folds a live event into the mirror unless it is older than what the
// mirror already reflects (a replayed or late event with seq at or below the
// snapshot's, or a poll's), and reports whether it was folded.
func (s *session) apply(ev *leylinev1.Event) bool {
	if _, rejection := ev.Body.(*leylinev1.Event_WriteRejected); rejection {
		// Not state: a poll cannot have reflected it, so it is never stale.
		return true
	}
	if ev.Seq != 0 && ev.Seq <= s.seq {
		return false
	}
	if ev.Seq > s.seq {
		s.seq = ev.Seq
	}
	s.fold(ev)
	return true
}

// fold merges a full-state event into the local mirror (invariant 6: events
// carry whole objects, so the mirror is a straight replace).
func (s *session) fold(ev *leylinev1.Event) {
	switch b := ev.Body.(type) {
	case *leylinev1.Event_Capture:
		// State unset is the destroy tombstone; CAPTURE_DETACHED is a capture
		// whose radio is unplugged and which rebinds when it returns, so only
		// the former leaves the mirror.
		if b.Capture.State == leylinev1.CaptureState_CAPTURE_STATE_UNSPECIFIED {
			s.state.Captures = withoutCapture(s.state.Captures, b.Capture.CaptureId)
		} else {
			replaceCapture(s.state, b.Capture)
		}
		if s.capture != nil && s.capture.CaptureId == b.Capture.CaptureId {
			s.capture = b.Capture
		}
	case *leylinev1.Event_Channel:
		// A destroyed channel is emitted one last time with its state unset,
		// and folding that as a replace leaves a dead channel in the mirror
		// for the rest of the run -- which is how a verb ends up counting a
		// channel that is gone.
		if b.Channel.State == leylinev1.ChannelState_CHANNEL_STATE_UNSPECIFIED {
			s.state.Channels = withoutChannel(s.state.Channels, b.Channel.ChannelId)
		} else {
			replaceChannel(s.state, b.Channel)
		}
		if s.channel != nil && s.channel.ChannelId == b.Channel.ChannelId {
			s.channel = b.Channel
		}
	case *leylinev1.Event_Sink:
		if b.Sink.State == leylinev1.SinkState_SINK_STATE_UNSPECIFIED {
			s.state.Sinks = withoutSink(s.state.Sinks, b.Sink.SinkId)
		} else {
			replaceSink(s.state, b.Sink)
		}
		if s.sink != nil && s.sink.SinkId == b.Sink.SinkId {
			s.sink = b.Sink
		}
	case *leylinev1.Event_Anchor:
		// A capture publishes its anchor with its first block, and again on a
		// rate change or a rebind, so the one its Capture arrived with is the
		// stale (or undated) one: the newest is what dates a sample index.
		for _, c := range s.state.GetCaptures() {
			if c.GetCaptureId() == b.Anchor.GetCaptureId() {
				c.Anchor = b.Anchor
			}
		}
		if s.capture != nil && s.capture.CaptureId == b.Anchor.GetCaptureId() {
			s.capture.Anchor = b.Anchor
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

func replaceSink(st *leylinev1.GetStateResponse, k *leylinev1.Sink) {
	for i, x := range st.Sinks {
		if x.SinkId == k.SinkId {
			st.Sinks[i] = k
			return
		}
	}
	st.Sinks = append(st.Sinks, k)
}

// withoutCapture, withoutChannel and withoutSink drop a destroyed object from
// the mirror.
func withoutCapture(in []*leylinev1.Capture, id string) []*leylinev1.Capture {
	out := in[:0]
	for _, c := range in {
		if c.CaptureId != id {
			out = append(out, c)
		}
	}
	return out
}

func withoutChannel(in []*leylinev1.Channel, id string) []*leylinev1.Channel {
	out := in[:0]
	for _, c := range in {
		if c.ChannelId != id {
			out = append(out, c)
		}
	}
	return out
}

func withoutSink(in []*leylinev1.Sink, id string) []*leylinev1.Sink {
	out := in[:0]
	for _, k := range in {
		if k.SinkId != id {
			out = append(out, k)
		}
	}
	return out
}

// say prints prose to stdout in human mode and to stderr under --json (or
// when the verb reserves stdout for a stream), so stdout stays parseable.
func (s *session) say(format string, args ...any) {
	if s.app.JSON || s.proseToStderr {
		fmt.Fprintf(s.app.Stderr, format, args...)
		return
	}
	fmt.Fprintf(s.app.Stdout, format, args...)
}
