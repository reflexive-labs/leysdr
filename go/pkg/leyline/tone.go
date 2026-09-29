// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"errors"
	"fmt"
	"strconv"

	"github.com/dpup/leysdr/go/pkg/dcs"
)

// ErrTone is the one refusal ParseTone makes. The app's validator prints the same sentence, so
// a tone typed into either client is refused in the same words (docs/design/channels.md,
// "Bookmarks gain three fields").
var ErrTone = errors.New("tone must be a CTCSS tone such as 100.0 or a DCS code such as D023N")

// CTCSSTones is the table a bookmark's tone must be on: the 38 EIA tones and the twelve extras
// (69.3, 159.8, 165.5, 171.3, 177.3, 183.5, 189.9, 196.6, 199.5, 206.5, 229.1, 254.1) every
// current radio menu offers. It is CHIRP's TONES list, so an exported memory's tone is always
// on it. Ascending, in hertz.
var CTCSSTones = []float64{
	67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
	94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
	131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9,
	171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
	203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1,
}

// Tone is a bookmark's sub-audible squelch tone: a CTCSS tone, or a DCS code with its polarity.
// Exactly one of CTCSSHz and DCSCode is set. DCSCode is the number itself, 0o023 for D023N, as
// go/pkg/dcs holds one; the contract's dcs_code carries the octal digits read as decimal, and
// dcs.Wire converts.
type Tone struct {
	CTCSSHz     float64
	DCSCode     int
	DCSInverted bool
}

// ParseTone reads a tone the way CHIRP spells one, and only that way: a tone on CTCSSTones
// with one decimal ("100.0", never "100" or "100.00"), or "D" + three octal digits + "N" or
// "I" for a standard DCS code and its polarity ("D023N", "D754I"). Anything else is ErrTone.
// The spelling is strict because the file is shared: both clients match the string, and a
// tone written two ways would be two tones.
func ParseTone(s string) (Tone, error) {
	if len(s) == 5 && s[0] == 'D' && (s[4] == 'N' || s[4] == 'I') {
		code, err := strconv.ParseUint(s[1:4], 8, 16)
		if err != nil || !dcs.IsStandard(int(code)) {
			return Tone{}, ErrTone
		}
		return Tone{DCSCode: int(code), DCSInverted: s[4] == 'I'}, nil
	}
	for _, hz := range CTCSSTones {
		if s == formatCTCSS(hz) {
			return Tone{CTCSSHz: hz}, nil
		}
	}
	return Tone{}, ErrTone
}

// String is the spelling ParseTone reads: "100.0", "D023N", "D023I".
func (t Tone) String() string {
	if t.DCSCode != 0 {
		polarity := "N"
		if t.DCSInverted {
			polarity = "I"
		}
		return "D" + dcs.Format(t.DCSCode) + polarity
	}
	return formatCTCSS(t.CTCSSHz)
}

// Words is the tone as a table or a label shows it, the words the app's transmissions log
// uses for a heard tone: "PL 100.0", "DCS 023", "DCS 023 inverted".
func (t Tone) Words() string {
	if t.DCSCode != 0 {
		s := "DCS " + dcs.Format(t.DCSCode)
		if t.DCSInverted {
			s += " inverted"
		}
		return s
	}
	return "PL " + formatCTCSS(t.CTCSSHz)
}

func formatCTCSS(hz float64) string { return fmt.Sprintf("%.1f", hz) }
