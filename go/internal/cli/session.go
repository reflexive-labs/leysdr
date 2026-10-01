// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/words"
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

// covers reports whether freq±bw/2 lies inside the capture's span.
func covers(cap *leylinev1.Capture, freq uint64, bw uint32) bool {
	half := float64(cap.SampleRate) / 2
	lo := float64(freq) - float64(bw)/2
	hi := float64(freq) + float64(bw)/2
	c := float64(cap.CenterHz)
	return lo >= c-half && hi <= c+half
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
		// A recording is named before the channels are counted: "1 channel listening" is true of
		// a record job's own channel but tells the reader nothing they can act on.
		if err := s.refuseRetuneOverRecording(cap.CaptureId, o.retune); err != nil {
			return err
		}
		if n := s.activeChannels(cap.CaptureId); n > 0 && !o.retune {
			hint := s.takeOverHint
			if hint == "" {
				hint = fmt.Sprintf("Add --retune to move it anyway, or free %s with: ley stop --all", words.Pick(n, "it", "them"))
			}
			return fmt.Errorf("the radio is on %s with %s listening; retuning to %s would silence %s. %s",
				units.FormatFrequency(cap.CenterHz), words.Count(n, "channel"), units.FormatFrequency(o.freq), words.Pick(n, "it", "them"), hint)
		}
		s.say("retuning capture %s from %s to %s\n", cap.CaptureId, units.FormatFrequency(cap.CenterHz), units.FormatFrequency(o.freq))
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
				return fmt.Errorf("retune to %s rejected (no reason observed)", units.FormatFrequency(o.freq))
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
	if s.device == nil || len(s.device.TuningRanges) == 0 || units.InRanges(hz, s.device.TuningRanges) {
		return nil
	}
	return s.friendly(&leyline.Error{
		Code: leyline.CodeFreqOutOfRange, Target: s.device.DeviceId,
		Message: fmt.Sprintf("%d Hz is outside the device tuning range", hz),
	}, input, hz)
}

// recordingsOn lists the running record jobs whose recording would be damaged
// by moving this capture. A record job either owns a channel on the capture
// (the audio form) or reads the capture itself (--iq); both are found by the
// job's own frequency against what the mirror holds.
//
// The daemon never refuses a user's write on a job's behalf -- it degrades the
// recording and records the gap. The client that takes the user's action does
// the check, which for `ley` is here (docs/design/recording.md, "Don't-disturb").
func (s *session) recordingsOn(captureID string) []*leylinev1.Job {
	cap := captureByID(s.state, captureID)
	if cap == nil {
		return nil
	}
	var out []*leylinev1.Job
	for _, j := range s.state.GetJobs() {
		cfg := j.GetRecord()
		if cfg == nil || !isLiveJob(j) {
			continue
		}
		if cfg.GetChannelId() != "" {
			if ch := channelByID(s.state, cfg.GetChannelId()); ch != nil && ch.GetCaptureId() == captureID {
				out = append(out, j)
			}
			continue
		}
		// A frequency-form job: its own channel on this capture, or, for --iq,
		// this capture's span around where it was asked to listen.
		hz := cfg.GetFrequencyHz()
		onChannel := false
		for _, ch := range s.state.GetChannels() {
			if ch.GetCaptureId() == captureID && ch.GetOwner().GetKind() == "job" && ch.GetRequiredHz() == hz {
				onChannel = true
			}
		}
		if onChannel || (cfg.GetMode() == leylinev1.DemodMode_RAW_IQ && covers(cap, hz, 0)) {
			out = append(out, j)
		}
	}
	return out
}

