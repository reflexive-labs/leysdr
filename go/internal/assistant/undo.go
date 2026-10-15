// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// Undo puts back what the assistant changed, newest first ("undo that", story A2). A set is undone
// by setting the value it replaced, read from get_state before the write; a tune made a channel of
// its own, so it is undone by stopping that channel. Volume is not undone: the state does not
// carry a sink's volume, so there is nothing to read before the write.

// undoEntry is one change the assistant can put back.
type undoEntry struct {
	tool     string // "set" or "tune"
	channel  string // the channel set changed or tune made
	param    string // set's setting
	old      string // set's value before, in the form set takes
	takeOver bool   // the set needed take_over, so putting it back does too
	shown    string // tune: the frequency, for the report
}

// undoStack is the conversation's changes, newest last.
type undoStack struct {
	entries []undoEntry
}

var unmarshal = protojson.UnmarshalOptions{DiscardUnknown: true}

// readState is get_state through the tools, or nil when it cannot be read.
func readState(ctx context.Context, tools *Tools) *leylinev1.GetStateResponse {
	res := tools.Call(ctx, "get_state", nil)
	if res.IsError {
		return nil
	}
	var st leylinev1.GetStateResponse
	if unmarshal.Unmarshal([]byte(res.JSON), &st) != nil {
		return nil
	}
	return &st
}

// noteSet records a set that ran, from the state read before it and the event that confirmed it.
func (u *undoStack) noteSet(before *leylinev1.GetStateResponse, args map[string]any, res Result) {
	if before == nil || res.IsError {
		return
	}
	var ev leylinev1.Event
	if unmarshal.Unmarshal([]byte(res.JSON), &ev) != nil {
		return
	}
	param := strings.ToLower(strArg(args, "param"))
	switch param {
	case "frequency":
		param = "freq"
	case "filter":
		param = "bw"
	}
	channel := strArg(args, "channel")
	var old string
	if id := ev.GetChannel().GetChannelId(); id != "" {
		channel = id
		old = channelValue(before, id, param)
	} else if c := ev.GetCapture(); c != nil && param == "gain" {
		old = gainValue(before, c.GetCaptureId())
	}
	if old == "" {
		return
	}
	u.entries = append(u.entries, undoEntry{tool: "set", channel: channel, param: param, old: old, takeOver: boolArg(args, "take_over")})
}

// noteTune records the channel a tune made.
func (u *undoStack) noteTune(res Result) {
	if res.IsError {
		return
	}
	var made struct {
		Capture json.RawMessage `json:"capture"`
		Channel json.RawMessage `json:"channel"`
	}
	if json.Unmarshal([]byte(res.JSON), &made) != nil {
		return
	}
	var ch leylinev1.Channel
	var capture leylinev1.Capture
	if unmarshal.Unmarshal(made.Channel, &ch) != nil || ch.GetChannelId() == "" {
		return
	}
	_ = unmarshal.Unmarshal(made.Capture, &capture)
	shown := units.FormatFrequency(uint64(int64(capture.GetCenterHz()) + ch.GetOffsetHz()))
	u.entries = append(u.entries, undoEntry{tool: "tune", channel: ch.GetChannelId(), shown: shown})
}

// undo puts the newest change back and says what it did.
func (u *undoStack) undo(ctx context.Context, tools *Tools) Result {
	if len(u.entries) == 0 {
		return Result{Text: "nothing to undo: the assistant has not tuned or changed a setting in this conversation", IsError: true}
	}
	e := u.entries[len(u.entries)-1]
	var res Result
	switch e.tool {
	case "tune":
		res = tools.Call(ctx, "stop", mustJSON(map[string]any{"channel": e.channel}))
		if !res.IsError {
			res.Text = joinLine(fmt.Sprintf("undid the tune: stopped channel %s on %s, which it made.", e.channel, e.shown), res.Text)
		}
	default:
		args := map[string]any{"param": e.param, "value": e.old, "channel": e.channel}
		if e.takeOver {
			args["take_over"] = true
		}
		res = tools.Call(ctx, "set", mustJSON(args))
		if !res.IsError {
			res.Text = joinLine(fmt.Sprintf("undid the %s change: put back %s.", e.param, e.old), res.Text)
		}
	}
	if !res.IsError {
		u.entries = u.entries[:len(u.entries)-1]
	}
	return res
}

// channelValue is a channel's setting in the form set takes, or "" when the state lacks it.
func channelValue(st *leylinev1.GetStateResponse, channelID, param string) string {
	for _, ch := range st.GetChannels() {
		if ch.GetChannelId() != channelID {
			continue
		}
		switch param {
		case "freq":
			for _, c := range st.GetCaptures() {
				if c.GetCaptureId() == ch.GetCaptureId() {
					// Hz as a bare integer: set reads a number of 100000 or more as Hz.
					return strconv.FormatInt(int64(c.GetCenterHz())+ch.GetOffsetHz(), 10)
				}
			}
		case "mode":
			return leyline.ModeName(ch.GetMode())
		case "bw":
			return strconv.FormatUint(uint64(ch.GetBandwidthHz()), 10)
		case "squelch":
			if math.IsNaN(ch.GetSquelchDb()) {
				return "off"
			}
			return strconv.FormatFloat(ch.GetSquelchDb(), 'f', -1, 64)
		}
	}
	return ""
}

// gainValue is a capture's gain in the form set takes: auto, or each stage by name.
func gainValue(st *leylinev1.GetStateResponse, captureID string) string {
	for _, c := range st.GetCaptures() {
		if c.GetCaptureId() != captureID || len(c.GetGains()) == 0 {
			continue
		}
		var stages []string
		for _, g := range c.GetGains() {
			if g.GetAuto() {
				return "auto"
			}
			stages = append(stages, g.GetElement()+"="+strconv.FormatFloat(g.GetDb(), 'f', -1, 64))
		}
		return strings.Join(stages, ",")
	}
	return ""
}

func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err) // maps of strings and bools always marshal
	}
	return b
}

// joinLine puts a line before text.
func joinLine(line, text string) string {
	if text == "" {
		return line
	}
	return line + "\n" + text
}
