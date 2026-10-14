// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/internal/words"
)

// The channel tools: set and stop, the two verbs that change a channel tune already made. Each
// resolves its channel the way its verb does (resolveTarget) and writes through the verb's own
// code (applySet, stopChannel, stopAll); what is the adapter's own is the don't-disturb refusal,
// made before anything is written, and the remedies spelled as arguments instead of flags.

func (srv *mcpServer) registerControlTools() {
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "set",
		Description: "Change one setting of a channel that is running and report the value the radio applied (ParamWrite, confirmed by the daemon's event; ley set). " +
			"param is one of ley set's settings: freq, mode, bw, squelch, gain, volume. The channel is the only active one, else the one an agent made when exactly one is, else the one channel names. " +
			"A freq outside what the radio is tuned to moves the radio, and that is refused when other channels are listening on it, naming them, unless take_over is true. gain belongs to the radio and moves every channel on it. " +
			"Returns the Event that confirmed the write, the shape 'ley set --json' prints; the text is the line ley set prints.",
		Annotations: toolMutates,
		InputSchema: setSchema(),
	}, srv.set)
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "stop",
		Description: "Stop channels (Control.DestroyChannel; ley stop). With no arguments it stops every channel this server made; channel names one (an id, id prefix, row number from get_state or a frequency); all: true stops every channel on one radio and frees it, as 'ley stop all'. " +
			"A channel another client made is refused, naming its owner, unless take_over is true. Returns Empty, as 'ley stop --json' prints; the text says what stopped.",
		Annotations: toolMutates,
	}, srv.stop)
}

type setArgs struct {
	Param    string `json:"param" jsonschema:"which setting: freq (or frequency), mode, bw (or filter), squelch, gain, volume"`
	Value    string `json:"value"`
	Channel  string `json:"channel,omitempty" jsonschema:"which channel: an id (chan_...), id prefix, row number from get_state or frequency (default: the only active one, else the only one an agent made)"`
	TakeOver bool   `json:"take_over,omitempty" jsonschema:"move the radio for a freq even when other channels are listening on it; they fall silent (default: false, refuse and say who is listening). Send it only after a refusal named who is listening"`
}

// setSchema describes value with ley set's own parameter table, so the forms the tool accepts
// are the verb's and cannot drift from them.
func setSchema() *jsonschema.Schema {
	sch, err := jsonschema.For[setArgs](&jsonschema.ForOptions{})
	if err != nil {
		panic(fmt.Sprintf("mcp: the set schema: %v", err))
	}
	sch.Properties["value"].Description = "the new value, as 'ley set' takes it for each setting:\n" + setParamList() + "\n(gain: " + gainHelp + ")"
	return sch
}

// mcpSetTarget and mcpStopTarget word resolveTarget's refusals for an agent, which names a channel
// with an argument rather than a flag.
var (
	mcpSetTarget  = targetHint{flag: "channel", pick: "channel (an id, a row number from get_state or a frequency)", example: `set with {"param": "squelch", "value": "-40", "channel": "2"}`}
	mcpStopTarget = targetHint{flag: "channel", pick: "channel (an id, a row number from get_state or a frequency)", example: `stop with {"channel": "2"}`}
)

func (srv *mcpServer) set(ctx context.Context, _ *mcp.CallToolRequest, in setArgs) (*mcp.CallToolResult, any, error) {
	p := setParamByName(in.Param)
	if p == nil {
		return nil, nil, toolError(unknownParam(in.Param))
	}
	if strings.TrimSpace(in.Value) == "" {
		return nil, nil, fmt.Errorf("set %s needs a value (%s)", p.name, p.forms)
	}
	app, out, errb := srv.toolApp()
	s, err := openSession(ctx, app)
	if err != nil {
		return nil, nil, toolError(err)
	}
	defer s.Close()
	s.proseToStderr = true
	s.takeOverHint = takeOverHint
	ch, capture, err := resolveTarget(s, in.Channel, "", mcpSetTarget)
	if err != nil {
		return nil, nil, toolError(err)
	}
	if p.name == "freq" && !in.TakeOver {
		if err := refuseSetRetune(s, ch, capture, in.Value); err != nil {
			return nil, nil, err
		}
	}
	res, err := applySet(ctx, s, p.name, in.Value, ch, capture, in.TakeOver)
	if err != nil {
		return nil, nil, toolError(err)
	}
	if res.rejected != nil {
		return nil, nil, toolError(fmt.Errorf("rejected: %w", s.friendly(rejectedError(res.rejected), in.Value, res.hz)))
	}
	fmt.Fprintln(out, confirmLine(ui.Style{}, s.State, p.name, res.stages, res.event, ch, capture))
	srv.touched(capture.GetCaptureId())
	return protoResult(res.event, errb.String()+out.String())
}

