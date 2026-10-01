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
func covers(cap *leylinev1.Capture, freq uint64, bw uint32) bool {
	half := float64(cap.SampleRate) / 2
	lo := float64(freq) - float64(bw)/2
	hi := float64(freq) + float64(bw)/2
	c := float64(cap.CenterHz)
	return lo >= c-half && hi <= c+half
}

// ensureCapture reuses the device's capture when it covers freq±bw/2, retunes
// it (WriteParams center_hz) when it exists but does not, and creates one
// otherwise. It returns after the capture state is confirmed.
func (s *verbSession) ensureCapture(ctx context.Context, o *tuneOptions) error {
	if cap := leyline.FindCapture(s.State, s.device.DeviceId); cap != nil {
		s.Capture = cap
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
		sum, err := s.Client.WriteParams(ctx, w)
		if err != nil {
			return s.friendly(err, o.input, o.freq)
		}
		rejected := sum.GetWritesApplied() < sum.GetWritesReceived()
		ev, err := s.AwaitEvent(ctx, func(ev *leylinev1.Event) bool {
			switch b := ev.Body.(type) {
			case *leylinev1.Event_Capture:
				return !rejected && b.Capture.CaptureId == cap.CaptureId && b.Capture.CenterHz == o.freq
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
	cap, err := s.Client.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: s.device.DeviceId, CenterHz: center, SampleRate: o.rate})
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
	s.TrackCapture(cap)
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

// recordingsOn lists the running record jobs whose recording would be damaged
// by moving this capture. A record job either owns a channel on the capture
// (the audio form) or reads the capture itself (--iq); both are found by the
// job's own frequency against what the mirror holds.
//
// The daemon never refuses a user's write on a job's behalf -- it degrades the
// recording and records the gap. The client that takes the user's action does
// the check, which for `ley` is here (docs/design/recording.md, "Don't-disturb").
func (s *verbSession) recordingsOn(captureID string) []*leylinev1.Job {
	cap := captureByID(s.State, captureID)
	if cap == nil {
		return nil
	}
	var out []*leylinev1.Job
	for _, j := range s.State.GetJobs() {
		cfg := j.GetRecord()
		if cfg == nil || !isLiveJob(j) {
			continue
		}
		if cfg.GetChannelId() != "" {
			if ch := channelByID(s.State, cfg.GetChannelId()); ch != nil && ch.GetCaptureId() == captureID {
				out = append(out, j)
			}
			continue
		}
		// A frequency-form job: its own channel on this capture, or, for --iq,
		// this capture's span around where it was asked to listen.
		hz := cfg.GetFrequencyHz()
		onChannel := false
		for _, ch := range s.State.GetChannels() {
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
func (s *verbSession) refuseRetuneOverRecording(captureID string, retune bool) error {
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
func (s *verbSession) activeChannels(captureID string) int {
	n := 0
	for _, ch := range s.State.GetChannels() {
		if ch.CaptureId == captureID && ch.State == leylinev1.ChannelState_CHANNEL_ACTIVE {
			n++
		}
	}
	return n
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
		w := &leylinev1.ParamWrite{Tag: 2, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: o.squelch}}
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