// refuseRetuneOverRecording is the sentence `ley tune` and `ley set freq` print
// rather than moving a radio out from under a recording. nil when nothing is
// recording, or when --retune said to go ahead.
func (s *session) refuseRetuneOverRecording(captureID string, retune bool) error {
	recs := s.recordingsOn(captureID)
	if len(recs) == 0 || retune {
		return nil
	}
	st := s.app.ErrStyle
	ids := make([]string, 0, len(recs))
	for _, j := range recs {
		ids = append(ids, j.GetJobId())
	}
	hint := s.takeOverHint
	if hint == "" {
		hint = "Add --retune to move it anyway (the recording logs the gap), or stop it with: " +
			st.Cmd("ley jobs cancel "+ids[0])
	}
	return fmt.Errorf("%s recording on this radio (%s); retuning would leave a gap in %s. %s",
		words.Count(len(recs), "job is"), strings.Join(ids, ", "), words.Pick(len(recs), "it", "them"), hint)
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

// applyGain writes --gain to the capture, one stage at a time in the order
// given (the first stage for a bare level), and waits for each confirming
// capture event so the banner shows the values the daemon settled on (the
// daemon snaps to the element's table, as set.go mirrors).
func (s *session) applyGain(ctx context.Context, o *tuneOptions) error {
	if o.gain == "" {
		return nil
	}
	settings, err := units.ParseGains(o.gain)
	if err != nil {
		return fmt.Errorf("--gain %w", err)
	}
	if len(s.device.GainElements) == 0 {
		return fmt.Errorf("%s reports no gain stages, so --gain has nothing to set; leave it off", deviceName(s.device))
	}
	for _, g := range settings {
		if err := s.writeGain(ctx, g); err != nil {
			return err
		}
	}
	return nil
}

// writeGain writes one stage's gain and waits for the daemon to confirm or
// refuse it. A named stage is matched against the device ignoring case; one
// the device does not list is sent as typed, so the refusal is the daemon's,
// with the stages the radio has.
func (s *session) writeGain(ctx context.Context, g units.GainSetting) error {
	el := s.device.GainElements[0]
	name := el.GetName()
	if g.Element != "" {
		el, name = nil, g.Element
		for _, e := range s.device.GainElements {
			if strings.EqualFold(e.GetName(), g.Element) {
				el, name = e, e.GetName()
			}
		}
	}
	db, auto, tol := g.DB, g.Auto, 1.0
	if el != nil && !auto {
		if err := units.CheckGain(db, el); err != nil {
			return fmt.Errorf("--gain %w", err)
		}
		db, tol = units.SnapGain(el, db), units.GainTolerance(el)
	}
	gw := &leylinev1.GainWrite{Element: name}
	if auto {
		gw.Value = &leylinev1.GainWrite_Auto{Auto: true}
	} else {
		gw.Value = &leylinev1.GainWrite_Db{Db: db}
	}
	w := &leylinev1.ParamWrite{Tag: 3, TargetId: s.capture.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: gw}}
	if _, err := s.client.WriteParams(ctx, w); err != nil {
		return fmt.Errorf("--gain was not applied: %w", err)
	}
	ev, err := s.awaitEvent(ctx, func(ev *leylinev1.Event) bool {
		switch b := ev.Body.(type) {
		case *leylinev1.Event_Capture:
			if b.Capture.CaptureId != s.capture.CaptureId {
				return false
			}
			for _, gs := range b.Capture.Gains {
				if gs.Element == name && (auto && gs.Auto || !auto && !gs.Auto && math.Abs(gs.Db-db) <= tol) {
					return true
				}
			}
		case *leylinev1.Event_WriteRejected:
			return s.mine(ev) && b.WriteRejected.Tag == 3
		}
		return false
	})
	if err != nil {
		return fmt.Errorf("--gain was not applied: %w", err)
	}
	if r, ok := ev.Body.(*leylinev1.Event_WriteRejected); ok {
		return fmt.Errorf("--gain was not applied: %w", rejectedError(r.WriteRejected))
	}
	return nil
}

// rejectedError turns a WriteRejected event into a *leyline.Error so callers
// can key on its code like any RPC failure.
func rejectedError(r *leylinev1.WriteRejected) error {
	return &leyline.Error{Code: r.GetError().GetCode(), Message: r.GetError().GetMessage(), Target: r.GetError().GetTarget()}
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
		// The initial squelch is part of the tune: wait for the daemon to
		// confirm it, and treat a rejection as a tune failure (the caller
		// tears down what was created) rather than listening with the wrong
		// squelch and calling it applied.
		w := &leylinev1.ParamWrite{Tag: 2, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: o.squelch}}
		sum, err := s.client.WriteParams(ctx, w)
		if err != nil {
			return fmt.Errorf("--squelch was not applied: %w", err)
		}
		rejected := sum.GetWritesApplied() < sum.GetWritesReceived()
		ev, err := s.awaitEvent(ctx, func(ev *leylinev1.Event) bool {
			switch b := ev.Body.(type) {
			case *leylinev1.Event_Channel:
				return !rejected && b.Channel.ChannelId == ch.ChannelId && b.Channel.SquelchDb == o.squelch
			case *leylinev1.Event_WriteRejected:
				return s.mine(ev) && b.WriteRejected.Tag == 2
			}
			return false
		})
		if err != nil {
			if rejected {
				return fmt.Errorf("--squelch %.0f dBFS was rejected by the daemon (no reason observed)", o.squelch)
			}
			return fmt.Errorf("--squelch was not applied: %w", err)
		}
		if r, ok := ev.Body.(*leylinev1.Event_WriteRejected); ok {
			return fmt.Errorf("--squelch was not applied: %w", rejectedError(r.WriteRejected))
		}
	}
	return nil
}

// squelchProbeTimeout bounds the wait for the spectrum row auto squelch needs.
const squelchProbeTimeout = 2 * time.Second

