// SPDX-License-Identifier: Apache-2.0

package ais

import "math"

// AIS line rate and Gaussian shaping. BT is the bandwidth-time product ITU-R
// M.1371 specifies for the transmit filter; the demodulator does not need it,
// but the modulator shapes with it so the fixture is a faithful GMSK burst
// rather than square MSK.
const (
	BaudHz = 9600.0
	BT     = 0.4
)

// Demodulator recovers AIS wire bits from the FM discriminator output -- the
// demod tap of an NFM channel, which is instantaneous frequency. For GMSK a 1
// and a 0 sit at plus and minus a quarter-baud of deviation, so an
// integrate-and-dump over one bit followed by a sign slice is the matched
// receiver; a PLL bit clock, exactly the one pkg/decoders/afsk uses, times the
// samples, and NRZI is undone inline. It is single-axis where AFSK is two.
//
// Measured over 100 random position reports (roundtrip_test.go and
// noise_test.go): 100/100 decode clean at 48 kHz, and with additive white noise
// on the discriminator output 100/100 at 10 dB SNR, 99/100 at 8 dB and 96/100
// at 6 dB before the count falls off. The slicer is non-coherent and the bit
// clock a first-order PLL, so this sits a few dB short of a coherent GMSK
// receiver, which is the same trade pkg/decoders/afsk makes.
type Demodulator struct {
	rate   float64
	window int // integrate-and-dump length, one bit in samples

	hist   []float64
	pos    int
	sum    float64
	filled int

	dc     float64 // slow mean, removes a carrier-offset bias on the slicer
	dcGain float64

	phase float64 // PLL bit clock, wraps in [-1, 1)
	step  float64
	gain  float64

	lastSign  bool
	haveSign  bool
	lastLevel bool // NRZI state

	index int64
}

// New builds a demodulator for an audio rate between 8 kHz and 96 kHz. The
// daemon's channel rate is about 48 kHz, which is ~5 samples per bit at 9600
// baud; the bound is a sanity check on the descriptor.
func New(rate float64) *Demodulator {
	if rate < 8000 || rate > 96000 {
		panic("ais: rate outside 8 kHz to 96 kHz")
	}
	n := int(math.Round(rate / BaudHz))
	if n < 2 {
		n = 2
	}
	d := &Demodulator{
		rate: rate, window: n, hist: make([]float64, n),
		step: BaudHz / rate * 2, gain: 0.25,
		dcGain: 1 / (64 * rate / BaudHz), // ~64-bit time constant
	}
	return d
}

// Reset clears the demodulator. A gap invalidates the bit clock and the
// integrator alike.
func (d *Demodulator) Reset() {
	for i := range d.hist {
		d.hist[i] = 0
	}
	d.pos, d.filled, d.sum = 0, 0, 0
	d.dc, d.phase = 0, 0
	d.haveSign = false
}

// Window is the integrate-and-dump length in samples, one bit time.
func (d *Demodulator) Window() int { return d.window }

// Index is how many samples the demodulator has consumed, the counter the bit
// callback's sample index is measured on.
func (d *Demodulator) Index() int64 { return d.index }

// Feed runs a block of discriminator samples through the chain and calls emit
// for every bit the clock samples, with the absolute sample index of that
// instant.
func (d *Demodulator) Feed(samples []float32, emit func(bit bool, at int64)) {
	for _, s := range samples {
		x := float64(s)
		d.dc += (x - d.dc) * d.dcGain
		y := x - d.dc

		// Integrate-and-dump: a running sum over one bit is the matched filter
		// for the rectangular data the Gaussian filter rounded the edges of.
		d.sum -= d.hist[d.pos]
		d.hist[d.pos] = y
		d.sum += y
		d.pos++
		if d.pos == d.window {
			d.pos = 0
		}
		if d.filled < d.window {
			d.filled++
			d.index++
			continue
		}

		sign := d.sum >= 0
		if d.haveSign && sign != d.lastSign {
			// A transition should fall half a bit from the sample instant, at
			// phase 0; pull the clock a fraction of the way there.
			d.phase *= 1 - d.gain
		}
		d.lastSign, d.haveSign = sign, true

		d.phase += d.step
		if d.phase >= 1 {
			d.phase -= 2
			// NRZI: no transition is a 1.
			bit := sign == d.lastLevel
			d.lastLevel = sign
			emit(bit, d.index)
		}
		d.index++
	}
}

// Modulator synthesises the discriminator-output waveform of an AIS GMSK burst:
// Gaussian-filtered NRZ, peak amplitude amp, one value per sample. It exists so
// roundtrip_test.go and the leyfix ais_burst fixture can make signal without a
// radio. For the direct round trip its output is fed straight to Demodulator;
// for the fixture it is the modulating signal an FM carrier integrates.
type Modulator struct {
	rate, amp float64
	taps      []float64
}

// NewModulator builds a modulator at an audio rate with peak amplitude amp.
func NewModulator(rate, amp float64) *Modulator {
	return &Modulator{rate: rate, amp: amp, taps: gaussianTaps(rate, BaudHz, BT)}
}

// Modulate appends the frequency waveform for the wire bits (post-NRZI levels):
// a 1 is +amp, a 0 is -amp, upsampled to one bit's worth of samples each and
// Gaussian-shaped so the transitions are the continuous curves GMSK sends
// rather than steps.
func (m *Modulator) Modulate(dst []float32, wireBits []bool) []float32 {
	sps := m.rate / BaudHz
	nrz := make([]float64, 0, int(float64(len(wireBits))*sps)+len(m.taps))
	var carry float64
	for _, b := range wireBits {
		v := -1.0
		if b {
			v = 1.0
		}
		n := int(sps + carry)
		carry += sps - float64(n)
		for i := 0; i < n; i++ {
			nrz = append(nrz, v)
		}
	}
	// Convolve with the Gaussian taps, keeping the centre of the response.
	half := len(m.taps) / 2
	for i := range nrz {
		var acc float64
		for k, t := range m.taps {
			j := i + k - half
			if j < 0 {
				j = 0
			} else if j >= len(nrz) {
				j = len(nrz) - 1
			}
			acc += nrz[j] * t
		}
		dst = append(dst, float32(m.amp*acc))
	}
	return dst
}

// gaussianTaps is the impulse response of the GMSK premodulation filter with
// bandwidth-time product bt, normalised to unit sum so a held bit reaches full
// amplitude. sigma comes from BT the standard way, sigma_t = T*sqrt(ln2)/(2*pi*BT).
func gaussianTaps(rate, baud, bt float64) []float64 {
	sps := rate / baud
	sigma := sps * math.Sqrt(math.Ln2) / (2 * math.Pi * bt)
	half := int(math.Ceil(3 * sigma))
	taps := make([]float64, 2*half+1)
	var sum float64
	for i := range taps {
		x := float64(i - half)
		taps[i] = math.Exp(-x * x / (2 * sigma * sigma))
		sum += taps[i]
	}
	for i := range taps {
		taps[i] /= sum
	}
	return taps
}
