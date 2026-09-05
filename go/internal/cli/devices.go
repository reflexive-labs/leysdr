package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

func newDevicesCommand(app *App) *cobra.Command {
	var watch bool
	cmd := &cobra.Command{
		Use:   "devices",
		Short: "List SDR devices known to the daemon",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runDevices(cmd, app, watch)
		},
	}
	cmd.Flags().BoolVar(&watch, "watch", false, "keep running and print device events (hot-plug)")
	cmd.AddCommand(newDevicesDetachCommand(app))
	return cmd
}

// newDevicesDetachCommand removes a file playback device attached by `ley play` (typically one
// left behind by `ley play --persistent`). Its capture and channels are destroyed with it.
func newDevicesDetachCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "detach <device-id>",
		Short: "Detach a file playback device (destroys its capture and channels)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			c, err := app.dial(ctx)
			if err != nil {
				return app.notRunning(err)
			}
			defer c.Close()
			if _, err := c.Control.DetachFileDevice(ctx, &leylinev1.DetachFileDeviceRequest{DeviceId: args[0]}); err != nil {
				return err
			}
			if app.JSON {
				return app.printJSON(&leylinev1.Empty{})
			}
			fmt.Fprintf(app.Stdout, "detached %s\n", args[0])
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
