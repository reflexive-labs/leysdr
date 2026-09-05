package cli

import (
	"context"
	"fmt"
	"math"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// setParam describes one adjustable parameter: its help line and the forms a
// value may take (quoted back in every parse error).
type setParam struct {
	name, help, forms string
}

// setParams is the parameter table, in help order.
var setParams = []setParam{
	{"freq", "move to a frequency; retunes the radio when it is out of the current span", "146.52 (MHz), 1010k, 146520000"},
	{"mode", "how to decode", "nfm, am, wfm, usb, lsb, cw, fm, ssb"},
	{"bw", "channel bandwidth", "12.5 (kHz), 200k, 12500"},
	{"squelch", "mute the audio when the signal is weaker than this level", "-40, -40dB, off, auto"},
	{"gain", "radio gain (--element picks the gain stage)", "30, 30dB, auto"},
	{"volume", "speaker volume", "0.5, 50%"},
}

func setParamByName(name string) *setParam {
	for i := range setParams {
		if setParams[i].name == name {
			return &setParams[i]
		}
	}
	return nil
}

// setParamList renders the table for help and errors.
func setParamList() string {
	var b strings.Builder
	for _, p := range setParams {
		fmt.Fprintf(&b, "  %-8s %s (%s)\n", p.name, p.help, p.forms)
	}
	return strings.TrimRight(b.String(), "\n")
}

func newSetCommand(app *App) *cobra.Command {
	var channelSel, captureSel, element string
	cmd := &cobra.Command{
		Use:   "set [parameter value]",
		Short: "Adjust what is playing, while it plays",
		Long: `set changes one setting of the channel that is playing and reports the value
the radio actually applied. With no arguments it shows the current settings.

Parameters:
` + setParamList() + `

Which channel (a channel is one station picked out of what the radio hears:
frequency, mode, squelch): the only active one; among several, the one a
ley command made when there is just one, and set says which; otherwise
--channel with an id, id prefix, row number from 'ley state' or frequency.
--capture targets a capture (the radio's tuning and gain) directly for freq
and gain. Longer explanations: ley help squelch, modes, gain.`,
		Example: `  ley set                    show the current settings
  ley set squelch -45        mute below -45 dBFS
  ley set squelch auto       measure the noise floor and sit 10 dB above it
  ley set gain 30
  ley set freq 146.62
  ley set volume 50%
  ley set mode am --channel 2`,
		GroupID: GroupAdjusting,
		Args:    cobra.ArbitraryArgs,
		// Cobra would read "-40" as a flag; parsing is disabled here and
		// parseNegativeSafe does it instead. Confined to set on purpose:
		// it is the only verb whose positionals are commonly negative.
		DisableFlagParsing: true,
		RunE: func(cmd *cobra.Command, raw []string) error {
			args, err := parseNegativeSafe(cmd, raw)
			if err != nil || args == nil {
				return err
			}
			switch {
			case len(args) == 1:
				if p := setParamByName(args[0]); p != nil {
					return fmt.Errorf("set %s needs a value (%s): ley set %s %s", p.name, p.forms, p.name, strings.Split(p.forms, ",")[0])
				}
				return unknownParam(args[0])
			case len(args) > 2:
				return fmt.Errorf("set takes one parameter and one value, got %d words; e.g. ley set squelch -40", len(args))
			case len(args) == 2 && setParamByName(args[0]) == nil:
				return unknownParam(args[0])
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			ch, cap, err := resolveTarget(s, channelSel, captureSel)
			if err != nil {
				return err
			}
			if len(args) == 0 {
				return showSettings(s, ch, cap)
			}
			return runSet(cmd.Context(), s, args[0], args[1], element, ch, cap)
		},
	}
	cmd.Flags().StringVar(&channelSel, "channel", "", "which channel: an id (chan_...), id prefix, row number from 'ley state' or frequency, e.g. --channel 146.62 (default: the active one)")
	cmd.Flags().StringVar(&captureSel, "capture", "", "which capture (a radio tuned to a band), for freq and gain: id, prefix, row number or frequency (default: the channel's)")
	cmd.Flags().StringVar(&element, "element", "", "which gain stage, for radios with more than one; names from 'ley devices', e.g. --element IF (default: the radio's first)")
	return cmd
}

// unknownParam is the error for a parameter name that is not in the table.
func unknownParam(name string) error {
	return fmt.Errorf("%q is not a setting. Settings:\n%s", name, setParamList())
}

// resolveTarget picks the channel (and its capture) a set applies to. With
// no selector: one active channel → it; several → the one a cli client made
// most recently, when exactly one channel is cli-owned (the rest belong to
// the app, an agent or a job), and the choice is printed; otherwise a
// numbered list. Selectors accept an id, id prefix, row number or frequency.
func resolveTarget(s *session, channelSel, captureSel string) (*leylinev1.Channel, *leylinev1.Capture, error) {
	st := s.state
	var ch *leylinev1.Channel
	var cap *leylinev1.Capture
	var err error
	if captureSel != "" {
		if cap, err = leyline.ResolveCapture(st, captureSel); err != nil {
			return nil, nil, fmt.Errorf("--capture: %w", err)
		}
	}
	if channelSel != "" {
		if ch, err = leyline.ResolveChannel(st, channelSel); err != nil {
			return nil, nil, fmt.Errorf("--channel: %w", err)
		}
	} else {
		var active []*leylinev1.Channel
		for _, c := range st.Channels {
			if c.State == leylinev1.ChannelState_CHANNEL_ACTIVE && (cap == nil || c.CaptureId == cap.CaptureId) {
				active = append(active, c)
			}
		}
		switch len(active) {
		case 1:
			ch = active[0]
		case 0:
			if cap == nil {
				return nil, nil, fmt.Errorf("nothing is playing; start with: ley tune 146.52 (or pick a channel with --channel)")
			}
		default:
			var cli []*leylinev1.Channel
			for _, c := range active {
				if c.GetOwner().GetKind() == "cli" {
					cli = append(cli, c)
				}
			}
			if len(cli) != 1 {
				return nil, nil, fmt.Errorf("%d channels are playing; pick one with --channel:\n%s\ne.g. ley set squelch -40 --channel 2", len(active), channelTable(st, active))
			}
			ch = cli[0]
			s.say("using channel %d, %s (the one ley made most recently)\n", channelRow(st, ch), channelSummary(st, ch))
		}
	}
	if cap == nil && ch != nil {
		cap = captureByID(st, ch.CaptureId)
	}
	return ch, cap, nil
}

// channelRow is the 1-based row of ch in the state's channel list (the
// number --channel accepts).
func channelRow(st *leylinev1.GetStateResponse, ch *leylinev1.Channel) int {
	for i, c := range st.Channels {
		if c.ChannelId == ch.ChannelId {
			return i + 1
		}
	}
	return 0
}

// channelSummary renders "146.520 MHz NFM, chan_… (cli:ley)".
func channelSummary(st *leylinev1.GetStateResponse, ch *leylinev1.Channel) string {
	owner := "no owner"
	if o := ch.GetOwner(); o != nil {
		owner = o.Kind + ":" + o.Label
	}
	return fmt.Sprintf("%s %s, %s (%s)", leyline.FormatFrequency(channelFreq(ch, captureByID(st, ch.CaptureId))), strings.ToUpper(leyline.ModeName(ch.Mode)), ch.ChannelId, owner)
}

// channelTable renders a numbered list of channels using state row numbers.
func channelTable(st *leylinev1.GetStateResponse, chs []*leylinev1.Channel) string {
	lines := make([]string, 0, len(chs))
	for _, c := range chs {
		lines = append(lines, fmt.Sprintf("  %d  %s", channelRow(st, c), channelSummary(st, c)))
	}
	return strings.Join(lines, "\n")
}

// showSettings prints the target channel's current values (the proto3 JSON
// of the channel under --json).
func showSettings(s *session, ch *leylinev1.Channel, cap *leylinev1.Capture) error {
	if ch == nil {
		return fmt.Errorf("no channel to show; ley state lists captures and channels")
	}
	if s.app.JSON {
		return s.app.printJSON(ch)
	}
	hz := channelFreq(ch, cap)
	freq := leyline.FormatFrequency(hz)
	if b := leyline.BandFor(hz); b != nil {
		freq += " (" + b.Name + ")"
	}
	squelch := "off (audio always on)"
	if !leyline.SquelchOff(ch.SquelchDb) {
		squelch = fmt.Sprintf("%.0f dBFS", ch.SquelchDb)
	}
	volume := "no speaker sink"
	for _, sk := range s.state.Sinks {
		if sa, ok := sk.Kind.(*leylinev1.Sink_SystemAudio); ok && sk.ChannelId == ch.ChannelId {
			volume = fmt.Sprintf("%.0f%%", sa.SystemAudio.Volume*100)
		}
	}
	model := "unknown radio"
	if cap != nil {
		for _, d := range s.state.Devices {
			if d.DeviceId == cap.DeviceId {
				model = d.Model
			}
		}
	}
	fmt.Fprintf(s.app.Stdout, "channel %s on %s\n  frequency  %s\n  mode       %s\n  bandwidth  %s\n  squelch    %s\n  gain       %s\n  volume     %s\nchange one with: ley set squelch -50 · ley set gain 30 · ley set freq 146.62\n",
		ch.ChannelId, model, freq, strings.ToUpper(leyline.ModeName(ch.Mode)), leyline.FormatFrequency(uint64(ch.BandwidthHz)), squelch, strings.TrimPrefix(gainString(cap), "gain "), volume)
	return nil
}

// paramErr wraps a parse failure with the parameter's accepted forms.
func paramErr(name string, err error) error {
	p := setParamByName(name)
	return fmt.Errorf("%s: %w; accepted: %s", name, err, p.forms)
}

// buildWrites turns (param, value) into the ParamWrites and a predicate that
// recognises the confirming event. hz is the frequency the write concerns
// (for friendly out-of-range errors), 0 when none.
func buildWrites(ctx context.Context, s *session, param, value, element string, ch *leylinev1.Channel, cap *leylinev1.Capture) (writes []*leylinev1.ParamWrite, confirmed func(*leylinev1.Event) bool, hz uint64, err error) {
	needChannel := func() error {
		if ch == nil {
			return fmt.Errorf("set %s needs a channel; pick one with --channel", param)
		}
		return nil
	}
	needCapture := func() error {
		if cap == nil {
			return fmt.Errorf("set %s needs a capture; pick one with --capture", param)
		}
		return nil
	}
	switch param {
	case "freq":
		hz, err = leyline.ParseUserFrequency(value)
		if err != nil {
			return nil, nil, 0, paramErr(param, err)
		}
		if err := needCapture(); err != nil {
			return nil, nil, 0, err
		}
		if s.device == nil {
			for _, d := range s.state.Devices {
				if d.DeviceId == cap.DeviceId {
					s.device = d
				}
			}
		}
		if ch == nil || !covers(cap, hz, ch.BandwidthHz) {
			if err := s.checkRange(value, hz); err != nil {
				return nil, nil, 0, err
			}
		}
		if ch == nil {
			w := &leylinev1.ParamWrite{Tag: 1, TargetId: cap.CaptureId, Param: &leylinev1.ParamWrite_CenterHz{CenterHz: hz}}
			return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
				c, ok := ev.Body.(*leylinev1.Event_Capture)
				return ok && c.Capture.CaptureId == cap.CaptureId && c.Capture.CenterHz == hz
			}, hz, nil
		}
		offset := int64(hz) - int64(cap.CenterHz)
		if covers(cap, hz, ch.BandwidthHz) {
			w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_OffsetHz{OffsetHz: offset}}
			return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
				c, ok := ev.Body.(*leylinev1.Event_Channel)
				return ok && c.Channel.ChannelId == ch.ChannelId && c.Channel.OffsetHz == offset
			}, hz, nil
		}
		s.say("retuning capture %s to %s (channel offset 0)\n", cap.CaptureId, leyline.FormatFrequency(hz))
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
		}, hz, nil
	case "gain":
		db, auto, err := leyline.ParseGain(value)
		if err != nil {
			return nil, nil, 0, paramErr(param, err)
		}
		if err := needCapture(); err != nil {
			return nil, nil, 0, err
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
					if err := leyline.CheckGain(db, el); err != nil {
						return nil, nil, 0, paramErr(param, err)
					}
					db, tol = snapGain(el, db)
				}
			}
		}
		if element == "" {
			return nil, nil, 0, fmt.Errorf("this radio reports no gain stages; gain cannot be set")
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
		}, 0, nil
	}
	return buildChannelWrites(ctx, s, param, value, ch, cap, needChannel)
}

