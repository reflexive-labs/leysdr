// SPDX-License-Identifier: Apache-2.0

// Package callsign finds amateur callsigns in speech text. A speech engine
// writes a callsign the way it was spoken -- "whiskey six alpha bravo
// charlie", "W 6 ABC", "W6ABC" -- so Normalise first folds the phonetic
// alphabet, spoken digits and spelled letters into compact runs, and Find then
// applies the callsign pattern to each run: a prefix of one or two letters or
// of a digit and a letter, one digit, and a suffix of one to three letters, so
// a four-letter suffix (N0CALL) is not matched. What Find returns is a pattern
// match over a model's text, not a decoded identity, and a record that carries
// it says so (docs/design/ai.md, "Callsigns are a pattern match").
package callsign

import (
	"regexp"
	"strings"
	"unicode"
)

// spoken maps a spoken word to the character it spells: the NATO phonetic
// alphabet with its common spellings, the digits with the ham forms
// ("niner", "oh"), and the words for the portable stroke.
var spoken = map[string]string{
	"alpha": "A", "alfa": "A", "bravo": "B", "charlie": "C", "delta": "D", "echo": "E",
	"foxtrot": "F", "golf": "G", "hotel": "H", "india": "I", "juliet": "J", "juliett": "J",
	"kilo": "K", "lima": "L", "mike": "M", "november": "N", "oscar": "O", "papa": "P",
	"quebec": "Q", "romeo": "R", "sierra": "S", "tango": "T", "uniform": "U", "victor": "V",
	"whiskey": "W", "whisky": "W", "x-ray": "X", "xray": "X", "yankee": "Y", "zulu": "Z",
	"zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
	"six": "6", "seven": "7", "eight": "8", "nine": "9", "niner": "9",
	"slash": "/", "stroke": "/",
}

// fillers are words an operator says inside a spelled callsign that spell
// nothing: "kilo six number two". They are dropped inside a run and kept as
// words outside one.
var fillers = map[string]bool{"number": true}

// Normalise rewrites text so that every spelled or spoken callsign is one
// upper-case token: "this is whiskey six alpha bravo charlie" becomes
// "this is W6ABC". A run is a sequence of phonetic words, digit words,
// digits, single letters and letter-digit tokens; it is joined without spaces
// and upper-cased, and ends at a word that ends in a comma, a semicolon, a
// full stop, a question mark or an exclamation mark, so two callsigns in a
// list stay two. Every other word is kept as written, so the result still
// reads as the sentence. The lower-case words "a" and "i" are read as words,
// not letters, because in running text they nearly always are.
func Normalise(text string) string {
	toks := scan(text)
	out := make([]string, len(toks))
	for i, t := range toks {
		out[i] = t.text
	}
	return strings.Join(out, " ")
}

// token is one word of the normalised text, or one run.
type token struct {
	text string
	run  bool
	// phonetic is set on a run that holds a spoken word ("bravo", "six"), which
	// is a person spelling something out rather than a word that happens to mix
	// letters and digits.
	phonetic bool
}

// scan splits text into words and runs, as Normalise describes.
func scan(text string) []token {
	var out []token
	var run strings.Builder
	phonetic := false
	var pending []string // fillers seen inside a run, kept if the run ends there
	flush := func() {
		if run.Len() > 0 {
			out = append(out, token{text: run.String(), run: true, phonetic: phonetic})
			run.Reset()
			phonetic = false
		}
		for _, f := range pending {
			out = append(out, token{text: f})
		}
		pending = pending[:0]
	}
	for _, field := range strings.Fields(text) {
		word := strings.TrimFunc(field, func(r rune) bool {
			return !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '/'
		})
		if ch, ok := spelled(word); ok {
			pending = pending[:0]
			run.WriteString(ch)
			_, isSpoken := spoken[strings.ToLower(word)]
			phonetic = phonetic || isSpoken
			if strings.ContainsAny(field[len(field)-1:], ",;.?!") {
				flush()
			}
			continue
		}
		if run.Len() > 0 && fillers[strings.ToLower(word)] {
			pending = append(pending, field)
			continue
		}
		flush()
		out = append(out, token{text: field})
	}
	flush()
	return out
}

// spelled is what one word contributes to a run, if it belongs in one.
func spelled(word string) (string, bool) {
	if word == "" {
		return "", false
	}
	if ch, ok := spoken[strings.ToLower(word)]; ok {
		return ch, true
	}
	if word == "a" || word == "i" {
		return "", false
	}
	hasDigit := false
	for _, r := range word {
		switch {
		case r >= '0' && r <= '9':
			hasDigit = true
		case r == '/', r < unicode.MaxASCII && unicode.IsLetter(r):
		default:
			return "", false
		}
	}
	// A single letter, or a token holding a digit ("6", "W6ABC", "W6ABC/P");
	// a plain word of letters is a word.
	if len([]rune(word)) == 1 || hasDigit {
		return strings.ToUpper(word), true
	}
	return "", false
}

// pattern is an amateur callsign: a prefix of one or two letters or of a
// digit and a letter, one digit, and a suffix of one to three letters. A
// four-letter suffix (N0CALL) is not matched.
var pattern = regexp.MustCompile(`^([A-Z]{1,2}|[0-9][A-Z])[0-9]([A-Z]{1,3})$`)

// singlePrefixes are the letters the ITU issues as a whole callsign prefix
// (B China, F France, G United Kingdom, K/N/W United States, M United Kingdom,
// R Russia). I is one too but is left out: a lone capital I in running text is
// nearly always the pronoun.
const singlePrefixes = "BFGKMNRW"

// portable is the stroke suffix an operator away from home adds: /P
// portable, /M mobile. It is not part of the callsign.
var portable = regexp.MustCompile(`/[PM]$`)

// isCallsign applies the pattern to one run. A one-letter prefix must be one
// the ITU issues alone, and with it a one-letter suffix (N0A) counts only when
// it was spelled out phonetically, because a typed B2B or a model's "C3PO" is
// far more often not a callsign.
func isCallsign(call string, phonetic bool) bool {
	m := pattern.FindStringSubmatch(call)
	if m == nil {
		return false
	}
	prefix, suffix := m[1], m[2]
	if len(prefix) == 1 && (!strings.Contains(singlePrefixes, prefix) || (len(suffix) < 2 && !phonetic)) {
		return false
	}
	return true
}

// Find returns the callsigns the pattern matches in the normalised text, in
// the order they first appear and each once. A text with none returns nil.
func Find(text string) []string {
	var found []string
	seen := map[string]bool{}
	for _, tok := range scan(text) {
		if !tok.run {
			continue
		}
		call := portable.ReplaceAllString(tok.text, "")
		if isCallsign(call, tok.phonetic) && !seen[call] {
			seen[call] = true
			found = append(found, call)
		}
	}
	return found
}
