// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"unicode"

	"github.com/dpup/leysdr/go/pkg/leyline"
)

// A dial target is a point on the dial the user named: a frequency, or a preset
// standing for one. Every verb that takes a point accepts both, so `noaa2`
// works wherever `162.400` does and fails the same way when it is a typo.
//
// This is deliberately not where bands are resolved. `2m`, `20m` and `160m`
// already parse as 2, 20 and 160 MHz, so a band name in this position would
// silently redefine seven of the fourteen bands; bands are reached through an
// explicit `--band`, which cannot be mistaken for a frequency.
type dialTarget struct {
	Hz uint64
	// Preset is the preset the argument named, or nil when it was a frequency.
	// Callers that have a use for its mode (only `tune` does) read it here.
	Preset *leyline.Preset
}

// resolveDialTarget reads a frequency (bare numbers are MHz) or a preset name.
//
// The two examples are not the same string and should not be collapsed into
// one: `usage` is whole commands, for someone who gave no argument at all and
// needs to see the shape; `example` is a readable frequency, for someone whose
// argument did not parse and needs to see what one looks like.
func resolveDialTarget(arg, verb, usage, example string) (dialTarget, error) {
	if arg == "" {
		return dialTarget{}, usageErrorf("%s needs a frequency or preset: %s; check with: ley help presets", verb, usage)
	}
	t, err := resolveDial(arg, example)
	if err == nil {
		return t, nil
	}
	// A parse failure needs to be shown what a readable frequency looks like. A
	// preset typo does not: resolveDial has already offered the near names and
	// the frequency alternative, and appending the example again would staple
	// two hints together.
	if looksNumeric(arg) {
		return dialTarget{}, usageErrorf("%v. Example: %s", err, example)
	}
	return dialTarget{}, usageError(err)
}

// resolveDial is resolveDialTarget without the usage wrapping, for the callers
// that carry a frame of their own: `--freq` prefixes its errors with the flag
// name, and `ley set` appends the values that parameter accepts. Wrapping twice
// would read as two error messages stapled together.
func resolveDial(arg, example string) (dialTarget, error) {
	// A leading digit or sign means it is meant as a number; report the parse
	// error rather than sending it off to be spell-checked against presets.
	if looksNumeric(arg) {
		hz, err := leyline.ParseUserFrequency(arg)
		if err != nil {
			return dialTarget{}, err
		}
		return dialTarget{Hz: hz}, nil
	}
	p, err := leyline.ResolvePreset(arg)
	if err != nil {
		return dialTarget{}, fmt.Errorf("%w; or give a frequency such as %s", err, example)
	}
	return dialTarget{Hz: p.Hz, Preset: &p}, nil
}

// looksNumeric reports whether an argument was meant as a frequency rather than
// a name. It decides which of the two error shapes a failure gets.
func looksNumeric(arg string) bool {
	if arg == "" {
		return false
	}
	r := rune(arg[0])
	return unicode.IsDigit(r) || r == '.' || r == '-' || r == '+'
}
