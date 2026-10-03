// SPDX-License-Identifier: Apache-2.0

package main

import (
	"math"
	"math/rand/v2"
)

// The sources that make scene_2m look like a busy simplex and repeater cluster around 146.520:
// a cheap radio's splatter, a four-level FSK burst and a repeater's courtesy tail. Each is
// seeded and streams block by block like the sources in signals.go.

// biquadLP is a second-order low-pass at fc with quality factor q, by the bilinear transform.
func biquadLP(fc, rate, q float64) biquad {
	k := math.Tan(math.Pi * fc / rate)
	norm := 1 / (1 + k/q + k*k)
	f := biquad{a1: 2 * (k*k - 1) * norm, a2: (1 - k/q + k*k) * norm}
	f.b0 = k * k * norm
	f.b1, f.b2 = 2*f.b0, f.b0
	return f
}

// butterworth4 is a fourth-order Butterworth low-pass at fc: two sections at the poles' Q values.
func butterworth4(fc, rate float64) [2]biquad {
	return [2]biquad{biquadLP(fc, rate, 0.5412), biquadLP(fc, rate, 1.3066)}
}

// splatter adds a skirt of noise around another source's carrier: complex Gaussian noise through
// a fourth-order Butterworth low-pass of half-width widthHz, mixed up to offsetHz, at dbc under
// the carrier's level. It models a cheap handheld whose overdriven audio stage spreads energy
// past its channel. Wrapped inside a keyed source, the skirt is there only while the carrier is.
type splatter struct {
	inner                   source
	rate, offsetHz, widthHz float64
	carrierDBFS, dbc        float64
	seed                    uint64
	rng                     *rand.Rand
	fi, fq                  [2]biquad
	sigma                   float64
}

func (s *splatter) init() {
	s.rng = rand.New(rand.NewPCG(s.seed, 0x73706c6174))
	s.fi = butterworth4(s.widthHz, s.rate)
	s.fq = butterworth4(s.widthHz, s.rate)
	// The filter's noise gain is the energy of its impulse response, which has decayed to
	// nothing well inside 200 periods of the cutoff.
	probe := butterworth4(s.widthHz, s.rate)
	x, gain := 1.0, 0.0
	for range int(200 * s.rate / s.widthHz) {
		y := probe[1].step(probe[0].step(x))
		gain += y * y
		x = 0
	}
	p := math.Pow(10, (s.carrierDBFS-s.dbc)/10)
	s.sigma = math.Sqrt(p / (2 * gain))
}

func (s *splatter) fill(dst []complex128, n0 int64) {
	s.inner.fill(dst, n0)
	if s.rng == nil {
		s.init()
	}
	w := 2 * math.Pi * s.offsetHz / s.rate
	for i := range dst {
		re := s.fi[1].step(s.fi[0].step(s.rng.NormFloat64()))
		im := s.fq[1].step(s.fq[0].step(s.rng.NormFloat64()))
		ph := math.Mod(w*float64(n0+int64(i)), 2*math.Pi)
		c, sn := math.Cos(ph), math.Sin(ph)
		dst[i] += complex(s.sigma*(re*c-im*sn), s.sigma*(re*sn+im*c))
	}
}

func (s *splatter) describe() map[string]any {
	return map[string]any{
		"type": "splatter", "carrier_hz": s.offsetHz, "half_width_hz": s.widthHz,
		"filter": "4th-order Butterworth", "dbc": -s.dbc, "dbfs": s.carrierDBFS - s.dbc,
		"seed": s.seed, "carrier": s.inner.describe(),
	}
}

// span is the inner source's band or the skirt's, whichever is wider. At twice its half-width
// the skirt is 24 dB further down, which puts it near the floor.
func (s *splatter) span() (float64, float64) {
	off, bw := s.inner.span()
	return off, math.Max(bw, 4*s.widthHz)
}

// fsk4Deviations are the four frequency levels of C4FM, in Hz from the carrier.
var fsk4Deviations = [4]float64{-1800, -600, 600, 1800}

// fsk4SymbolRate is C4FM's 4800 symbols per second.
const fsk4SymbolRate = 4800

