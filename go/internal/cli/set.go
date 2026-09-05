package cli

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func newSetCommand(app *App) *cobra.Command {
	var channelID, captureID, element string
	cmd := &cobra.Command{
		Use:   "set <param> <value>",
		Short: "Live-adjust a channel or capture parameter",
		Long: `set streams one WriteParams call and waits (up to 2 s) for the daemon's
confirming event. Parameters:

  freq <hz>        move the channel; retunes the capture centre when the new
                   frequency falls outside the capture span (offset becomes 0)
  gain <dB|auto>   capture gain (--element selects the gain element)
  squelch <dB|off> channel squelch threshold in dBFS
  bw <hz>          channel bandwidth
  mode <mode>      nfm|am|wfm|usb|lsb|cw
  volume <0..1>    the channel's system-audio sink volume

The target is --channel/--capture, else the single active channel.`,
		Args:               cobra.ArbitraryArgs,
		DisableFlagParsing: true, // negative values ("-40") must not read as flags
		RunE: func(cmd *cobra.Command, raw []string) error {
			args, err := parseNegativeSafe(cmd, raw)
			if err != nil || args == nil {
				return err
			}
			if len(args) != 2 {
				return fmt.Errorf("set needs exactly <param> <value>, got %d args", len(args))
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			return runSet(cmd.Context(), s, args[0], args[1], channelID, captureID, element)
		},
	}
	cmd.Flags().StringVar(&channelID, "channel", "", "target channel ID (default: the single active channel)")
	cmd.Flags().StringVar(&captureID, "capture", "", "target capture ID (freq/gain; default: the channel's capture)")
	cmd.Flags().StringVar(&element, "element", "", "gain element name (default: the device's first)")
	return cmd
}

// resolveTarget picks the channel (and its capture) a set applies to.
func resolveTarget(st *leylinev1.GetStateResponse, channelID, captureID string) (*leylinev1.Channel, *leylinev1.Capture, error) {
	var ch *leylinev1.Channel
	if channelID != "" {
		if ch = channelByID(st, channelID); ch == nil {
			return nil, nil, fmt.Errorf("%s: channel %s not found", leyline.CodeChannelNotFound, channelID)
		}
	} else {
		var active []*leylinev1.Channel
		for _, c := range st.Channels {
			if c.State == leylinev1.ChannelState_CHANNEL_ACTIVE && (captureID == "" || c.CaptureId == captureID) {
				active = append(active, c)
			}
		}
		switch len(active) {
		case 1:
			ch = active[0]
		case 0:
			if captureID == "" {
				return nil, nil, fmt.Errorf("no active channel; use --channel or --capture")
			}
		default:
			ids := make([]string, 0, len(active))
			for _, c := range active {
				ids = append(ids, fmt.Sprintf("%s (%s %s)", c.ChannelId, leyline.ModeName(c.Mode), leyline.FormatFrequency(channelFreq(c, captureByID(st, c.CaptureId)))))
			}
			return nil, nil, fmt.Errorf("%d active channels; pick one with --channel: %s", len(active), strings.Join(ids, ", "))
		}
	}
	var cap *leylinev1.Capture
	if captureID != "" {
		if cap = captureByID(st, captureID); cap == nil {
			return nil, nil, fmt.Errorf("%s: capture %s not found", leyline.CodeCaptureNotFound, captureID)
		}
	} else if ch != nil {
		cap = captureByID(st, ch.CaptureId)
	}
	return ch, cap, nil
}

// buildWrites turns (param, value) into the ParamWrites and a predicate that
// recognises the confirming event.
func buildWrites(s *session, param, value, element string, ch *leylinev1.Channel, cap *leylinev1.Capture) ([]*leylinev1.ParamWrite, func(*leylinev1.Event) bool, error) {
	needChannel := func() error {
		if ch == nil {
			return fmt.Errorf("set %s needs a channel; use --channel", param)
		}
		return nil
	}
	needCapture := func() error {
		if cap == nil {
			return fmt.Errorf("set %s needs a capture; use --capture", param)
		}
		return nil
	}
	switch param {
	case "freq":
		hz, err := leyline.ParseFrequency(value)
		if err != nil {
			return nil, nil, err
		}
		if err := needCapture(); err != nil {
			return nil, nil, err
		}
		if ch == nil {
			w := &leylinev1.ParamWrite{Tag: 1, TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_CenterHz{CenterHz: hz}}
			return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
				c, ok := ev.Body.(*leylinev1.Event_Capture)
				return ok && c.Capture.CaptureId == cap.CaptureId && c.Capture.CenterHz == hz
			}, nil
		}
		offset := int64(hz) - int64(cap.CenterHz)
		if covers(cap, hz, ch.BandwidthHz) {
			w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_OffsetHz{OffsetHz: offset}}
			return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
				c, ok := ev.Body.(*leylinev1.Event_Channel)
				return ok && c.Channel.ChannelId == ch.ChannelId && c.Channel.OffsetHz == offset
			}, nil
		}
		if !s.app.JSON {
			fmt.Fprintf(s.app.Stdout, "retuning capture %s to %s (channel offset 0)\n", cap.CaptureId, leyline.FormatFrequency(hz))
		}
		ws := []*leylinev1.ParamWrite{
			{Tag: 1, TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_CenterHz{CenterHz: hz}},
			{Tag: 2, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_OffsetHz{OffsetHz: 0}},
		}
		return ws, func(ev *leylinev1.Event) bool {
			// Either order of the two confirmations may arrive first; judge the mirror.
			switch ev.Body.(type) {
			case *leylinev1.Event_Channel, *leylinev1.Event_Capture:
				return channelByID(s.state, ch.ChannelId).GetOffsetHz() == 0 && captureByID(s.state, cap.CaptureId).GetCenterHz() == hz
			}
			return false
		}, nil
	case "gain":
		db, auto, err := leyline.ParseGain(value)
		if err != nil {
			return nil, nil, err
		}
		if err := needCapture(); err != nil {
			return nil, nil, err
		}
		// The daemon snaps to the element's discrete table (valid_db) or step
		// grid; mirror that here so the confirmation predicate matches the value
		// the daemon will actually report.
		tol := 1.0
		for _, d := range s.state.Devices {
			if d.DeviceId != cap.DeviceId {
				continue
			}
			if element == "" && len(d.GainElements) > 0 {
				element = d.GainElements[0].Name
			}
			for _, el := range d.GainElements {
				if el.Name == element && !auto {
					db, tol = snapGain(el, db)
				}
			}
		}
		if element == "" {
			return nil, nil, fmt.Errorf("device %s has no gain elements", cap.DeviceId)
		}
		g := &leylinev1.GainWrite{Element: element}
		if auto {
			g.Value = &leylinev1.GainWrite_Auto{Auto: true}
		} else {
			g.Value = &leylinev1.GainWrite_Db{Db: db}
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: g}}
		return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
			c, ok := ev.Body.(*leylinev1.Event_Capture)
			if !ok || c.Capture.CaptureId != cap.CaptureId {
				return false
			}
			for _, gs := range c.Capture.Gains {
				if gs.Element == element && (auto && gs.Auto || !auto && !gs.Auto && math.Abs(gs.Db-db) <= tol) {
					return true
				}
			}
			return false
		}, nil
	case "squelch":
		db, err := leyline.ParseSquelch(value)
		if err != nil {
			return nil, nil, err
		}
		if err := needChannel(); err != nil {
			return nil, nil, err
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: db}}
		return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
			c, ok := ev.Body.(*leylinev1.Event_Channel)
			return ok && c.Channel.ChannelId == ch.ChannelId && (leyline.SquelchOff(db) && leyline.SquelchOff(c.Channel.SquelchDb) || c.Channel.SquelchDb == db)
		}, nil
	case "bw":
		hz, err := leyline.ParseFrequency(value)
		if err != nil {
			return nil, nil, err
		}
		if err := needChannel(); err != nil {
			return nil, nil, err
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_BandwidthHz{BandwidthHz: uint32(hz)}}
		return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
			c, ok := ev.Body.(*leylinev1.Event_Channel)
			return ok && c.Channel.ChannelId == ch.ChannelId && c.Channel.BandwidthHz == uint32(hz)
		}, nil
	case "mode":
		m, err := leyline.ParseMode(value)
		if err != nil {
			return nil, nil, err
		}
		if err := needChannel(); err != nil {
			return nil, nil, err
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_Mode{Mode: m}}
		return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
			c, ok := ev.Body.(*leylinev1.Event_Channel)
			return ok && c.Channel.ChannelId == ch.ChannelId && c.Channel.Mode == m
		}, nil
	case "volume":
		v, err := strconv.ParseFloat(value, 64)
		if err != nil || v < 0 || v > 1 {
			return nil, nil, fmt.Errorf("volume must be a number within 0..1")
		}
		if err := needChannel(); err != nil {
			return nil, nil, err
		}
		var sink *leylinev1.Sink
		for _, sk := range s.state.Sinks {
			if _, ok := sk.Kind.(*leylinev1.Sink_SystemAudio); ok && sk.ChannelId == ch.ChannelId {
				sink = sk
			}
		}
		if sink == nil {
			return nil, nil, fmt.Errorf("%s: channel %s has no system-audio sink", leyline.CodeSinkNotFound, ch.ChannelId)
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: sink.SinkId, Param: &leylinev1.ParamWrite_SinkVolume{SinkVolume: v}}
		return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
			c, ok := ev.Body.(*leylinev1.Event_Sink)
			return ok && c.Sink.SinkId == sink.SinkId && c.Sink.GetSystemAudio().GetVolume() == v
		}, nil
	}
	return nil, nil, fmt.Errorf("unknown param %q (freq|gain|squelch|bw|mode|volume)", param)
}

