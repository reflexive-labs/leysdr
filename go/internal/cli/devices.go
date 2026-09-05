package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func newDevicesCommand(app *App) *cobra.Command {
	var watch bool
	cmd := &cobra.Command{
		Use:   "devices",
		Short: "List the radios the daemon can see",
		Long: `devices lists every radio (SDR) the daemon has found, with its tuning range,
sample rates (how wide a band it can take in at once) and gain elements
(the amplifier stages 'ley set gain' adjusts). An empty list on a terminal
is followed by a checklist of what to try. --watch keeps running and prints
a line whenever a radio is plugged in or removed. Row numbers from this
list are accepted wherever a device id is (ley tune --device 2).`,
		Example: `  ley devices              # is my radio visible?
  ley devices --watch      # print a line on plug and unplug
  ley devices detach 2     # remove the second listed file playback device`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runDevices(cmd, app, watch)
		},
	}
	cmd.Flags().BoolVar(&watch, "watch", false, "keep running and print a line when a radio is plugged in or removed")
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

func runDevices(cmd *cobra.Command, app *App, watch bool) error {
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
		if !watch {
			return app.printJSON(resp)
		}
		for _, d := range resp.Devices {
			if err := app.printJSON(d); err != nil {
				return err
			}
		}
	} else {
		printDeviceTable(app, resp.Devices)
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
		fmt.Fprintln(app.Stdout, eventLine(ev, nil))
		_ = p
	}
	if err := <-errs; err != nil && ctx.Err() == nil {
		return err
	}
	return nil
}

func printDeviceTable(app *App, devices []*leylinev1.DeviceDescriptor) {
	w := app.table()
	fmt.Fprintln(w, "ID\tDRIVER\tMODEL\tSERIAL\tSTATE\tRANGE\tRATES\tGAIN")
	for _, d := range devices {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
			d.DeviceId, d.Driver, d.Model, d.Serial, enumName(d.State.String()),
			rangesString(d.TuningRanges), ratesString(d.SampleRates), gainsString(d.GainElements))
	}
	w.Flush()
}