// fsk4 is a four-level FSK carrier with seeded random symbols, shaped like C4FM digital voice on
// a waterfall: 4800 symbols per second at ±600 and ±1800 Hz. The frequency moves from one level
// to the next along a raised-cosine over the first half of each symbol and holds for the second
// half, a cheap stand-in for C4FM's root-raised-cosine filter that keeps the spectrum inside
// about 8 kHz. It carries nothing a decoder could read.
//
// Samples are made in order; asking for an earlier one starts the symbols over from the seed.
type fsk4 struct {
	rate, carrierHz, dbfs float64
	seed                  uint64

	rng       *rand.Rand
	sym       int64 // index of the symbol cur holds
	prev, cur float64
	phase     float64
}

func (s *fsk4) reset() {
	s.rng = rand.New(rand.NewPCG(s.seed, 0x66736b34))
	s.sym = 0
	s.cur = fsk4Deviations[s.rng.IntN(4)]
	s.prev = s.cur
}

// devAt is the frequency offset from the carrier at absolute sample n.
func (s *fsk4) devAt(n int64) float64 {
	t := float64(n) * fsk4SymbolRate / s.rate
	k := int64(t)
	if s.rng == nil || k < s.sym {
		s.reset()
	}
	for s.sym < k {
		s.prev = s.cur
		s.cur = fsk4Deviations[s.rng.IntN(4)]
		s.sym++
	}
	u := t - float64(k)
	if u >= 0.5 {
		return s.cur
	}
	return s.prev + (s.cur-s.prev)*(1-math.Cos(2*math.Pi*u))/2
}

func (s *fsk4) fill(dst []complex128, n0 int64) {
	a := ampFromDBFS(s.dbfs)
	ph := s.phase
	for i := range dst {
		n := n0 + int64(i)
		ph += 2 * math.Pi * (s.carrierHz + s.devAt(n)) / s.rate
		if ph > math.Pi {
			ph -= 2 * math.Pi
		} else if ph < -math.Pi {
			ph += 2 * math.Pi
		}
		dst[i] += complex(a*math.Cos(ph), a*math.Sin(ph))
	}
	s.phase = ph
}

func (s *fsk4) describe() map[string]any {
	return map[string]any{
		"type": "fsk4", "carrier_hz": s.carrierHz, "symbol_rate": fsk4SymbolRate,
		"deviations_hz": fsk4Deviations[:], "shaping": "raised-cosine over the first half symbol",
		"dbfs": s.dbfs, "seed": s.seed,
	}
}

// span is Carson's rule over the outer level and half the symbol rate.
func (s *fsk4) span() (float64, float64) {
	return s.carrierHz, 2 * (fsk4Deviations[3] + fsk4SymbolRate/2)
}

// courtesyTail is a repeater's tail after each over: the carrier stays up for tailS with the
// voice gone, and a beep of beepHz sounds for beepS starting beepAtS into the tail. It changes
// what modulates an fmVoice; the keyed source around that voice holds the carrier for
// withTails(overs, tailS).
type courtesyTail struct {
	rate                          float64
	overs                         []keySegment
	tailS, beepAtS, beepS, beepHz float64
	// beepLevel is the beep's peak as a fraction of the voice's full deviation.
	beepLevel float64
}

// audio is what modulates the carrier at sample n, given the voice's sample there: the voice
// inside an over, the beep or silence inside a tail. Outside both the voice passes through, and
// the keyed source mutes it.
func (c *courtesyTail) audio(voice float64, n int64) float64 {
	t := float64(n) / c.rate
	for _, o := range c.overs {
		if t < o.startS {
			break
		}
		if t < o.endS {
			return voice
		}
		dt := t - o.endS
		if dt >= c.tailS {
			continue
		}
		if b := dt - c.beepAtS; b >= 0 && b < c.beepS {
			return c.beepLevel * math.Sin(2*math.Pi*c.beepHz*b)
		}
		return 0
	}
	return voice
}

// withTails is a repeater's keying: each over with its tail.
func withTails(overs []keySegment, tailS float64) []keySegment {
	out := make([]keySegment, len(overs))
	for i, o := range overs {
		out[i] = keySegment{startS: o.startS, endS: round2(o.endS + tailS)}
	}
	return out
}

func (c *courtesyTail) describe(devHz float64) map[string]any {
	return map[string]any{
		"tail_s": c.tailS, "beep_at_s": c.beepAtS, "beep_s": c.beepS, "beep_hz": c.beepHz,
		"beep_deviation_hz": c.beepLevel * devHz,
	}
}
