// SPDX-License-Identifier: Apache-2.0

package main

import "strings"

// hintEnv names a vocabulary hint that takes the place of --hint, so a measurement can vary the
// hint without reinstalling the manifest that carries --hint.
const hintEnv = "LEYDEC_SPEECH_HINT"

// defaultHint is the vocabulary every call starts with: the phonetic alphabet, spelled the way
// go/pkg/callsign reads it, and the words of a net. A speech model writes a callsign spoken
// phonetically as the words it heard, and with these in the prompt it spells them the way the
// callsign pattern folds them back. Whisper reads at most 224 tokens of prompt, keeping the last,
// so this stays short and --hint, which comes after it, is never the part cut.
const defaultHint = "Amateur radio. Alpha, Bravo, Charlie, Delta, Echo, Foxtrot, Golf, Hotel, India, " +
	"Juliet, Kilo, Lima, Mike, November, Oscar, Papa, Quebec, Romeo, Sierra, Tango, Uniform, " +
	"Victor, Whiskey, X-ray, Yankee, Zulu. Niner. Net control, check-in, go ahead, over, roger, " +
	"copy, QSL, QSO, 73, this is, clear, monitoring, repeater, simplex."

// vocabularyHint is the prompt sent with the audio: the default, then the hint from
// LEYDEC_SPEECH_HINT when it is set and from --hint otherwise.
func vocabularyHint(flagHint string, getenv func(string) string) string {
	extra := strings.TrimSpace(flagHint)
	if env := strings.TrimSpace(getenv(hintEnv)); env != "" {
		extra = env
	}
	if extra == "" {
		return defaultHint
	}
	return defaultHint + " " + extra
}
