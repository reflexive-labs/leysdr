// SPDX-License-Identifier: Apache-2.0

// Package afsk demodulates and modulates Bell 202 AFSK at 1200 baud, the
// modulation APRS rides on VHF (docs/design/decoders.md, "APRS is decoded in
// Go, in this repository").
//
// The receive chain is a pair of mark/space correlators one bit long, a
// normalising discriminator, a short smoother, and a PLL bit clock sampled at
// the wrap, then NRZI. The discriminator is (|mark| - |space|) over their sum,
// which is what makes the chain indifferent to level and to how much stronger
// one tone arrives than the other: audio off the NFM chain has been through a
// 300 Hz high-pass and 6 dB/octave de-emphasis, which leaves 2200 Hz about
// 5 dB under 1200 Hz, and the ratio still changes sign in the right place.
// Options.PreEmphasis and Options.TwistDB can put that tilt back explicitly;
// both are off by default because both were measured to cost 5 to 10 dB of
// sensitivity on flat audio and neither was needed to decode the real capture.
//
// Measured by the round-trip tests in this package, over 100 random UI frames
// of 43 to 78 bytes: 100/100 decode clean at 48 kHz and 100/100 at 12 kHz. In
// white Gaussian noise at 48 kHz, with SNR taken as signal power over the noise
// in the whole 24 kHz audio band: 100/100 at +1 dB, 99/100 at 0 dB, 95/100 at
// -1 dB, 86/100 at -2 dB and 12/100 at -4 dB; at 12 kHz, where the same number
// means 6 dB more noise in band, 100/100 at +6 dB and 79/100 at +4 dB. 0 dB at
// 48 kHz is 13 dB of Eb/N0, and non-coherent FSK needs about 12.3 dB to hold a
// 500-bit frame together, so this chain stops about a decibel short of the
// theoretical wall.
//
// Against the owner's 144.39 MHz captures (rf-captures/aprs_144390_auto.s16 and
// aprs_144390_g40.s16, 180 s each, 2026-09-12) it recovers the one packet the
// auto-gain file contains, a N0CALL-1 position beacon, and none from the
// fixed-gain file, which a tone scan says carries none. 144.39 is quiet where
// the capture was made; the count is what the channel held, not a score.
package afsk

import "math"

// Bell 202 tones and rate. Mark is a 1 bit on the wire before NRZI.
const (
	MarkHz  = 1200.0
	SpaceHz = 2200.0
	BaudHz  = 1200.0
)

// Options tune the receive chain. Zero values are not defaults; use
// DefaultOptions and change what you mean to change.
type Options struct {
	// PreEmphasis is the single-zero coefficient of y = x - k*x[-1], the
	// +6 dB/octave tilt that undoes the NFM chain's de-emphasis. 0 disables it.
	PreEmphasis float64
	// TwistDB lifts the space (2200 Hz) correlator by this many dB before the
	// comparison, which is how the NFM chain's de-emphasis is corrected without
	// amplifying the hiss above the signal the way a pre-emphasis filter on the
	// input does.
	TwistDB float64
	// Normalize divides the mark-space difference by their sum, which makes the
	// discriminator independent of level and of how much stronger one tone
	// arrives than the other.
	Normalize bool
	// SmoothBits is the smoother's time constant in bit times.
	SmoothBits float64
	// DCBits is the time constant, in bit times, of a slow mean subtracted from
	// the discriminator; 0 turns it off, which is the default. Tracking the mean
	// costs more than it buys: Normalize already removes a level or twist
	// imbalance, and the tracker follows unbalanced data instead, which cost
	// about 10 dB of sensitivity when it was measured with it on.
	DCBits float64
	// PLLGain is the fraction of the phase error a transition corrects.
	PLLGain float64
	// WindowBits is the correlator length in bit times.
	WindowBits float64
}

// DefaultOptions is what New uses; the numbers are the ones the round-trip and
// real-capture tests in this package were measured with.
func DefaultOptions() Options {
	return Options{
		PreEmphasis: 0,
		TwistDB:     0,
		Normalize:   true,
		SmoothBits:  0.25,
		PLLGain:     0.25,
		WindowBits:  1,
	}
}

