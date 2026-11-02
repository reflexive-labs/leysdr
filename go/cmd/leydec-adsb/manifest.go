// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// manifest is what --manifest prints and what decoders/adsb/manifest.json in the repository
// holds. The file is the source of truth -- discovery reads files and executes nothing
// (docs/design/decoders.md, "Manifest: a file, not a flag") -- and TestManifestMatchesTheFile
// keeps the two identical.
func manifest() *leylinev1.DecoderManifest {
	return &leylinev1.DecoderManifest{
		Name:        "adsb",
		Version:     "0.1.0",
		Aliases:     []string{"aircraft"},
		Description: "ADS-B and Mode S aircraft on 1090 MHz: identification, position, velocity, altitude and squawk",
		License:     "Apache-2.0",
		Recipe: &leylinev1.DecoderRecipe{
			FrequenciesHz: []uint64{1_090_000_000},
			// A reply is 2 MHz wide and a half-bit is 0.5 µs, so the decoder needs the whole
			// band at 2.4 MSPS, centred.
			SampleRate: 2_400_000,
			// The mode is ignored on the IQ path; AM is the nearest to what the decoder does
			// with the samples, which is take their magnitude.
			Mode: leylinev1.DemodMode_AM,
			// A capture the job borrows keeps its owner's gain.
			Gain: leylinev1.GainPolicy_GAIN_LEAVE,
		},
		Input: &leylinev1.DecoderInput{
			Mode:   leylinev1.InputMode_CONTINUOUS,
			Signal: leylinev1.DecoderSignal_SIGNAL_IQ,
		},
		Outputs: []leylinev1.OutputShape{
			leylinev1.OutputShape_SHAPE_RECORDS,
			leylinev1.OutputShape_SHAPE_ENTITIES,
		},
		// An aircraft in range sends several squitters a second; a minute without one means it
		// has gone out of range or landed.
		EntitySilenceS:        60,
		NeedsDedicatedCapture: true,
		Fields:                fieldHints(),
		Display:               display(),
		Executable:            "leydec-adsb",
		Args:                  []string{},
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
		hint("icao", txt, "", "the aircraft's 24-bit address, six hex digits"),
		hint("callsign", txt, "", "the flight's callsign or the aircraft's registration, as it sends it"),
		hint("category", txt, "", "emitter category: set and code, A1 light to A5 heavy, A7 rotorcraft"),
		hint("altitude_ft", nbr, "ft", "pressure altitude, or GNSS height for type codes 20 to 22"),
		hint("ground_speed_kn", nbr, "kn", "ground speed"),
		hint("track_deg", nbr, "deg", "track over ground, degrees true"),
		hint("airspeed_kn", nbr, "kn", "indicated or true airspeed, sent when ground speed is not"),
		hint("heading_deg", nbr, "deg", "magnetic heading, sent with airspeed"),
		hint("vertical_rate_fpm", nbr, "ft/min", "vertical rate, negative descending"),
		hint("squawk", txt, "", "the transponder's identity code, four octal digits"),
		hint("df", nbr, "", "Mode S downlink format: 17 ADS-B, 18 non-transponder ADS-B, 11 all-call reply, 4, 5, 20, 21 surveillance replies"),
		hint("tc", nbr, "", "ADS-B type code: 1-4 identification, 5-8 surface position, 9-18 and 20-22 airborne position, 19 velocity"),
	}
}
