// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// presetJSON and bandJSON are the `--json` shapes of `ley presets` and `ley
// bands`. Both tables are client-local data with no proto message (the CLI
// resolves them into the same RPCs a number uses), so they are emitted
// through encoding/json as one array; docs/reference/cli.md names the exception.
type presetJSON struct {
	Name    string   `json:"name"`
	Aliases []string `json:"aliases"`
	Hz      uint64   `json:"hz"`
	Mode    string   `json:"mode"`
	// BandwidthHz is the channel's own width where its plan gives one, else the band's.
	BandwidthHz uint32 `json:"bandwidth_hz"`
	Description string `json:"description"`
}

// channelJSON is one entry of a band's plan in `ley bands --json`: the shape docs/design/channels.md
// gives under "The plan is data in the band table". mode, bandwidth_hz and decoder are present only
// where the channel has its own; note is always present so a row is read the same way everywhere.
type channelJSON struct {
	Name        string   `json:"name"`
	Aliases     []string `json:"aliases"`
	Hz          uint64   `json:"hz"`
	Mode        string   `json:"mode,omitempty"`
	BandwidthHz uint32   `json:"bandwidth_hz,omitempty"`
	Note        string   `json:"note"`
	Decoder     string   `json:"decoder,omitempty"`
}

type bandJSON struct {
	Name string `json:"name"`
	// Aliases are what --band accepts; the first is the canonical short form.
	Aliases     []string `json:"aliases"`
	MinHz       uint64   `json:"min_hz"`
	MaxHz       uint64   `json:"max_hz"`
	Mode        string   `json:"mode"`
	BandwidthHz uint32   `json:"bandwidth_hz"`
	// StepHz is the band's channel spacing, which the app tunes by; it is not
	// the bandwidth (airband is 10 kHz wide and spaced 25 kHz).
	StepHz uint32 `json:"step_hz"`
	Note   string `json:"note"`
	// Parts names the bands a group is made of; absent on a plain band.
	Parts []string `json:"parts,omitempty"`
	// Channels is the band's plan, in the service's own order; absent on a band with none.
	Channels []channelJSON `json:"channels,omitempty"`
}

// bandRow is the --json shape of one band, plan included.
func bandRow(b leyline.Band) bandJSON {
	row := bandJSON{
		Name: b.Name, Aliases: b.Aliases, MinHz: b.MinHz, MaxHz: b.MaxHz,
		Mode: bandModeName(b.Mode), BandwidthHz: b.BandwidthHz, StepHz: b.StepHz,
		Note: b.Note, Parts: b.Parts,
	}
	for _, c := range b.Channels {
		ch := channelJSON{Name: c.Name, Aliases: c.Aliases, Hz: c.Hz, BandwidthHz: c.BandwidthHz, Note: c.Note, Decoder: c.Decoder}
		if c.Mode != leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
			ch.Mode = leyline.ModeName(c.Mode)
		}
		row.Channels = append(row.Channels, ch)
	}
	return row
}

// bandModeName renders a band's mode: "usb/lsb" where the sideband follows
// the frequency (the amateur HF convention), else the mode's own name.
func bandModeName(m leylinev1.DemodMode) string {
	if m == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
		return "usb/lsb"
	}
	return leyline.ModeName(m)
}

// printArray marshals a client-local JSON shape -- an array of table rows, or
// the single object a band lookup answers with. It does not use printJSON,
// which takes a proto message: none of this data has one, which is
// the documented exception in docs/reference/cli.md.
func (a *App) printArray(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(a.Stdout, "%s\n", b)
	return err
}

func newPresetsCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "presets",
		Short: "List the named frequencies tune accepts",
		Long: `presets lists the names 'ley tune' takes in place of a frequency, with the
frequency and mode each one stands for. The table lives in ley, not the
daemon: a preset is translated into the same tune the number would do, and
nothing is probed or scanned. 'ley help presets' explains them in prose and
lists the bands as well.

Every preset is a channel of a band's plan (ley bands noaa lists one), named
by the word that resolves without a band: wx3, marine16, cb19, murs1, ch5.
The ALIASES column carries what the band's radios print (WX3, 16), which
'ley tune 16 --band marine' takes, and the older names that still work.

--json prints an array of {name, aliases, hz, mode, bandwidth_hz, description}:
client-local data with no proto message, so it is not the proto3 JSON mapping.`,
		Example: `  ley presets                    # the table
  ley presets --json | jq -r .[].name
  ley tune noaa                  # what a preset is for`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			ps := leyline.Presets()
			if app.JSON {
				out := make([]presetJSON, 0, len(ps))
				for _, p := range ps {
					aliases := p.Aliases
					if aliases == nil {
						aliases = []string{}
					}
					out = append(out, presetJSON{Name: p.Name, Aliases: aliases, Hz: p.Hz, Mode: leyline.ModeName(p.Mode), BandwidthHz: p.BandwidthHz, Description: p.Description})
				}
				return app.printArray(out)
			}
			return printPresetTable(app, ps)
		},
	}
}

func newBandsCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "bands [frequency|preset|band]",
		Short: "List the bands ley recognises and their defaults",
		Long: `bands lists the slices of spectrum ley knows by name, with the mode and
bandwidth 'ley tune' uses there when --mode and --bw are not given. Outside
every band tune falls back to NFM and says so. Like presets, the table lives
in ley and never reaches the daemon; 'ley help presets' prints it in prose
alongside the presets.

The ALIAS column is what 'ley spectrum --band', 'ley waterfall --band' and
'ley phosphor --band' accept, so you can look at a whole band without working
out its centre and width. Aliases are not accepted where a frequency is: 2m,
20m and 160m already mean 2, 20 and 160 MHz there, and a band name in that
position would quietly redefine them.

usb/lsb means the sideband follows the amateur convention: USB at and above
10 MHz, LSB below (ley help modes).

CHANNELS counts the band's plan, the numbered channels its radios print;
'ley bands noaa' lists them, and 'ley tune 16 --band marine' tunes one by
its number ('ley presets' is every plan as one table).

--json prints an array of {name, aliases, min_hz, max_hz, mode, bandwidth_hz,
step_hz, note, parts, channels}: client-local data with no proto message, so
it is not the proto3 JSON mapping. step_hz is the band's channel spacing --
what one arrow key moves the dial by, which is not the bandwidth: airband is
10 kHz wide and spaced 25 kHz. channels, on a band with a plan, is an array
of {name, aliases, hz, mode, bandwidth_hz, note, decoder}, mode and
bandwidth_hz only where they differ from the band's. The Mac app reads the
same array from a checked-in bands.json (make bands-json).`,
		Example: `  ley bands                      # the table
  ley bands 146.52               # what is this, and what will tune do here?
  ley bands 2m                   # the same answer, asked by name
  ley bands noaa                 # a band and its plan, WX1 to WX7
  ley bands --json | jq -r '.[] | .aliases[0]'
  ley spectrum --band noaa       # the whole NOAA weather band`,
		GroupID: GroupLooking,
		Args:    cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			if len(args) == 1 {
				return runBandLookup(app, args[0])
			}
			// The groups come after the bands: the table stays frequency-ordered and
			// disjoint, and a group is a name for a sweep rather than a place.
			bs := append(leyline.Bands(), leyline.BandGroups()...)
			if app.JSON {
				out := make([]bandJSON, 0, len(bs))
				for _, b := range bs {
					out = append(out, bandRow(b))
				}
				return app.printArray(out)
			}
			return printBandTable(app, bs)
		},
	}
}

// printPresetTable renders `ley presets`. Presets are grouped under the band
// whose plan they are in, so the seven near-identical NOAA rows read as one
// group that is easy to skip; the DESCRIPTION column is the channel's note
// alone, since the band and the frequency are already on the screen, and the
// aliases are Muted because they are the fallback spelling, not the one to
// type. --json keeps every field, description and all.
func printPresetTable(app *App, ps []leyline.Preset) error {
	s := tableStyle(app)
	keys := make([]string, len(ps))
	for i, p := range ps {
		keys[i] = presetGroup(p)
	}
	order, heads := groupRows(keys)
	cols := []column{
		{head: "NAME"},
		{head: "FREQUENCY"},
		{head: "MODE"},
		{head: "ALIASES", drop: 1},
		{head: "DESCRIPTION", min: 14, drop: 2},
	}
	for _, i := range order {
		p := ps[i]
		aliases := s.Glyphs().Absent
		if len(p.Aliases) > 0 {
			aliases = s.Muted(strings.Join(p.Aliases, ", "))
		}
		add(cols, p.Name, leyline.FormatFrequency(p.Hz), leyline.ModeName(p.Mode), aliases, p.Note)
	}
	_, err := printColumns(app.Stdout, s, cols, heads)
	return err
}

