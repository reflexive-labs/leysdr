// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"fmt"
	"math"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/bandplan"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// A speech decoder hears overs: the daemon sends a provider the audio while the squelch is open
// (docs/design/ai.md, "Segmented input"). On a channel whose squelch never closes that is all of
// it, sixty minutes an hour, cut into pieces at the manifest's max_segment_ms.

// decodeListen is what a decode job will listen through, as far as ley can tell before it
// starts: the frequency and mode, and for a borrowed channel whether its squelch is off. A
// channel the job makes gets an auto squelch from the daemon in NFM and AM and none in any other
// mode.
type decodeListen struct {
	hz         uint64
	mode       leylinev1.DemodMode
	borrowed   bool
	squelchOff bool
}

// neverQuietBand is the band hz is in when that band's stations transmit without a break: FM
// and AM broadcast, and NOAA weather radio, which loops its forecast. Nil anywhere else. It is the
// fallback when the channel itself would close: an auto squelch on a carrier never does.
func neverQuietBand(hz uint64) *bandplan.Band {
	b := bandplan.BandFor(hz)
	if b == nil {
		return nil
	}
	if b.Mode == leylinev1.DemodMode_WFM || b.Name == "AM broadcast" || b.Name == "NOAA weather" {
		return b
	}
	return nil
}

// squelchGates says whether a squelch gates a channel in mode: NFM and AM.
func squelchGates(mode leylinev1.DemodMode) bool {
	return mode == leylinev1.DemodMode_NFM || mode == leylinev1.DemodMode_AM
}

// openSquelchCost is the line decode and watch print before decoder starts listening through l
// when its squelch will never close and every minute of the audio leaves this Mac, or "" when it
// does not apply: a decoder that is not SEGMENTED, one that sends nothing anywhere, or a channel
// that goes quiet. The channel decides it first: a borrowed one with its squelch off, or a channel
// of the job's own in a mode with no squelch gate; the band plan is the fallback.
func openSquelchCost(m *leylinev1.DecoderManifest, l decodeListen) string {
	hosts := m.GetContactsHosts()
	if m.GetInput().GetMode() != leylinev1.InputMode_SEGMENTED || len(hosts) == 0 {
		return ""
	}
	where := units.FormatFrequency(l.hz) + " " + strings.ToUpper(leyline.ModeName(l.mode))
	var why string
	switch {
	case l.borrowed && l.squelchOff:
		why = where + " has its squelch off"
	case !l.borrowed && !squelchGates(l.mode):
		why = where + " has no squelch"
	default:
		b := neverQuietBand(l.hz)
		if b == nil {
			return ""
		}
		why = fmt.Sprintf("%s is %s, which never goes quiet", units.FormatFrequency(l.hz), b.Name)
	}
	return why + ": this channel's squelch never closes, so every minute of its audio goes to " +
		strings.Join(hosts, ", ") + " (60 min an hour)"
}

// findDecoder is the installed decoder called name, or nil when ley cannot list them or none is;
// the daemon refuses an unknown decoder itself.
func findDecoder(ctx context.Context, s *verbSession, name string) *leylinev1.DecoderManifest {
	resp, err := s.Client.ListDecoders(ctx)
	if err != nil {
		return nil
	}
	for _, m := range resp.GetDecoders() {
		if m.GetName() == name {
			return m
		}
	}
	return nil
}

// decodeChannelTarget fills in a decode's channel: with --channel, the channel it borrows (an
// id, id prefix, row number or frequency, or "this" for the one ley set would pick); without,
// the mode of the channel it makes, which for a decoder whose recipe names no frequency (speech)
// is the band plan's mode at hz, as ley tune picks one: WFM on broadcast FM, AM on airband. It
// returns what the job will listen through.
func decodeChannelTarget(s *verbSession, m *leylinev1.DecoderManifest, sel string, hz uint64,
	cfg *leylinev1.DecodeConfig,
) (decodeListen, error) {
	if sel != "" {
		if s.State == nil {
			return decodeListen{}, usageErrorf("--channel needs the daemon's channels, and ley could not read them")
		}
		if sel == "this" {
			sel = ""
		}
		ch, _, err := resolveTarget(s, sel, "", decodeChannelHint)
		if err != nil {
			return decodeListen{}, err
		}
		cfg.ChannelId = ch.GetChannelId()
		at, _ := leyline.ChannelFrequency(s.State, ch)
		return decodeListen{hz: at, mode: ch.GetMode(), borrowed: true, squelchOff: math.IsNaN(ch.GetSquelchDb())}, nil
	}
	mode := m.GetRecipe().GetMode()
	if mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
		mode = leylinev1.DemodMode_NFM
	}
	if m != nil && len(m.GetRecipe().GetFrequenciesHz()) == 0 && hz != 0 {
		mode, _ = bandplan.DefaultMode(hz)
		cfg.Mode = mode
	}
	if hz == 0 && m != nil && len(m.GetRecipe().GetFrequenciesHz()) > 0 {
		hz = m.GetRecipe().GetFrequenciesHz()[0]
	}
	return decodeListen{hz: hz, mode: mode}, nil
}

// decodeChannelHint is how decode and watch name a channel in resolveTarget's messages.
var decodeChannelHint = targetHint{flag: "--channel", pick: "--channel N", example: "ley decode speech --channel 2"}

// confirmOpenSquelch states openSquelchCost before anything starts and asks, as ley transcribe
// asks before it sends a recording: --yes skips the question, and without a terminal to answer
// and without --yes it refuses with a usage error, because nobody agreed to send the audio.
// False with no error is a person who said no. rerun is the command to run with --yes.
func confirmOpenSquelch(s *verbSession, m *leylinev1.DecoderManifest, l decodeListen, yes bool, rerun string) (bool, error) {
	if m == nil {
		return true, nil
	}
	line := openSquelchCost(m, l)
	if line == "" {
		return true, nil
	}
	app := s.app
	if yes {
		fmt.Fprintf(app.Stderr, "%s.\n", line)
		return true, nil
	}
	if app.IsInTTY == nil || !app.IsInTTY() {
		fmt.Fprintf(app.Stderr, "%s.\n", line)
		return false, usageErrorf("stdin is not a terminal, so nobody can confirm sending the audio. Run: %s --yes", rerun)
	}
	fmt.Fprintf(app.Stderr, "%s. Start? [y/N] ", line)
	answer, _ := bufio.NewReader(app.Stdin).ReadString('\n')
	if a := strings.ToLower(strings.TrimSpace(answer)); a != "y" && a != "yes" {
		fmt.Fprintln(app.Stderr, "Nothing was started, and nothing was sent.")
		return false, nil
	}
	return true, nil
}
