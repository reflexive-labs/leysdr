// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// What somebody else just did, said as a sentence.
//
// An event carries the whole changed object and never a delta (invariant 6).
// That is right for the wire and wrong for a person: `ley set mode am` in
// another terminal emits a channel event *and* a capture event -- the capture
// because every interactive write stamps its don't-disturb activity clock --
// and a state-dump renderer prints both, 26-character ids and all, into the
// middle of somebody's listening session.
//
// The mirror already holds the previous copy of every object, so the client
// can diff and say what moved. Rendering a diff is presentation; the daemon
// still sends whole objects and invariant 6 is untouched. The rule for what
// earns a line is "could the person listening act on it": a retune, a mode,
// a squelch, their audio going away. An activity timestamp could not, and an
// id they did not ask for never could.

// beforeEvent returns the mirror's copy of the object ev names, from before
// the event is folded in. It must be called before session.apply. A nil result
// means this session had not seen the object yet.
func (s *session) beforeEvent(ev *leylinev1.Event) any {
	switch b := ev.Body.(type) {
	case *leylinev1.Event_Capture:
		if c := captureByID(s.state, b.Capture.CaptureId); c != nil {
			return c
		}
	case *leylinev1.Event_Channel:
		if c := channelByID(s.state, b.Channel.ChannelId); c != nil {
			return c
		}
	case *leylinev1.Event_Sink:
		if s.sink != nil && s.sink.SinkId == b.Sink.SinkId {
			return s.sink
		}
	case *leylinev1.Event_Device:
		if d := deviceByID(s.state, b.Device.DeviceId); d != nil {
			return d
		}
	}
	return nil
}

// deviceByID finds a device in a state snapshot.
func deviceByID(state *leylinev1.GetStateResponse, id string) *leylinev1.DeviceDescriptor {
	if state == nil {
		return nil
	}
	for _, d := range state.Devices {
		if d.DeviceId == id {
			return d
		}
	}
	return nil
}

// change is one field that moved, split at the verb so that a write touching
// three knobs reads as one sentence ("set the mode to AM, the filter to
// 25.000 kHz and the squelch to -20 dBFS") rather than as three clauses each
// repeating "set".
type change struct{ verb, what string }

// changeLine renders one other-client event as a sentence, and reports whether
// the session's own channel is gone -- the one change a live verb cannot carry
// on through. An empty line with ended false means nothing worth saying moved.
func (s *session) changeLine(before any, ev *leylinev1.Event) (line string, ended bool) {
	st := s.app.ErrStyle
	var what []change
	switch b := ev.Body.(type) {
	case *leylinev1.Event_Capture:
		was, _ := before.(*leylinev1.Capture)
		what = captureChanges(was, b.Capture, s.capture, st)
	case *leylinev1.Event_Channel:
		was, _ := before.(*leylinev1.Channel)
		what, ended = s.channelChanges(was, b.Channel, st)
	case *leylinev1.Event_Sink:
		was, _ := before.(*leylinev1.Sink)
		what = sinkChanges(was, b.Sink, s.sink, st)
	case *leylinev1.Event_Device:
		was, _ := before.(*leylinev1.DeviceDescriptor)
		what = deviceChanges(was, b.Device, s.device, st)
	}
	if len(what) == 0 {
		return "", ended
	}
	return whoChanged(ev.CausedBy) + " " + sentence(what), ended
}

// whoChanged names the client that caused an event the way a person would
// refer to it. The id stays in --json, where something might key on it.
func whoChanged(ci *leylinev1.ClientInfo) string {
	if ci == nil {
		return "something"
	}
	switch ci.Kind {
	case "cli":
		return "another terminal"
	case "app":
		return "the app"
	case "mcp":
		return "an agent"
	case "job":
		return "a job"
	case "daemon":
		return "the daemon"
	}
	if ci.Label != "" {
		return ci.Label
	}
	return "another client"
}

// sentence words a run of changes, folding neighbours that share a verb into
// one clause.
func sentence(what []change) string {
	var clauses []string
	for i := 0; i < len(what); {
		j := i
		var objs []string
		for ; j < len(what) && what[j].verb == what[i].verb; j++ {
			objs = append(objs, what[j].what)
		}
		clauses = append(clauses, what[i].verb+" "+andList(objs))
		i = j
	}
	return andList(clauses)
}

// andList reads a list as English: "a", "a and b", "a, b and c".
func andList(parts []string) string {
	switch len(parts) {
	case 0:
		return ""
	case 1:
		return parts[0]
	case 2:
		return parts[0] + " and " + parts[1]
	}
	return strings.Join(parts[:len(parts)-1], ", ") + " and " + parts[len(parts)-1]
}

// captureChanges lists what moved on the capture this session is riding on.
// Everything else about a capture -- its activity clock above all, which every
// interactive write in every terminal stamps -- is bookkeeping a listener
// cannot act on.
func captureChanges(was, now, ours *leylinev1.Capture, st ui.Style) []change {
	if ours == nil || now.CaptureId != ours.CaptureId || was == nil {
		return nil
	}
	var out []change
	if was.CenterHz != now.CenterHz {
		out = append(out, change{"retuned", "the radio to " + leyline.FormatFrequency(now.CenterHz)})
	}
	if was.SampleRate != now.SampleRate {
		out = append(out, change{"set", "the sample rate to " + leyline.FormatFrequency(now.SampleRate)})
	}
	if g := gainChange(was.Gains, now.Gains); g != "" {
		out = append(out, change{"set", g})
	}
	if was.State != now.State {
		// State unset is the destroy tombstone, not a state the radio is in;
		// printing the enum word there says "state unspecified" for "gone".
		if now.State == leylinev1.CaptureState_CAPTURE_STATE_UNSPECIFIED {
			out = append(out, change{"stopped", "this radio"})
		} else {
			out = append(out, change{"left", "the radio " + inkState(st, stateWord(now.State.String()))})
		}
	}
	return out
}