// buildChannelWrites handles the channel-scoped parameters (squelch, bw,
// mode, volume) for buildWrites.
func buildChannelWrites(ctx context.Context, s *session, param, value string, ch *leylinev1.Channel, cap *leylinev1.Capture, needChannel func() error) ([]*leylinev1.ParamWrite, func(*leylinev1.Event) bool, uint64, error) {
	channelEvent := func(match func(*leylinev1.Channel) bool) func(*leylinev1.Event) bool {
		return func(ev *leylinev1.Event) bool {
			c, ok := ev.Body.(*leylinev1.Event_Channel)
			return ok && c.Channel.ChannelId == ch.ChannelId && match(c.Channel)
		}
	}
	switch param {
	case "squelch":
		db, auto, err := leyline.ParseSquelch(value)
		if err != nil {
			return nil, nil, 0, paramErr(param, err)
		}
		if err := needChannel(); err != nil {
			return nil, nil, 0, err
		}
		if auto {
			if cap == nil {
				return nil, nil, 0, fmt.Errorf("squelch auto needs the channel's capture, which is gone; ley state shows what is left")
			}
			floor := 0.0
			if db, floor, err = s.measureSquelch(ctx, cap, ch.BandwidthHz); err != nil {
				return nil, nil, 0, fmt.Errorf("squelch auto: %w; set a level by hand: ley set squelch -40", err)
			}
			s.say("squelch auto → %.0f dBFS (10 dB above the band's noise floor, %.0f dBFS)\n", db, floor)
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: db}}
		return []*leylinev1.ParamWrite{w}, channelEvent(func(c *leylinev1.Channel) bool {
			return leyline.SquelchOff(db) && leyline.SquelchOff(c.SquelchDb) || c.SquelchDb == db
		}), 0, nil
	case "bw":
		bw, err := leyline.ParseBandwidth(value)
		if err != nil {
			return nil, nil, 0, paramErr(param, err)
		}
		if err := needChannel(); err != nil {
			return nil, nil, 0, err
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_BandwidthHz{BandwidthHz: bw}}
		return []*leylinev1.ParamWrite{w}, channelEvent(func(c *leylinev1.Channel) bool { return c.BandwidthHz == bw }), 0, nil
	case "mode":
		if err := needChannel(); err != nil {
			return nil, nil, 0, err
		}
		m, reason, err := leyline.ResolveMode(value, channelFreq(ch, cap))
		if err != nil {
			return nil, nil, 0, paramErr(param, err)
		}
		if reason != "" {
			s.say("using %s: %s\n", strings.ToUpper(leyline.ModeName(m)), reason)
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_Mode{Mode: m}}
		return []*leylinev1.ParamWrite{w}, channelEvent(func(c *leylinev1.Channel) bool { return c.Mode == m }), 0, nil
	case "volume":
		v, err := leyline.ParseVolume(value)
		if err != nil {
			return nil, nil, 0, paramErr(param, err)
		}
		if err := needChannel(); err != nil {
			return nil, nil, 0, err
		}
		var sink *leylinev1.Sink
		for _, sk := range s.state.Sinks {
			if _, ok := sk.Kind.(*leylinev1.Sink_SystemAudio); ok && sk.ChannelId == ch.ChannelId {
				sink = sk
			}
		}
		if sink == nil {
			return nil, nil, 0, &friendlyError{
				msg:   fmt.Sprintf("channel %s is not playing through the speakers (no system-audio sink), so there is no volume to set; ley tune without --no-audio plays audio", ch.ChannelId),
				cause: &leyline.Error{Code: leyline.CodeSinkNotFound, Message: "no system_audio sink", Target: ch.ChannelId},
			}
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: sink.SinkId, Param: &leylinev1.ParamWrite_SinkVolume{SinkVolume: v}}
		return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
			c, ok := ev.Body.(*leylinev1.Event_Sink)
			return ok && c.Sink.SinkId == sink.SinkId && c.Sink.GetSystemAudio().GetVolume() == v
		}, 0, nil
	}
	return nil, nil, 0, unknownParam(param)
}