// levelProbeTimeout bounds the wait for the capture's first CaptureLevel once
// the row is in hand: the daemon sends one a quarter of a second, so two
// intervals is one missed and one caught, and an older daemon that sends none
// costs a session this much once.
const levelProbeTimeout = 600 * time.Millisecond

// watchLevel subscribes to the capture's CaptureLevel and nothing else. The
// stream's error is not read: a daemon that sends no levels leaves the channel
// silent, and every reader of it is bounded by something else. A subscription
// that could not be opened is a nil channel, which blocks the same way.
func (s *session) watchLevel(ctx context.Context, captureID string) <-chan *leylinev1.TelemetryMsg {
	msgs, _, err := s.client.WatchTelemetry(ctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_CaptureId{CaptureId: captureID},
		Types: []leylinev1.TelemetryType{leylinev1.TelemetryType_CAPTURE_LEVEL},
	})
	if err != nil {
		return nil
	}
	return msgs
}

// awaitLevel is the first CaptureLevel off a watchLevel channel, or nil when
// none arrives within wait.
func awaitLevel(ctx context.Context, msgs <-chan *leylinev1.TelemetryMsg, wait time.Duration) *leylinev1.CaptureLevel {
	deadline := time.NewTimer(wait)
	defer deadline.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-deadline.C:
			return nil
		case m, ok := <-msgs:
			if !ok {
				return nil
			}
			if b, ok := m.Body.(*leylinev1.TelemetryMsg_CaptureLevel); ok {
				return b.CaptureLevel
			}
		}
	}
}

// measureSquelch derives a squelch threshold from one FFT row of the capture:
// the row's median bin is the noise floor per bin (a median is presentation,
// the spectrum itself is the daemon's), scaled to the channel bandwidth with
// 10·log10(bw / bin width); the threshold sits 10 dB above that. It returns
// an error when no row arrives within squelchProbeTimeout so callers can
// leave squelch off and say so.
func (s *session) measureSquelch(ctx context.Context, cap *leylinev1.Capture, bw uint32) (threshold, floor float64, err error) {
	sctx, cancel := context.WithTimeout(ctx, squelchProbeTimeout+levelProbeTimeout)
	defer cancel()
	// The capture's level is asked for first, so its first reading, a quarter
	// of a second away at most, is usually in hand by the time the row is: it
	// shows whether the radio is clipping, which the row cannot.
	levels := s.watchLevel(sctx, cap.CaptureId)
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
	case <-time.After(squelchProbeTimeout):
		return 0, 0, fmt.Errorf("no spectrum row arrived within %s", squelchProbeTimeout)
	case <-ctx.Done():
		return 0, 0, ctx.Err()
	}
	vals := leyline.DecodeFFTBins(fr.Payload, sub.Descriptor.GetFft().GetBinFormat())
	if len(vals) == 0 {
		return 0, 0, fmt.Errorf("spectrum row in an unexpected format")
	}
	// The same row answers whether the band is heard at all; a second
	// subscription would be another wait for the same numbers. The level
	// answers whether the radio is clipping, and a daemon that sends none
	// leaves the row's own full-scale rule to say so.
	level := awaitLevel(sctx, levels, levelProbeTimeout)
	s.failureNote = failureWords(vals, level, cap.GetGains(), s.device.GetGainElements())
	s.bandNote = bandWords(vals, level != nil, cap.GetGains(), s.device.GetGainElements())
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
// cancelled already. Whether the capture is still in use is asked of the
// daemon, not the mirror: another client may have added a channel since the
// last event was folded, and DestroyCapture would silence it. A failed
// destroy is reported on stderr with the recovery, since the next tune would
// otherwise fail with DEVICE_BUSY and no explanation.
func (s *session) teardown() {
	ctx, cancel := context.WithTimeout(context.Background(), confirmTimeout)
	defer cancel()
	if s.channel != nil {
		if _, err := s.client.Control.DestroyChannel(ctx, &leylinev1.DestroyChannelRequest{ChannelId: s.channel.ChannelId}); err != nil && leyline.Code(err) != leyline.CodeChannelNotFound {
			s.cleanupFailed("channel "+s.channel.ChannelId, err)
		}
	}
	if s.capture == nil || !s.createdCapture {
		return
	}
	if st, err := s.client.State(ctx); err == nil {
		s.state = st
	}
	var others []string
	for _, ch := range s.state.Channels {
		if ch.CaptureId == s.capture.CaptureId && (s.channel == nil || ch.ChannelId != s.channel.ChannelId) {
			others = append(others, ch.ChannelId)
		}
	}
	if len(others) > 0 {
		fmt.Fprintf(s.app.Stderr, "leaving capture %s running: %s still on it (%s); ley stop --all frees the radio\n",
			s.capture.CaptureId, words.Count(len(others), "other channel"), strings.Join(others, ", "))
		return
	}
	if _, err := s.client.Control.DestroyCapture(ctx, &leylinev1.DestroyCaptureRequest{CaptureId: s.capture.CaptureId}); err != nil && leyline.Code(err) != leyline.CodeCaptureNotFound {
		s.cleanupFailed("capture "+s.capture.CaptureId, err)
		return
	}
	s.freedRadio = true
}