// runSet writes, waits for confirmation (or a rejection) and prints the result.
func runSet(ctx context.Context, s *session, param, value, channelID, captureID, element string) error {
	ch, cap, err := resolveTarget(s.state, channelID, captureID)
	if err != nil {
		return err
	}
	writes, confirmed, err := buildWrites(s, param, value, element, ch, cap)
	if err != nil {
		return err
	}
	sum, err := s.client.WriteParams(ctx, writes...)
	if err != nil {
		return err
	}
	rejected := sum.GetWritesApplied() < sum.GetWritesReceived()
	ev, err := s.awaitEvent(ctx, func(ev *leylinev1.Event) bool {
		if r, ok := ev.Body.(*leylinev1.Event_WriteRejected); ok && s.mine(ev) {
			for _, w := range writes {
				if w.Tag == r.WriteRejected.Tag {
					return true
				}
			}
		}
		// The summary already says a write was rejected: only its reason is awaited.
		return !rejected && confirmed(ev)
	})
	if err != nil {
		if rejected {
			return fmt.Errorf("rejected: %d of %d writes applied (no WriteRejected reason observed)", sum.GetWritesApplied(), sum.GetWritesReceived())
		}
		return err
	}
	if s.app.JSON {
		return s.app.printJSON(ev)
	}
	if r, ok := ev.Body.(*leylinev1.Event_WriteRejected); ok {
		return fmt.Errorf("rejected: %s: %s", r.WriteRejected.Error.GetCode(), r.WriteRejected.Error.GetMessage())
	}
	fmt.Fprintln(s.app.Stdout, eventLine(ev, s.state))
	return nil
}