// refuseSetRetune is tune's don't-disturb refusal for a set freq: a frequency the capture does
// not cover moves the radio, and every other channel listening on it falls silent. The channel
// being set moves with the radio, so it is not one of them. A value that does not parse is left
// to applySet, whose error names the forms.
func refuseSetRetune(s *verbSession, ch *leylinev1.Channel, capture *leylinev1.Capture, value string) error {
	if capture == nil {
		return nil
	}
	t, err := resolveDial(value, "146.52 (MHz)", nil)
	if err != nil {
		return nil
	}
	if ch != nil && covers(capture, t.Hz, ch.GetBandwidthHz()) {
		return nil
	}
	return retuneRefusal(s.State, capture, t.Hz, ch.GetChannelId())
}

type stopArgs struct {
	Channel  string `json:"channel,omitempty" jsonschema:"which channel: an id (chan_...), id prefix, row number from get_state or frequency (default: every channel this server made)"`
	All      bool   `json:"all,omitempty" jsonschema:"stop every channel on one radio and the capture that holds it, so the radio is free, as 'ley stop all' (default: false)"`
	Device   string `json:"device,omitempty" jsonschema:"with all: which radio, when several are in use (an id, id prefix or row number from list_devices)"`
	TakeOver bool   `json:"take_over,omitempty" jsonschema:"stop channels another client made, which falls silent (default: false, refuse and say whose they are). Send it only after a refusal named them"`
}

func (srv *mcpServer) stop(ctx context.Context, _ *mcp.CallToolRequest, in stopArgs) (*mcp.CallToolResult, any, error) {
	if in.All && in.Channel != "" {
		return nil, nil, errors.New("all stops every channel on a radio and takes no channel; send one or the other")
	}
	if in.Device != "" && !in.All {
		return nil, nil, errors.New("device only goes with all: true; to stop one channel name it with channel")
	}
	app, out, errb := srv.toolApp()
	s, err := openSession(ctx, app)
	if err != nil {
		return nil, nil, toolError(err)
	}
	defer s.Close()
	s.proseToStderr = true
	switch {
	case in.All:
		err = srv.stopRadio(ctx, s, in.Device, in.TakeOver)
	case in.Channel != "":
		err = srv.stopOne(ctx, s, in.Channel, in.TakeOver)
	default:
		err = srv.stopMine(ctx, s)
	}
	if err != nil {
		return nil, nil, toolError(err)
	}
	return protoResult(&leylinev1.Empty{}, errb.String()+out.String())
}

// stopOne is `ley stop <channel>`, refused when the channel is another client's.
func (srv *mcpServer) stopOne(ctx context.Context, s *verbSession, sel string, takeOver bool) error {
	ch, capture, err := resolveTarget(s, sel, "", mcpStopTarget)
	if err != nil {
		return err
	}
	if !takeOver {
		if err := srv.othersChannels(s.State, []*leylinev1.Channel{ch}); err != nil {
			return err
		}
	}
	return stopChannel(ctx, s, ch, capture)
}

// stopMine stops every channel this server made: the caller's own, which nobody else is
// listening through.
func (srv *mcpServer) stopMine(ctx context.Context, s *verbSession) error {
	var mine []*leylinev1.Channel
	for _, ch := range s.State.GetChannels() {
		if ch.GetOwner().GetClientId() == srv.client.ClientID() {
			mine = append(mine, ch)
		}
	}
	if len(mine) == 0 {
		return errors.New("this server has made no channels; name one with channel (get_state lists them), or all: true frees a radio")
	}
	for _, ch := range mine {
		if err := stopChannel(ctx, s, ch, captureByID(s.State, ch.GetCaptureId())); err != nil {
			return err
		}
	}
	return nil
}

// stopRadio is `ley stop all`, refused when a channel on the radio is another client's.
func (srv *mcpServer) stopRadio(ctx context.Context, s *verbSession, deviceSel string, takeOver bool) error {
	dev, err := stopAllDevice(s.State, deviceSel)
	if err != nil {
		return err
	}
	if dev != nil && !takeOver {
		var on []*leylinev1.Channel
		for _, ch := range s.State.GetChannels() {
			if c := captureByID(s.State, ch.GetCaptureId()); c != nil && c.GetDeviceId() == dev.GetDeviceId() {
				on = append(on, ch)
			}
		}
		if err := srv.othersChannels(s.State, on); err != nil {
			return err
		}
	}
	return stopAll(ctx, s, deviceSel)
}

// othersChannels refuses to stop channels another client made, naming each with its frequency
// and owner: stopping them silences whoever is listening, which the policy asks about first.
func (srv *mcpServer) othersChannels(st *leylinev1.GetStateResponse, chs []*leylinev1.Channel) error {
	var who []string
	for _, ch := range chs {
		if ch.GetOwner().GetClientId() == srv.client.ClientID() {
			continue
		}
		who = append(who, fmt.Sprintf("%s (%s, %s)", ch.GetChannelId(), channelFreqLabel(st, ch), clientLabel(ch.GetOwner())))
	}
	if len(who) == 0 {
		return nil
	}
	return fmt.Errorf("%s made by another client: %s. Stopping %s silences whoever is listening. Call again with take_over: true to stop %s anyway",
		words.Pick(len(who), "that channel was", "those channels were"), strings.Join(who, ", "),
		words.Pick(len(who), "it", "them"), words.Pick(len(who), "it", "them"))
}
