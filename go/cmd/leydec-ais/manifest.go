// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// manifest is what --manifest prints and what decoders/ais/manifest.json in the
// repository holds. The file is the source of truth -- discovery reads files and
// executes nothing (docs/design/decoders.md, "Manifest: a file, not a flag") --
// and TestManifestMatchesTheFile keeps the two identical.
func manifest() *leylinev1.DecoderManifest {
	return &leylinev1.DecoderManifest{
		Name:        "ais",
		Version:     "0.1.0",
		Aliases:     []string{"vessels"},
		Description: "AIS marine vessel tracking, GMSK 9600 on the two 25 kHz channels at 161.975 and 162.025 MHz",
		License:     "Apache-2.0",
		Recipe: &leylinev1.DecoderRecipe{
			// AIS 1 (channel 87B) first, then AIS 2 (88B); DecodeConfig picks
			// the other or overrides.
			FrequenciesHz: []uint64{161_975_000, 162_025_000},
			BandwidthHz:   25_000,
			Mode:          leylinev1.DemodMode_NFM,
			// A capture the job borrows keeps its owner's gain.
			Gain: leylinev1.GainPolicy_GAIN_LEAVE,
		},
		Input: &leylinev1.DecoderInput{
			Mode: leylinev1.InputMode_CONTINUOUS,
			// The raw discriminator, not the listener's audio: GMSK is decoded
			// straight off the instantaneous frequency, and de-emphasis would
			// tilt the bits the slicer keys on.
			Tap:    leylinev1.AudioTap_TAP_DEMOD,
			Signal: leylinev1.DecoderSignal_SIGNAL_AUDIO,
		},
		Outputs: []leylinev1.OutputShape{
			leylinev1.OutputShape_SHAPE_RECORDS,
			leylinev1.OutputShape_SHAPE_ENTITIES,
		},
		// Ten minutes: AIS position reports come every few seconds under way,
		// but a moored or slow vessel and a Class B set report far less often,
		// so a vessel is not gone until it has been quiet for a while.
		EntitySilenceS: 600,
		Fields:         fieldHints(),
		Executable:     "leydec-ais",
		Args:           []string{},
	}
}

func hint(name string, typ leylinev1.FieldType, unit, desc string) *leylinev1.FieldHint {
	return &leylinev1.FieldHint{Name: name, Type: typ, Unit: unit, Description: desc}
}

func fieldHints() []*leylinev1.FieldHint {
	const (
		txt = leylinev1.FieldType_TEXT
		nbr = leylinev1.FieldType_NUMBER
	)
	return []*leylinev1.FieldHint{
		hint("mmsi", nbr, "", "Maritime Mobile Service Identity, the vessel's numeric id"),
		hint("msg_type", nbr, "", "AIS message type number"),
		hint("sog_kn", nbr, "kn", "speed over ground"),
		hint("cog_deg", nbr, "deg", "course over ground, degrees true"),
		hint("heading_deg", nbr, "deg", "true heading, degrees"),
		hint("nav_status", nbr, "", "navigational status code (0 under way, 1 at anchor, 5 moored)"),
		hint("name", txt, "", "vessel name"),
		hint("callsign", txt, "", "radio callsign"),
		hint("ship_type", nbr, "", "ship and cargo type code"),
		hint("destination", txt, "", "voyage destination"),
	}
}
