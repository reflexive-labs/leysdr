// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
)

// subAudibleTracker turns the daemon's sub-audible telemetry into at most one
// line per change. The daemon repeats itself on a heartbeat, because the
// telemetry plane has no GetState and a client that subscribes mid-transmission
// has to be told what is already there; a person watching does not need to be
// told twice.
type subAudibleTracker struct {
	last     float64
	haveLast bool
	lastOn   bool
}

// line renders a sub-audible report, and reports whether it is worth printing.
func (t *subAudibleTracker) line(sa *leylinev1.SubAudible, st ui.Style) (string, bool) {
	if sa == nil {
		return "", false
	}
	on := sa.Kind == leylinev1.SubAudibleKind_SUB_AUDIBLE_CTCSS
	std := sa.StandardToneHz
	if t.haveLast && on == t.lastOn && std == t.last {
		return "", false
	}
	t.haveLast, t.lastOn, t.last = true, on, std
	if !on {
		// Tone loss prints nothing. A channel that never had a tone should not
		// print a "no tone" line, and when a tone stops, the line that reported
		// it is enough.
		return "", false
	}
	var b strings.Builder
	b.WriteString(st.Label("PL"))
	switch {
	case std > 0:
		b.WriteString(fmt.Sprintf("  %.1f Hz", std))
	default:
		// Measured but not classifiable: two standard tones could both explain
		// it, and naming one would be a guess. Report the measurement.
		b.WriteString(fmt.Sprintf("  %.1f Hz", sa.ToneHz))
		b.WriteString("  " + st.Warn("between two standard tones"))
	}
	if d := sa.DeviationHz; !math.IsNaN(d) && d > 0 {
		b.WriteString("  " + st.Muted("dev ") + fmt.Sprintf("%.0f", d) + st.Muted(" Hz"))
	}
	if s := sa.ToneSnrDb; !math.IsNaN(s) {
		b.WriteString("  " + st.Muted("tone/band ") + fmt.Sprintf("%.0f", s) + st.Muted(" dB"))
	}
	return b.String(), true
}
