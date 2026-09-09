package cli

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func newDevicesCommand(app *App) *cobra.Command {
	var watch, wide bool
	cmd := &cobra.Command{
		Use:   "devices",
		Short: "List the radios the daemon can see",
		Long: `devices lists every radio (SDR) the daemon has found, with its tuning range,
sample rates (how wide a band it can take in at once) and gain elements
(the amplifier stages 'ley set gain' adjusts). An empty list on a terminal
is followed by a checklist of what to try. --watch keeps running and prints
a line whenever a radio is plugged in or removed. Row numbers from this
list are accepted wherever a device id is (ley tune --device 2), and --wide
adds the driver, serial and full device id columns.

--json prints a ListDevicesResponse; with --watch that line comes first and
each plug or unplug then adds an Event line carrying the full device.`,
		Example: `  ley devices              # is my radio visible?
  ley devices --watch      # print a line on plug and unplug
  ley devices --watch --json   # {"devices":[...]}, then one Event per change
  ley devices detach 2     # remove the second listed file playback device`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runDevices(cmd, app, watch, wide)
		},
	}
	cmd.Flags().BoolVar(&watch, "watch", false, "keep running and print a line when a radio is plugged in or removed")
	cmd.Flags().BoolVar(&wide, "wide", false, "add the driver, serial and full device id columns")
	cmd.AddCommand(newDevicesDetachCommand(app))
	return cmd
}

// newDevicesDetachCommand removes a file playback device attached by `ley play` (typically one
// left behind by `ley play --persistent`). Its capture and channels are destroyed with it.
func newDevicesDetachCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "detach <device>",
		Short: "Remove a file playback device left behind by ley play",
		Long: `detach removes a file playback device (one 'ley play --persistent' left
behind) together with its capture and channels. The device can be given as
its id, an unambiguous id prefix, or its row number in 'ley devices'.`,
		Example: `  ley devices detach dev_01J...   # by id
  ley devices detach 2            # the second row of ley devices`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			c, err := app.dial(ctx)
			if err != nil {
				return app.notRunning(err)
			}
			defer c.Close()
			st, err := c.State(ctx)
			if err != nil {
				return app.notRunning(err)
			}
			d, err := leyline.ResolveDevice(st, args[0])
			if err != nil {
				return fmt.Errorf("%w. Run: ley devices", err)
			}
			if d.Driver != "file" {
				return fmt.Errorf("%s is a real radio (%s), not a playback file; free it with: ley stop --all", d.DeviceId, d.Model)
			}
			if _, err := c.Control.DetachFileDevice(ctx, &leylinev1.DetachFileDeviceRequest{DeviceId: d.DeviceId}); err != nil {
				return err
			}
			if app.JSON {
				return app.printJSON(&leylinev1.Empty{})
			}
			fmt.Fprintf(app.Stdout, "detached %s\n", d.DeviceId)
			return nil
		},
	}
}

func runDevices(cmd *cobra.Command, app *App, watch, wide bool) error {
	ctx := cmd.Context()
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	resp, err := c.Control.ListDevices(ctx, &leylinev1.ListDevicesRequest{})
	if err != nil {
		return app.notRunning(err)
	}
	if app.JSON {
		// With --watch the first line is this same ListDevicesResponse; Event
		// lines (each carrying the full DeviceDescriptor) follow it.
		if err := app.printJSON(resp); err != nil {
			return err
		}
	} else {
		printDeviceTable(app, resp.Devices, wide)
		if len(resp.Devices) == 0 && app.IsTTY() {
			fmt.Fprintln(app.Stdout, noDeviceChecklist)
		}
	}
	if !watch {
		return nil
	}
	events, errs, err := c.Events(ctx, nil)
	if err != nil {
		return err
	}
	for ev := range events {
		p, ok := ev.Body.(*leylinev1.Event_Device)
		if !ok {
			continue
		}
		if app.JSON {
			if err := app.printJSON(ev); err != nil {
				return err
			}
			continue
		}
		if !humanEvent(ev) {
			continue
		}
		fmt.Fprintln(app.Stdout, eventLine(ev, nil))
		_ = p
	}
	if err := <-errs; err != nil && ctx.Err() == nil {
		return err
	}
	return nil
}

