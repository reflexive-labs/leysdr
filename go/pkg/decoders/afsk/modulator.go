// SPDX-License-Identifier: Apache-2.0

package afsk

import "math"

// Modulator generates continuous-phase Bell 202 AFSK. It exists so the tests
// and the aprs_afsk fixture can make signal without a radio
// (docs/plans/decoders.md, DEC-2 and DEC-3).
type Modulator struct {
	rate      float64
	amplitude float64
	phase     float64
}

// NewModulator builds a modulator at an audio rate, with peak amplitude amp.
func NewModulator(rate, amp float64) *Modulator {
	return &Modulator{rate: rate, amplitude: amp}
}

// Modulate appends one tone per wire bit: mark (1200 Hz) for true, space
// (2200 Hz) for false. Phase carries across bits and across calls, which is
// what makes it Bell 202 rather than a sequence of clicks.
func (m *Modulator) Modulate(dst []float32, bits []bool) []float32 {
	perBit := m.rate / BaudHz
	var carry float64
	for _, bit := range bits {
		f := SpaceHz
		if bit {
			f = MarkHz
		}
		w := 2 * math.Pi * f / m.rate
		// Bit boundaries rarely fall on a sample; carry the fractional part so
		// the baud rate does not drift over a long frame.
		n := int(perBit + carry)
		carry += perBit - float64(n)
		for i := 0; i < n; i++ {
			dst = append(dst, float32(m.amplitude*math.Sin(m.phase)))
			m.phase += w
			if m.phase > 2*math.Pi {
				m.phase -= 2 * math.Pi
			}
		}
	}
	return dst
}

// Silence appends n samples of nothing, keeping the phase where it was.
func (m *Modulator) Silence(dst []float32, n int) []float32 {
	for i := 0; i < n; i++ {
		dst = append(dst, 0)
	}
	return dst
}

// NRZI encodes data bits as wire levels: a 0 flips the level, a 1 holds it.
// The first level is mark. The demodulator undoes this inline.
func NRZI(bits []bool) []bool {
	out := make([]bool, len(bits))
	level := true
	for i, b := range bits {
		if !b {
			level = !level
		}
		out[i] = level
	}
	return out
}
