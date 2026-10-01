// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"net"
	"slices"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
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
adds the driver, serial and full device id columns. A radio on another
machine joins the list with 'ley devices attach' and leaves it with
'ley devices detach'.

--json prints a ListDevicesResponse; with --watch that line comes first and
each plug or unplug then adds an Event line carrying the full device.`,
		Example: `  ley devices              # is my radio visible?
  ley devices --watch      # print a line on plug and unplug
  ley devices --watch --json   # {"devices":[...]}, then one Event per change
  ley devices attach rtltcp pi.local:1234   # a radio on another machine
  ley devices detach 2     # remove the second listed attached device`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runDevices(cmd, app, watch, wide)
		},
	}
	cmd.Flags().BoolVar(&watch, "watch", false, "keep running and print a line when a radio is plugged in or removed")
	cmd.Flags().BoolVar(&wide, "wide", false, "add the driver, serial and full device id columns")
	cmd.AddCommand(newDevicesAttachCommand(app))
	cmd.AddCommand(newDevicesDetachCommand(app))
	return cmd
}

// newDevicesDetachCommand removes a device a client attached: a file playback device from
// `ley play --persistent`, or a radio `ley devices attach` added. Its capture and channels are
// destroyed with it.
func newDevicesDetachCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "detach <device>",
		Short: "Remove an attached radio or playback file",
		Long: `detach removes a device a client attached -- a radio added with
'ley devices attach', or a file playback device 'ley play --persistent'
left behind -- together with its capture and channels. A remote radio is
forgotten, so the daemon stops re-attaching it at startup. The device can
be given as its id, an unambiguous id prefix, or its row number in
'ley devices'.

A dongle plugged into this machine is found, not attached, so there is
nothing to detach: unplug it, or free it with 'ley stop --all'.`,
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
			// A radio on this machine's USB is discovered by the daemon and
			// cannot be detached by a client. The daemon refuses it too, but
			// checking here saves a round trip and lets the error say how to
			// free the hardware.
			if d.Driver != "file" && d.Driver != "rtltcp" {
				return fmt.Errorf("%s is a real radio (%s), not a playback file; free it with: ley stop --all", d.DeviceId, d.Model)
			}
			if err := c.DetachDevice(ctx, d.DeviceId); err != nil {
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
		if _, ok := ev.Body.(*leylinev1.Event_Device); !ok {
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
	}
	if err := <-errs; err != nil && ctx.Err() == nil {
		return err
	}
	return nil
}

// printDeviceTable renders the devices table. It shows whether each radio is
// usable now and, if not, why, so MODEL comes first and STATE second; ids and
// serials are the columns read least, so they move behind --wide, where the
// full id stays verbatim for `ley devices detach`.
func printDeviceTable(app *App, devices []*leylinev1.DeviceDescriptor, wide bool) {
	s := tableStyle(app)
	cols := []column{
		// MODEL is the key column, so it shrinks only enough to fit a very
		// long name; GAIN and RATES are dropped rather than truncated to
		// nothing, and the footer reports the drop.
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
			absentIfEmpty(s, rangesPhrase(d.TuningRanges)),
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
	// --wide requests every column, so the width budget is off there: a
	// dropped id is what --wide exists to avoid.
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
		hidden := slices.Concat(dropped, []string{"DRIVER", "SERIAL", "ID"})
		fmt.Fprintf(app.Stdout, "%s  %s\n",
			s.Cmd("ley devices --wide"), s.Muted("adds "+strings.Join(hidden, ", ")))
	}
}

