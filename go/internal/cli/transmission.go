// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
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
func (t transmission) render(st ui.Style) string {
	var b strings.Builder
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
