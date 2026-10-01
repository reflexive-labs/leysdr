// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"math"
	"strings"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/bandplan"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// setParam describes one adjustable parameter: its help line and the forms a
// value may take (quoted back in every parse error).
type setParam struct {
	name, help, forms string
	// formsInHelp leaves the forms out of the help table because the help already shows them
	// (gain's is gainHelp, the sentence every gain takes); errors still quote them.
	formsInHelp bool
}

// setParams is the parameter table, in help order.
var setParams = []setParam{
	{"freq", "move to a frequency ('frequency' works too); retunes the radio when it is out of the current span", "146.52 (MHz), 1010k, 146520000", false},
	{"mode", "how to decode", "nfm, am, wfm, usb, lsb, cw, fm, ssb", false},
	{"bw", "channel bandwidth (filter width; 'filter' works too)", "12.5 (kHz), 200k, 12500", false},
	{"squelch", "mute the audio when the signal is weaker than this level", "-40, -40dB, off, auto", false},
	{"gain", gainHelp, "30, auto, LNA=0,VGA=20", true},
	{"volume", "speaker volume", "0.5, 50%", false},
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
		if p.formsInHelp {
			fmt.Fprintf(&b, "  %-8s %s\n", p.name, p.help)
			continue
		}
		fmt.Fprintf(&b, "  %-8s %s (%s)\n", p.name, p.help, p.forms)
	}
	return strings.TrimRight(b.String(), "\n")
}

