// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"math"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/session"
	"github.com/reflexive-labs/leysdr/go/internal/words"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// Bringing a tune up and down: the capture (reused, retuned or created), the channel and its
// initial squelch, the system-audio sink, and the teardown that removes what the run made.

// covers reports whether freq±bw/2 lies inside the capture's span.
func covers(capture *leylinev1.Capture, freq uint64, bw uint32) bool {
	half := float64(capture.SampleRate) / 2
	lo := float64(freq) - float64(bw)/2
	hi := float64(freq) + float64(bw)/2
	c := float64(capture.CenterHz)
	return lo >= c-half && hi <= c+half
}

// ensureCapture reuses the device's capture when it covers freq±bw/2, retunes
// it (WriteParams center_hz) when it exists but does not, and creates one
// otherwise. It returns after the capture state is confirmed.
func (s *verbSession) ensureCapture(ctx context.Context, o *tuneOptions) error {
	if capture := leyline.FindCapture(s.State, s.device.DeviceId); capture != nil {
		s.Capture = capture
		if covers(capture, o.freq, o.bw) {
			return nil
		}
		if err := s.checkRange(o.input, o.freq); err != nil {
			return err
		}
		if err := s.refuseDisplacing(ctx, capture, o.freq, o.input, o.retune, nil); err != nil {
			return err
		}
		s.say("retuning capture %s from %s to %s\n", capture.CaptureId, units.FormatFrequency(capture.CenterHz), units.FormatFrequency(o.freq))
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: capture.CaptureId, Param: &leylinev1.ParamWrite_CenterHz{CenterHz: o.freq}}
		sum, err := s.Client.WriteParams(ctx, w)
		if err != nil {
			return s.friendly(err, o.input, o.freq)
		}
		rejected := sum.GetWritesApplied() < sum.GetWritesReceived()
		ev, err := s.AwaitEvent(ctx, func(ev *leylinev1.Event) bool {
			switch b := ev.Body.(type) {
			case *leylinev1.Event_Capture:
				return !rejected && b.Capture.CaptureId == capture.CaptureId && b.Capture.CenterHz == o.freq
			case *leylinev1.Event_WriteRejected:
				return s.Mine(ev) && b.WriteRejected.Tag == 1
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
	capture, err := s.Client.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: s.device.DeviceId, CenterHz: center, SampleRate: o.rate})
	if err != nil {
		if leyline.Code(err) != leyline.CodeDeviceBusy {
			return s.friendly(err, o.input, o.freq)
		}
		// Another client is creating (or has just created) this device's capture; wait for it
		// to appear in the state and then reuse or retune it like any existing capture.
		deadline := time.Now().Add(5 * time.Second)
		for {
			st, serr := s.Client.State(ctx)
			if serr != nil {
				return serr
			}
			s.State = st
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
	s.TrackCapture(capture)
	s.createdCapture = true
	return nil
}

// checkRange mirrors the daemon's tuning-range check for the session's device
// so an impossible frequency fails with the friendly message before a write
// is attempted (the daemon remains the authority; it rejects anything the
// mirror lets through). Devices with unknown ranges are not checked.
func (s *verbSession) checkRange(input string, hz uint64) error {
	if s.device == nil || len(s.device.TuningRanges) == 0 || units.InRanges(hz, s.device.TuningRanges) {
		return nil
	}
	return s.friendly(&leyline.Error{
		Code: leyline.CodeFreqOutOfRange, Target: s.device.DeviceId,
		Message: fmt.Sprintf("%d Hz is outside the device tuning range", hz),
	}, input, hz)
}

// refuseDisplacing is the one confirmation a retune asks for (docs/design/claims.md, "In the
// clients"): Control.Plan says what moving the capture to centre would pause, and the move is
// refused, naming each of them, unless retune said to go ahead. The daemon never refuses a
// person's retune on a job's behalf; it pauses the job and says who moved the radio, so the
// client asks first. Views are never in the plan's list, and neither are this client's own
// claims. keep is a channel that moves with the radio (set freq's own), which is not paused.
// A plan the daemon declines (a sweep holds the radio, a centre it cannot tune) is the
// daemon's error.
func (s *verbSession) refuseDisplacing(ctx context.Context, capture *leylinev1.Capture, centre uint64, input string, retune bool, keep *leylinev1.Channel) error {
	if retune {
		return nil
	}
	p, err := s.Client.Control.Plan(ctx, &leylinev1.PlanRequest{Request: &leylinev1.PlanRequest_Retune{
		Retune: &leylinev1.RetunePlan{CaptureId: capture.GetCaptureId(), CenterHz: centre},
	}})
	if err != nil {
		return s.friendly(err, input, centre)
	}
	switch o := p.GetOutcome().(type) {
	case *leylinev1.CapturePlan_Decline:
		return s.friendly(&leyline.Error{Code: o.Decline.GetCode(), Message: o.Decline.GetReason(), Target: capture.GetCaptureId()}, input, centre)
	case *leylinev1.CapturePlan_Retune:
		var names []string
		for _, c := range o.Retune.GetDisplaced() {
			if c.GetPriority() == leylinev1.ClaimPriority_PRIORITY_VIEW || isChannelClaim(c, keep, capture) {
				continue
			}
			names = append(names, claimName(s.State, c))
		}
		if len(names) == 0 {
			return nil
		}
		return fmt.Errorf("retuning to %s would pause %s%s", units.FormatFrequency(centre), joinAnd(names), s.retuneRemedy())
	}
	return nil
}

// retuneRemedy ends the refusal: `ley`'s flag, or the MCP adapter's argument (takeOverHint).
func (s *verbSession) retuneRemedy() string {
	if s.takeOverHint != "" {
		return ". " + s.takeOverHint
	}
	return "; " + s.app.ErrStyle.Cmd("--retune") + " moves it anyway"
}

// isChannelClaim reports whether c is ch's own claim: a channel claim of its owner's on its
// frequency. A claim names no channel, so this is the closest match the ledger allows.
func isChannelClaim(c *leylinev1.Claim, ch *leylinev1.Channel, capture *leylinev1.Capture) bool {
	if ch == nil || c.GetKind() != leylinev1.ClaimKind_CLAIM_CHANNEL || c.GetHolder().GetClientId() != ch.GetOwner().GetClientId() {
		return false
	}
	return c.GetCovers().GetFrequencyHz() == uint64(int64(capture.GetCenterHz())+ch.GetOffsetHz())
}

// createChannel creates the demod channel at freq relative to the capture and
// applies the initial squelch: an explicit level, or the measured one when
// the run asked for auto (a failed measurement leaves squelch off and says so).
func (s *verbSession) createChannel(ctx context.Context, o *tuneOptions) error {
	offset := int64(o.freq) - int64(s.Capture.CenterHz)
	ch, err := s.Client.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{
		CaptureId: s.Capture.CaptureId, OffsetHz: offset, BandwidthHz: o.bw, Mode: o.mode, Persistent: o.persistent,
	})
	if err != nil {
		return s.friendly(err, o.input, o.freq)
	}
	s.TrackChannel(ch)
	if o.squelchAuto {
		db, floor, err := s.measureSquelch(ctx, s.Capture, ch.BandwidthHz)
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
		w := squelchWrite(2, ch.ChannelId, o.squelch, o.squelchAuto)
		sum, err := s.Client.WriteParams(ctx, w)
		if err != nil {
			return fmt.Errorf("--squelch was not applied: %w", err)
		}
		rejected := sum.GetWritesApplied() < sum.GetWritesReceived()
		ev, err := s.AwaitEvent(ctx, func(ev *leylinev1.Event) bool {
			switch b := ev.Body.(type) {
			case *leylinev1.Event_Channel:
				return !rejected && b.Channel.ChannelId == ch.ChannelId && b.Channel.SquelchDb == o.squelch
			case *leylinev1.Event_WriteRejected:
				return s.Mine(ev) && b.WriteRejected.Tag == 2
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

// rejectedError turns a WriteRejected event into a *leyline.Error so callers
// can key on its code like any RPC failure.
func rejectedError(r *leylinev1.WriteRejected) error {
	return &leyline.Error{Code: r.GetError().GetCode(), Message: r.GetError().GetMessage(), Target: r.GetError().GetTarget()}
}

// attachAudio attaches a system_audio sink; PLATFORM_UNSUPPORTED is reported
// as a warning rather than an error so headless hosts can still tune.
func (s *verbSession) attachAudio(ctx context.Context, o *tuneOptions) error {
	sink, err := s.Client.Control.AttachSink(ctx, &leylinev1.AttachSinkRequest{
		ChannelId: s.Channel.ChannelId,
		Sink:      &leylinev1.Sink{Kind: &leylinev1.Sink_SystemAudio{SystemAudio: &leylinev1.SystemAudioSink{Volume: proto.Float64(o.volume)}}},
	})
	if err != nil {
		if leyline.Code(err) == leyline.CodePlatformUnsupported {
			fmt.Fprintln(s.app.Stderr, "warning: system audio is not available on this host; continuing without audio (ley --json tune streams meters; see ley help scripting)")
			return nil
		}
		return err
	}
	s.Sink = sink
	return nil
}

// teardown destroys the channel and, when this run created the capture and
// nothing else uses it, the capture. Uses a fresh context: the run's may be
// cancelled already. Whether the capture is still in use is asked of the
// daemon, not the mirror: another client may have added a channel since the
// last event was folded, and DestroyCapture would silence it. A failed
// destroy is reported on stderr with the recovery, since the next tune would
// otherwise fail with DEVICE_BUSY and no explanation.
func (s *verbSession) teardown(ctx context.Context) {
	ctx, cancel := session.CleanupContext(ctx, confirmTimeout)
	defer cancel()
	if s.Channel != nil {
		if _, err := s.Client.Control.DestroyChannel(ctx, &leylinev1.DestroyChannelRequest{ChannelId: s.Channel.ChannelId}); err != nil && leyline.Code(err) != leyline.CodeChannelNotFound {
			s.cleanupFailed("channel "+s.Channel.ChannelId, err)
		}
	}
	if s.Capture == nil || !s.createdCapture {
		return
	}
	if st, err := s.Client.State(ctx); err == nil {
		s.State = st
	}
	var others []string
	for _, ch := range s.State.Channels {
		if ch.CaptureId == s.Capture.CaptureId && (s.Channel == nil || ch.ChannelId != s.Channel.ChannelId) {
			others = append(others, ch.ChannelId)
		}
	}
	if len(others) > 0 {
		fmt.Fprintf(s.app.Stderr, "leaving capture %s running: %s still on it (%s); ley stop --all frees the radio\n",
			s.Capture.CaptureId, words.Count(len(others), "other channel"), strings.Join(others, ", "))
		return
	}
	if _, err := s.Client.Control.DestroyCapture(ctx, &leylinev1.DestroyCaptureRequest{CaptureId: s.Capture.CaptureId}); err != nil && leyline.Code(err) != leyline.CodeCaptureNotFound {
		s.cleanupFailed("capture "+s.Capture.CaptureId, err)
		return
	}
	s.freedRadio = true
}

// cleanupFailed reports a teardown RPC failure with the way out.
func (s *verbSession) cleanupFailed(what string, err error) {
	fmt.Fprintf(s.app.Stderr, "warning: could not remove %s: %v; the radio may still be held, free it with: ley stop --all\n", what, err)
}

// squelchWrite is the write for a squelch level: one ley measured (auto) goes as squelch_auto_db,
// so the channel says the level was measured (Channel.squelch_source); a level the user typed,
// or off, as squelch_db.
func squelchWrite(tag uint64, channelID string, db float64, auto bool) *leylinev1.ParamWrite {
	w := &leylinev1.ParamWrite{Tag: tag, TargetId: channelID, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: db}}
	if auto && !units.SquelchOff(db) {
		w.Param = &leylinev1.ParamWrite_SquelchAutoDb{SquelchAutoDb: db}
	}
	return w
}
