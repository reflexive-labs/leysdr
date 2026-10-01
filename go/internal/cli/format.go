// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// stateWord renders a proto state enum the way people say it: lower case,
// spaces for underscores ("out of capture"). The raw enum stays in --json.
func stateWord(s string) string {
	return strings.ReplaceAll(strings.ToLower(enumName(s)), "_", " ")
}

// inkState gives a state word its ink: green when the thing is working,
// yellow when it is degraded but alive, red when it is gone. The word carries
// the meaning on its own; the colour only highlights it.
func inkState(st ui.Style, word string) string {
	switch word {
	case "active", "available", "running":
		return st.Ok(word)
	case "in use", "out of capture", "degraded":
		return st.Warn(word)
	case "detached", "disconnected", "capture detached", "failed":
		return st.Err(word)
	default:
		return word
	}
}

// formatOffset renders a channel offset from its capture centre with a sign
// and a unit ("+100.000 kHz", "-12.500 kHz", "0 Hz").
func formatOffset(hz int64) string {
	if hz == 0 {
		return "0 Hz"
	}
	sign := "+"
	if hz < 0 {
		sign, hz = "-", -hz
	}
	return sign + units.FormatFrequency(uint64(hz))
}

// clientLabel is the short owner form ("cli:ley"); the session id it hides
// stays in clientString, --wide and --json.
func clientLabel(ci *leylinev1.ClientInfo) string {
	if ci == nil {
		return "-"
	}
	return ci.Kind + ":" + ci.Label
}

// enumName strips the "CAPTURE_"/"CHANNEL_" style prefix from proto enum names
// so tables read "ACTIVE" rather than "CAPTURE_ACTIVE".
func enumName(s string) string {
	for _, p := range []string{"CAPTURE_", "CHANNEL_", "DEVICE_STATE_", "DEMOD_MODE_"} {
		s = strings.TrimPrefix(s, p)
	}
	return s
}

// ratesString renders sample rates as "0.25..3.2 MSPS (n)".
func ratesString(rates []uint64) string {
	if len(rates) == 0 {
		return "-"
	}
	lo, hi := rates[0], rates[0]
	for _, r := range rates {
		if r < lo {
			lo = r
		}
		if r > hi {
			hi = r
		}
	}
	if lo == hi {
		return fmt.Sprintf("%.3g MSPS", float64(lo)/1e6)
	}
	return fmt.Sprintf("%.3g..%.3g MSPS (%d)", float64(lo)/1e6, float64(hi)/1e6, len(rates))
}

// gainsString renders gain elements as ranges, with the names and number form every gain line
// uses (stageGainWords): "LNA 0–40 dB, VGA 0–62 dB, AMP 0 or 11 dB", "TUNER 0–49.6 dB auto". A
// switch (two settings, no step) lists its two levels, which are what --gain takes for off and on.
// An element with no table and a 0..0 range is one the daemon could not read (it never managed to
// open the dongle) and renders "unknown" rather than "0 dB".
func gainsString(gs []*leylinev1.GainElement) string {
	if len(gs) == 0 {
		return "-"
	}
	parts := make([]string, 0, len(gs))
	for _, g := range gs {
		var s string
		switch {
		case len(g.ValidDb) == 0 && g.MinDb == 0 && g.MaxDb == 0:
			parts = append(parts, g.Name+" unknown")
			continue
		case isGainSwitch(g):
			lo, hi := min(g.ValidDb[0], g.ValidDb[1]), max(g.ValidDb[0], g.ValidDb[1])
			s = fmt.Sprintf("%s %s or %s dB", g.Name, gainDB(lo), gainDB(hi))
		case g.MinDb == g.MaxDb:
			s = fmt.Sprintf("%s %s dB", g.Name, gainDB(g.MinDb))
		default:
			s = fmt.Sprintf("%s %s–%s dB", g.Name, gainDB(g.MinDb), gainDB(g.MaxDb))
		}
		if g.SupportsAuto {
			s += " auto"
		}
		parts = append(parts, s)
	}
	return strings.Join(parts, ", ")
}

// squelchString renders a squelch value ("off" for NaN).
func squelchString(db float64) string {
	if units.SquelchOff(db) {
		return "off"
	}
	return fmt.Sprintf("%.1f dB", db)
}

// clientString renders a ClientInfo as "cli:ley (cli_…)".
func clientString(ci *leylinev1.ClientInfo) string {
	if ci == nil {
		return "-"
	}
	return fmt.Sprintf("%s:%s (%s)", ci.Kind, ci.Label, ci.ClientId)
}

// channelFreqLabel renders a channel's absolute frequency (capture center
// plus offset, via leyline.ChannelFrequency) or "?" when its capture is not
// in state or the sum is below zero.
func channelFreqLabel(state *leylinev1.GetStateResponse, ch *leylinev1.Channel) string {
	hz, ok := leyline.ChannelFrequency(state, ch)
	if !ok {
		return "?"
	}
	return units.FormatFrequency(hz)
}