// printDeviceTable renders the devices table. The reader is asking "is my
// radio usable right now, and if not why not", so MODEL leads and STATE is
// the next thing the eye reaches; the ids and serials that used to occupy
// the two most-scanned columns move behind --wide, where the full id stays
// verbatim for `ley devices detach`.
func printDeviceTable(app *App, devices []*leylinev1.DeviceDescriptor, wide bool) {
	s := tableStyle(app)
	cols := []column{
		// MODEL is the answer, so it shrinks only far enough to survive a
		// pathological name; GAIN and RATES are dropped rather than cut to
		// noise, and the footer says where they went.
		{head: "MODEL", min: 20},
		{head: "STATE"},
		{head: "RANGE"},
		{head: "RATES", drop: 1},
		{head: "GAIN", drop: 2},
	}
	if wide {
		cols = append(cols,
			column{head: "DRIVER"},
			column{head: "SERIAL"},
			column{head: "ID"})
	}
	for _, d := range devices {
		cells := []string{
			d.Model,
			deviceStateCell(s, d),
			deviceRangesString(s, d.TuningRanges),
			ratesString(d.SampleRates),
			gainsString(d.GainElements),
		}
		if wide {
			cells = append(cells, d.Driver, absentIfEmpty(s, d.Serial), s.Muted(d.DeviceId))
		}
		for i := range cells {
			cols[i].cells = append(cols[i].cells, cells[i])
		}
	}
	// --wide is the reader asking for every column, so the width budget is
	// off there: a dropped id is exactly what they went to --wide to avoid.
	if wide {
		s.Width = 0
	}
	dropped, err := printColumns(app.Stdout, s, cols, nil)
	if err != nil {
		return
	}
	if len(devices) == 0 {
		fmt.Fprintln(app.Stdout, s.Muted("(no radios found)"))
		return
	}
	if !wide && app.IsTTY() {
		hidden := append(dropped, "DRIVER", "SERIAL", "ID")
		fmt.Fprintf(app.Stdout, "%s  %s\n",
			s.Cmd("ley devices --wide"), s.Muted("adds "+strings.Join(hidden, ", ")))
	}
}

// deviceStateCell is the STATE word with the ink its meaning already carries:
// green available, yellow in use, red disconnected. The word is the whole
// answer; the colour only helps the eye find it.
func deviceStateCell(s ui.Style, d *leylinev1.DeviceDescriptor) string {
	text := deviceStateString(d)
	switch {
	// A playback file is never plugged in, so DISCONNECTED is its resting
	// state, not a fault: the word stays, the alarm ink does not.
	case d.Driver == "file" && d.State == leylinev1.DeviceState_DISCONNECTED:
		return s.Muted(text)
	case heldExternally(d), d.State == leylinev1.DeviceState_IN_USE:
		return s.Warn(text)
	case d.State == leylinev1.DeviceState_AVAILABLE:
		return s.Ok(text)
	case d.State == leylinev1.DeviceState_DISCONNECTED:
		return s.Err(text)
	}
	return s.Muted(text)
}

// deviceRangesString renders the RANGE column as "24.000 MHz to 1.766 GHz",
// the same spelling `ley bands` uses. A range with one frequency in it (a
// file device plays back one centre) collapses to that frequency rather than
// spending 24 columns saying it twice, and a radio that reports no range at
// all reads as the absent glyph, never as a blank cell.
func deviceRangesString(s ui.Style, rs []*leylinev1.FrequencyRange) string {
	parts := make([]string, 0, len(rs))
	for _, r := range rs {
		if r.MinHz == r.MaxHz {
			parts = append(parts, leyline.FormatFrequency(r.MinHz))
			continue
		}
		parts = append(parts, leyline.FormatFrequency(r.MinHz)+" to "+leyline.FormatFrequency(r.MaxHz))
	}
	if len(parts) == 0 {
		return s.Glyphs().Absent
	}
	return strings.Join(parts, ", ")
}

// absentIfEmpty keeps a table cell from going blank: an absent value is the
// glyph, so "the daemon has no serial" and "this column does not apply" do
// not look like a rendering bug.
func absentIfEmpty(s ui.Style, text string) string {
	if text == "" {
		return s.Glyphs().Absent
	}
	return text
}

// deviceStateString renders the STATE column: the bare enum name, with
// "(other program)" appended when the daemon flags the device held_externally
// so an IN_USE row is not mistaken for one of our own captures.
func deviceStateString(d *leylinev1.DeviceDescriptor) string {
	s := enumName(d.State.String())
	if heldExternally(d) {
		s += " (other program)"
	}
	return s
}