// deviceStateCell is the STATE word inked by meaning: green available, yellow
// in use, red disconnected. The word carries the meaning; the colour only
// highlights it.
func deviceStateCell(s ui.Style, d *leylinev1.DeviceDescriptor) string {
	text := deviceStateString(d)
	switch {
	// A playback file is never plugged in, so DISCONNECTED is its normal
	// state, not a fault: it keeps the word but not the red ink.
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

// newDevicesAttachCommand adds a radio the daemon cannot find by itself. The kind is a word
// rather than a flag so a later source (another network protocol, a named pipe) slots in beside
// rtltcp without changing the shape of the command.
func newDevicesAttachCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "attach rtltcp <host:port>",
		Short: "Add a radio another machine is serving",
		Long: `attach adds a dongle served over the network by rtl_tcp -- a Pi on the roof
with an antenna on it -- to the daemon's device list, where it behaves like
any other radio: ley devices shows it, ley tune and ley scan use it. The
daemon remembers it across restarts, so this is done once; the undo is
'ley devices detach'.

The kind is 'rtltcp'. Attaching connects once, so an unreachable host is an
error and nothing is remembered (a radio never reached is usually a typo).
A drop afterwards is not an error: the daemon reconnects to a radio it
knows. Attaching an endpoint already attached prints the radio it has.

The device id is on stdout; --json prints the DeviceDescriptor instead.`,
		Example: `  ley devices attach rtltcp pi.local:1234   # the dongle on the Pi
  ley devices attach rtltcp 10.0.0.5:1234 --json
  ley devices detach 2                     # remove it again, by row number`,
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runDevicesAttach(cmd, app, args[0], args[1])
		},
	}
}

// rtlTCPPort is what rtl_tcp listens on unless it is told otherwise, so it is the port to suggest.
const rtlTCPPort = 1234

func runDevicesAttach(cmd *cobra.Command, app *App, kind, endpoint string) error {
	if kind != "rtltcp" {
		return usageErrorf("%q is not a kind of radio ley can attach; the kinds are: rtltcp", kind)
	}
	host, port, err := parseEndpoint(endpoint)
	if err != nil {
		return usageError(err)
	}
	ctx := cmd.Context()
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	// A second attach of one endpoint hands back the radio the daemon already
	// has, which is correct but needs a different message; the list taken
	// before the call tells the two cases apart, and only the message uses it.
	var before []*leylinev1.DeviceDescriptor
	if !app.JSON {
		resp, lerr := c.Control.ListDevices(ctx, &leylinev1.ListDevicesRequest{})
		if lerr != nil {
			return app.notRunning(lerr)
		}
		before = resp.GetDevices()
	}
	dev, err := c.AttachDevice(ctx, leyline.RtlTCPSource(host, port))
	if err != nil {
		return err
	}
	if app.JSON {
		return app.printJSON(dev)
	}
	// The id is machine output and goes to stdout; the sentence about it is
	// prose for the person, as in ley play.
	fmt.Fprintf(app.Stdout, "device %s\n", dev.DeviceId)
	if hasDevice(before, dev.DeviceId) {
		fmt.Fprintf(app.Stderr, "%s is already attached as %s\n", dev.Model, dev.DeviceId)
		return nil
	}
	fmt.Fprintf(app.Stderr, "attached %s as %s; the daemon remembers it. Forget it with: ley devices detach %s\n",
		dev.Model, dev.DeviceId, detachSelector(ctx, c, dev))
	return nil
}

// parseEndpoint splits host:port, which is how an rtl_tcp server is spelled everywhere else (its
// own command line, the address people paste at each other), and reports a bad value in those
// terms.
func parseEndpoint(endpoint string) (string, uint32, error) {
	host, portText, err := net.SplitHostPort(endpoint)
	if err != nil || host == "" {
		return "", 0, fmt.Errorf("%q is not a host:port; rtl_tcp usually listens on %d, so try: ley devices attach rtltcp pi.local:%d", endpoint, rtlTCPPort, rtlTCPPort)
	}
	port, err := strconv.ParseUint(portText, 10, 32)
	if err != nil || port == 0 || port > 65535 {
		return "", 0, fmt.Errorf("%q is not a port between 1 and 65535; rtl_tcp usually listens on %d", portText, rtlTCPPort)
	}
	return host, uint32(port), nil
}

// hasDevice reports whether this list already contains the device.
func hasDevice(devices []*leylinev1.DeviceDescriptor, id string) bool {
	for _, d := range devices {
		if d.GetDeviceId() == id {
			return true
		}
	}
	return false
}

// detachSelector is what to type to remove this radio again: its row number in ley devices, which
// is shorter than a ULID, and the id itself when the list cannot be read.
func detachSelector(ctx context.Context, c *leyline.Client, dev *leylinev1.DeviceDescriptor) string {
	st, err := c.State(ctx)
	if err != nil {
		return dev.DeviceId
	}
	for i, d := range st.GetDevices() {
		if d.GetDeviceId() == dev.DeviceId {
			return strconv.Itoa(i + 1)
		}
	}
	return dev.DeviceId
}
