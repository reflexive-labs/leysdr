// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// subAudibleTracker turns the daemon's sub-audible telemetry into at most one
// line per change. The daemon repeats itself on a heartbeat, because the
// telemetry plane has no GetState and a client that subscribes mid-transmission
// has to be told what is already there; a person watching does not need to be
// told twice. A CTCSS tone and a DCS code are both squelch codes, so a move
// from one to the other is a change like any other.
type subAudibleTracker struct {
	last     subAudibleKey
	haveLast bool
}

// subAudibleKey is what makes two reports the same news: the kind, and the tone
// or the code it names.
type subAudibleKey struct {
	kind     leylinev1.SubAudibleKind
	std      float64
	code     uint32
	inverted bool
}

func keyOf(sa *leylinev1.SubAudible) subAudibleKey {
	switch sa.Kind {
	case leylinev1.SubAudibleKind_SUB_AUDIBLE_CTCSS:
		return subAudibleKey{kind: sa.Kind, std: sa.StandardToneHz}
	case leylinev1.SubAudibleKind_SUB_AUDIBLE_DCS:
		return subAudibleKey{kind: sa.Kind, code: sa.DcsCode, inverted: sa.DcsInverted}
	}
	// NONE and UNSPECIFIED are one state to a person: nothing below the voice.
	return subAudibleKey{}
}

// line renders a sub-audible report, and reports whether it is worth printing.
func (t *subAudibleTracker) line(sa *leylinev1.SubAudible, st ui.Style) (string, bool) {
	if sa == nil {
		return "", false
	}
	k := keyOf(sa)
	if t.haveLast && k == t.last {
		return "", false
	}
	t.haveLast, t.last = true, k
	var b strings.Builder
	switch k.kind {
	case leylinev1.SubAudibleKind_SUB_AUDIBLE_CTCSS:
		b.WriteString(st.Label("PL"))
		if std := sa.StandardToneHz; std > 0 {
			b.WriteString(fmt.Sprintf("  %.1f Hz", std))
		} else {
			// Measured but not classifiable: two standard tones could both explain
			// it, and naming one would be a guess. Report the measurement.
			b.WriteString(fmt.Sprintf("  %.1f Hz", sa.ToneHz))
			b.WriteString("  " + st.Warn("between two standard tones"))
		}
	case leylinev1.SubAudibleKind_SUB_AUDIBLE_DCS:
		b.WriteString(st.Label("DCS"))
		b.WriteString("  " + dcsText(sa))
	default:
		// Tone loss prints nothing. A channel that never had a tone should not
		// print a "no tone" line, and when a tone stops, the line that reported
		// it is enough.
		return "", false
	}
	if d := sa.DeviationHz; !math.IsNaN(d) && d > 0 {
		b.WriteString("  " + st.Muted("dev ") + fmt.Sprintf("%.0f", d) + st.Muted(" Hz"))
	}
	// tone/band is the CTCSS detector's measurement; a DCS report has no tone to
	// hold against the band.
	if s := sa.ToneSnrDb; k.kind == leylinev1.SubAudibleKind_SUB_AUDIBLE_CTCSS && !math.IsNaN(s) {
		b.WriteString("  " + st.Muted("tone/band ") + fmt.Sprintf("%.0f", s) + st.Muted(" dB"))
	}
	return b.String(), true
}

// dcsText is a DCS report's code as radios print it, three octal digits, with
// "inverted" after it when the daemon read the complemented stream: "023",
// "023 inverted". dcs_code carries the octal digits read as decimal, so 23 is
// printed as 023.
func dcsText(sa *leylinev1.SubAudible) string {
	s := fmt.Sprintf("%03d", sa.DcsCode)
	if sa.DcsInverted {
		s += " inverted"
	}
	return s
}
