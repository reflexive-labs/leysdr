// SPDX-License-Identifier: Apache-2.0

package same

import "math"

// Modulator generates continuous-phase SAME AFSK, so the tests and the
// same_alert fixture can make an alert burst without a transmitter.
type Modulator struct {
	rate      float64
	amplitude float64
	phase     float64
}

// NewModulator builds a modulator at an audio rate with peak amplitude amp.
func NewModulator(rate, amp float64) *Modulator {
	return &Modulator{rate: rate, amplitude: amp}
}

// Bytes appends the AFSK for a run of bytes, each eight bits
// least-significant-first, mark (2083.3 Hz) for a 1 and space (1562.5 Hz) for a
// 0. Phase carries across bits and calls, which is what makes it one tone
// stream rather than a sequence of clicks.
func (m *Modulator) Bytes(dst []float32, data []byte) []float32 {
	perBit := m.rate / BaudHz
	var carry float64
	for _, by := range data {
		for i := 0; i < 8; i++ {
			f := SpaceHz
			if by&(1<<uint(i)) != 0 {
				f = MarkHz
			}
			w := 2 * math.Pi * f / m.rate
			n := int(perBit + carry)
			carry += perBit - float64(n)
			for k := 0; k < n; k++ {
				dst = append(dst, float32(m.amplitude*math.Sin(m.phase)))
				m.phase += w
				if m.phase > 2*math.Pi {
					m.phase -= 2 * math.Pi
				}
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

func preamble() []byte {
	b := make([]byte, 16)
	for i := range b {
		b[i] = PreambleByte
	}
	return b
}

// Header appends one transmission: the sixteen-byte preamble then the header
// text, which must be the whole "ZCZC-...-CALLSIGN-" string.
func (m *Modulator) Header(dst []float32, header string) []float32 {
	dst = m.Bytes(dst, preamble())
	return m.Bytes(dst, []byte(header))
}

// EOM appends one end-of-message transmission: the preamble then "NNNN".
func (m *Modulator) EOM(dst []float32) []float32 {
	dst = m.Bytes(dst, preamble())
	return m.Bytes(dst, []byte("NNNN"))
}

// Message appends a full SAME message the way a transmitter sends it: the
// header copies times, a short pause, then the EOM copies times. Real SAME uses
// three of each; a fixture too short for three can send one and the demodulator
// decodes a single copy just the same.
func (m *Modulator) Message(dst []float32, header string, copies int) []float32 {
	for i := 0; i < copies; i++ {
		dst = m.Header(dst, header)
		dst = m.Silence(dst, int(m.rate*0.01))
	}
	dst = m.Silence(dst, int(m.rate*0.05))
	for i := 0; i < copies; i++ {
		dst = m.EOM(dst)
		dst = m.Silence(dst, int(m.rate*0.01))
	}
	return dst
}