// gainChange words the first gain element that moved. Every element is on the
// event (full state), but a person setting gain sets one.
func gainChange(was, now []*leylinev1.GainState) string {
	prev := map[string]*leylinev1.GainState{}
	for _, g := range was {
		prev[g.Element] = g
	}
	for _, g := range now {
		p := prev[g.Element]
		if p == nil || (p.Auto == g.Auto && p.Db == g.Db) {
			continue
		}
		if g.Auto {
			return "the gain to auto"
		}
		return fmt.Sprintf("the gain to %.1f dB", g.Db)
	}
	return ""
}

// channelChanges lists what moved on a channel. Only this session's own
// channel is reported field by field: somebody else's squelch is their
// business, but a channel appearing or leaving the capture we share is not.
func (s *session) channelChanges(was, now *leylinev1.Channel, st ui.Style) ([]change, bool) {
	ours := s.channel != nil && now.ChannelId == s.channel.ChannelId
	// The daemon marks a destroyed channel by emitting it one last time with
	// its state unset (SessionStore.destroyChannel). That is the whole wire
	// signal, so a renderer that prints the enum name says STATE_UNSPECIFIED
	// where it means "gone".
	gone := now.State == leylinev1.ChannelState_CHANNEL_STATE_UNSPECIFIED
	if !ours {
		return otherChannelChanges(s.state, was, now, gone), false
	}
	if gone {
		return []change{{"stopped", "this channel"}}, true
	}
	var out []change
	if was == nil {
		return nil, false
	}
	if was.State != now.State {
		switch now.State {
		case leylinev1.ChannelState_OUT_OF_CAPTURE:
			out = append(out, change{"retuned", "the radio away from this channel (" + st.Cmd("ley tune") + " again to follow)"})
		case leylinev1.ChannelState_CHANNEL_ACTIVE:
			out = append(out, change{"brought", "the radio back to this channel"})
		}
	}
	if was.OffsetHz != now.OffsetHz {
		out = append(out, change{"moved", "this channel to " + channelFreqLabel(s.state, now)})
	}
	if was.Mode != now.Mode {
		out = append(out, change{"set", "the mode to " + strings.ToUpper(leyline.ModeName(now.Mode))})
	}
	if was.BandwidthHz != now.BandwidthHz {
		out = append(out, change{"set", "the filter to " + leyline.FormatFrequency(uint64(now.BandwidthHz))})
	}
	if squelchMoved(was.SquelchDb, now.SquelchDb) {
		if leyline.SquelchOff(now.SquelchDb) {
			out = append(out, change{"turned", "the squelch off"})
		} else {
			out = append(out, change{"set", fmt.Sprintf("the squelch to %.0f dBFS", now.SquelchDb)})
		}
	}
	return out, false
}

// otherChannelChanges reports only a channel arriving on or leaving the
// capture this session shares -- both move the radio's load and neither is
// visible any other way.
func otherChannelChanges(state *leylinev1.GetStateResponse, was, now *leylinev1.Channel, gone bool) []change {
	switch {
	case gone && was != nil:
		return []change{{"closed", "the channel at " + channelFreqLabel(state, now)}}
	case !gone && was == nil:
		return []change{{"opened", fmt.Sprintf("a channel at %s (%s)", channelFreqLabel(state, now), strings.ToUpper(leyline.ModeName(now.Mode)))}}
	}
	return nil
}

// squelchMoved compares two squelch settings, where NaN means off and NaN !=
// NaN: a plain comparison would report a change on every event of an
// unsquelched channel.
func squelchMoved(was, now float64) bool {
	if leyline.SquelchOff(was) || leyline.SquelchOff(now) {
		return leyline.SquelchOff(was) != leyline.SquelchOff(now)
	}
	return was != now
}

// sinkChanges reports what moved on this session's own audio sink. A sink that
// has been detached is emitted one last time with its state unset, the same
// tombstone the channel uses.
func sinkChanges(was, now, ours *leylinev1.Sink, st ui.Style) []change {
	if ours == nil || now.SinkId != ours.SinkId {
		return nil
	}
	if now.State == leylinev1.SinkState_SINK_STATE_UNSPECIFIED {
		return []change{{"stopped", "the audio (" + st.Cmd("ley tune") + " again to get it back)"}}
	}
	if was == nil {
		return nil
	}
	wv, nv := was.GetSystemAudio(), now.GetSystemAudio()
	if wv == nil || nv == nil || wv.GetVolume() == nv.GetVolume() {
		return nil
	}
	if nv.GetVolume() == 0 {
		return []change{{"muted", "the audio"}}
	}
	return []change{{"set", fmt.Sprintf("the volume to %.2f", nv.GetVolume())}}
}

// deviceChanges reports the radio this session is listening through leaving or
// coming back. Other devices plugged in elsewhere are not this session's news.
func deviceChanges(was, now, ours *leylinev1.DeviceDescriptor, st ui.Style) []change {
	if ours == nil || now.DeviceId != ours.DeviceId || was == nil || was.State == now.State {
		return nil
	}
	switch now.State {
	case leylinev1.DeviceState_DISCONNECTED:
		return []change{{"unplugged", "the radio (" + st.Cmd("ley devices") + " lists what is left)"}}
	case leylinev1.DeviceState_AVAILABLE, leylinev1.DeviceState_IN_USE:
		return []change{{"plugged", "the radio back in"}}
	}
	return nil
}