// runSet writes, waits for confirmation (or a rejection) and prints the result.
func runSet(ctx context.Context, s *session, param, value, element string, ch *leylinev1.Channel, cap *leylinev1.Capture) error {
	writes, confirmed, hz, err := buildWrites(ctx, s, param, value, element, ch, cap)
	if err != nil {
		return err
	}
	sum, err := s.client.WriteParams(ctx, writes...)
	if err != nil {
		return s.friendly(err, value, hz)
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
			return fmt.Errorf("the radio rejected the change (%d of %d writes applied) without saying why; ley state shows what it is doing now", sum.GetWritesApplied(), sum.GetWritesReceived())
		}
		return err
	}
	if s.app.JSON {
		return s.app.printJSON(ev)
	}
	if r, ok := ev.Body.(*leylinev1.Event_WriteRejected); ok {
		return fmt.Errorf("rejected: %w", s.friendly(rejectedError(r.WriteRejected), value, hz))
	}
	fmt.Fprintln(s.app.Stdout, eventLine(ev, s.state))
	return nil
}

// parseNegativeSafe parses flags for a command that disabled Cobra's flag
// parsing so negative numbers ("-40") stay positional. Each negative-looking
// word is swapped for a marker before pflag sees the list and swapped back
// afterwards, so flags may appear before or after the positionals
// ("set --json squelch -40" and "set squelch -40 --json" both work). It
// returns nil args after printing help for -h/--help.
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
