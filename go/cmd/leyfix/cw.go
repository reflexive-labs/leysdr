package main

import (
	"math"
	"strings"
)

var morse = map[rune]string{
	'A': ".-", 'B': "-...", 'C': "-.-.", 'D': "-..", 'E': ".", 'F': "..-.", 'G': "--.",
	'H': "....", 'I': "..", 'J': ".---", 'K': "-.-", 'L': ".-..", 'M': "--", 'N': "-.",
	'O': "---", 'P': ".--.", 'Q': "--.-", 'R': ".-.", 'S': "...", 'T': "-", 'U': "..-",
	'V': "...-", 'W': ".--", 'X': "-..-", 'Y': "-.--", 'Z': "--..",
	'0': "-----", '1': ".----", '2': "..---", '3': "...--", '4': "....-",
	'5': ".....", '6': "-....", '7': "--...", '8': "---..", '9': "----.",
}

// keyInterval is one key-down span in seconds within the message period.
type keyInterval struct{ start, end float64 }

// morseTiming lays out text at wpm (PARIS timing: dit = 1.2/wpm s). The
// message is followed by a word gap so it can repeat with period.
func morseTiming(text string, wpm float64) (spans []keyInterval, period float64) {
	dit := 1.2 / wpm
	t := 0.0
	for wi, word := range strings.Fields(strings.ToUpper(text)) {
		if wi > 0 {
			t += 7 * dit
		}
		for li, ch := range word {
			code, ok := morse[ch]
			if !ok {
				continue
			}
			if li > 0 {
				t += 3 * dit
			}
			for ei, e := range code {
				if ei > 0 {
					t += dit
				}
				d := dit
				if e == '-' {
					d = 3 * dit
				}
				spans = append(spans, keyInterval{t, t + d})
				t += d
			}
		}
	}
	return spans, t + 7*dit
}

// cwKeyed is a carrier keyed with Morse text; edges are raised-cosine ramps
// of edgeS seconds inside each key-down span.
type cwKeyed struct {
	rate, carrierHz, dbfs, wpm, edgeS float64
	text                              string
	spans                             []keyInterval
	period                            float64
}

func newCW(rate, carrierHz, dbfs, wpm, edgeS float64, text string) *cwKeyed {
	s := &cwKeyed{rate: rate, carrierHz: carrierHz, dbfs: dbfs, wpm: wpm, edgeS: edgeS, text: text}
	s.spans, s.period = morseTiming(text, wpm)
	return s
}

// envelope returns the key envelope in [0,1] at time t (seconds).
func (s *cwKeyed) envelope(t float64) float64 {
	t = math.Mod(t, s.period)
	for _, sp := range s.spans {
		if t < sp.start || t >= sp.end {
			continue
		}
		e := 1.0
		if d := t - sp.start; d < s.edgeS {
			e = 0.5 * (1 - math.Cos(math.Pi*d/s.edgeS))
		}
		if d := sp.end - t; d < s.edgeS {
			e = math.Min(e, 0.5*(1-math.Cos(math.Pi*d/s.edgeS)))
		}
		return e
	}
	return 0
}

func (s *cwKeyed) fill(dst []complex128, n0 int64) {
	a := ampFromDBFS(s.dbfs)
	w := 2 * math.Pi * s.carrierHz / s.rate
	for i := range dst {
		n := n0 + int64(i)
		env := a * s.envelope(float64(n)/s.rate)
		if env == 0 {
			continue
		}
		ph := math.Mod(w*float64(n), 2*math.Pi)
		dst[i] += complex(env*math.Cos(ph), env*math.Sin(ph))
	}
}

func (s *cwKeyed) describe() map[string]any {
	return map[string]any{
		"type": "cw", "carrier_hz": s.carrierHz, "dbfs": s.dbfs,
		"wpm": s.wpm, "text": s.text, "edge_ms": s.edgeS * 1000,
	}
}
