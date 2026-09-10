package cli

import (
	"context"
	"fmt"
	"math"
	"strings"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// setParam describes one adjustable parameter: its help line and the forms a
// value may take (quoted back in every parse error).
type setParam struct {
	name, help, forms string
}

// setParams is the parameter table, in help order.
var setParams = []setParam{
	{"freq", "move to a frequency ('frequency' works too); retunes the radio when it is out of the current span", "146.52 (MHz), 1010k, 146520000"},
	{"mode", "how to decode", "nfm, am, wfm, usb, lsb, cw, fm, ssb"},
	{"bw", "channel bandwidth (filter width; 'filter' works too)", "12.5 (kHz), 200k, 12500"},
	{"squelch", "mute the audio when the signal is weaker than this level", "-40, -40dB, off, auto"},
	{"gain", "radio gain (--element picks the gain stage)", "30, 30dB, auto"},
	{"volume", "speaker volume", "0.5, 50%"},
}

// setAliases maps the words newcomers reach for onto the table's names.
var setAliases = map[string]string{"filter": "bw", "frequency": "freq"}

func setParamByName(name string) *setParam {
	if a, ok := setAliases[name]; ok {
		name = a
	}
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
frequency, mode, squelch): the only active one; among several, the channel
a ley command made, but only when exactly one active channel is ley-made,
and set says which; otherwise --channel with an id, id prefix, row number
from 'ley state' or frequency.
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
			// Bad words never reach the daemon: they are usage errors (exit 2).
			switch {
			case len(args) == 1:
				if p := setParamByName(args[0]); p != nil {
					return usageErrorf("set %s needs a value (%s): ley set %s %s", p.name, p.forms, p.name, strings.Split(p.forms, ",")[0])
				}
				return unknownParam(args[0])
			case len(args) > 2:
				return usageErrorf("set takes one parameter and one value, got %d words; e.g. ley set squelch -40", len(args))
			case len(args) == 2:
				p := setParamByName(args[0])
				if p == nil {
					return unknownParam(args[0])
				}
				args[0] = p.name
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			ch, cap, err := resolveTarget(s, channelSel, captureSel, setTarget)
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
	return usageErrorf("%q is not a setting. Settings:\n%s", name, setParamList())
}

// targetHint says how a verb names its channel, for resolveTarget's messages:
// set takes a flag (`--channel N`), stop a bare argument (`N`).
type targetHint struct {
	// flag prefixes a bad selector's error ("--channel" or "channel").
	flag string
	// pick is the selector form to suggest ("--channel N" or "its number N").
	pick string
	// example is a full command using pick ("ley set squelch -40 --channel 2").
	example string
}

// setTarget and stopTarget are the hints for the two verbs that resolve a target.
var (
	setTarget  = targetHint{flag: "--channel", pick: "--channel N", example: "ley set squelch -40 --channel 2"}
	stopTarget = targetHint{flag: "channel", pick: "its number N", example: "ley stop 2"}
)

// resolveTarget picks the channel (and its capture) a set applies to. With
// no selector: one active channel → it; several → the cli-made one, but only
// when exactly one active channel is cli-owned (the rest belong to the app,
// an agent or a job), and the choice is printed; otherwise a numbered list
// worded with hint. Selectors accept an id, id prefix, row number or
// frequency; an explicit channel and capture that disagree are a usage error.
func resolveTarget(s *session, channelSel, captureSel string, hint targetHint) (*leylinev1.Channel, *leylinev1.Capture, error) {
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
			return nil, nil, fmt.Errorf("%s: %w", hint.flag, err)
		}
		if cap != nil && ch.CaptureId != cap.CaptureId {
			return nil, nil, usageErrorf("channel %s is on capture %s, not --capture %s; drop one selector or pick a channel on that capture", ch.ChannelId, ch.CaptureId, cap.CaptureId)
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
				return nil, nil, fmt.Errorf("nothing is playing; start with: ley tune 146.52 (or pick a channel with %s)", hint.pick)
			}
		default:
			var cli []*leylinev1.Channel
			for _, c := range active {
				if c.GetOwner().GetKind() == "cli" {
					cli = append(cli, c)
				}
			}
			if len(cli) != 1 {
				return nil, nil, fmt.Errorf("%d channels are playing; pick one with %s:\n%s\ne.g. %s", len(active), hint.pick, channelTable(st, active), hint.example)
			}
			ch = cli[0]
			s.say("using channel %d, %s (the only active channel ley made)\n", channelRow(st, ch), channelSummary(st, ch))
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
	return fmt.Sprintf("%s %s, %s (%s)", channelFreqLabel(st, ch), strings.ToUpper(leyline.ModeName(ch.Mode)), ch.ChannelId, owner)
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
	hz, _ := leyline.ChannelFrequency(s.state, ch)
	freq := channelFreqLabel(s.state, ch)
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
			volume = fmt.Sprintf("%.0f%%", sa.SystemAudio.GetVolume()*100)
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
	// Three objects, three groups: a reader who changes gain has to see that
	// it belongs to the radio and moves every channel on it, not just this
	// one. Values the radio cannot offer are Muted, so the settings actually
	// in force carry the weight.
	st := s.app.Style
	fmt.Fprintf(s.app.Stdout, "%s %s on %s\n", st.Label("channel"), st.Muted(ch.ChannelId), model)
	settingRow(s.app, "frequency", freq, true)
	settingRow(s.app, "mode", strings.ToUpper(leyline.ModeName(ch.Mode)), true)
	settingRow(s.app, "bandwidth", leyline.FormatFrequency(uint64(ch.BandwidthHz)), true)
	settingRow(s.app, "squelch", squelch, !leyline.SquelchOff(ch.SquelchDb))
	gain := strings.TrimPrefix(gainString(cap), "gain ")
	fmt.Fprintf(s.app.Stdout, "%s\n", st.Muted("on the radio"))
	settingRow(s.app, "gain", gain, gain != "no gain control")
	fmt.Fprintf(s.app.Stdout, "%s\n", st.Muted("through the speakers"))
	settingRow(s.app, "volume", volume, volume != "no speaker sink")
	fmt.Fprintf(s.app.Stdout, "%s %s\n", st.Muted("change one with:"),
		st.Cmd("ley set squelch -50")+st.Muted(" · ")+st.Cmd("ley set gain 30")+st.Muted(" · ")+st.Cmd("ley set freq 146.62"))
	return nil
}

