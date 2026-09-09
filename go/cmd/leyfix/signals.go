package main

import (
	"math"
	"math/rand/v2"
)

// source produces complex baseband samples block by block. Sources carry
// their own phase state so generation can stream to disk.
type source interface {
	// fill adds len(dst) samples starting at absolute sample index n0 into dst.
	fill(dst []complex128, n0 int64)
	// describe returns the JSON description recorded in the sidecar generator block.
	describe() map[string]any
}

func ampFromDBFS(dbfs float64) float64 { return math.Pow(10, dbfs/20) }

// fmTone is a sinusoidal tone FM-modulated onto a carrier: instantaneous
// frequency carrier + dev·sin(2π·tone·t), realised by integrating phase.
type fmTone struct {
	rate, carrierHz, toneHz, devHz, dbfs float64
	// A sub-audible tone rides the same carrier at its own (much smaller)
	// deviation: this is how CTCSS/PL is transmitted, and the NFM chain's
	// 300 Hz high-pass removes it from the audio one stage after the
	// discriminator. Zero for a fixture that carries none.
	subToneHz, subDevHz float64
	phase               float64
	wide                bool
}

func (s *fmTone) fill(dst []complex128, n0 int64) {
	a := ampFromDBFS(s.dbfs)
	wc := 2 * math.Pi * s.carrierHz / s.rate
	wd := 2 * math.Pi * s.devHz / s.rate
	wt := 2 * math.Pi * s.toneHz / s.rate
	ws := 2 * math.Pi * s.subToneHz / s.rate
	wsd := 2 * math.Pi * s.subDevHz / s.rate
	ph := s.phase
	for i := range dst {
		n := float64(n0 + int64(i))
		ph += wc + wd*math.Sin(wt*n) + wsd*math.Sin(ws*n)
		if ph > math.Pi {
			ph -= 2 * math.Pi
		} else if ph < -math.Pi {
			ph += 2 * math.Pi
		}
		dst[i] += complex(a*math.Cos(ph), a*math.Sin(ph))
	}
	s.phase = ph
}

func (s *fmTone) describe() map[string]any {
	kind := "nfm_tone"
	if s.wide {
		kind = "wfm_tone"
	}
	d := map[string]any{
		"type": kind, "carrier_hz": s.carrierHz, "tone_hz": s.toneHz,
		"deviation_hz": s.devHz, "dbfs": s.dbfs,
	}
	if s.subToneHz != 0 {
		d["sub_tone_hz"] = s.subToneHz
		d["sub_deviation_hz"] = s.subDevHz
	}
	return d
}

// amTone is carrier·(1 + depth·sin(2π·tone·t)); dbfs is the carrier level.
type amTone struct {
	rate, carrierHz, toneHz, depth, dbfs float64
}

func (s *amTone) fill(dst []complex128, n0 int64) {
	a := ampFromDBFS(s.dbfs)
	wc := 2 * math.Pi * s.carrierHz / s.rate
	wt := 2 * math.Pi * s.toneHz / s.rate
	for i := range dst {
		n := float64(n0 + int64(i))
		env := a * (1 + s.depth*math.Sin(wt*n))
		ph := math.Mod(wc*n, 2*math.Pi)
		dst[i] += complex(env*math.Cos(ph), env*math.Sin(ph))
	}
}

func (s *amTone) describe() map[string]any {
	return map[string]any{
		"type": "am_tone", "carrier_hz": s.carrierHz, "tone_hz": s.toneHz,
		"depth": s.depth, "dbfs": s.dbfs,
	}
}

// ssbTone is an analytic tone at carrier ± tone (carrier suppressed): a
// single complex exponential, the upper sideband when upper is true.
type ssbTone struct {
	rate, carrierHz, toneHz, dbfs float64
	upper                         bool
}

func (s *ssbTone) fill(dst []complex128, n0 int64) {
	a := ampFromDBFS(s.dbfs)
	f := s.carrierHz + s.toneHz
	if !s.upper {
		f = s.carrierHz - s.toneHz
	}
	w := 2 * math.Pi * f / s.rate
	for i := range dst {
		ph := math.Mod(w*float64(n0+int64(i)), 2*math.Pi)
		dst[i] += complex(a*math.Cos(ph), a*math.Sin(ph))
	}
}

func (s *ssbTone) describe() map[string]any {
	kind := "usb_tone"
	if !s.upper {
		kind = "lsb_tone"
	}
	return map[string]any{"type": kind, "carrier_hz": s.carrierHz, "tone_hz": s.toneHz, "dbfs": s.dbfs}
}

// gaussNoise is complex white Gaussian noise with mean power dbfs.
type gaussNoise struct {
	dbfs float64
	rng  *rand.Rand
}

func (s *gaussNoise) fill(dst []complex128, _ int64) {
	sigma := math.Sqrt(math.Pow(10, s.dbfs/10) / 2)
	for i := range dst {
		dst[i] += complex(sigma*s.rng.NormFloat64(), sigma*s.rng.NormFloat64())
	}
}

func (s *gaussNoise) describe() map[string]any {
	return map[string]any{"type": "noise", "dbfs": s.dbfs}
}