// printBandTable renders `ley bands`. The eight amateur allocations are one
// family printed as eight nearly identical rows, so bands are grouped by
// family (in the order the families first appear, frequency order within
// one) and the note drops the "amateur radio," the heading now carries.
// --json keeps the flat, frequency-ordered array with the full note.
//
// The step is not a column. The six here already want 86 columns before NOTE
// is given its minimum, so an eighty-column terminal is truncating the note to
// print them; another column would spend the rest of that note on a number
// no `ley` verb tunes by yet (the app reads it from bands.json).
func printBandTable(app *App, bs []leyline.Band) error {
	s := tableStyle(app)
	keys := make([]string, len(bs))
	for i, b := range bs {
		keys[i] = bandFamily(b)
	}
	order, heads := groupRows(keys)
	// ALIAS is never dropped: it is the only column you can type, and without
	// it --band is undiscoverable. When width runs out BANDWIDTH goes first,
	// then CHANNELS (a count, and `ley bands noaa` has the plan itself), and
	// NOTE, which says what a band is, stays to its minimum.
	cols := []column{
		{head: "NAME"},
		{head: "ALIAS"},
		{head: "RANGE"},
		{head: "MODE"},
		{head: "BANDWIDTH", drop: 3},
		{head: "CHANNELS", drop: 2, right: true},
		// 13, not the usual 14: at 90 columns that one character is what keeps
		// CHANNELS on the screen once BANDWIDTH has gone.
		{head: "NOTE", min: 13, drop: 1},
	}
	for _, i := range order {
		b := bs[i]
		rng := leyline.FormatFrequency(b.MinHz) + " to " + leyline.FormatFrequency(b.MaxHz)
		alias := ""
		if len(b.Aliases) > 0 {
			alias = b.Aliases[0]
		}
		channels := s.Glyphs().Absent
		if n := len(b.Channels); n > 0 {
			channels = fmt.Sprint(n)
		}
		add(cols, b.Name, alias, rng, bandModeName(b.Mode), formatBandwidth(b.BandwidthHz), channels,
			strings.TrimPrefix(b.Note, bandFamily(b)+", "))
	}
	_, err := printColumns(app.Stdout, s, cols, heads)
	return err
}

// add appends one row of cells across cols, in column order.
func add(cols []column, cells ...string) {
	for i := range cells {
		cols[i].cells = append(cols[i].cells, cells[i])
	}
}

// presetGroup is the sub-heading a preset sits under: the band or group whose
// plan it is in, which is the same name `ley bands` prints.
func presetGroup(p leyline.Preset) string {
	return p.Band
}

// bandFamily is the sub-heading a band sits under. The amateur allocations
// are the family worth collapsing; broadcast is the other one a newcomer
// already has a word for; GMRS and MURS are each two halves and a group, so
// the six rows read as one block; everything else is a service.
func bandFamily(b leyline.Band) string {
	switch {
	case strings.HasPrefix(b.Note, "amateur radio"):
		return "amateur radio"
	case strings.Contains(b.Name, "broadcast"):
		return "broadcast"
	case strings.HasPrefix(b.Name, "GMRS"), strings.HasPrefix(b.Name, "MURS"):
		return "GMRS and MURS"
	}
	return "other services"
}

// groupRows returns the row order that puts each group together and the
// heading to print before each row ("" inside a group). Groups appear in the
// order they first occur and rows keep their table order inside one, so
// nothing the reader has memorised moves further than its family.
func groupRows(keys []string) ([]int, []string) {
	var order []int
	var seen []string
	for _, k := range keys {
		if slices.Contains(seen, k) {
			continue
		}
		seen = append(seen, k)
		for i, k2 := range keys {
			if k2 == k {
				order = append(order, i)
			}
		}
	}
	heads := make([]string, len(order))
	prev := ""
	for i, row := range order {
		if keys[row] != prev {
			heads[i] = keys[row]
			prev = keys[row]
		}
	}
	return order, heads
}

// runBandLookup answers "what is this frequency, and what would `ley tune` do
// with it?" -- the question the table could only answer by making the reader
// scan fifteen rows and compare ranges in their head.
//
// A band alias is checked first. Everywhere else in ley a leading digit means
// a frequency, so `2m` is 2 MHz; here that would answer "160 m amateur" for the
// alias this screen tells you to type. `bands` is the only verb about band
// names, so here the name wins, and the output says which reading it used so
// the user can retype for the other one.
func runBandLookup(app *App, arg string) error {
	if b, err := leyline.ResolveBand(arg); err == nil {
		// Seven aliases are also valid frequencies (2m is 2 MHz), so when the
		// argument reads both ways, say which one was taken. Picking silently
		// would be the same quiet wrong answer that kept bands off the
		// positional of every other verb.
		if hz, ferr := leyline.ParseUserFrequency(arg); ferr == nil && hz != b.CenterHz() {
			fmt.Fprintf(app.Stderr, "%s\n", app.ErrStyle.Muted(fmt.Sprintf(
				"reading %q as the band; for the frequency say %s", arg, leyline.FormatFrequency(hz))))
		}
		return printBandAnswer(app, b.CenterHz(), &b, "", true)
	}
	t, err := resolveDialTarget(arg, "bands", "ley bands, ley bands 146.52, ley bands 2m", "146.52 (MHz)", nil)
	if err != nil {
		return err
	}
	reason := ""
	if t.Preset != nil {
		reason = "preset " + t.Preset.Name + ": " + t.Preset.Description
	}
	return printBandAnswer(app, t.Hz, leyline.BandFor(t.Hz), reason, false)
}

