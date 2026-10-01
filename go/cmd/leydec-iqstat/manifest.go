// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// manifest is what --manifest prints and what decoders/iqstat/manifest.json in
// the repository holds. The file is the source of truth -- discovery reads
// files and executes nothing (docs/design/decoders.md, "Manifest: a file, not
// a flag") -- and TestManifestMatchesTheFile keeps the two identical. It is
// built here rather than embedded because the file lives outside the Go module.
func manifest() *leylinev1.DecoderManifest {
	return &leylinev1.DecoderManifest{
		Name:        "iqstat",
		Version:     "0.1.0",
		Description: "IQ path test decoder: block power over the capture's complex baseband",
		License:     "Apache-2.0",
		Recipe: &leylinev1.DecoderRecipe{
			// A placeholder frequency: iqstat reads whatever IQ it is handed, so
			// the recipe only needs a valid capture to attach to.
			FrequenciesHz: []uint64{100_000_000},
			// The daemon chooses the capture rate; a bandwidth is meaningless for
			// a decoder that takes the whole baseband.
			SampleRate:  0,
			BandwidthHz: 0,
			// NFM is a valid recipe; the mode is ignored on the IQ path, which
			// gets raw baseband rather than a demodulated channel.
			Mode: leylinev1.DemodMode_NFM,
		},
		Input: &leylinev1.DecoderInput{
			Mode: leylinev1.InputMode_CONTINUOUS,
			// The reason this plugin exists: it reads IQ, not audio.
			Signal: leylinev1.DecoderSignal_SIGNAL_IQ,
		},
		Outputs:    []leylinev1.OutputShape{leylinev1.OutputShape_SHAPE_RECORDS},
		Fields:     fieldHints(),
		Executable: "leydec-iqstat",
		Args:       []string{},
	}
}

func hint(name string, typ leylinev1.FieldType, unit, desc string) *leylinev1.FieldHint {
	return &leylinev1.FieldHint{Name: name, Type: typ, Unit: unit, Description: desc}
}

func fieldHints() []*leylinev1.FieldHint {
	const (
		nbr = leylinev1.FieldType_NUMBER
		itg = leylinev1.FieldType_INTEGER
	)
	return []*leylinev1.FieldHint{
		hint("power_dbfs", nbr, "dBFS", "mean power of the block, 10*log10(mean |x|^2)"),
		hint("sample_rate", itg, "Hz", "the capture's IQ sample rate"),
		hint("samples", itg, "", "samples counted since the last record"),
		hint("center_hz", itg, "Hz", "the capture's center frequency"),
	}
}
