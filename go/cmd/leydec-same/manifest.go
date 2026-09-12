// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"

// manifest is what --manifest prints and what decoders/same/manifest.json in
// the repository holds. The file is the source of truth -- discovery reads
// files and executes nothing (docs/design/decoders.md, "Manifest") -- and
// TestManifestMatchesTheFile keeps the two identical.
func manifest() *leylinev1.DecoderManifest {
	return &leylinev1.DecoderManifest{
		Name:        "same",
		Version:     "0.1.0",
		Description: "SAME/EAS alert headers on NOAA weather radio, AFSK at 520.83 baud",
		License:     "Apache-2.0",
		Recipe: &leylinev1.DecoderRecipe{
			// The seven NWR channels, 162.400 to 162.550 MHz; the first is the
			// default and DecodeConfig picks another or overrides.
			FrequenciesHz: []uint64{
				162_400_000, 162_425_000, 162_450_000, 162_475_000,
				162_500_000, 162_525_000, 162_550_000,
			},
			BandwidthHz: 15_000,
			Mode:        leylinev1.DemodMode_NFM,
			Gain:        leylinev1.GainPolicy_GAIN_LEAVE,
		},
		Input: &leylinev1.DecoderInput{
			Mode: leylinev1.InputMode_CONTINUOUS,
			// The SAME tones (1562/2083 Hz) sit in the audio band, and the
			// normalising discriminator in pkg/decoders/same reads them off the
			// audio without loss; TAP_AUDIO is what every channel has.
			Tap: leylinev1.AudioTap_TAP_AUDIO,
		},
		// SAME produces only records, each with a validity window -- there is
		// nothing to aggregate into an entity (docs/design/decoders.md, §5).
		Outputs:    []leylinev1.OutputShape{leylinev1.OutputShape_SHAPE_RECORDS},
		Fields:     fieldHints(),
		Executable: "leydec-same",
		Args:       []string{},
	}
}

func hint(name string, typ leylinev1.FieldType, unit, desc string) *leylinev1.FieldHint {
	return &leylinev1.FieldHint{Name: name, Type: typ, Unit: unit, Description: desc}
}

func fieldHints() []*leylinev1.FieldHint {
	const txt = leylinev1.FieldType_TEXT
	return []*leylinev1.FieldHint{
		hint("org", txt, "", "originator: EAS, WXR, CIV or PEP"),
		hint("event", txt, "", "three-letter SAME event code, e.g. TOR, RWT"),
		hint("event_name", txt, "", "human name for the event code"),
		hint("fips", txt, "", "affected counties as five-digit FIPS codes, comma-separated"),
		hint("fips_raw", txt, "", "location codes as the raw six-digit PSSCCC, comma-separated"),
		hint("callsign", txt, "", "the sending station's id, same as device_id"),
		hint("purge", txt, "", "how long the alert is valid, HHMM"),
		hint("issued", txt, "", "issue time as day-of-year and UTC time, JJJHHMM"),
	}
}
