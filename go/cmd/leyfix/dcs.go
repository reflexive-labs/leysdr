// SPDX-License-Identifier: Apache-2.0

package main

import (
	"math"

	"github.com/reflexive-labs/leysdr/go/pkg/dcs"
)

// dcsLowPassHz is where the DCS bit stream is rolled off before it reaches the modulator, as a
// transmitter's shaping does: a recorded GMRS handheld's demod tap is 40 dB down above 300 Hz.
const dcsLowPassHz = 300

// dcsShaper is a DCS word as modulating audio: the 23-bit word repeated without a gap at
// 134.4 bit/s, NRZ with a one as +1, through a second-order low-pass at dcsLowPassHz.
//
// The stream starts at the first bit of the word as framed (code bits first), and a file does
// not end on a word boundary, so a looping player rotates the alignment every pass; a decoder has
// to find the word at any rotation, as it does on the air.
type dcsShaper struct {
	rate     float64
	code     int
	inverted bool

	word  dcs.Word
	built bool
	// The biquad's state runs on across blocks, so the stream is continuous however generate
	// slices it.
	b0, b1, b2, a1, a2 float64
	x1, x2, y1, y2     float64
}

// build computes the word and a Butterworth low-pass by the bilinear transform.
func (s *dcsShaper) build() {
	s.word = dcs.Encode(s.code, s.inverted)
	k := math.Tan(math.Pi * dcsLowPassHz / s.rate)
	q := 1 / math.Sqrt2
	norm := 1 / (1 + k/q + k*k)
	s.b0 = k * k * norm
	s.b1 = 2 * s.b0
	s.b2 = s.b0
	s.a1 = 2 * (k*k - 1) * norm
	s.a2 = (1 - k/q + k*k) * norm
	s.built = true
}

// bit is the NRZ level at absolute sample n: +1 for a one, -1 for a zero.
func (s *dcsShaper) bit(n int64) float64 {
	i := int64(float64(n)*dcs.BitRate/s.rate) % dcs.WordBits
	if s.word[i] == 1 {
		return 1
	}
	return -1
}

// next is the shaped level at absolute sample n; calls come in sample order.
func (s *dcsShaper) next(n int64) float64 {
	if !s.built {
		s.build()
	}
	x := s.bit(n)
	y := s.b0*x + s.b1*s.x1 + s.b2*s.x2 - s.a1*s.y1 - s.a2*s.y2
	s.x2, s.x1, s.y2, s.y1 = s.x1, x, s.y1, y
	return y
}

// describe is the shaper's part of a source's sidecar description.
func (s *dcsShaper) describe(d map[string]any) {
	d["dcs_code"] = dcs.Format(s.code)
	d["dcs_inverted"] = s.inverted
	d["bit_rate"] = dcs.BitRate
	d["low_pass_hz"] = dcsLowPassHz
}

// dcsCode FM-modulates a DCS word under a voice tone, at subDevHz of peak deviation. It is
// modelled on afskPacket, a bit stream driving the modulator, rather than on fmTone's sine.
type dcsCode struct {
	rate, carrierHz, toneHz, devHz, dbfs float64
	code                                 int
	inverted                             bool
	subDevHz                             float64

	shaper *dcsShaper
	// The carrier phase runs on across blocks, as the shaper's filter state does.
	phase float64
}

func (s *dcsCode) fill(dst []complex128, n0 int64) {
	if s.shaper == nil {
		s.shaper = &dcsShaper{rate: s.rate, code: s.code, inverted: s.inverted}
	}
	a := ampFromDBFS(s.dbfs)
	wc := 2 * math.Pi * s.carrierHz / s.rate
	wd := 2 * math.Pi * s.devHz / s.rate
	wt := 2 * math.Pi * s.toneHz / s.rate
	wsd := 2 * math.Pi * s.subDevHz / s.rate
	ph := s.phase
	for i := range dst {
		n := n0 + int64(i)
		ph += wc + wd*math.Sin(wt*float64(n)) + wsd*s.shaper.next(n)
		if ph > math.Pi {
			ph -= 2 * math.Pi
		} else if ph < -math.Pi {
			ph += 2 * math.Pi
		}
		dst[i] += complex(a*math.Cos(ph), a*math.Sin(ph))
	}
	s.phase = ph
}

func (s *dcsCode) describe() map[string]any {
	d := map[string]any{
		"type": "nfm_dcs", "carrier_hz": s.carrierHz, "tone_hz": s.toneHz,
		"deviation_hz": s.devHz, "dbfs": s.dbfs, "sub_deviation_hz": s.subDevHz,
	}
	(&dcsShaper{code: s.code, inverted: s.inverted}).describe(d)
	return d
}

// span is Carson's rule over both deviations and the higher of the voice tone and the bit
// stream's low-pass edge.
func (s *dcsCode) span() (float64, float64) {
	return s.carrierHz, 2 * (s.devHz + s.subDevHz + math.Max(s.toneHz, dcsLowPassHz))
}
