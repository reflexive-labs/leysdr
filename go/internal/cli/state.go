package cli

import (
	"fmt"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func newStateCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "state",
		Short: "Show everything the daemon knows right now",
		Long: `state prints the daemon's whole picture: the daemon itself, every radio,
every capture (a radio tuned to a band), every channel (one station picked
out of a capture: frequency, mode, squelch) and every sink (where the audio
goes). It is the place to look when something is not doing what you expect,
and 'ley state --json' is the snapshot scripts and agents should read.`,
		Example: `  ley state                # the whole picture, as tables
  ley state --json         # the same as proto3 JSON (GetStateResponse)`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
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
			if app.JSON {
				return app.printJSON(st)
			}
			printState(app, st)
			return nil
		},
	}
}

func daemonLine(d *leylinev1.DaemonInfo) string {
	if d == nil {
		return "daemon: (no info)"
	}
	up := time.Since(time.Unix(0, d.StartedAtNs)).Truncate(time.Second)
	return fmt.Sprintf("daemon %s pid %d up %s socket %s", d.Version, d.Pid, up, d.SocketPath)
}

func printState(app *App, st *leylinev1.GetStateResponse) {
	fmt.Fprintf(app.Stdout, "%s (event seq %d)\n\n", daemonLine(st.Daemon), st.EventSeq)
	fmt.Fprintln(app.Stdout, "Devices")
	printDeviceTable(app, st.Devices)
	fmt.Fprintln(app.Stdout, "\nCaptures")
	w := app.table()
	fmt.Fprintln(w, "ID\tDEVICE\tCENTER\tRATE\tSTATE\tGAINS\tAUDIO SINKS\tCREATED BY")
	for _, c := range st.Captures {
		gains := "-"
		if len(c.Gains) > 0 {
			gains = ""
			for i, g := range c.Gains {
				if i > 0 {
					gains += ","
				}
				if g.Auto {
					gains += g.Element + "=auto"
				} else {
					gains += fmt.Sprintf("%s=%gdB", g.Element, g.Db)
				}
			}
		}
		sinks := uint32(0)
		if c.Activity != nil {
			sinks = c.Activity.LiveAudioSinks
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", c.CaptureId, c.DeviceId, leyline.FormatFrequency(c.CenterHz),
			ratesString([]uint64{c.SampleRate}), enumName(c.State.String()), gains, sinks, clientString(c.CreatedBy))
	}
	w.Flush()
	fmt.Fprintln(app.Stdout, "\nChannels")
	w = app.table()
	fmt.Fprintln(w, "ID\tCAPTURE\tFREQ\tOFFSET\tMODE\tBW\tSQUELCH\tSTATE\tPERSISTENT\tOWNER")
	for _, ch := range st.Channels {
		freq := "-"
		if _, ok := leyline.ChannelFrequency(st, ch); ok {
			freq = channelFreqLabel(st, ch)
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%+d\t%s\t%d\t%s\t%s\t%v\t%s\n", ch.ChannelId, ch.CaptureId, freq, ch.OffsetHz,
			leyline.ModeName(ch.Mode), ch.BandwidthHz, squelchString(ch.SquelchDb), enumName(ch.State.String()), ch.Persistent, clientString(ch.Owner))
	}
	w.Flush()
	fmt.Fprintln(app.Stdout, "\nSinks")
	w = app.table()
	fmt.Fprintln(w, "ID\tCHANNEL\tKIND\tDETAIL")
	for _, s := range st.Sinks {
		kind, detail := "?", ""
		switch k := s.Kind.(type) {
		case *leylinev1.Sink_SystemAudio:
			kind, detail = "system_audio", fmt.Sprintf("volume %.2f %s", k.SystemAudio.GetVolume(), k.SystemAudio.AudioDeviceUid)
		case *leylinev1.Sink_Stream:
			kind, detail = "stream", k.Stream.StreamId
		case *leylinev1.Sink_File:
			kind, detail = "file", fmt.Sprintf("%s %s", k.File.Kind, k.File.ResourceUri)
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", s.SinkId, s.ChannelId, kind, detail)
	}
	w.Flush()
}
