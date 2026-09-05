package cli

import (
	"fmt"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// enumName strips the "CAPTURE_"/"CHANNEL_" style prefix from proto enum names
// so tables read "ACTIVE" rather than "CAPTURE_ACTIVE".
func enumName(s string) string {
	for _, p := range []string{"CAPTURE_", "CHANNEL_", "DEVICE_STATE_", "DEMOD_MODE_"} {
		s = strings.TrimPrefix(s, p)
	}
	return s
}

// rangesString renders tuning ranges as "24 MHz-1.766 GHz".
func rangesString(rs []*leylinev1.FrequencyRange) string {
	parts := make([]string, 0, len(rs))
	for _, r := range rs {
		parts = append(parts, leyline.FormatFrequency(r.MinHz)+"-"+leyline.FormatFrequency(r.MaxHz))
	}
	if len(parts) == 0 {
		return "-"
	}
	return strings.Join(parts, ",")
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

// gainsString renders gain elements as "tuner 0..49.6dB(auto)".
func gainsString(gs []*leylinev1.GainElement) string {
	if len(gs) == 0 {
		return "-"
	}
	parts := make([]string, 0, len(gs))
	for _, g := range gs {
		s := fmt.Sprintf("%s %g..%gdB", g.Name, g.MinDb, g.MaxDb)
		if g.SupportsAuto {
			s += "(auto)"
		}
		parts = append(parts, s)
	}
	return strings.Join(parts, ",")
}

// squelchString renders a squelch value ("off" for NaN).
func squelchString(db float64) string {
	if leyline.SquelchOff(db) {
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

// channelFreq returns the absolute frequency of a channel given its capture.
func channelFreq(ch *leylinev1.Channel, cap *leylinev1.Capture) uint64 {
	if cap == nil {
		return 0
	}
	return uint64(int64(cap.CenterHz) + ch.OffsetHz)
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
		return fmt.Sprintf("capture %s %s %s @ %s%s%s", c.CaptureId, enumName(c.State.String()), leyline.FormatFrequency(c.CenterHz), ratesString([]uint64{c.SampleRate}), gainStatesString(c.Gains), who)
	case *leylinev1.Event_Channel:
		c := p.Channel
		freq := ""
		if cap := captureByID(state, c.CaptureId); cap != nil {
			freq = " " + leyline.FormatFrequency(channelFreq(c, cap))
		}
		return fmt.Sprintf("channel %s %s%s %s bw %d squelch %s%s", c.ChannelId, enumName(c.State.String()), freq, leyline.ModeName(c.Mode), c.BandwidthHz, squelchString(c.SquelchDb), who)
	case *leylinev1.Event_Sink:
		s := p.Sink
		kind := "sink"
		if sa, ok := s.Kind.(*leylinev1.Sink_SystemAudio); ok {
			kind = fmt.Sprintf("system_audio vol %.2f", sa.SystemAudio.Volume)
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

// gainStatesString renders the capture's gain states (" gain TUNER 7.7 dB"), so a
// confirmation line shows the value the daemon snapped to.
func gainStatesString(gains []*leylinev1.GainState) string {
	var b strings.Builder
	for _, g := range gains {
		if g.Auto {
			fmt.Fprintf(&b, " gain %s auto", g.Element)
		} else {
			fmt.Fprintf(&b, " gain %s %.1f dB", g.Element, g.Db)
		}
	}
	return b.String()
}