// Demodulator turns audio samples into bits. It is a streaming object: Feed
// may be called with any block size and the state carries across calls.
type Demodulator struct {
	rate float64
	// window is one bit time in samples, the correlator length.
	window int

	// Correlator tables and the sample history they slide over.
	markCos, markSin   []float64
	spaceCos, spaceSin []float64
	hist               []float64
	pos                int
	filled             int

	opt    Options
	twist  float64 // linear gain on the space branch, from Options.TwistDB
	prevIn float64 // pre-emphasis state

	dc     float64 // slow mean of the discriminator; off unless DCBits is set
	dcGain float64
	smooth float64 // short smoother on the discriminator
	smGain float64

	// PLL bit clock: phase wraps at +1, the wrap is the sample instant, and a
	// transition pulls the phase toward 0 (half a bit from the sample point).
	phase    float64
	step     float64
	lastSign bool
	haveSign bool

	// NRZI state: no transition is a 1, a transition is a 0.
	lastLevel bool

	index int64 // absolute sample index, for stamping bits
}

// New builds a demodulator for an audio rate between 8 kHz and 96 kHz. The daemon's channel rate
// is about 48 kHz and depends on the capture rate (49.2 kHz at 3.2 MSPS), so the bound is a sanity
// check on the descriptor, not a promise about which rates were measured.
func New(rate float64) *Demodulator { return NewWith(rate, DefaultOptions()) }

// NewWith builds a demodulator with explicit options.
func NewWith(rate float64, o Options) *Demodulator {
	if rate < 8000 || rate > 96000 {
		panic("afsk: rate outside 8 kHz to 96 kHz")
	}
	n := int(math.Round(rate / BaudHz * o.WindowBits))
	d := &Demodulator{
		rate: rate, window: n, opt: o, twist: math.Pow(10, o.TwistDB/20),
		markCos: make([]float64, n), markSin: make([]float64, n),
		spaceCos: make([]float64, n), spaceSin: make([]float64, n),
		hist: make([]float64, n),
		step: BaudHz / rate * 2,
	}
	for k := 0; k < n; k++ {
		// No taper: over one bit time the two correlators are matched filters,
		// and a raised-cosine window shortens the effective integration. The
		// taper was measured at about 2 dB worse against noise.
		const w = 1.0
		tm := 2 * math.Pi * MarkHz * float64(k) / rate
		ts := 2 * math.Pi * SpaceHz * float64(k) / rate
		d.markCos[k], d.markSin[k] = w*math.Cos(tm), w*math.Sin(tm)
		d.spaceCos[k], d.spaceSin[k] = w*math.Cos(ts), w*math.Sin(ts)
	}
	if o.DCBits > 0 {
		d.dcGain = 1 / (o.DCBits * rate / BaudHz)
	}
	// The smoother takes the correlator's ripple off without rounding the
	// transitions the PLL locks to.
	d.smGain = 1 / (o.SmoothBits * rate / BaudHz)
	return d
}

// Reset clears the demodulator's state. A gap in the stream invalidates
// everything the bit clock believes.
func (d *Demodulator) Reset() {
	for i := range d.hist {
		d.hist[i] = 0
	}
	d.pos, d.filled = 0, 0
	d.prevIn, d.dc, d.smooth, d.phase = 0, 0, 0, 0
	d.haveSign = false
}

// Window is the correlator length in samples, one bit time.
func (d *Demodulator) Window() int { return d.window }

// Feed runs a block of audio through the chain and calls emit for every bit
// the clock samples, with the absolute sample index of that instant.
func (d *Demodulator) Feed(samples []float32, emit func(bit bool, at int64)) {
	for _, s := range samples {
		x := float64(s)
		// Pre-emphasis (Options.PreEmphasis).
		y := x - d.opt.PreEmphasis*d.prevIn
		d.prevIn = x

		d.hist[d.pos] = y
		d.pos++
		if d.pos == d.window {
			d.pos = 0
		}
		if d.filled < d.window {
			d.filled++
			d.index++
			continue
		}

		var mi, mq, si, sq float64
		j := d.pos // oldest sample
		for k := 0; k < d.window; k++ {
			v := d.hist[j]
			mi += v * d.markCos[k]
			mq += v * d.markSin[k]
			si += v * d.spaceCos[k]
			sq += v * d.spaceSin[k]
			j++
			if j == d.window {
				j = 0
			}
		}
		mm, sm := math.Hypot(mi, mq), d.twist*math.Hypot(si, sq)
		disc := mm - sm
		if d.opt.Normalize {
			disc /= mm + sm + 1e-12
		}
		d.dc += (disc - d.dc) * d.dcGain
		d.smooth += (disc - d.dc - d.smooth) * d.smGain

		sign := d.smooth >= 0
		if d.haveSign && sign != d.lastSign {
			// A transition should land half a bit from the sample instant,
			// which is phase 0; pull the clock a fraction of the way there.
			d.phase *= 1 - d.opt.PLLGain
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

// Index is how many samples the demodulator has consumed, the counter the bit
// callback's sample index is measured on.
func (d *Demodulator) Index() int64 { return d.index }
