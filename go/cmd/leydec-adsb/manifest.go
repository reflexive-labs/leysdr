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
			// 40 dB on a capture the job creates or retunes; one it borrows keeps its owner's
			// gain. On 2026-11-02 the owner's R820T at gain 30 decoded nothing on 1090 MHz and
			// at 40 decoded 19 frames: Mode S replies arrive weak, and the radio's usual level
			// for VHF voice leaves them under the noise.
			Gain:   leylinev1.GainPolicy_GAIN_FIXED,
			GainDb: 40,
		},
		Input: &leylinev1.DecoderInput{
			Mode:   leylinev1.InputMode_CONTINUOUS,
			Signal: leylinev1.DecoderSignal_SIGNAL_IQ,
		},
		Outputs: []leylinev1.OutputShape{
			leylinev1.OutputShape_SHAPE_RECORDS,
			leylinev1.OutputShape_SHAPE_ENTITIES,
		},
		// An aircraft in range sends several squitters a second, but one near the edge of range
		// is heard in bursts. On live ADS-B on 2026-11-03 a 60 s timeout dropped such aircraft
		// off the table and brought them back a little later; two minutes without a squitter
		// means it has gone out of range or landed.
		EntitySilenceS:        120,
		NeedsDedicatedCapture: true,
		Fields:                fieldHints(),
		Display:               display(),
		Executable:            "leydec-adsb",
		Args:                  []string{},
	}
}

func hint(name, label string, typ leylinev1.FieldType, unit, desc string) *leylinev1.FieldHint {
	return &leylinev1.FieldHint{Name: name, Label: label, Type: typ, Unit: unit, Description: desc}
}

func fieldHints() []*leylinev1.FieldHint {
	const (
		txt = leylinev1.FieldType_TEXT
		nbr = leylinev1.FieldType_NUMBER
	)
	return []*leylinev1.FieldHint{
		hint("icao", "ICAO address", txt, "", "the aircraft's 24-bit address, six hex digits"),
		hint("callsign", "Callsign", txt, "", "the flight's callsign or the aircraft's registration, as it sends it"),
		hint("category", "Category", txt, "", "emitter category: set and code, A1 light to A5 heavy, A7 rotorcraft"),
		hint("altitude_ft", "Altitude", nbr, "ft", "pressure altitude, or GNSS height for type codes 20 to 22"),
		hint("ground_speed_kn", "Ground speed", nbr, "kn", "ground speed"),
		hint("track_deg", "Track", nbr, "deg", "track over ground, degrees true"),
		hint("airspeed_kn", "Airspeed", nbr, "kn", "indicated or true airspeed, sent when ground speed is not"),
		hint("heading_deg", "Heading", nbr, "deg", "magnetic heading, sent with airspeed"),
		hint("vertical_rate_fpm", "Vertical rate", nbr, "ft/min", "vertical rate, negative descending"),
		hint("squawk", "Squawk", txt, "", "the transponder's identity code, four octal digits"),
		hint("df", "Downlink format", nbr, "", "Mode S downlink format: 17 ADS-B, 18 non-transponder ADS-B, 11 all-call reply, 4, 5, 20, 21 surveillance replies"),
		hint("tc", "Type code", nbr, "", "ADS-B type code: 1-4 identification, 5-8 surface position, 9-18 and 20-22 airborne position, 19 velocity"),
	}
}
