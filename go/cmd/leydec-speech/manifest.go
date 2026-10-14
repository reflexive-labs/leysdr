// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// manifest is what --manifest prints and what decoders/speech/manifest.json in
// the repository holds. The file is the source of truth -- discovery reads
// files and executes nothing (docs/design/decoders.md) -- and
// TestManifestMatchesTheFile keeps the two identical.
//
// The recipe has no frequency: speech is wherever somebody is talking, so
// `ley decode speech` needs --freq and `ley transcribe` reads a recording. The
// args run the scripted engine, the only one this build has; it calls no
// provider, so credential_provider and contacts_hosts stay empty until an
// engine that does is added.
func manifest() *leylinev1.DecoderManifest {
	return &leylinev1.DecoderManifest{
		Name:        "speech",
		Version:     "0.1.0",
		Aliases:     []string{"transcribe"},
		Description: "Speech to text, one record per over; this build's engine replays a script",
		License:     "Apache-2.0",
		Recipe: &leylinev1.DecoderRecipe{
			Mode: leylinev1.DemodMode_NFM,
			Gain: leylinev1.GainPolicy_GAIN_LEAVE,
		},
		Input: &leylinev1.DecoderInput{
			// One over at a time, cut at the squelch with the default 500 ms pre-roll and
			// hang, so one record is one speaker (docs/design/ai.md, "Segmented input").
			Mode: leylinev1.InputMode_SEGMENTED,
			// What a listener hears, de-emphasised and limited, which is the audio a speech
			// engine is trained on.
			Tap: leylinev1.AudioTap_TAP_AUDIO,
		},
		Outputs:    []leylinev1.OutputShape{leylinev1.OutputShape_SHAPE_RECORDS},
		Fields:     fieldHints(),
		Executable: "leydec-speech",
		Args:       []string{"--engine", "scripted"},
	}
}

func fieldHints() []*leylinev1.FieldHint {
	const txt, num = leylinev1.FieldType_TEXT, leylinev1.FieldType_NUMBER
	return []*leylinev1.FieldHint{
		{Name: "text", Type: txt, Description: "what the speech engine heard, as it wrote it"},
		{Name: "language", Type: txt, Description: "the language the engine transcribed, as an ISO 639-1 code"},
		{Name: "model", Type: txt, Description: "the model that produced the text"},
		{Name: "confidence", Type: num, Description: "the engine's own confidence in the text, 0 to 1, when it reports one"},
		{Name: "callsigns", Type: txt, Description: "callsigns in the text, comma-separated: a pattern match over the normalised text, not a decoded identity"},
	}
}
