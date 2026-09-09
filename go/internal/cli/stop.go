package cli

import (
	"context"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func newStopCommand(app *App) *cobra.Command {
	var all bool
	var deviceSel string
	cmd := &cobra.Command{
		Use:   "stop [channel|all]",
		Short: "Stop a channel, or everything on the radio (which frees it)",
		Long: `stop removes a channel the radio is decoding: one left running by
'ley tune --persistent' or 'ley play --persistent', or one another client
made. With no argument it picks the channel the way set does: the only
active one, else the channel a ley command made when exactly one active
channel is ley-made, else it lists them. A channel can be named by id, id
prefix, row number from 'ley state' or frequency.

'ley stop all' (or --all) removes every channel on one radio and the
capture that holds it, so the radio is free for another program. With
several radios in use, --device says which.`,
		Example: `  ley stop                  the channel ley left running
  ley stop 146.62           the channel on that frequency
  ley stop 2                row 2 of ley state
  ley stop all              everything; the radio is free afterwards
  ley stop --all --device 2`,
		GroupID: GroupAdjusting,
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sel := ""
			if len(args) == 1 {
				sel = args[0]
				if strings.EqualFold(sel, "all") {
					all, sel = true, ""
				}
			}
			if all && sel != "" {
				return usageErrorf("stop --all takes no channel; drop %q or the flag", sel)
			}
			if deviceSel != "" && !all {
				return usageErrorf("--device only goes with --all (or 'stop all'); to stop one channel name it: ley stop 146.52")
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			if all {
				return stopAll(cmd.Context(), s, deviceSel)
			}
			ch, cap, err := resolveTarget(s, sel, "", stopTarget)
			if err != nil {
				return err
			}
			return stopChannel(cmd.Context(), s, ch, cap)
		},
	}
	cmd.Flags().BoolVar(&all, "all", false, "stop every channel on the radio and free it (same as 'ley stop all')")
	cmd.Flags().StringVar(&deviceSel, "device", "", "with --all: which radio, when several are in use (id, prefix, row number from 'ley devices' or frequency)")
	return cmd
}

// stopChannel destroys one channel and says what happened. The capture stays
// (another channel or a spectrum watcher may use it); the line says how to
// free the radio when the channel was the last one on it.
func stopChannel(ctx context.Context, s *session, ch *leylinev1.Channel, cap *leylinev1.Capture) error {
	if ch == nil {
		return fmt.Errorf("nothing to stop; ley state lists what is running")
	}
	st := s.app.Style
	desc := fmt.Sprintf("%s %s %s", channelFreqLabel(s.state, ch), strings.ToUpper(leyline.ModeName(ch.Mode)),
		st.Muted(fmt.Sprintf("(channel %d, %s)", channelRow(s.state, ch), ch.ChannelId)))
	resp, err := s.client.Control.DestroyChannel(ctx, &leylinev1.DestroyChannelRequest{ChannelId: ch.ChannelId})
	if err != nil {
		return err
	}
	if s.app.JSON {
		// The daemon's Empty answer: the object is gone, so nothing stale is echoed.
		return s.app.printJSON(resp)
	}
	others := 0
	for _, c := range s.state.Channels {
		if c.CaptureId == ch.CaptureId && c.ChannelId != ch.ChannelId {
			others++
		}
	}
	if others == 0 && cap != nil {
		// The outcome reads alone; the caveat -- the channel is gone but the
		// hardware is still held -- is a footnote on its own line rather
		// than the middle clause of a 118-character sentence.
		fmt.Fprintf(s.app.Stdout, "stopped %s\n", desc)
		fmt.Fprintf(s.app.Stdout, "%s %s\n", st.Muted("the radio stays tuned, free it with:"), st.Cmd("ley stop --all"))
		return nil
	}
	fmt.Fprintf(s.app.Stdout, "stopped %s\n", desc)
	return nil
}

// stopAll destroys every channel on one device and its captures, freeing the
// radio. Without --device the device is the one in use; several in use need
// the flag.
func stopAll(ctx context.Context, s *session, deviceSel string) error {
	st := s.state
	var dev *leylinev1.DeviceDescriptor
	if deviceSel != "" {
		d, err := leyline.ResolveDevice(st, deviceSel)
		if err != nil {
			return fmt.Errorf("--device: %w. Run: ley devices", err)
		}
		dev = d
	} else {
		var inUse []*leylinev1.DeviceDescriptor
		for _, d := range st.Devices {
			if leyline.FindCapture(st, d.DeviceId) != nil {
				inUse = append(inUse, d)
			}
		}
		switch len(inUse) {
		case 0:
			s.stopNothing("nothing is running; every radio is free")
			return nil
		case 1:
			dev = inUse[0]
		default:
			// The rows say what each radio is doing: two dongles of the same
			// model differ by the frequency they are on, not by their ids.
			lines := make([]string, 0, len(inUse))
			for _, d := range inUse {
				for i, all := range st.Devices {
					if all.DeviceId == d.DeviceId {
						lines = append(lines, fmt.Sprintf("  %d  %s  %s  %s", i+1, d.Model, deviceDoing(st, d), d.DeviceId))
					}
				}
			}
			return fmt.Errorf("%d radios are in use; say which with --device:\n%s\ne.g. ley stop --all --device 1", len(inUse), strings.Join(lines, "\n"))
		}
	}
	var caps []*leylinev1.Capture
	for _, c := range st.Captures {
		if c.DeviceId == dev.DeviceId {
			caps = append(caps, c)
		}
	}
	if len(caps) == 0 {
		s.stopNothing(fmt.Sprintf("nothing is running on %s (%s); it is free", dev.Model, dev.DeviceId))
		return nil
	}
	stopped := 0
	for _, cap := range caps {
		for _, ch := range st.Channels {
			if ch.CaptureId != cap.CaptureId {
				continue
			}
			if _, err := s.client.Control.DestroyChannel(ctx, &leylinev1.DestroyChannelRequest{ChannelId: ch.ChannelId}); err != nil && leyline.Code(err) != leyline.CodeChannelNotFound {
				return err
			}
			stopped++
		}
		if _, err := s.client.Control.DestroyCapture(ctx, &leylinev1.DestroyCaptureRequest{CaptureId: cap.CaptureId}); err != nil && leyline.Code(err) != leyline.CodeCaptureNotFound {
			return err
		}
	}
	if s.app.JSON {
		// One Empty for the whole action, as the daemon answers each destroy.
		return s.app.printJSON(&leylinev1.Empty{})
	}
	noun := "channels"
	if stopped == 1 {
		noun = "channel"
	}
	sty := s.app.Style
	fmt.Fprintf(s.app.Stdout, "stopped %d %s and %s %s %s\n", stopped, noun, sty.Ok("freed"), dev.Model, sty.Muted("("+dev.DeviceId+")"))
	return nil
}

// deviceDoing describes what one radio is playing, for a picker whose rows
// would otherwise differ only by an id: the frequency and mode of its first
// channel, and how many others ride with it. It is plain text -- these rows
// live inside an error message, which takes no ink (docs/cli-style.md 6).
func deviceDoing(st *leylinev1.GetStateResponse, d *leylinev1.DeviceDescriptor) string {
	var chs []*leylinev1.Channel
	for _, c := range st.Captures {
		if c.DeviceId != d.DeviceId {
			continue
		}
		for _, ch := range st.Channels {
			if ch.CaptureId == c.CaptureId {
				chs = append(chs, ch)
			}
		}
	}
	if len(chs) == 0 {
		return "tuned, no channels"
	}
	doing := fmt.Sprintf("%s %s", channelFreqLabel(st, chs[0]), strings.ToUpper(leyline.ModeName(chs[0].Mode)))
	if len(chs) > 1 {
		doing += fmt.Sprintf(" and %s", plural(len(chs)-1, "other channel"))
	}
	return doing
}

// stopNothing reports that stop --all found nothing to do. The sentence is
// for a person, so it goes to stderr and is dropped under --json; either way
// the exit status is 0 (a free radio is the state stop --all asks for).
func (s *session) stopNothing(msg string) {
	if s.app.JSON {
		return
	}
	fmt.Fprintln(s.app.Stderr, msg)
}
