// SPDX-License-Identifier: Apache-2.0

// Package wer scores a speech engine's text against a hand transcript: word error rate by
// Levenshtein alignment, and how many of the callsigns spoken the engine wrote down. Both sides
// are normalised first (Normalise), so a callsign written as spoken ("whiskey six alpha bravo
// charlie") and one written compactly ("W6ABC") are the same word, and case and punctuation never
// count as errors.
package wer

import (
	"strings"
	"unicode"

	"github.com/reflexive-labs/leysdr/go/pkg/callsign"
)

// Normalise rewrites text for scoring: every span that spells one callsign becomes that callsign
// (callsign.Find over the span), then the text is lower-cased, punctuation becomes a space (an
// apostrophe is dropped and a full stop between two digits kept, so "don't" and "dont" are one
// word and "146.94" stays one number), and whitespace collapses to single spaces. Digits are kept
// as digits and number words as words: "six" and "6" are different words outside a callsign,
// which is how a person reading the text would see them too.
func Normalise(text string) string {
	return strings.Join(Words(text), " ")
}

// Words is Normalise split into words.
func Words(text string) []string {
	return strings.Fields(stripPunctuation(strings.ToLower(foldCallsigns(text))))
}

// foldCallsigns replaces each run of words that callsign.Normalise joins into one token, and in
// which callsign.Find sees exactly one callsign, with that callsign. Every other word is kept as
// written, so "see you at six alpha" stays words: only a callsign span is folded, never a stray
// letter-digit run.
func foldCallsigns(text string) string {
	words := strings.Fields(text)
	out := make([]string, 0, len(words))
	for i := 0; i < len(words); {
		j := runEnd(words, i)
		span := strings.Join(words[i:j], " ")
		if calls := callsign.Find(span); len(calls) == 1 {
			out = append(out, calls[0])
		} else {
			out = append(out, words[i:j]...)
		}
		i = j
	}
	return strings.Join(out, " ")
}

// runEnd is the end of the longest stretch of words from i that callsign.Normalise keeps as one
// token: a spelled run such as "whiskey six alpha bravo charlie", or the single word at i.
func runEnd(words []string, i int) int {
	j := i + 1
	for j < len(words) && isOneToken(callsign.Normalise(strings.Join(words[i:j+1], " "))) {
		j++
	}
	return j
}

func isOneToken(s string) bool {
	return s != "" && !strings.ContainsAny(s, " \t")
}

// stripPunctuation keeps letters, digits and a full stop between two digits; it drops
// apostrophes and turns everything else into a space.
func stripPunctuation(s string) string {
	rs := []rune(s)
	var b strings.Builder
	for i, r := range rs {
		switch {
		case unicode.IsLetter(r), unicode.IsDigit(r):
			b.WriteRune(r)
		case r == '\'' || r == '’':
		case r == '.' && i > 0 && i+1 < len(rs) && unicode.IsDigit(rs[i-1]) && unicode.IsDigit(rs[i+1]):
			b.WriteRune(r)
		default:
			b.WriteRune(' ')
		}
	}
	return b.String()
}

// Counts is an alignment's edits against the reference.
type Counts struct {
	RefWords int `json:"ref_words"`
	Subs     int `json:"substitutions"`
	Dels     int `json:"deletions"`
	Ins      int `json:"insertions"`
}

// Errors is substitutions, deletions and insertions together: the edit distance.
func (c Counts) Errors() int { return c.Subs + c.Dels + c.Ins }

// Rate is the word error rate, errors over reference words. A reference with no words divides by
// one, so an engine that writes words over silence still scores worse than one that writes none.
func (c Counts) Rate() float64 {
	return float64(c.Errors()) / float64(max(c.RefWords, 1))
}

// Add sums two counts.
func (c Counts) Add(o Counts) Counts {
	return Counts{RefWords: c.RefWords + o.RefWords, Subs: c.Subs + o.Subs, Dels: c.Dels + o.Dels, Ins: c.Ins + o.Ins}
}

// WER aligns hyp to ref by Levenshtein distance over words and counts the edits.
func WER(ref, hyp []string) (subs, dels, ins int, rate float64) {
	c := Align(ref, hyp)
	return c.Subs, c.Dels, c.Ins, c.Rate()
}

// Align is WER as Counts. Where two alignments cost the same, the backtrace prefers a match or a
// substitution to a deletion and a deletion to an insertion, so the split between the three is
// stable; their sum is the distance either way.
func Align(ref, hyp []string) Counts {
	n, m := len(ref), len(hyp)
	// d[i][j] is the distance between ref[:i] and hyp[:j].
	d := make([][]int, n+1)
	for i := range d {
		d[i] = make([]int, m+1)
		d[i][0] = i
	}
	for j := 0; j <= m; j++ {
		d[0][j] = j
	}
	for i := 1; i <= n; i++ {
		for j := 1; j <= m; j++ {
			sub := d[i-1][j-1]
			if ref[i-1] != hyp[j-1] {
				sub++
			}
			d[i][j] = min(sub, d[i-1][j]+1, d[i][j-1]+1)
		}
	}
	c := Counts{RefWords: n}
	for i, j := n, m; i > 0 || j > 0; {
		switch {
		case i > 0 && j > 0 && ref[i-1] == hyp[j-1] && d[i][j] == d[i-1][j-1]:
			i, j = i-1, j-1
		case i > 0 && j > 0 && d[i][j] == d[i-1][j-1]+1:
			c.Subs++
			i, j = i-1, j-1
		case i > 0 && d[i][j] == d[i-1][j]+1:
			c.Dels++
			i--
		default:
			c.Ins++
			j--
		}
	}
	return c
}

// CallsignRecall is how many of the reference's callsigns the hypothesis has, each counted once:
// hits over total, and the recall itself. Recall is 1 when the reference has none, because
// nothing was missed; a caller shows total beside it so that 0 of 0 is not read as a result.
func CallsignRecall(refCallsigns, hypCallsigns []string) (hits, total int, recall float64) {
	have := map[string]bool{}
	for _, c := range hypCallsigns {
		have[strings.ToUpper(c)] = true
	}
	seen := map[string]bool{}
	for _, c := range refCallsigns {
		c = strings.ToUpper(c)
		if seen[c] {
			continue
		}
		seen[c] = true
		total++
		if have[c] {
			hits++
		}
	}
	if total == 0 {
		return 0, 0, 1
	}
	return hits, total, float64(hits) / float64(total)
}
