// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"strings"
	"unicode"

	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// A dial target is a point on the dial the user named: a frequency, or a preset
// standing for one. Every verb that takes a point accepts both, so `noaa2`
// works wherever `162.400` does and fails the same way when it is a typo.
//
// Bands are not resolved here. `2m`, `20m` and `160m`
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
// With a band, the argument is a channel name in that band's plan and nothing
// else (see resolveDial).
//
// The two examples are not the same string and should not be collapsed into
// one: `usage` is whole commands, for someone who gave no argument at all and
// needs to see the shape; `example` is a readable frequency, for someone whose
// argument did not parse and needs to see what one looks like.
func resolveDialTarget(arg, verb, usage, example string, band *leyline.Band) (dialTarget, error) {
	if arg == "" {
		if band != nil {
			return dialTarget{}, usageErrorf("%s needs a channel of the %s plan: %s; check with: ley bands %s", verb, band.Name, usage, band.Aliases[0])
		}
		return dialTarget{}, usageErrorf("%s needs a frequency or preset: %s; check with: ley help presets", verb, usage)
	}
	t, err := resolveDial(arg, example, band)
	if err == nil {
		return t, nil
	}
	// A parse failure needs to be shown what a readable frequency looks like. A
	// preset typo does not: resolveDial has already offered the near names and
	// the frequency alternative, and appending the example again would staple
	// two hints together. Under --band the argument was never a number.
	if band == nil && looksNumeric(arg) {
		return dialTarget{}, usageErrorf("%v. Example: %s", err, example)
	}
	return dialTarget{}, usageError(err)
}

// resolveDial is resolveDialTarget without the usage wrapping, for the callers
// that carry a frame of their own: `--freq` prefixes its errors with the flag
// name, and `ley set` appends the values that parameter accepts. Wrapping twice
// would read as two error messages stapled together.
//
// With a band, the argument is read only as a channel of that band's plan: `16`
// is marine channel 16 under --band marine, and the numeric parse is not tried,
// because a frequency needs no band. A miss names the band and its plan rather
// than offering a frequency (docs/design/channels.md, "The CLI"; the plan's
// KTD8).
func resolveDial(arg, example string, band *leyline.Band) (dialTarget, error) {
	if band != nil {
		p, ok := leyline.ResolvePlanChannel(*band, arg)
		if !ok {
			return dialTarget{}, fmt.Errorf("no channel called %q in the %s plan; %s", arg, band.Name, planHint(*band))
		}
		return dialTarget{Hz: p.Hz, Preset: &p}, nil
	}
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

// planHint is the plan a miss under --band is shown: every name when the plan
// is short enough to read in one line (the design's threshold for drawing a
// plan as ticks), else its span and where to see the whole of it.
func planHint(band leyline.Band) string {
	plan := band.Plan()
	alias := band.Aliases[0]
	switch {
	case len(plan) == 0:
		return fmt.Sprintf("it has no channel plan, so give a frequency instead; check with: ley bands %s", alias)
	case len(plan) <= 24:
		names := make([]string, len(plan))
		for i, c := range plan {
			names[i] = c.Name
		}
		return "its channels are " + strings.Join(names, ", ") + "; check with: ley bands " + alias
	default:
		return fmt.Sprintf("it runs %s to %s, %d channels; check with: ley bands %s", plan[0].Name, plan[len(plan)-1].Name, len(plan), alias)
	}
}

// bandFlag resolves a --band value for a dial verb, or nil when the flag was
// not given. The error names the flag so it cannot be mistaken for the
// positional's.
func bandFlag(value string) (*leyline.Band, error) {
	if value == "" {
		return nil, nil
	}
	b, err := leyline.ResolveBand(value)
	if err != nil {
		return nil, usageError(fmt.Errorf("--band %w", err))
	}
	return &b, nil
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