// settingRow prints one row of the settings view: the label in the padded
// left column, the value plain when it is in force and Muted when it is a
// "the radio cannot do this" placeholder.
func settingRow(app *App, label, value string, live bool) {
	st := app.Style
	if !live {
		value = st.Muted(value)
	}
	fmt.Fprintf(app.Stdout, "  %s %s\n", st.Label(st.Pad(label, 10)), value)
}

// paramErr wraps a parse failure with the parameter's accepted forms. It is
// a usage error (exit 2): nothing was sent to the daemon.
func paramErr(name string, err error) error {
	p := setParamByName(name)
	return usageError(fmt.Errorf("%s: %w; accepted: %s", name, err, p.forms))
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
		t, terr := resolveDial(value, "146.52 (MHz)")
		if terr != nil {
			return nil, nil, 0, paramErr(param, terr)
		}
		hz = t.Hz
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
					db, tol = leyline.SnapGain(el, db), leyline.GainTolerance(el)
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
	writes, confirmed, err = buildChannelWrites(ctx, s, param, value, ch, cap, needChannel)
	return writes, confirmed, 0, err
}

// buildChannelWrites handles the channel-scoped parameters (squelch, bw,
// mode, volume) for buildWrites.
func buildChannelWrites(ctx context.Context, s *session, param, value string, ch *leylinev1.Channel, cap *leylinev1.Capture, needChannel func() error) ([]*leylinev1.ParamWrite, func(*leylinev1.Event) bool, error) {
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
			return nil, nil, paramErr(param, err)
		}
		if err := needChannel(); err != nil {
			return nil, nil, err
		}
		if auto {
			if cap == nil {
				return nil, nil, fmt.Errorf("squelch auto needs the channel's capture, which is gone; ley state shows what is left")
			}
			floor := 0.0
			if db, floor, err = s.measureSquelch(ctx, cap, ch.BandwidthHz); err != nil {
				return nil, nil, fmt.Errorf("squelch auto: %w; set a level by hand: ley set squelch -40", err)
			}
			s.say("squelch auto → %.0f dBFS (10 dB above the band's noise floor, %.0f dBFS)\n", db, floor)
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: db}}
		return []*leylinev1.ParamWrite{w}, channelEvent(func(c *leylinev1.Channel) bool {
			return leyline.SquelchOff(db) && leyline.SquelchOff(c.SquelchDb) || c.SquelchDb == db
		}), nil
	case "bw":
		bw, err := leyline.ParseBandwidth(value)
		if err != nil {
			return nil, nil, paramErr(param, err)
		}
		if err := needChannel(); err != nil {
			return nil, nil, err
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_BandwidthHz{BandwidthHz: bw}}
		return []*leylinev1.ParamWrite{w}, channelEvent(func(c *leylinev1.Channel) bool { return c.BandwidthHz == bw }), nil
	case "mode":
		if err := needChannel(); err != nil {
			return nil, nil, err
		}
		hz, _ := leyline.ChannelFrequency(s.state, ch)
		m, reason, err := leyline.ResolveMode(value, hz)
		if err != nil {
			return nil, nil, paramErr(param, err)
		}
		if reason != "" {
			s.say("using %s: %s\n", strings.ToUpper(leyline.ModeName(m)), reason)
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_Mode{Mode: m}}
		return []*leylinev1.ParamWrite{w}, channelEvent(func(c *leylinev1.Channel) bool { return c.Mode == m }), nil
	case "volume":
		v, err := leyline.ParseVolume(value)
		if err != nil {
			return nil, nil, paramErr(param, err)
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
			return nil, nil, &friendlyError{
				msg:   fmt.Sprintf("channel %s is not playing through the speakers (no system-audio sink), so there is no volume to set; ley tune without --no-audio plays audio", ch.ChannelId),
				cause: &leyline.Error{Code: leyline.CodeSinkNotFound, Message: "no system_audio sink", Target: ch.ChannelId},
			}
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: sink.SinkId, Param: &leylinev1.ParamWrite_SinkVolume{SinkVolume: v}}
		return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
			c, ok := ev.Body.(*leylinev1.Event_Sink)
			return ok && c.Sink.SinkId == sink.SinkId && c.Sink.GetSystemAudio().GetVolume() == v
		}, nil
	}
	return nil, nil, unknownParam(param)
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
	r, wasRejected := ev.Body.(*leylinev1.Event_WriteRejected)
	if s.app.JSON {
		if err := s.app.printJSON(ev); err != nil {
			return err
		}
		if wasRejected {
			// The event on stdout is the whole report; the status says it failed.
			return &ExitError{Code: 1, Err: rejectedError(r.WriteRejected)}
		}
		return nil
	}
	if wasRejected {
		return fmt.Errorf("rejected: %w", s.friendly(rejectedError(r.WriteRejected), value, hz))
	}
	fmt.Fprintln(s.app.Stdout, confirmLine(s.app.Style, s.state, param, element, ev, ch, cap))
	return nil
}

