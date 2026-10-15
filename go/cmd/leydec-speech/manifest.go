// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// One binary is two decoders. `speech` runs the openai engine on the user's key, and is what
// `ley transcribe`, the app and `ley decode speech` reach; `speech-scripted` runs the scripted
// engine, needs no key and sends nothing, and is what the tests and evals transcribe with. Each
// has its manifest in the repository, decoders/speech/manifest.json and
// decoders/speech-scripted/manifest.json. The files are the source of truth -- discovery reads
// files and executes nothing (docs/design/decoders.md) -- and TestManifestsMatchTheFiles keeps
// them and these identical.
//
// The built-in manifest is the one for the engine on the command line, because its
// credential_provider decides whether the SDK reads a key before the descriptor: the scripted
// engine run by an installed manifest that names no provider must not wait for one.
func manifestFor(engineName string) *leylinev1.DecoderManifest {
	if engineName == "scripted" {
		return scriptedManifest()
	}
	return speechManifest()
}

// speechManifest is decoders/speech/manifest.json. The recipe has no frequency: speech is
// wherever somebody is talking, so `ley decode speech` needs --freq and `ley transcribe` reads a
// recording.
func speechManifest() *leylinev1.DecoderManifest {
	m := baseManifest()
	m.Name = "speech"
	m.Aliases = []string{"transcribe"}
	m.Description = "Speech to text, one record per over, by OpenAI's transcription API on your key: " +
		"each over's squelch-open audio leaves this Mac for api.openai.com, or for the endpoint the key was added with"
	m.CredentialProvider = "openai"
	m.ContactsHosts = []string{"api.openai.com"}
	m.Args = []string{"--engine", "openai"}
	return m
}

// scriptedManifest is decoders/speech-scripted/manifest.json: the same decoder with the scripted
// engine, no provider and no alias, so `transcribe` still means the real one.
func scriptedManifest() *leylinev1.DecoderManifest {
	m := baseManifest()
	m.Name = "speech-scripted"
	m.Description = "Speech to text for tests: replays the lines of the file LEYDEC_SPEECH_SCRIPT names, " +
		"one per over, and sends nothing anywhere"
	m.Args = []string{"--engine", "scripted"}
	return m
}

// baseManifest is what the two share.
func baseManifest() *leylinev1.DecoderManifest {
	return &leylinev1.DecoderManifest{
		Version: "0.2.0",
		License: "Apache-2.0",
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
	}
}

func fieldHints() []*leylinev1.FieldHint {
	const txt, num = leylinev1.FieldType_TEXT, leylinev1.FieldType_NUMBER
	return []*leylinev1.FieldHint{
		{Name: "text", Type: txt, Description: "what the speech engine heard, as it wrote it"},
		{Name: "language", Type: txt, Description: "the language the engine transcribed, as an ISO 639-1 code"},
		{Name: "model", Type: txt, Description: "the model that produced the text"},
		{Name: "confidence", Type: num, Description: "the engine's own confidence in the text, 0 to 1, when it reports one"},
		{Name: "callsigns", Type: txt, Description: "callsigns in the text, comma-separated: a pattern match over the normalised text (prefix, one digit, 1 to 3 letters; a 4-letter suffix such as N0CALL is not matched), not a decoded identity"},
	}
}
