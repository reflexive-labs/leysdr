// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"fmt"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/bandplan"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// A speech decoder hears overs: the daemon sends a provider the audio while the squelch is open
// (docs/design/ai.md, "Segmented input"). On a channel whose squelch never closes that is all of
// it, sixty minutes an hour, cut into pieces at the manifest's max_segment_ms. A live job's
// channel gets an auto squelch at the floor plus 10 dB, so the channels that stay open are the
// ones whose stations never stop transmitting, which the band plan names.

// neverQuietBand is the band hz is in when that band's stations transmit without a break: FM
// and AM broadcast, and NOAA weather radio, which loops its forecast. Nil anywhere else.
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

// openSquelchCost is the line decode and watch print before decoder starts on hz when its squelch
// will never close and every minute of the audio leaves this Mac, or "" when it does not apply:
// a decoder that is not SEGMENTED, one that sends nothing anywhere, or a band that goes quiet.
func openSquelchCost(m *leylinev1.DecoderManifest, hz uint64) string {
	hosts := m.GetContactsHosts()
	if m.GetInput().GetMode() != leylinev1.InputMode_SEGMENTED || len(hosts) == 0 {
		return ""
	}
	b := neverQuietBand(hz)
	if b == nil {
		return ""
	}
	return fmt.Sprintf("%s is %s, which never goes quiet: this channel's squelch never closes, so every minute of its audio goes to %s (60 min an hour)",
		units.FormatFrequency(hz), b.Name, strings.Join(hosts, ", "))
}

// confirmOpenSquelch states openSquelchCost before anything starts and asks, as ley transcribe
// asks before it sends a recording: --yes skips the question, and without a terminal to answer
// and without --yes it refuses with a usage error, because nobody agreed to send the audio.
// False with no error is a person who said no. rerun is the command to run with --yes.
func confirmOpenSquelch(ctx context.Context, s *verbSession, decoder string, hz uint64, yes bool, rerun string) (bool, error) {
	resp, err := s.Client.ListDecoders(ctx)
	if err != nil {
		// The daemon refuses an unknown decoder itself, with the message decodeFailure turns.
		return true, nil
	}
	var line string
	for _, m := range resp.GetDecoders() {
		if m.GetName() == decoder {
			line = openSquelchCost(m, hz)
		}
	}
	if line == "" {
		return true, nil
	}
	app := s.app
	if yes {
		fmt.Fprintf(app.Stderr, "%s.\n", upperFirst(line))
		return true, nil
	}
	if app.IsInTTY == nil || !app.IsInTTY() {
		fmt.Fprintf(app.Stderr, "%s.\n", upperFirst(line))
		return false, usageErrorf("stdin is not a terminal, so nobody can confirm sending the audio. Run: %s --yes", rerun)
	}
	fmt.Fprintf(app.Stderr, "%s. Start? [y/N] ", upperFirst(line))
	answer, _ := bufio.NewReader(app.Stdin).ReadString('\n')
	if a := strings.ToLower(strings.TrimSpace(answer)); a != "y" && a != "yes" {
		fmt.Fprintln(app.Stderr, "Nothing was started, and nothing was sent.")
		return false, nil
	}
	return true, nil
}

// upperFirst capitalises a sentence that begins with a word, and leaves one that begins with a
// number as it is.
func upperFirst(s string) string {
	if s == "" || s[0] < 'a' || s[0] > 'z' {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}
