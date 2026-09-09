package cli

import (
	"encoding/json"
	"fmt"
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
	Name        string `json:"name"`
	MinHz       uint64 `json:"min_hz"`
	MaxHz       uint64 `json:"max_hz"`
	Mode        string `json:"mode"`
	BandwidthHz uint32 `json:"bandwidth_hz"`
	Note        string `json:"note"`
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
			w := app.table()
			fmt.Fprintln(w, "NAME\tFREQUENCY\tMODE\tALIASES\tDESCRIPTION")
			for _, p := range ps {
				aliases := "-"
				if len(p.Aliases) > 0 {
					aliases = strings.Join(p.Aliases, ", ")
				}
				fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\n", p.Name, leyline.FormatFrequency(p.Hz), leyline.ModeName(p.Mode), aliases, p.Description)
			}
			return w.Flush()
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

usb/lsb means the sideband follows the amateur convention: USB at and above
10 MHz, LSB below (ley help modes).

--json prints an array of {name, min_hz, max_hz, mode, bandwidth_hz, note}:
client-local data with no proto message, so it is not the proto3 JSON mapping.`,
		Example: `  ley bands                      # the table
  ley bands --json | jq -r '.[] | .name'
  ley tune 146.52                # 2 m amateur: NFM, 12.5 kHz`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			bs := leyline.Bands()
			if app.JSON {
				out := make([]bandJSON, 0, len(bs))
				for _, b := range bs {
					out = append(out, bandJSON{Name: b.Name, MinHz: b.MinHz, MaxHz: b.MaxHz, Mode: bandModeName(b.Mode), BandwidthHz: b.BandwidthHz, Note: b.Note})
				}
				return app.printArray(out)
			}
			w := app.table()
			fmt.Fprintln(w, "NAME\tRANGE\tMODE\tBANDWIDTH\tNOTE")
			for _, b := range bs {
				fmt.Fprintf(w, "%s\t%s to %s\t%s\t%s\t%s\n", b.Name, leyline.FormatFrequency(b.MinHz), leyline.FormatFrequency(b.MaxHz), bandModeName(b.Mode), formatBandwidth(b.BandwidthHz), b.Note)
			}
			return w.Flush()
		},
	}
}