// bandAnswerJSON is `ley bands <frequency> --json`: one object rather than the
// table's array. The band is null when none matches, but the answer is not --
// a script asking what to tune with still gets the mode and bandwidth, which is
// the part it came for.
type bandAnswerJSON struct {
	Hz          uint64    `json:"hz"`
	Band        *bandJSON `json:"band"`
	Mode        string    `json:"mode"`
	BandwidthHz uint32    `json:"bandwidth_hz"`
	Reason      string    `json:"reason"`
}

// printBandAnswer renders one band lookup. wholeBand says the argument named a
// band rather than a point in one, which changes what the first line can claim.
func printBandAnswer(app *App, hz uint64, b *leyline.Band, reason string, wholeBand bool) error {
	mode, _ := leyline.DefaultMode(hz)
	bw := leyline.BandwidthFor(hz, mode)
	if reason == "" {
		if b != nil {
			reason = b.Name + " band default"
		} else {
			// The same words `ley tune` uses, so the two verbs cannot diverge.
			reason = "no band recognised, using NFM"
		}
	}
	if app.JSON {
		out := bandAnswerJSON{Hz: hz, Mode: leyline.ModeName(mode), BandwidthHz: bw, Reason: reason}
		if b != nil {
			row := bandRow(*b)
			out.Band = &row
		}
		return app.printArray(out)
	}
	st := app.Style
	var w strings.Builder
	switch {
	case b == nil:
		fmt.Fprintf(&w, "%s is in no band ley knows\n", leyline.FormatFrequency(hz))
	case wholeBand:
		fmt.Fprintf(&w, "%s is %s to %s\n", b.Name,
			leyline.FormatFrequency(b.MinHz), leyline.FormatFrequency(b.MaxHz))
	default:
		fmt.Fprintf(&w, "%s is in %s (%s to %s)\n", leyline.FormatFrequency(hz), b.Name,
			leyline.FormatFrequency(b.MinHz), leyline.FormatFrequency(b.MaxHz))
	}
	// The mode is resolved for this frequency, so an HF band answers lsb or usb
	// rather than the table's usb/lsb.
	row := func(label, value, note string) {
		w.WriteString("  " + st.Pad(st.Label(label), 10) + value)
		if note != "" {
			w.WriteString("  " + st.Muted(note))
		}
		w.WriteString("\n")
	}
	row("mode", leyline.ModeName(mode), reason)
	row("bandwidth", formatBandwidth(bw), "")
	var plan []leyline.Channel
	if b != nil {
		if note := strings.TrimPrefix(b.Note, bandFamily(*b)+", "); note != "" {
			row("note", note, "")
		}
		if len(b.Aliases) > 0 {
			row("alias", b.Aliases[0], "")
		}
		// A whole-band lookup is the place to see the plan; a point lookup
		// answers the point, and the CHANNEL word for it is in the reason.
		if plan = b.Plan(); wholeBand && len(plan) > 0 {
			row("channels", fmt.Sprint(len(plan)), "ley tune <channel> --band "+b.Aliases[0])
		}
	}
	if _, err := fmt.Fprint(app.Stdout, w.String()); err != nil {
		return err
	}
	if wholeBand && len(plan) > 0 {
		if err := printPlanTable(app, plan); err != nil {
			return err
		}
	}
	next := "ley bands"
	if b != nil && len(b.Aliases) > 0 {
		next = "ley spectrum --band " + b.Aliases[0]
	}
	_, err := fmt.Fprintf(app.Stdout, "  %s\n", st.Cmd(next))
	return err
}

// printPlanTable renders a band's plan under a band lookup: a row per channel
// in the service's own order, with the name the radio prints, the frequency,
// the word that tunes it without a band (PRESET), the other names it answers
// to (Muted: fallback spellings), and the note.
func printPlanTable(app *App, plan []leyline.Channel) error {
	s := tableStyle(app)
	cols := []column{
		{head: "CHANNEL"},
		{head: "FREQUENCY"},
		{head: "PRESET"},
		{head: "ALSO", drop: 1, hideEmpty: true},
		{head: "NOTE", min: 14, drop: 2},
	}
	for _, c := range plan {
		also := s.Glyphs().Absent
		if len(c.Aliases) > 1 {
			also = s.Muted(strings.Join(c.Aliases[1:], ", "))
		}
		add(cols, c.Name, leyline.FormatFrequency(c.Hz), c.Aliases[0], also, c.Note)
	}
	// The plan is indented under the answer's rows, the way a grouped table's
	// rows sit under their heading.
	_, err := printColumns(app.Stdout, s, cols, make([]string, len(plan)))
	return err
}