func newSetCommand(app *App) *cobra.Command {
	var (
		channelSel, captureSel string
		retune                 bool
	)
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
  ley set gain LNA=0,VGA=20  two stages of a HackRF
  ley set freq 146.62
  ley set volume 50%
  ley set mode am --channel 2`,
		GroupID: GroupAdjusting,
		Args:    cobra.ArbitraryArgs,
		// Cobra would read "-40" as a flag; parsing is disabled here and
		// parseNegativeSafe does it instead. Only set does this: it is the
		// only verb whose positionals are commonly negative.
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
			defer s.Close()
			ch, capture, err := resolveTarget(s, channelSel, captureSel, setTarget)
			if err != nil {
				return err
			}
			if len(args) == 0 {
				return showSettings(s, ch, capture)
			}
			return runSet(cmd.Context(), s, args[0], args[1], ch, capture, retune)
		},
	}
	cmd.Flags().StringVar(&channelSel, "channel", "", "which channel: an id (chan_...), id prefix, row number from 'ley state' or frequency, e.g. --channel 146.62 (default: the active one)")
	cmd.Flags().StringVar(&captureSel, "capture", "", "which capture (a radio tuned to a band), for freq and gain: id, prefix, row number or frequency (default: the channel's)")
	cmd.Flags().BoolVar(&retune, "retune", false, "move the radio even when a recording is running on it (the recording logs the gap); without it set freq refuses and names the job")
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
func resolveTarget(s *verbSession, channelSel, captureSel string, hint targetHint) (*leylinev1.Channel, *leylinev1.Capture, error) {
	st := s.State
	var ch *leylinev1.Channel
	var capture *leylinev1.Capture
	var err error
	if captureSel != "" {
		// The resolver's own sentence names what it could not find ("no capture
		// matches ..."), so it is the error line as it stands.
		if capture, err = leyline.ResolveCapture(st, captureSel); err != nil {
			return nil, nil, err
		}
	}
	if channelSel != "" {
		if ch, err = leyline.ResolveChannel(st, channelSel); err != nil {
			return nil, nil, err
		}
		if capture != nil && ch.CaptureId != capture.CaptureId {
			return nil, nil, usageErrorf("channel %s is on capture %s, not --capture %s; drop one selector or pick a channel on that capture", ch.ChannelId, ch.CaptureId, capture.CaptureId)
		}
	} else {
		var active []*leylinev1.Channel
		for _, c := range st.Channels {
			if c.State == leylinev1.ChannelState_CHANNEL_ACTIVE && (capture == nil || c.CaptureId == capture.CaptureId) {
				active = append(active, c)
			}
		}
		switch len(active) {
		case 1:
			ch = active[0]
		case 0:
			if capture == nil {
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
	if capture == nil && ch != nil {
		capture = captureByID(st, ch.CaptureId)
	}
	return ch, capture, nil
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
func showSettings(s *verbSession, ch *leylinev1.Channel, capture *leylinev1.Capture) error {
	if ch == nil {
		return fmt.Errorf("no channel to show; ley state lists captures and channels")
	}
	if s.app.JSON {
		return s.app.printJSON(ch)
	}
	hz, _ := leyline.ChannelFrequency(s.State, ch)
	freq := channelFreqLabel(s.State, ch)
	if b := bandplan.BandFor(hz); b != nil {
		freq += " (" + b.Name + ")"
	}
	squelch := "off (audio always on)"
	if !units.SquelchOff(ch.SquelchDb) {
		squelch = fmt.Sprintf("%.0f dBFS", ch.SquelchDb)
	}
	volume := "no speaker sink"
	for _, sk := range s.State.Sinks {
		if sa, ok := sk.Kind.(*leylinev1.Sink_SystemAudio); ok && sk.ChannelId == ch.ChannelId {
			volume = fmt.Sprintf("%.0f%%", sa.SystemAudio.GetVolume()*100)
		}
	}
	model := "unknown radio"
	if capture != nil {
		for _, d := range s.State.Devices {
			if d.DeviceId == capture.DeviceId {
				model = d.Model
			}
		}
	}
	// One group per object (channel, radio, speakers): a user changing gain
	// needs to see that it belongs to the radio and moves every channel on
	// it, not just this one. Values the radio cannot offer are Muted, so the
	// settings in force stand out.
	st := s.app.Style
	fmt.Fprintf(s.app.Stdout, "%s %s on %s\n", st.Label("channel"), st.Muted(ch.ChannelId), model)
	settingRow(s.app, "frequency", freq, true)
	settingRow(s.app, "mode", strings.ToUpper(leyline.ModeName(ch.Mode)), true)
	settingRow(s.app, "bandwidth", units.FormatFrequency(uint64(ch.BandwidthHz)), true)
	settingRow(s.app, "squelch", squelch, !units.SquelchOff(ch.SquelchDb))
	gain := strings.TrimPrefix(stageGainWords(capture.GetGains(), deviceGainElements(s.State, capture.GetDeviceId())), "gain ")
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
	return usageError(fmt.Errorf("%s %w; accepted: %s", name, err, p.forms))
}

// buildWrites turns (param, value) into the ParamWrites and a predicate that
// recognises the confirming event. hz is the frequency the write concerns
// (for friendly out-of-range errors), 0 when none.
func buildWrites(ctx context.Context, s *verbSession, param, value string, ch *leylinev1.Channel, capture *leylinev1.Capture, retune bool) (writes []*leylinev1.ParamWrite, confirmed func(*leylinev1.Event) bool, hz uint64, err error) {
	needChannel := func() error {
		if ch == nil {
			return fmt.Errorf("set %s needs a channel; pick one with --channel", param)
		}
		return nil
	}
	needCapture := func() error {
		if capture == nil {
			return fmt.Errorf("set %s needs a capture; pick one with --capture", param)
		}
		return nil
	}
	if param == "freq" {
		t, terr := resolveDial(value, "146.52 (MHz)", nil)
		if terr != nil {
			return nil, nil, 0, paramErr(param, terr)
		}
		hz = t.Hz
		if err := needCapture(); err != nil {
			return nil, nil, 0, err
		}
		if s.device == nil {
			for _, d := range s.State.Devices {
				if d.DeviceId == capture.DeviceId {
					s.device = d
				}
			}
		}
		if ch == nil || !covers(capture, hz, ch.BandwidthHz) {
			if err := s.checkRange(value, hz); err != nil {
				return nil, nil, 0, err
			}
		}
		// Moving the radio under a running recording leaves a gap in it. The daemon degrades the
		// job and records the gap rather than refusing a person; `ley` asks first.
		if rerr := s.refuseRetuneOverRecording(capture.CaptureId, retune); rerr != nil && (ch == nil || !covers(capture, hz, ch.BandwidthHz)) {
			return nil, nil, 0, rerr
		}
		if ch == nil {
			w := &leylinev1.ParamWrite{Tag: 1, TargetId: capture.CaptureId, Param: &leylinev1.ParamWrite_CenterHz{CenterHz: hz}}
			return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
				c, ok := ev.Body.(*leylinev1.Event_Capture)
				return ok && c.Capture.CaptureId == capture.CaptureId && c.Capture.CenterHz == hz
			}, hz, nil
		}
		offset := int64(hz) - int64(capture.CenterHz)
		if covers(capture, hz, ch.BandwidthHz) {
			w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_OffsetHz{OffsetHz: offset}}
			return []*leylinev1.ParamWrite{w}, func(ev *leylinev1.Event) bool {
				c, ok := ev.Body.(*leylinev1.Event_Channel)
				return ok && c.Channel.ChannelId == ch.ChannelId && c.Channel.OffsetHz == offset
			}, hz, nil
		}
		s.say("retuning capture %s to %s (channel offset 0)\n", capture.CaptureId, units.FormatFrequency(hz))
		ws := []*leylinev1.ParamWrite{
			{Tag: 1, TargetId: capture.CaptureId, Param: &leylinev1.ParamWrite_CenterHz{CenterHz: hz}},
			{Tag: 2, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_OffsetHz{OffsetHz: 0}},
		}
		return ws, func(ev *leylinev1.Event) bool {
			// Either order of the two confirmations may arrive first; judge the mirror.
			switch ev.Body.(type) {
			case *leylinev1.Event_Channel, *leylinev1.Event_Capture:
				return channelByID(s.State, ch.ChannelId).GetOffsetHz() == 0 && captureByID(s.State, capture.CaptureId).GetCenterHz() == hz
			}
			return false
		}, hz, nil
	}
	writes, confirmed, err = buildChannelWrites(ctx, s, param, value, ch, capture, needChannel)
	return writes, confirmed, 0, err
}

// buildChannelWrites handles the channel-scoped parameters (squelch, bw,
// mode, volume) for buildWrites.
func buildChannelWrites(ctx context.Context, s *verbSession, param, value string, ch *leylinev1.Channel, capture *leylinev1.Capture, needChannel func() error) ([]*leylinev1.ParamWrite, func(*leylinev1.Event) bool, error) {
	channelEvent := func(match func(*leylinev1.Channel) bool) func(*leylinev1.Event) bool {
		return func(ev *leylinev1.Event) bool {
			c, ok := ev.Body.(*leylinev1.Event_Channel)
			return ok && c.Channel.ChannelId == ch.ChannelId && match(c.Channel)
		}
	}
	switch param {
	case "squelch":
		db, auto, err := units.ParseSquelch(value)
		if err != nil {
			return nil, nil, paramErr(param, err)
		}
		if err := needChannel(); err != nil {
			return nil, nil, err
		}
		if auto {
			if capture == nil {
				return nil, nil, fmt.Errorf("squelch auto needs the channel's capture, which is gone; ley state shows what is left")
			}
			floor := 0.0
			if db, floor, err = s.measureSquelch(ctx, capture, ch.BandwidthHz); err != nil {
				return nil, nil, fmt.Errorf("squelch auto: %w; set a level by hand: ley set squelch -40", err)
			}
			s.say("squelch auto → %.0f dBFS (10 dB above the band's noise floor, %.0f dBFS)\n", db, floor)
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_SquelchDb{SquelchDb: db}}
		return []*leylinev1.ParamWrite{w}, channelEvent(func(c *leylinev1.Channel) bool {
			return units.SquelchOff(db) && units.SquelchOff(c.SquelchDb) || c.SquelchDb == db
		}), nil
	case "bw":
		bw, err := units.ParseBandwidth(value)
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
		hz, _ := leyline.ChannelFrequency(s.State, ch)
		m, reason, err := bandplan.ResolveMode(value, hz)
		if err != nil {
			return nil, nil, paramErr(param, err)
		}
		if reason != "" {
			s.say("using %s: %s\n", strings.ToUpper(leyline.ModeName(m)), reason)
		}
		w := &leylinev1.ParamWrite{Tag: 1, TargetId: ch.ChannelId, Param: &leylinev1.ParamWrite_Mode{Mode: m}}
		return []*leylinev1.ParamWrite{w}, channelEvent(func(c *leylinev1.Channel) bool { return c.Mode == m }), nil
	case "volume":
		v, err := units.ParseVolume(value)
		if err != nil {
			return nil, nil, paramErr(param, err)
		}
		if err := needChannel(); err != nil {
			return nil, nil, err
		}
		var sink *leylinev1.Sink
		for _, sk := range s.State.Sinks {
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

// buildGainWrites turns a gain value (units.ParseGains: auto, a level for the first stage, or
// STAGE=dB pairs) into one ParamWrite per stage, in the order given, and a predicate that
// recognises the capture event holding every one of them. stages is the stages written, spelled
// as the device spells them, for the confirmation line. A stage the device does not list goes as
// typed, so the refusal is the daemon's, with the stages the radio has.
func buildGainWrites(s *verbSession, value string, capture *leylinev1.Capture) (writes []*leylinev1.ParamWrite, confirmed func(*leylinev1.Event) bool, stages []string, err error) {
	settings, err := units.ParseGains(value)
	if err != nil {
		return nil, nil, nil, paramErr("gain", err)
	}
	if capture == nil {
		return nil, nil, nil, fmt.Errorf("set gain needs a capture; pick one with --capture")
	}
	els := deviceGainElements(s.State, capture.DeviceId)
	if len(els) == 0 {
		return nil, nil, nil, fmt.Errorf("this radio reports no gain stages; gain cannot be set")
	}
	type want struct {
		name    string
		db, tol float64
		auto    bool
	}
	wants := make([]want, len(settings))
	for i, g := range settings {
		el, name := els[0], els[0].GetName()
		if g.Element != "" {
			el, name = gainElement(els, g.Element), g.Element
			if el != nil {
				name = el.GetName()
			}
		}
		// The daemon snaps to the element's discrete table (valid_db) or step grid; mirror that
		// here so the confirmation predicate matches the value the daemon will actually report.
		w := want{name: name, db: g.DB, tol: 1.0, auto: g.Auto}
		if el != nil && !g.Auto {
			if err := units.CheckGain(g.DB, el); err != nil {
				return nil, nil, nil, paramErr("gain", err)
			}
			w.db, w.tol = units.SnapGain(el, g.DB), units.GainTolerance(el)
		}
		wants[i] = w
		gw := &leylinev1.GainWrite{Element: name}
		if w.auto {
			gw.Value = &leylinev1.GainWrite_Auto{Auto: true}
		} else {
			gw.Value = &leylinev1.GainWrite_Db{Db: w.db}
		}
		writes = append(writes, &leylinev1.ParamWrite{Tag: uint64(i + 1), TargetId: capture.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: gw}})
		stages = append(stages, name)
	}
	return writes, func(ev *leylinev1.Event) bool {
		c, ok := ev.Body.(*leylinev1.Event_Capture)
		if !ok || c.Capture.CaptureId != capture.CaptureId {
			return false
		}
		// Each write is confirmed by a capture event of its own; the one that carries every
		// stage at its new value is the last, and the line reports from it.
		for _, w := range wants {
			held := false
			for _, gs := range c.Capture.Gains {
				held = held || gs.Element == w.name && (w.auto && gs.Auto || !w.auto && !gs.Auto && math.Abs(gs.Db-w.db) <= w.tol)
			}
			if !held {
				return false
			}
		}
		return true
	}, stages, nil
}

// runSet writes, waits for confirmation (or a rejection) and prints the result.
func runSet(ctx context.Context, s *verbSession, param, value string, ch *leylinev1.Channel, capture *leylinev1.Capture, retune bool) error {
	var (
		writes    []*leylinev1.ParamWrite
		confirmed func(*leylinev1.Event) bool
		hz        uint64
		stages    []string
		err       error
	)
	if param == "gain" {
		writes, confirmed, stages, err = buildGainWrites(s, value, capture)
	} else {
		writes, confirmed, hz, err = buildWrites(ctx, s, param, value, ch, capture, retune)
	}
	if err != nil {
		return err
	}
	sum, err := s.Client.WriteParams(ctx, writes...)
	if err != nil {
		return s.friendly(err, value, hz)
	}
	rejected := sum.GetWritesApplied() < sum.GetWritesReceived()
	ev, err := s.AwaitEvent(ctx, func(ev *leylinev1.Event) bool {
		if r, ok := ev.Body.(*leylinev1.Event_WriteRejected); ok && s.Mine(ev) {
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
	fmt.Fprintln(s.app.Stdout, confirmLine(s.app.Style, s.State, param, stages, ev, ch, capture))
	return nil
}

// confirmLine is the one line a successful set prints: the setting, the
// value it held, the value the daemon applied (read back from the confirming
// event) and what it applies to, e.g. "squelch off → -40 dBFS on 146.520 MHz
// NFM (channel 1)", "gain 7.7 dB → auto on the radio (TUNER)", or on a radio
// with several stages every stage set, "gain LNA 8 dB, VGA 16 dB → LNA 0 dB,
// VGA 20 dB on the radio (cap_…)". stages is the gain stages written (nil
// reads as every stage the capture reports). The old value is dropped when it
// is unknown or unchanged, leaving today's "squelch → -40 dBFS on …". The
// channel id is not repeated: the caller already named the channel, and
// `ley set` with no arguments prints the id whenever it is wanted.
func confirmLine(sty ui.Style, st *leylinev1.GetStateResponse, param string, stages []string, ev *leylinev1.Event, ch *leylinev1.Channel, capture *leylinev1.Capture) string {
	// ch and cap are the objects as they were before the write; the state
	// carries the versions the confirming event folded in.
	els := deviceGainElements(st, capture.GetDeviceId())
	was, _ := setValue(param, stages, els, ev, ch, capture, nil)
	if ch != nil {
		if c := channelByID(st, ch.ChannelId); c != nil {
			ch = c
		}
	}
	if capture != nil {
		if c := captureByID(st, capture.CaptureId); c != nil {
			capture = c
		}
	}
	now, label := setValue(param, stages, els, ev, ch, capture, st)
	name := label
	if name == "" {
		name = param
	}
	change := "→ " + now
	if was != "" && was != now {
		change = sty.Muted(was) + " → " + now
	}
	return fmt.Sprintf("%s %s on %s", sty.Label(name), change, setScope(sty, st, param, stages, ch, capture))
}

// setValue renders one parameter's value from the objects that carry it,
// with the parameter's human name (the label `ley set` prints with no
// arguments). An empty value means "not knowable here", which is how the
// line falls back to naming only the new value.
//
// A gain is the stages written, in the words every screen prints them in (stageLevel): the level
// alone on a radio with one stage, each stage by name on a radio with several.
func setValue(param string, stages []string, els []*leylinev1.GainElement, ev *leylinev1.Event, ch *leylinev1.Channel, capture *leylinev1.Capture, st *leylinev1.GetStateResponse) (value, label string) {
	switch param {
	case "freq":
		if ch == nil {
			return units.FormatFrequency(capture.GetCenterHz()), "frequency"
		}
		if capture != nil {
			// centre plus offset, so the pre-write pair reads back the
			// frequency the channel had before the write moved it.
			return units.FormatFrequency(uint64(int64(capture.GetCenterHz()) + ch.GetOffsetHz())), "frequency"
		}
		if st == nil {
			return "", "frequency"
		}
		return channelFreqLabel(st, ch), "frequency"
	case "gain":
		return setGainWords(capture, stages, els), "gain"
	case "squelch":
		if units.SquelchOff(ch.GetSquelchDb()) {
			return "off (audio always on)", "squelch"
		}
		return fmt.Sprintf("%.0f dBFS", ch.GetSquelchDb()), "squelch"
	case "bw":
		return units.FormatFrequency(uint64(ch.GetBandwidthHz())), "bandwidth"
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

// setGainWords is a gain write's value for the confirmation line: the stages written as the
// capture holds them, in stageGainWords's words. "" when a stage is not on the capture (a value
// not knowable here), so the line names only the new value.
func setGainWords(capture *leylinev1.Capture, stages []string, els []*leylinev1.GainElement) string {
	gains := capture.GetGains()
	if len(stages) > 0 {
		gains = nil
		for _, name := range stages {
			var held *leylinev1.GainState
			for _, g := range capture.GetGains() {
				if strings.EqualFold(g.GetElement(), name) {
					held = g
				}
			}
			if held == nil {
				return ""
			}
			gains = append(gains, held)
		}
	}
	if len(gains) == 0 {
		return ""
	}
	// The words the stages would print as a capture of their own, less the "gain" the line
	// already leads with. A one-stage radio's stage is named by the scope instead.
	words := strings.TrimPrefix(stageGainWords(gains, els), "gain ")
	if len(capture.GetGains()) > 1 && len(gains) == 1 {
		g := gains[0]
		words = g.GetElement() + " " + stageLevel(g, gainElement(els, g.GetElement()))
	}
	return words
}

// setScope names what the write applied to, leaving out the field that just
// changed (a mode change does not restate the mode). A device-scoped write
// says "the radio" in Label ink, so a gain change never reads as a channel
// change; a channel-scoped one is Muted scaffolding behind the value.
func setScope(sty ui.Style, st *leylinev1.GetStateResponse, param string, _ []string, ch *leylinev1.Channel, capture *leylinev1.Capture) string {
	// gain belongs to the radio even when the command addressed a channel:
	// it moves every channel on that radio, and the line has to say so.
	if ch == nil || param == "gain" {
		target := sty.Label("the radio")
		// On a one-stage radio the value is a bare level, so the scope names the stage; with
		// several, the value already names each one.
		if param == "gain" && len(capture.GetGains()) == 1 {
			return target + sty.Muted(" ("+capture.Gains[0].Element+")")
		}
		if capture != nil {
			return target + sty.Muted(" ("+capture.CaptureId+")")
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