// cleanupFailed reports a teardown RPC failure with the way out.
func (s *session) cleanupFailed(what string, err error) {
	fmt.Fprintf(s.app.Stderr, "warning: could not remove %s: %v; the radio may still be held, free it with: ley stop --all\n", what, err)
}

// meterLine renders the in-place status line in plain words: the signal
// level and whether audio is passing. OPEN/CLOSED live in --json only.
func meterLine(freq uint64, mode leylinev1.DemodMode, m *leylinev1.Meter, air onAir) string {
	return fmt.Sprintf("%s %s  signal %.0f dBFS  %s", units.FormatFrequency(freq), strings.ToUpper(leyline.ModeName(mode)), m.PowerDbfs, meterGate(m, air))
}

// meterGate is the meter line's last words: whether audio is passing and, when
// the open edge was seen, for how long. The count is whole seconds because the
// line redraws on every meter tick and tenths would only flicker.
func meterGate(m *leylinev1.Meter, air onAir) string {
	switch {
	case !m.GetSquelchOpen():
		return "muted, waiting for a signal"
	case air.known:
		return fmt.Sprintf("on air %d s", air.seconds)
	default:
		return "audio"
	}
}

// stageGainWords is the one way a capture's gain prints, wherever it prints (plans/v1-release.md,
// R-23): "gain 28 dB" or "gain auto" on a radio with one stage, every stage by name on a radio
// with several ("gain LNA 0 dB, VGA 20 dB, AMP off"), because "gain 8.0 dB" on a HackRF read as
// the radio's whole gain when it was the LNA alone (plans/app.md, M2-10). Names are the daemon's
// spelling. els is the device's gain elements, which is how a two-value stage is known to be a
// switch; without them (the device is gone) such a stage prints its level ("AMP 11 dB").
func stageGainWords(gains []*leylinev1.GainState, els []*leylinev1.GainElement) string {
	switch len(gains) {
	case 0:
		return "no gain control"
	case 1:
		return "gain " + stageLevel(gains[0], gainElement(els, gains[0].GetElement()))
	}
	stages := make([]string, len(gains))
	for i, g := range gains {
		stages[i] = g.GetElement() + " " + stageLevel(g, gainElement(els, g.GetElement()))
	}
	return "gain " + strings.Join(stages, ", ")
}

// stageLevel is one stage's setting as stageGainWords prints it: "auto", "on" or "off" for a
// switch, else the level ("20 dB", "49.6 dB").
func stageLevel(g *leylinev1.GainState, el *leylinev1.GainElement) string {
	switch {
	case g.GetAuto():
		return "auto"
	case isGainSwitch(el):
		if g.GetDb() > min(el.ValidDb[0], el.ValidDb[1]) {
			return "on"
		}
		return "off"
	}
	return gainDB(g.GetDb()) + " dB"
}

// gainDB renders a gain level with a decimal only when it has one: "49.6", "8", "0". Gains are
// set in steps of a tenth of a dB at the finest (the RTL-SDR tables), so the level is rounded to
// one decimal first and a stored 29.700000001 still reads 29.7.
func gainDB(db float64) string {
	return strconv.FormatFloat(math.Round(db*10)/10, 'f', -1, 64)
}

// isGainSwitch reports whether a gain element is a switch rather than a level: two valid settings
// and no step, as the HackRF's AMP (0 or 11 dB).
func isGainSwitch(el *leylinev1.GainElement) bool {
	return el != nil && len(el.ValidDb) == 2 && el.StepDb == 0
}

// gainElement is the element of els a stage names, matched ignoring case as the daemon matches
// it; nil when els does not list it.
func gainElement(els []*leylinev1.GainElement, name string) *leylinev1.GainElement {
	for _, el := range els {
		if strings.EqualFold(el.GetName(), name) {
			return el
		}
	}
	return nil
}

// deviceGainElements is the gain elements of the device a capture runs on, from the state; nil
// when the state no longer lists it.
func deviceGainElements(st *leylinev1.GetStateResponse, deviceID string) []*leylinev1.GainElement {
	for _, d := range st.GetDevices() {
		if d.GetDeviceId() == deviceID {
			return d.GetGainElements()
		}
	}
	return nil
}
