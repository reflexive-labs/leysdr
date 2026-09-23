// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/dpup/leysdr/go/pkg/labels"
)

// newLabelCommand builds `ley label`. A label is a human name for a transmitter id, kept in a
// client-side JSON store because a label is user data a fold cannot derive (docs/design/
// decoders.md, "The state boundary" and section 5, "Registry devices"). `ley devices-seen` joins
// these names onto the discovered transmitters.
func newLabelCommand(app *App) *cobra.Command {
	var clear bool
	cmd := &cobra.Command{
		Use:   "label <device-id> [name]",
		Short: "Give a transmitter a name you will recognise",
		Long: `label puts a human name on a transmitter id, so 'that soil probe'
becomes 'greenhouse' in 'ley devices-seen'. The id is the one the protocol
gives a transmitter -- an ICAO hex, an MMSI, a callsign-SSID, an rtl_433
model/id -- and a name is yours to choose.

Labels are your data, not the daemon's: they live in a small JSON file
($LEYLINE_LABELS overrides its path) and outlive any decode job, because the
device registry is a fold over the records and the one thing a fold cannot
work out is what you decided a device is.

With a name, label sets it; with no name, label prints the current one; with
an empty name or --clear, label removes it. --json prints the label record.`,
		Example: `  ley label LEYTST-1 greenhouse    # name a transmitter
  ley label LEYTST-1               # what is it named?
  ley label LEYTST-1 --clear       # forget the name
  ley label LEYTST-1 --json | jq -r .name`,
		GroupID: GroupLooking,
		Args:    cobra.RangeArgs(1, 2),
		RunE: func(_ *cobra.Command, args []string) error {
			id := args[0]
			name := ""
			if len(args) == 2 {
				name = args[1]
			}
			setting := len(args) == 2 || clear
			if clear {
				name = ""
			}
			return runLabel(app, id, name, setting)
		},
	}
	cmd.Flags().BoolVar(&clear, "clear", false, "remove the name from this transmitter")
	return cmd
}

// runLabel reads or writes one label. setting is true when the invocation carried a name or
// --clear, so `ley label id` with no name only reports and never writes an empty file.
func runLabel(app *App, id, name string, setting bool) error {
	store, err := labels.Open(labels.ResolvePath(app.LookupEnv))
	if err != nil {
		return fmt.Errorf("cannot read the labels file: %w", err)
	}
	if setting {
		// Keep the protocol of an existing label as a note, so a cleared label still records it and
		// renaming does not drop where the device was first seen.
		protocol := ""
		if prev, ok := store.Get(id); ok {
			protocol = prev.Protocol
		}
		l, serr := store.Set(id, name, protocol)
		if serr != nil {
			return fmt.Errorf("cannot write the labels file: %w", serr)
		}
		if app.JSON {
			return app.printArray(l)
		}
		return printLabel(app, id, name)
	}
	l, ok := store.Get(id)
	if app.JSON {
		if !ok {
			l = labels.Label{DeviceID: id}
		}
		return app.printArray(l)
	}
	return printLabel(app, id, l.Name)
}

// printLabel prints a transmitter's current label, as the table shows it. An empty name prints
// that there is no label yet and the command that sets one.
func printLabel(app *App, id, name string) error {
	s := app.Style
	if name == "" {
		fmt.Fprintf(app.Stdout, "%s\n", s.Muted(fmt.Sprintf("%s has no label; ley label %s <name> gives it one", id, id)))
		return nil
	}
	fmt.Fprintf(app.Stdout, "%s  %s\n", id, name)
	return nil
}
