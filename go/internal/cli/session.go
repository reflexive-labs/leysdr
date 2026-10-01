// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"fmt"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/session"
	"github.com/reflexive-labs/leysdr/go/pkg/bandplan"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// confirmTimeout bounds how long verbs wait for the daemon's confirming event.
const confirmTimeout = session.ConfirmTimeout

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

// verbSession is what one verb or MCP tool call runs with: the connection and
// state mirror (session.Session), the device it picked, and the words its
// banner and closing line need. For a tune it is one lifecycle: the capture
// (created or reused), the channel and the optional system-audio sink, with
// the open event stream that keeps a non-persistent channel alive.
type verbSession struct {
	*session.Session
	app            *App
	device         *leylinev1.DeviceDescriptor
	createdCapture bool
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
	channelGone bool
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
func (s *verbSession) friendly(err error, input string, hz uint64) error {
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

// openSession dials the daemon, snapshots its state and opens the event
// stream from the snapshot (session.Open). A daemon that cannot be reached
// or answered is reported as not running.
func openSession(ctx context.Context, app *App) (*verbSession, error) {
	c, err := app.dial(ctx)
	if err != nil {
		return nil, app.notRunning(err)
	}
	st, err := c.State(ctx)
	if err != nil {
		c.Close()
		return nil, app.notRunning(err)
	}
	m, err := session.Open(ctx, c, st)
	if err != nil {
		c.Close()
		return nil, err
	}
	return &verbSession{Session: m, app: app}, nil
}

// say prints prose to stdout in human mode and to stderr under --json (or
// when the verb reserves stdout for a stream), so stdout stays parseable.
func (s *verbSession) say(format string, args ...any) {
	if s.app.JSON || s.proseToStderr {
		fmt.Fprintf(s.app.Stderr, format, args...)
		return
	}
	fmt.Fprintf(s.app.Stdout, format, args...)
}