// confirmLine is the one line a successful set prints: the setting, the
// value it held, the value the daemon applied (read back from the confirming
// event) and what it applies to, e.g. "squelch off → -40 dBFS on 146.520 MHz
// NFM (channel 1)" or "gain 7.7 dB → auto on the radio (TUNER)". The old
// value is dropped when it is unknown or unchanged, leaving today's
// "squelch → -40 dBFS on …". The channel id is not repeated: the caller
// already named the channel, and `ley set` with no arguments prints the id
// whenever it is wanted.
func confirmLine(sty ui.Style, st *leylinev1.GetStateResponse, param, element string, ev *leylinev1.Event, ch *leylinev1.Channel, cap *leylinev1.Capture) string {
	if param == "gain" && element == "" && len(cap.GetGains()) > 0 {
		element = cap.Gains[0].Element
	}
	// ch and cap are the objects as they were before the write; the state
	// carries the versions the confirming event folded in.
	was, _ := setValue(param, element, ev, ch, cap, nil)
	if ch != nil {
		if c := channelByID(st, ch.ChannelId); c != nil {
			ch = c
		}
	}
	if cap != nil {
		if c := captureByID(st, cap.CaptureId); c != nil {
			cap = c
		}
	}
	now, label := setValue(param, element, ev, ch, cap, st)
	name := label
	if name == "" {
		name = param
	}
	change := "→ " + now
	if was != "" && was != now {
		change = sty.Muted(was) + " → " + now
	}
	return fmt.Sprintf("%s %s on %s", sty.Label(name), change, setScope(sty, st, param, element, ch, cap))
}

