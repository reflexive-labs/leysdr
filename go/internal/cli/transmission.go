// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"
	"strings"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// A transmission is what one squelch-open interval turned out to be: how long
// it ran and how loud it got. The daemon summarises it on the close edge of a
// SquelchTransition, so a client keeps the log without subscribing to meters
// and without timing anything itself.
//
// The duration arrives in capture samples, which is SampleTime's rate: the
// channel's own rate is not on the wire, and the capture's is something every
// client already has.
type transmission struct {
	seconds  float64 // NaN when the capture rate is unknown
	peakSNR  float64 // dB over the noise floor; NaN before the meter warms up
	peakDbfs float64
	// start is when the squelch opened, through the capture's anchor; zero
	// when no anchor covers it, and then the line carries no clock.
	start time.Time
}

// closedTransmission reads the summary off a squelch message, or reports false
// when the message is not the close edge of one. captureRate is the capture's
// sample rate; 0 means unknown, which costs the duration and nothing else.
func closedTransmission(sq *leylinev1.SquelchTransition, captureRate uint64) (transmission, bool) {
	if sq == nil || sq.Open || sq.DurationSamples == 0 {
		return transmission{}, false
	}
	t := transmission{
		seconds:  math.NaN(),
		peakSNR:  sq.PeakSnrDb,
		peakDbfs: sq.PeakAudioDbfs,
	}
	if captureRate > 0 {
		t.seconds = float64(sq.DurationSamples) / float64(captureRate)
	}
	return t, true
}

// transmissionStart is when a closed transmission began: the close edge's
// sample index less the samples it was open, dated through the capture's
// anchor. It reports false when the anchor does not cover that sample
// (anchorCovers) or the duration runs past the start of the capture, because a
// clock the daemon never kept is not one to print (AGENTS.md invariant 5).
func transmissionStart(sq *leylinev1.SquelchTransition, at *leylinev1.SampleTime, anchor *leylinev1.CaptureAnchor) (time.Time, bool) {
	if sq == nil || at == nil || !anchorCovers(anchor, at) || sq.GetDurationSamples() > at.GetSampleIndex() {
		return time.Time{}, false
	}
	return leyline.AnchorWallTime(anchor, at.GetSampleIndex()-sq.GetDurationSamples())
}

// anchorCovers is RecordWallTime's coverage rule for a live capture, which has
// one anchor rather than a page of them: the anchor names the sample's capture
// and is dated. A capture publishes its anchor with its first block, so the
// one in a Capture created a moment ago can still carry host time 0, and a
// time derived from that would be in 1970.
func anchorCovers(anchor *leylinev1.CaptureAnchor, t *leylinev1.SampleTime) bool {
	return anchor != nil && t != nil && anchor.GetCaptureId() != "" &&
		anchor.GetCaptureId() == t.GetCaptureId() && anchor.GetHostTimeNs() != 0
}

// captureAnchor is the anchor the mirror holds for a capture, nil when the
// capture is not in state. The mirror keeps it current: a Capture event carries
// it whole and an Anchor event replaces it (session.fold).
func captureAnchor(state *leylinev1.GetStateResponse, captureID string) *leylinev1.CaptureAnchor {
	for _, c := range state.GetCaptures() {
		if c.GetCaptureId() == captureID {
			return c.GetAnchor()
		}
	}
	return nil
}

// onAir is how long the open transmission has run, from its open edge to the
// meter tick being drawn. known is false when the open edge was not seen (the
// session subscribed mid-transmission, or the edge is on another capture), and
// then the meter line says audio, as it did before there was a count.
type onAir struct {
	known   bool
	seconds uint64
}

// onAirSince counts whole seconds between two sample times on one capture at
// the capture's rate; 0 for the rate means unknown, which costs the count.
func onAirSince(opened, now *leylinev1.SampleTime, captureRate uint64) onAir {
	if opened == nil || now == nil || captureRate == 0 ||
		opened.GetCaptureId() != now.GetCaptureId() || now.GetSampleIndex() < opened.GetSampleIndex() {
		return onAir{}
	}
	return onAir{known: true, seconds: (now.GetSampleIndex() - opened.GetSampleIndex()) / captureRate}
}

// fmtDuration is a transmission length as a listener reads it: tenths under a
// minute, because a two-way transmission is usually seconds long, and m:ss
// above it.
func fmtDuration(seconds float64) string {
	if math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds < 0 {
		return "-"
	}
	if seconds < 60 {
		return fmt.Sprintf("%.1f s", seconds)
	}
	m := int(seconds) / 60
	s := seconds - float64(m*60)
	return fmt.Sprintf("%d:%04.1f", m, s)
}

// render is one line of the transmission log. The duration leads because it is
// what the reader is scanning for; the levels are Muted scaffolding beside it.
// The level takes the ramp ink so it agrees with every other level ley draws.
// A start the anchor dates goes first, in Muted ink as every clock in ley is,
// so a log read later still says when; without one the line begins with the
// word.
func (t transmission) render(st ui.Style) string {
	var b strings.Builder
	if !t.start.IsZero() {
		b.WriteString(st.Muted(t.start.Format("15:04:05")) + "  ")
	}
	b.WriteString(st.Label("transmission"))
	b.WriteString("  " + fmtDuration(t.seconds))
	if !math.IsNaN(t.peakSNR) {
		b.WriteString("  " + st.Muted("peak snr ") + fmt.Sprintf("%.0f", t.peakSNR) + st.Muted(" dB"))
	}
	if !math.IsNaN(t.peakDbfs) && !math.IsInf(t.peakDbfs, 0) {
		b.WriteString("  " + st.Muted("peak ") + fmt.Sprintf("%.0f", t.peakDbfs) + st.Muted(" dBFS"))
	}
	return b.String()
}