// parseNegativeSafe parses flags for a command that disabled Cobra's flag
// parsing so negative numbers stay positional. It returns nil args after
// printing help for -h/--help.
func parseNegativeSafe(cmd *cobra.Command, raw []string) ([]string, error) {
	const marker = "\x00neg"
	var negatives []string
	flagArgs := make([]string, 0, len(raw))
	for _, a := range raw {
		if len(a) > 1 && a[0] == '-' && a[1] >= '0' && a[1] <= '9' {
			negatives = append(negatives, a)
			flagArgs = append(flagArgs, marker)
			continue
		}
		if a == "-h" || a == "--help" {
			return nil, cmd.Help()
		}
		flagArgs = append(flagArgs, a)
	}
	_ = cmd.InheritedFlags() // merges persistent flags into cmd.Flags()
	if err := cmd.Flags().Parse(flagArgs); err != nil {
		return nil, err
	}
	args := cmd.Flags().Args()
	for i, a := range args {
		if a == marker && len(negatives) > 0 {
			args[i], negatives = negatives[0], negatives[1:]
		}
	}
	return args, nil
}

// snapGain mirrors the daemon's gain quantisation (control.proto GainElement):
// a non-empty valid_db table snaps to the nearest entry, else step_db > 0
// snaps to the grid clamped to [min_db, max_db], else the value passes through.
// The returned tolerance is what the confirmation predicate should accept.
func snapGain(el *leylinev1.GainElement, db float64) (float64, float64) {
	const eps = 0.05
	if len(el.ValidDb) > 0 {
		best := el.ValidDb[0]
		for _, v := range el.ValidDb {
			if math.Abs(v-db) < math.Abs(best-db) {
				best = v
			}
		}
		return best, eps
	}
	if el.StepDb > 0 {
		db = math.Min(math.Max(db, el.MinDb), el.MaxDb)
		return el.MinDb + math.Round((db-el.MinDb)/el.StepDb)*el.StepDb, el.StepDb/2 + eps
	}
	return db, 1.0
}
