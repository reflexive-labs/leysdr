// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"github.com/spf13/cobra"

	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// bandFlags is the flag-side half of a band view: what the user typed on the
// way to a picture of a band. `ley spectrum`, `ley waterfall` and `ley
// phosphor` take the same arguments and read them by the same rules, so the
// rules live here once and a fourth view inherits them rather than copying
// them and drifting.
type bandFlags struct {
	bandName     string
	band         *leyline.Band
	freq, span   uint64
	freqInput    string
	bins         uint32
	rate         float64
	count, width int
	retune       bool
	device       string
}

// bandUsage is what a view calls itself in the messages its arguments produce.
// The examples and the hints are the verb the reader typed, so they are worth
// the four fields: a spectrum user told to try `ley waterfall 146.52` has been
// sent somewhere they were not going.
type bandUsage struct {
	// verb names the command, as in "give a frequency or --band, not both".
	verb string
	// examples are whole command lines, and freqHint the shape a frequency
	// takes, both for the error a mistyped positional produces.
	examples, freqHint string
	// spanHint is the example widths --span is refused with.
	spanHint string
}

// bindCommon registers the flags every band view spells the same way. The ones
// whose help depends on what the view draws -- a map's width is not a chart's,
// and rows per second are not redraws per second -- stay with the view.
func (f *bandFlags) bindCommon(cmd *cobra.Command) {
	cmd.Flags().StringVar(&f.bandName, "band", "", "show a whole named band instead of a frequency: 2m, fm, airband, noaa (ley bands lists them); the span follows the band unless --span says otherwise")
	cmd.Flags().StringVar(&f.device, "device", "", "device: an id, id prefix, list index or frequency (default: the first real radio)")
	cmd.Flags().BoolVar(&f.retune, "retune", false, "move the radio to the frequency even when other channels are listening on it (they fall silent)")
}

// parse reads the positional frequency, --band and --span, and settles the
// count, rate and width the view draws with. span arrives as the string the
// flag holds because an unset --span and "--span 0" mean different things.
func (f *bandFlags) parse(app *App, args []string, span string, u bandUsage) error {
	if len(args) == 1 {
		f.freqInput = args[0]
	}
	if f.freqInput != "" {
		t, err := resolveDialTarget(f.freqInput, u.verb, u.examples, u.freqHint)
		if err != nil {
			return err
		}
		f.freq = t.Hz
	}
	if f.bandName != "" {
		// A band is a range and a positional is a point; asking for both says
		// two different things about where to put the radio.
		if f.freqInput != "" {
			return usageErrorf("give a frequency or --band, not both: %s %s --band %s", u.verb, f.freqInput, f.bandName)
		}
		b, err := leyline.ResolveBand(f.bandName)
		if err != nil {
			return usageError(err)
		}
		f.band = &b
	}
	if span != "" {
		v, err := leyline.ParseUserFrequency(span)
		if err != nil {
			return usageErrorf("--span: %v. Example: %s", err, u.spanHint)
		}
		f.span = v
	}
	if f.count < 0 {
		return usageErrorf("--count must be 0 or more")
	}
	if f.rate <= 0 {
		return usageErrorf("--rate must be greater than 0")
	}
	// Width comes from the resolved style, which has already applied --width,
	// COLUMNS, the terminal's own size and the [40, 160] clamp
	// (docs/cli-style.md section 2).
	f.width = app.Style.Width
	if f.width <= 0 {
		f.width = ui.DefaultWidth
	}
	return nil
}
