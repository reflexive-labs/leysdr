// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"

	"github.com/dpup/leysdr/go/pkg/leyline"
)

// bandOptions is what a band view needs to find its capture. `ley spectrum`
// and `ley waterfall` draw different pictures of the same thing and pick their
// capture by exactly the same rules, so the rules live here once.
type bandOptions struct {
	freq, span uint64
	freqInput  string
	retune     bool
	device     string
	// band is a named band to show whole, from --band. It is resolved after the
	// device is picked, because how much of a band fits depends on the rates
	// that radio supports.
	band *leyline.Band
	// verb names the command in the messages, which are the user's map of what
	// just happened to their radio.
	verb string
}

// resolveBandFlag turns --band into a centre and a span, once the device is
// known. Nine of the fourteen bands fit inside a 2.4 MSPS capture, so for most
// of them this is exact; the rest are centred and the caller is told how much
// of the band it is actually looking at, which is the same courtesy spectrum
// already extends when it reuses an off-centre capture.
//
// An explicit --span wins: someone who said how wide meant it.
func (s *session) resolveBandFlag(app *App, o *bandOptions) {
	b := o.band
	if b == nil {
		return
	}
	o.freq = b.CenterHz()
	if o.freqInput == "" {
		o.freqInput = b.Name
	}
	if o.span != 0 {
		if o.span < b.WidthHz() {
			fmt.Fprintf(app.Stderr, "%s is %s wide; --span shows %s of it, centred on %s\n",
				b.Name, leyline.FormatFrequency(b.WidthHz()),
				leyline.FormatFrequency(o.span), leyline.FormatFrequency(b.CenterHz()))
		}
		return
	}
	// The smallest supported rate that covers the band, or the largest there is.
	want := b.WidthHz()
	var best uint64
	for _, r := range s.device.SampleRates {
		if r >= want && (best == 0 || r < best) {
			best = r
		}
	}
	if best == 0 {
		for _, r := range s.device.SampleRates {
			if r > best {
				best = r
			}
		}
		if best > 0 {
			fmt.Fprintf(app.Stderr, "%s is %s wide and this radio captures at most %s; showing that much, centred on %s\n",
				b.Name, leyline.FormatFrequency(want), leyline.FormatFrequency(best),
				leyline.FormatFrequency(b.CenterHz()))
		}
	}
	o.span = best
}

// openBand picks the device, reuses or creates a capture covering the
// frequency, and says on stderr whenever the radio ended up somewhere other
// than where the user pointed. The caller tears down a capture it created
// (s.createdCapture says whether there is one).
func (s *session) openBand(ctx context.Context, app *App, o bandOptions) error {
	var err error
	if s.device, err = pickDevice(s.state, o.device); err != nil {
		return err
	}
	// --band needs the device's rates to know how much of the band fits.
	s.resolveBandFlag(app, &o)
	cap := leyline.FindCapture(s.state, s.device.DeviceId)
	if cap == nil && o.freq == 0 {
		return usageErrorf("%s is not tuned to anything yet; say where to look, e.g.: ley %s 101.1",
			deviceName(s.device), o.verb)
	}
	if o.freq != 0 && (cap == nil || !leyline.CaptureCovers(cap, o.freq)) {
		if !leyline.InRanges(o.freq, s.device.TuningRanges) && len(s.device.TuningRanges) > 0 {
			msg := fmt.Sprintf("%s is outside %s's range (%s)", leyline.FormatFrequency(o.freq), deviceName(s.device), leyline.FormatRanges(s.device.TuningRanges))
			if hint := leyline.FrequencyHint(o.freqInput, o.freq, s.device.TuningRanges); hint != "" {
				msg += "; " + hint
			}
			return usageErrorf("%s", msg)
		}
	}
	// --span is the capture width. A fresh capture gets the nearest rate the
	// radio supports (said on stderr); an existing capture keeps its width, so
	// a different span is refused up front rather than silently ignored.
	span := o.span
	if span != 0 {
		span = leyline.NearestRate(s.device.SampleRates, o.span)
		if cap != nil && cap.SampleRate != span {
			return usageErrorf("the radio is already capturing %s wide, and %s shows the capture's width; drop --span, ask for --span %s, or free the radio with: ley stop all",
				leyline.FormatFrequency(cap.SampleRate), o.verb, leyline.FormatFrequency(cap.SampleRate))
		}
		if span != o.span {
			fmt.Fprintf(app.Stderr, "showing %s, the closest this radio can do to %s\n", leyline.FormatFrequency(span), leyline.FormatFrequency(o.span))
		}
	}
	// ensureCapture reuses a capture that covers the frequency, refuses to
	// move one other channels ride on (unless --retune), and creates one
	// otherwise; the capture created for this run is removed by the caller.
	freq := o.freq
	if freq == 0 {
		freq = cap.CenterHz
	}
	if err := s.ensureCapture(ctx, &tuneOptions{freq: freq, input: o.freqInput, rate: span, retune: o.retune}); err != nil {
		return err
	}
	// A reused capture keeps its own centre, so the picture can be centred
	// somewhere other than the frequency that was asked for. Say so rather
	// than let the axis be a surprise.
	if o.freq != 0 && s.capture != nil && s.capture.CenterHz != o.freq {
		fmt.Fprintf(app.Stderr, "showing the capture at %s, which covers %s\n", leyline.FormatFrequency(s.capture.CenterHz), leyline.FormatFrequency(o.freq))
	}
	return nil
}
