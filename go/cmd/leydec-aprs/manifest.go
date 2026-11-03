// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// manifest is what --manifest prints and what decoders/aprs/manifest.json in
// the repository holds. The file is the source of truth -- discovery reads
// files and executes nothing (docs/design/decoders.md, "Manifest: a file, not
// a flag") -- and TestManifestMatchesTheFile keeps the two identical. It is
// built here rather than embedded because the file lives outside the Go
// module, and go:embed cannot reach past it.
func manifest() *leylinev1.DecoderManifest {
	return &leylinev1.DecoderManifest{
		Name:        "aprs",
		Version:     "0.1.0",
		Description: "APRS over AX.25, Bell 202 AFSK at 1200 baud on 2 m",
		License:     "Apache-2.0",
		Recipe: &leylinev1.DecoderRecipe{
			// North America first, then the European allocation; DecodeConfig
			// picks another or overrides.
			FrequenciesHz: []uint64{144_390_000, 144_800_000},
			BandwidthHz:   15_000,
			Mode:          leylinev1.DemodMode_NFM,
			// A capture the job borrows keeps its owner's gain.
			Gain: leylinev1.GainPolicy_GAIN_LEAVE,
		},
		Input: &leylinev1.DecoderInput{
			Mode: leylinev1.InputMode_CONTINUOUS,
			// The discriminator tap would suit a data decoder better, but the
			// normalising discriminator in pkg/decoders/afsk reads de-emphasised
			// audio without losing a packet, and TAP_AUDIO is what every channel
			// has.
			Tap: leylinev1.AudioTap_TAP_AUDIO,
		},
		Outputs: []leylinev1.OutputShape{
			leylinev1.OutputShape_SHAPE_RECORDS,
			leylinev1.OutputShape_SHAPE_ENTITIES,
		},
		// Half an hour: a beacon every ten to thirty minutes is normal, and a
		// station is not gone until it has missed several.
		EntitySilenceS: 1800,
		Fields:         fieldHints(),
		Display:        display(),
		Executable:     "leydec-aprs",
		Args:           []string{},
	}
}

func hint(name, label string, typ leylinev1.FieldType, unit, desc string) *leylinev1.FieldHint {
	return &leylinev1.FieldHint{Name: name, Label: label, Type: typ, Unit: unit, Description: desc}
}

func fieldHints() []*leylinev1.FieldHint {
	const (
		txt = leylinev1.FieldType_TEXT
		nbr = leylinev1.FieldType_NUMBER
		flg = leylinev1.FieldType_FLAG
	)
	return []*leylinev1.FieldHint{
		hint("symbol", "Symbol", txt, "", "APRS symbol as its table identifier and code"),
		hint("comment", "Comment", txt, "", "the free text the station sent"),
		hint("path", "Path", txt, "", "digipeater path, used hops marked with a star"),
		hint("destination", "Destination", txt, "", "AX.25 destination address, usually the software's identifier"),
		hint("speed_kmh", "Speed", nbr, "km/h", "speed over ground"),
		hint("course_deg", "Course", nbr, "deg", "course over ground, degrees true"),
		hint("temp_c", "Temperature", nbr, "degC", "air temperature"),
		hint("wind_kmh", "Wind", nbr, "km/h", "sustained wind speed"),
		hint("wind_dir_deg", "Wind direction", nbr, "deg", "wind direction"),
		hint("gust_kmh", "Gust", nbr, "km/h", "peak gust in the last five minutes"),
		hint("rain_mm_1h", "Rain, last hour", nbr, "mm", "rain in the last hour"),
		hint("humidity_pct", "Humidity", nbr, "%", "relative humidity"),
		hint("pressure_hpa", "Pressure", nbr, "hPa", "barometric pressure"),
		hint("seq", "Sequence", txt, "", "telemetry sequence number"),
		hint("a1", "Analogue 1", nbr, "", "telemetry analogue channel 1"),
		hint("a2", "Analogue 2", nbr, "", "telemetry analogue channel 2"),
		hint("a3", "Analogue 3", nbr, "", "telemetry analogue channel 3"),
		hint("a4", "Analogue 4", nbr, "", "telemetry analogue channel 4"),
		hint("a5", "Analogue 5", nbr, "", "telemetry analogue channel 5"),
		hint("digital", "Digital bits", txt, "", "telemetry digital bits, most significant first"),
		hint("addressee", "Addressee", txt, "", "who a message is for"),
		hint("text", "Message", txt, "", "a message's text"),
		hint("msg_id", "Message id", txt, "", "message identifier an ack or reject quotes"),
		hint("object_name", "Object name", txt, "", "name of an object or item"),
		hint("alive", "Alive", flg, "", "whether an object or item is live or killed"),
	}
}
