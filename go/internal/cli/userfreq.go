// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/bandplan"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// frequencyHint returns a one-line hint for a frequency the device rejected as
// out of range, or "" when there is nothing useful to say. input is what the
// user typed and hz what units.ParseFrequency made of it. When re-reading a bare
// number as kHz lands inside a device range or a known band, suggest that
// spelling ("did you mean 1.010 MHz (AM broadcast)? write 1010k"); otherwise
// give the actual reason ("this device cannot tune below 24.000 MHz; HF needs
// an upconverter"). Callers print the device's tuning range themselves; this
// hint never repeats it.
func frequencyHint(input string, hz uint64, ranges []*leylinev1.FrequencyRange) string {
	if v, ok := units.BareNumber(strings.TrimSpace(input)); ok && v > 0 {
		khz := uint64(math.Round(v * 1e3))
		if khz != hz && (units.InRanges(khz, ranges) || bandplan.BandFor(khz) != nil) {
			label := units.FormatFrequency(khz)
			if b := bandplan.BandFor(khz); b != nil {
				label += " (" + b.Name + ")"
			}
			return fmt.Sprintf("did you mean %s? write %sk", label, strconv.FormatFloat(v, 'f', -1, 64))
		}
	}
	var minHz, maxHz uint64
	for _, r := range ranges {
		if r == nil {
			continue
		}
		if minHz == 0 || r.GetMinHz() < minHz {
			minHz = r.GetMinHz()
		}
		if r.GetMaxHz() > maxHz {
			maxHz = r.GetMaxHz()
		}
	}
	switch {
	case minHz > 0 && hz < minHz:
		s := "this device cannot tune below " + units.FormatFrequency(minHz)
		if hz < 30_000_000 {
			s += "; HF needs an upconverter or a device with direct sampling"
		}
		return s
	case maxHz > 0 && hz > maxHz:
		return "this device cannot tune above " + units.FormatFrequency(maxHz)
	}
	return ""
}

// parseRange reads a frequency range in the form a person types at a
// radio: "144M..148M", "144..148" (both MHz), "162.4M..162.55M". Each half
// goes through units.ParseFrequency, so a bare number is MHz on both sides and
// the units are the same ones every other argument takes.
//
// ".." is the only separator. A dash was considered and rejected: "144-148"
// reads as a subtraction to half the people who type it and as a range to the
// other half, and FormatFrequency already spends the dash on "24 MHz-1.766
// GHz" in device tables.
//
// A band name is refused rather than resolved. Half the metre names already
// parse as frequencies ("2m" is 2 MHz everywhere in ley), so accepting them
// here would make "2m..70cm" silently mean 2 MHz to something that does not
// parse. The same silent misreading is why band names are not accepted in any
// positional. --band is the flag that takes them.
func parseRange(s string) (minHz, maxHz uint64, err error) {
	orig := strings.TrimSpace(s)
	lo, hi, found := strings.Cut(orig, "..")
	if !found {
		if _, err := bandplan.ResolveBand(orig); err == nil {
			return 0, 0, fmt.Errorf("%q is a band, not a range; say --band %s", orig, orig)
		}
		return 0, 0, fmt.Errorf("%q is not a range; two frequencies with .. between them, as in 144M..148M", orig)
	}
	lo, hi = strings.TrimSpace(lo), strings.TrimSpace(hi)
	if minHz, err = units.ParseFrequency(lo); err != nil {
		return 0, 0, fmt.Errorf("the low end of %q: %w", orig, err)
	}
	if maxHz, err = units.ParseFrequency(hi); err != nil {
		return 0, 0, fmt.Errorf("the high end of %q: %w", orig, err)
	}
	if minHz >= maxHz {
		return 0, 0, fmt.Errorf("%s is not below %s; a range runs low..high", units.FormatFrequency(minHz), units.FormatFrequency(maxHz))
	}
	return minHz, maxHz, nil
}