// humanEvent reports whether an event is worth showing to a person watching a
// live verb. An Anchor is the capture's sample-timebase bookkeeping: it is
// emitted whenever a stream (re)starts and carries nothing the user can act
// on, so it stays in --json and out of the live view.
func humanEvent(ev *leylinev1.Event) bool {
	_, anchor := ev.Body.(*leylinev1.Event_Anchor)
	return !anchor
}

// eventLine renders an event as one human-readable line.
func eventLine(ev *leylinev1.Event, state *leylinev1.GetStateResponse) string {
	who := ""
	if ev.CausedBy != nil {
		who = " by " + clientString(ev.CausedBy)
	}
	switch p := ev.Body.(type) {
	case *leylinev1.Event_Device:
		d := p.Device
		return fmt.Sprintf("device %s %s %s%s", d.DeviceId, d.Model, enumName(d.State.String()), who)
	case *leylinev1.Event_Capture:
		c := p.Capture
		return fmt.Sprintf("capture %s %s %s @ %s%s%s", c.CaptureId, enumName(c.State.String()), units.FormatFrequency(c.CenterHz), ratesString([]uint64{c.SampleRate}), gainStatesString(c.Gains, deviceGainElements(state, c.DeviceId)), who)
	case *leylinev1.Event_Channel:
		c := p.Channel
		freq := ""
		if _, ok := leyline.ChannelFrequency(state, c); ok {
			freq = " " + channelFreqLabel(state, c)
		}
		return fmt.Sprintf("channel %s %s%s %s bw %d squelch %s%s", c.ChannelId, enumName(c.State.String()), freq, leyline.ModeName(c.Mode), c.BandwidthHz, squelchString(c.SquelchDb), who)
	case *leylinev1.Event_Sink:
		s := p.Sink
		kind := "sink"
		if sa, ok := s.Kind.(*leylinev1.Sink_SystemAudio); ok {
			kind = fmt.Sprintf("system_audio vol %.2f", sa.SystemAudio.GetVolume())
		}
		return fmt.Sprintf("sink %s on %s %s%s", s.SinkId, s.ChannelId, kind, who)
	case *leylinev1.Event_WriteRejected:
		r := p.WriteRejected
		if r.Error != nil {
			return fmt.Sprintf("write rejected (tag %d) %s: %s%s", r.Tag, r.Error.Code, r.Error.Message, who)
		}
		return fmt.Sprintf("write rejected (tag %d)%s", r.Tag, who)
	case *leylinev1.Event_Anchor:
		return fmt.Sprintf("anchor %s rate %d drift %.2f ppm", p.Anchor.CaptureId, p.Anchor.SampleRate, p.Anchor.DriftPpm)
	}
	return fmt.Sprintf("event seq %d%s", ev.Seq, who)
}

// captureByID finds a capture in a state snapshot.
func captureByID(state *leylinev1.GetStateResponse, id string) *leylinev1.Capture {
	if state == nil {
		return nil
	}
	for _, c := range state.Captures {
		if c.CaptureId == id {
			return c
		}
	}
	return nil
}

// channelByID finds a channel in a state snapshot.
func channelByID(state *leylinev1.GetStateResponse, id string) *leylinev1.Channel {
	if state == nil {
		return nil
	}
	for _, c := range state.Channels {
		if c.ChannelId == id {
			return c
		}
	}
	return nil
}

// gainStatesString renders the capture's gain states in the words every gain line uses
// (stageGainWords: " gain 7.7 dB", " gain LNA 0 dB, VGA 20 dB, AMP off"), so a confirmation
// line shows the value the daemon snapped to; "" when the capture reports none.
func gainStatesString(gains []*leylinev1.GainState, els []*leylinev1.GainElement) string {
	if len(gains) == 0 {
		return ""
	}
	return " " + stageGainWords(gains, els)
}

// rangesPhrase renders tuning ranges as "24.000 MHz to 1.766 GHz", never with a
// dash, so a dash always means "no value" (docs/dev/cli-style.md section 4). A range
// with one frequency in it -- a file device plays back a single centre --
// collapses to that frequency rather than printing it twice.
//
// It returns "" for no ranges rather than a glyph: the absent form belongs to
// the caller, which knows whether it is filling a table cell or a prose line.
func rangesPhrase(rs []*leylinev1.FrequencyRange) string {
	parts := make([]string, 0, len(rs))
	for _, r := range rs {
		if r == nil {
			continue
		}
		lo, hi := r.GetMinHz(), r.GetMaxHz()
		if lo == hi {
			parts = append(parts, units.FormatFrequency(lo))
			continue
		}
		parts = append(parts, units.FormatFrequency(lo)+" to "+units.FormatFrequency(hi))
	}
	return strings.Join(parts, ", ")
}
