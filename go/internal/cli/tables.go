package cli

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// presetJSON and bandJSON are the `--json` shapes of `ley presets` and `ley
// bands`. Both tables are client-local data with no proto message (the CLI
// resolves them into the same RPCs a number uses), so they are emitted
// through encoding/json as one array; docs/interfaces.md names the exception.
type presetJSON struct {
	Name        string   `json:"name"`
	Aliases     []string `json:"aliases"`
	Hz          uint64   `json:"hz"`
	Mode        string   `json:"mode"`
	Description string   `json:"description"`
}

type bandJSON struct {
	Name string `json:"name"`
	// Aliases are what --band accepts; the first is the canonical short form.
	Aliases     []string `json:"aliases"`
	MinHz       uint64   `json:"min_hz"`
	MaxHz       uint64   `json:"max_hz"`
	Mode        string   `json:"mode"`
	BandwidthHz uint32   `json:"bandwidth_hz"`
	Note        string   `json:"note"`
}

// bandModeName renders a band's mode: "usb/lsb" where the sideband follows
// the frequency (the amateur HF convention), else the mode's own name.
func bandModeName(m leylinev1.DemodMode) string {
	if m == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
		return "usb/lsb"
	}
	return leyline.ModeName(m)
}

// printArray writes a client-local table as one JSON array line.
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

--json prints an array of {name, aliases, hz, mode, description}: client-local
data with no proto message, so it is not the proto3 JSON mapping.`,
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
					out = append(out, presetJSON{Name: p.Name, Aliases: aliases, Hz: p.Hz, Mode: leyline.ModeName(p.Mode), Description: p.Description})
				}
				return app.printArray(out)
			}
			return printPresetTable(app, ps)
		},
	}
}

func newBandsCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "bands",
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

--json prints an array of {name, min_hz, max_hz, mode, bandwidth_hz, note}:
client-local data with no proto message, so it is not the proto3 JSON mapping.`,
		Example: `  ley bands                      # the table
  ley bands --json | jq -r '.[] | .aliases[0]'
  ley spectrum --band noaa        # the whole NOAA weather band
  ley tune 146.52                # 2 m amateur: NFM, 12.5 kHz`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			bs := leyline.Bands()
			if app.JSON {
				out := make([]bandJSON, 0, len(bs))
				for _, b := range bs {
					out = append(out, bandJSON{Name: b.Name, Aliases: b.Aliases, MinHz: b.MinHz, MaxHz: b.MaxHz, Mode: bandModeName(b.Mode), BandwidthHz: b.BandwidthHz, Note: b.Note})
				}
				return app.printArray(out)
			}
			return printBandTable(app, bs)
		},
	}
}

// printPresetTable renders `ley presets`. Presets are grouped under the band
// they live in, so the seven near-identical noaa rows read as one offer the
// eye can skip rather than seven; the frequency the description used to
// restate is dropped (the FREQUENCY column already says it), and the aliases
// are Muted because they are the fallback spelling, not the one to type.
// --json keeps every field, description and all.
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
		desc := strings.TrimPrefix(withoutFrequency(p.Description, p.Hz), keys[i]+" ")
		add(cols, p.Name, leyline.FormatFrequency(p.Hz), leyline.ModeName(p.Mode), aliases, desc)
	}
	_, err := printColumns(app.Stdout, s, cols, heads)
	return err
}

// printBandTable renders `ley bands`. The eight amateur allocations are one
// family printed as eight nearly identical rows, so bands are grouped by
// family (in the order the families first appear, frequency order within
// one) and the note drops the "amateur radio," the heading now carries.
// --json keeps the flat, frequency-ordered array with the full note.
func printBandTable(app *App, bs []leyline.Band) error {
	s := tableStyle(app)
	keys := make([]string, len(bs))
	for i, b := range bs {
		keys[i] = bandFamily(b)
	}
	order, heads := groupRows(keys)
	// ALIAS is never dropped: it is the only column you can type, and without
	// it --band is undiscoverable. BANDWIDTH goes first when width runs out.
	cols := []column{
		{head: "NAME"},
		{head: "ALIAS"},
		{head: "RANGE"},
		{head: "MODE"},
		{head: "BANDWIDTH", drop: 1},
		{head: "NOTE", min: 14, drop: 2},
	}
	for _, i := range order {
		b := bs[i]
		rng := leyline.FormatFrequency(b.MinHz) + " to " + leyline.FormatFrequency(b.MaxHz)
		alias := ""
		if len(b.Aliases) > 0 {
			alias = b.Aliases[0]
		}
		add(cols, b.Name, alias, rng, bandModeName(b.Mode), formatBandwidth(b.BandwidthHz),
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

// presetGroup is the sub-heading a preset sits under: the band containing it,
// which is the same name `ley bands` prints, or "other" for a preset outside
// every band ley knows.
func presetGroup(p leyline.Preset) string {
	if b := leyline.BandFor(p.Hz); b != nil {
		return b.Name
	}
	return "other"
}

// bandFamily is the sub-heading a band sits under. The amateur allocations
// are the family worth collapsing; broadcast is the other one a newcomer
// already has a word for, and everything else is a service.
func bandFamily(b leyline.Band) string {
	switch {
	case strings.HasPrefix(b.Note, "amateur radio"):
		return "amateur radio"
	case strings.Contains(b.Name, "broadcast"):
		return "broadcast"
	}
	return "other services"
}

// withoutFrequency drops the frequency a description restates, so the
// DESCRIPTION column carries only what the FREQUENCY column does not. The
// --json description keeps it: that string is data, not layout.
func withoutFrequency(desc string, hz uint64) string {
	return strings.TrimSuffix(desc, " ("+leyline.FormatFrequency(hz)+")")
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
