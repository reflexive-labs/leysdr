// SPDX-License-Identifier: Apache-2.0

// Package session is the connection and state mirror every ley verb and MCP tool runs on: a
// daemon-scoped GetState snapshot and the event stream resumed from its seq, folded into the
// snapshot as events arrive. Events carry whole objects (invariant 6), so the fold replaces by id
// and never merges, and reconnecting is a new snapshot plus a resume from its seq.
package session

import (
	"context"
	"errors"
	"fmt"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// ConfirmTimeout bounds how long a client waits for the daemon's confirming event, and how long
// cleanup RPCs get once the run's own context has ended.
const ConfirmTimeout = 2 * time.Second

// Session is one client's view of the daemon: the connection, the mirror of its state, and the
// capture, channel and sink this run works with, which the fold keeps current too.
type Session struct {
	Client  *leyline.Client
	State   *leylinev1.GetStateResponse
	Capture *leylinev1.Capture
	Channel *leylinev1.Channel
	Sink    *leylinev1.Sink

	events    <-chan *leylinev1.Event
	eventErrs <-chan error
	cancel    context.CancelFunc
	// seq is the newest event seq folded into the mirror (the snapshot's at open); an event at
	// or below it is already reflected and is skipped.
	seq uint64
}

// Open starts the daemon-scoped event stream from snap's seq. The daemon replays what happened
// between the snapshot and the stream's registration, so no confirmation is missed as long as
// both happen before any write.
func Open(ctx context.Context, c *leyline.Client, snap *leylinev1.GetStateResponse) (*Session, error) {
	ectx, cancel := context.WithCancel(ctx)
	events, errs, err := c.Events(ectx, leyline.ScopeSince(nil, snap.EventSeq))
	if err != nil {
		cancel()
		return nil, err
	}
	return &Session{Client: c, State: snap, seq: snap.EventSeq, events: events, eventErrs: errs, cancel: cancel}, nil
}

// Events is the live event stream, for a caller that folds events itself through Apply.
func (s *Session) Events() <-chan *leylinev1.Event { return s.events }

// EventErrs carries the event stream's one terminal error once Events has closed.
func (s *Session) EventErrs() <-chan error { return s.eventErrs }

// CleanupContext is the context for an RPC that undoes what a run made, once the run's own
// context may already be cancelled: ctx's values without its cancellation, bounded by d.
func CleanupContext(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), d)
}

// TrackCapture makes c the session's capture and puts it in the mirror, for a capture this run
// has just created and whose event has not arrived yet.
func (s *Session) TrackCapture(c *leylinev1.Capture) {
	s.Capture = c
	replaceCapture(s.State, c)
}

// TrackChannel does the same for a channel this run has just created.
func (s *Session) TrackChannel(ch *leylinev1.Channel) {
	s.Channel = ch
	replaceChannel(s.State, ch)
}

// DrainEvents folds the event stream into the mirror in the background for a
// caller that does not read events itself (spectrum, fft), so the stream keeps
// flowing and the mirror stays current while it runs. The returned func stops
// the drain and waits for it; the mirror (State, Capture, Channel, Sink) must
// not be read or written until it has returned.
func (s *Session) DrainEvents() (stop func()) {
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
				s.Apply(ev)
			}
		}
	}()
	return func() {
		close(quit)
		<-done
	}
}

// Close tears down the event stream and connection.
func (s *Session) Close() {
	s.cancel()
	s.Client.Close()
}

// AwaitEvent folds events until pred returns true or ConfirmTimeout elapses.
// Because a WatchEvents stream may register on the daemon slightly after the
// client opened it, the daemon's state is also re-read periodically and offered
// to pred as synthetic (caused_by-less) events; reconnect-by-GetState is the
// documented recovery path for missed events.
func (s *Session) AwaitEvent(ctx context.Context, pred func(*leylinev1.Event) bool) (*leylinev1.Event, error) {
	timer := time.NewTimer(ConfirmTimeout)
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
			st, err := s.Client.State(ctx)
			if err != nil {
				continue
			}
			s.State = st
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
			if s.Apply(ev) && pred(ev) {
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

// Apply folds a live event into the mirror unless it is older than what the
// mirror already reflects (a replayed or late event with seq at or below the
// snapshot's, or a poll's), and reports whether it was folded.
func (s *Session) Apply(ev *leylinev1.Event) bool {
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
func (s *Session) fold(ev *leylinev1.Event) {
	switch b := ev.Body.(type) {
	case *leylinev1.Event_Capture:
		// State unset is the destroy tombstone; CAPTURE_DETACHED is a capture
		// whose radio is unplugged and which rebinds when it returns, so only
		// the former leaves the mirror.
		if b.Capture.State == leylinev1.CaptureState_CAPTURE_STATE_UNSPECIFIED {
			s.State.Captures = withoutCapture(s.State.Captures, b.Capture.CaptureId)
		} else {
			replaceCapture(s.State, b.Capture)
		}
		if s.Capture != nil && s.Capture.CaptureId == b.Capture.CaptureId {
			s.Capture = b.Capture
		}
	case *leylinev1.Event_Channel:
		// A destroyed channel is emitted one last time with its state unset,
		// and folding that as a replace leaves a dead channel in the mirror
		// for the rest of the run -- which is how a verb ends up counting a
		// channel that is gone.
		if b.Channel.State == leylinev1.ChannelState_CHANNEL_STATE_UNSPECIFIED {
			s.State.Channels = withoutChannel(s.State.Channels, b.Channel.ChannelId)
		} else {
			replaceChannel(s.State, b.Channel)
		}
		if s.Channel != nil && s.Channel.ChannelId == b.Channel.ChannelId {
			s.Channel = b.Channel
		}
	case *leylinev1.Event_Sink:
		if b.Sink.State == leylinev1.SinkState_SINK_STATE_UNSPECIFIED {
			s.State.Sinks = withoutSink(s.State.Sinks, b.Sink.SinkId)
		} else {
			replaceSink(s.State, b.Sink)
		}
		if s.Sink != nil && s.Sink.SinkId == b.Sink.SinkId {
			s.Sink = b.Sink
		}
	case *leylinev1.Event_Anchor:
		// A capture publishes its anchor with its first block, and again on a
		// rate change or a rebind, so the one its Capture arrived with is the
		// stale (or undated) one: the newest is what dates a sample index.
		for _, c := range s.State.GetCaptures() {
			if c.GetCaptureId() == b.Anchor.GetCaptureId() {
				c.Anchor = b.Anchor
			}
		}
		if s.Capture != nil && s.Capture.CaptureId == b.Anchor.GetCaptureId() {
			s.Capture.Anchor = b.Anchor
		}
	}
}

// Mine reports whether the event was caused by this process.
func (s *Session) Mine(ev *leylinev1.Event) bool {
	return ev.CausedBy != nil && ev.CausedBy.ClientId == s.Client.ClientID()
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