// setValue renders one parameter's value from the objects that carry it,
// with the parameter's human name (the label `ley set` prints with no
// arguments). An empty value means "not knowable here", which is how the
// line falls back to naming only the new value.
func setValue(param, element string, ev *leylinev1.Event, ch *leylinev1.Channel, cap *leylinev1.Capture, st *leylinev1.GetStateResponse) (value, label string) {
	switch param {
	case "freq":
		if ch == nil {
			return leyline.FormatFrequency(cap.GetCenterHz()), "frequency"
		}
		if cap != nil {
			// centre plus offset, so the pre-write pair reads back the
			// frequency the channel had before the write moved it.
			return leyline.FormatFrequency(uint64(int64(cap.GetCenterHz()) + ch.GetOffsetHz())), "frequency"
		}
		if st == nil {
			return "", "frequency"
		}
		return channelFreqLabel(st, ch), "frequency"
	case "gain":
		if element == "" && len(cap.GetGains()) > 0 {
			element = cap.Gains[0].Element
		}
		for _, g := range cap.GetGains() {
			if g.Element != element {
				continue
			}
			if g.Auto {
				return "auto", "gain"
			}
			return fmt.Sprintf("%.1f dB", g.Db), "gain"
		}
		return "", "gain"
	case "squelch":
		if leyline.SquelchOff(ch.GetSquelchDb()) {
			return "off (audio always on)", "squelch"
		}
		return fmt.Sprintf("%.0f dBFS", ch.GetSquelchDb()), "squelch"
	case "bw":
		return leyline.FormatFrequency(uint64(ch.GetBandwidthHz())), "bandwidth"
	case "mode":
		return strings.ToUpper(leyline.ModeName(ch.GetMode())), "mode"
	case "volume":
		if sk, ok := ev.Body.(*leylinev1.Event_Sink); ok && st != nil {
			return fmt.Sprintf("%.0f%%", sk.Sink.GetSystemAudio().GetVolume()*100), "volume"
		}
		return "", "volume"
	}
	return "applied", param
}

// setScope names what the write applied to, leaving out the field that just
// changed (a mode change does not restate the mode). A device-scoped write
// says "the radio" in Label ink, so a gain change never reads as a channel
// change; a channel-scoped one is Muted scaffolding behind the value.
func setScope(sty ui.Style, st *leylinev1.GetStateResponse, param, element string, ch *leylinev1.Channel, cap *leylinev1.Capture) string {
	// gain belongs to the radio even when the command addressed a channel:
	// it moves every channel on that radio, and the line has to say so.
	if ch == nil || param == "gain" {
		target := sty.Label("the radio")
		if id := element; id != "" {
			return target + sty.Muted(" ("+id+")")
		}
		if cap != nil {
			return target + sty.Muted(" ("+cap.CaptureId+")")
		}
		return target
	}
	row := fmt.Sprintf("channel %d", channelRow(st, ch))
	mode := strings.ToUpper(leyline.ModeName(ch.Mode))
	if param == "freq" {
		// The value just said the frequency; the channel it moved is what
		// is left to name.
		return sty.Muted(row) + " (" + mode + ")"
	}
	where := channelFreqLabel(st, ch)
	if param != "mode" {
		where += " " + mode
	}
	return where + sty.Muted(" ("+row+")")
}

// parseNegativeSafe parses flags for a command that disabled Cobra's flag
// parsing so negative numbers ("-40") stay positional. Each negative-looking
// word is swapped for a marker before pflag sees the list and swapped back
// afterwards, so flags may appear before or after the positionals
// ("set --json squelch -40" and "set squelch -40 --json" both work). It
// returns nil args after printing help for -h/--help.
func parseNegativeSafe(cmd *cobra.Command, raw []string) ([]string, error) {
	const marker = "\x00neg"
	_ = cmd.InheritedFlags() // merges persistent flags into cmd.Flags()
	var negatives []string
	flagArgs := make([]string, 0, len(raw))
	for i, a := range raw {
		if len(a) > 1 && a[0] == '-' && a[1] >= '0' && a[1] <= '9' {
			// A word the flag before it consumes is that flag's value, not a
			// positional: swapping it would hand the flag the marker itself and
			// shift every later negative onto the wrong positional.
			if i > 0 && consumesNext(cmd.Flags(), raw[i-1]) {
				flagArgs = append(flagArgs, a)
				continue
			}
			negatives = append(negatives, a)
			flagArgs = append(flagArgs, marker)
			continue
		}
		if a == "-h" || a == "--help" {
			return nil, cmd.Help()
		}
		flagArgs = append(flagArgs, a)
	}
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

// consumesNext reports whether a word is a flag of this command that takes the
// following word as its value ("--channel 3"). A "--flag=value" carries its own
// value and a boolean flag takes none, so neither claims the word after it.
func consumesNext(fs *pflag.FlagSet, word string) bool {
	if len(word) < 2 || word[0] != '-' || strings.Contains(word, "=") {
		return false
	}
	var f *pflag.Flag
	if name, ok := strings.CutPrefix(word, "--"); ok {
		f = fs.Lookup(name)
	} else {
		// In a shorthand run ("-jc name") only the last letter can take the
		// next word; the ones before it are boolean or the run would have
		// swallowed the rest as a value.
		f = fs.ShorthandLookup(word[len(word)-1:])
	}
	return f != nil && f.NoOptDefVal == ""
}
