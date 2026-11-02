// SPDX-License-Identifier: Apache-2.0

package modes

import (
	"math"
	"slices"
)

// The Mode S reply on 1090 MHz is pulse-position modulated at 1 Mbit/s: an 8 µs preamble of four
// 0.5 µs pulses starting at 0, 1.0, 3.5 and 4.5 µs, then 56 or 112 bits of 1 µs each, a pulse
// in the first half of the bit for a 1 and in the second half for a 0 (ICAO Annex 10, Volume IV,
// 3.1.2.1). At 2.4 MSPS a microsecond is 2.4 samples, so the bit centres fall between samples.
// The demodulator works on the running integral of the magnitude, which it reads at fractional
// sample positions, so a half-bit's energy is measured over exactly 0.5 µs wherever it starts,
// and it searches the frame start in fifth-of-a-sample steps.
const (
	preambleUs = 8
	// phaseStep is the fractional start search's step in samples.
	phaseStep = 0.2
	// phasesTried is how many of the best-scoring start phases are demodulated before a
	// candidate is given up.
	phasesTried = 3
)

// The preamble's pulses and the quiet between them, in µs from the frame start.
var (
	preamblePulses = [4][2]float64{{0, 0.5}, {1, 1.5}, {3.5, 4}, {4.5, 5}}
	preambleQuiet  = [4][2]float64{{0.5, 1}, {1.5, 3.5}, {4, 4.5}, {5, 8}}
)

const (
	pulseUs = 2.0 // the four pulses' total length
	quietUs = 6.0 // the quiet's total length
	// stage1Ratio is how far the pulses' mean magnitude must stand over the quiet's at the
	// whole-sample start for the candidate to be looked at, and phaseRatio how far at the
	// fractional start that is demodulated. On the antenna capture of 2026-11-02
	// (TestRealCapture) these three accept 30 replies from 94k candidates in 9.5 s; 1.3, 1.4
	// and no floor accept 32 from 1.8M candidates, and 2.0, 2.2 and 1.5 accept 24 from 483.
	stage1Ratio = 1.6
	phaseRatio  = 1.8
	// floorRatio is how far the pulses' mean must stand over the block's mean magnitude.
	floorRatio = 1.0
)

// Frame is one reply the demodulator accepted on its parity.
type Frame struct {
	Msg []byte // 7 or 14 bytes, the demodulator's own copy
	// Addr is the aircraft address: from the AA field for DF11, DF17 and DF18, from the parity
	// for DF4, DF5, DF20 and DF21.
	Addr uint32
	// End is the sample index just past the frame's last bit.
	End int64
	// Corrected marks a DF17 or DF18 with one bit corrected by its parity.
	Corrected bool
}

// Stats counts the demodulator's work since it was made.
type Stats struct {
	Samples    int64 // magnitudes scanned
	Candidates int64 // starts that passed the whole-sample preamble test
	Frames     int64 // replies accepted
	Corrected  int64 // of those, DF17 or DF18 with one bit corrected
}

// Demod finds Mode S replies in complex baseband. It keeps the tail of each block it is fed, so
// a reply that straddles two blocks is decoded once the second arrives.
type Demod struct {
	spu float64 // samples per µs

	mag  []float32 // the magnitudes not yet scanned, and the tail a frame may still need
	pre  []float64 // pre[i] is the sum of mag[:i]
	base int64     // the sample index of mag[0]
	scan int       // where the next scan starts in mag
	// need is how many samples past a start a long frame needs, at the last phase tried.
	need int
	// floor is a running mean of the magnitude: the level a preamble must stand over.
	floor float64

	// stage1 is the preamble's edges at the whole-sample start, split into sample and fraction.
	stage1 [16]edge

	// Known reports whether addr is an aircraft heard recently in a reply that carries its
	// address in the clear (DF11, DF17, DF18). It gates the replies whose address comes from the
	// parity, and single-bit correction, which noise would otherwise satisfy by chance. Nil
	// accepts none of them.
	Known func(addr uint32) bool

	Stats Stats

	msg    [14]byte
	scores [5]phaseScore
	back   [112][2]uint8 // the Viterbi search's choice of previous bit, per bit and state
	cov    []float64     // the preamble's pulse coverage per sample
}

type edge struct {
	i int
	f float64
}

type phaseScore struct {
	phase, ratio float64
}

// NewDemod makes a demodulator for complex baseband at rate samples per second, which must be at
// least 2 MSPS: the half-bit is 0.5 µs.
func NewDemod(rate float64) *Demod {
	d := &Demod{spu: rate / 1e6}
	d.cov = make([]float64, int(preambleUs*d.spu)+2)
	d.need = int(math.Ceil((preambleUs+112)*d.spu+1)) + 2
	k := 0
	for _, set := range [][4][2]float64{preamblePulses, preambleQuiet} {
		for _, iv := range set {
			for _, us := range iv {
				x := us * d.spu
				d.stage1[k] = edge{int(x), x - math.Floor(x)}
				k++
			}
		}
	}
	return d
}

// Reset drops the samples held and starts counting again at sample index at, as after a gap.
func (d *Demod) Reset(at int64) {
	d.mag, d.pre = d.mag[:0], d.pre[:0]
	d.base, d.scan = at, 0
}

// Next is the sample index the next sample fed will have.
func (d *Demod) Next() int64 { return d.base + int64(len(d.mag)) }

// Feed scans a block of samples, continuing from the last, and calls emit for each reply found.
// emit may keep the Frame.
func (d *Demod) Feed(iq []complex64, emit func(Frame)) {
	var sum float64
	for _, x := range iq {
		re, im := real(x), imag(x)
		m := float32(math.Sqrt(float64(re*re + im*im)))
		d.mag = append(d.mag, m)
		sum += float64(m)
	}
	if len(iq) > 0 {
		mean := sum / float64(len(iq))
		if d.floor == 0 {
			d.floor = mean
		} else {
			d.floor += 0.1 * (mean - d.floor)
		}
	}
	d.pre = slices.Grow(d.pre[:0], len(d.mag)+1)[:len(d.mag)+1]
	var acc float64
	d.pre[0] = 0
	for i, m := range d.mag {
		acc += float64(m)
		d.pre[i+1] = acc
	}

	end := len(d.mag) - d.need
	n := d.scan
	minPulse := floorRatio * d.floor * pulseUs * d.spu
	for ; n < end; n++ {
		if !d.stage1Pass(n, minPulse) {
			continue
		}
		d.Stats.Candidates++
		if f, next, ok := d.tryAt(n); ok {
			d.Stats.Frames++
			if f.Corrected {
				d.Stats.Corrected++
			}
			emit(f)
			n = next - 1
		}
	}
	if end > 0 {
		d.Stats.Samples += int64(end - d.scan)
		copy(d.mag, d.mag[end:])
		d.mag = d.mag[:len(d.mag)-end]
		d.base += int64(end)
		d.scan = n - end
	}
}

// integral is the integral of the magnitude from sample position 0 to x, the magnitude held
// constant across each sample.
func (d *Demod) integral(x float64) float64 {
	i := int(x)
	return d.pre[i] + (x-float64(i))*float64(d.mag[i])
}

// stage1Pass is the cheap test run at every whole sample: the preamble's pulses against its quiet
// and against the floor.
func (d *Demod) stage1Pass(n int, minPulse float64) bool {
	s := &d.stage1
	at := func(e edge) float64 {
		i := n + e.i
		return d.pre[i] + e.f*float64(d.mag[i])
	}
	var p float64
	for k := 0; k < 8; k += 2 {
		p += at(s[k+1]) - at(s[k])
	}
	if p < minPulse {
		return false
	}
	var q float64
	for k := 8; k < 16; k += 2 {
		q += at(s[k+1]) - at(s[k])
	}
	return p/pulseUs > stage1Ratio*q/quietUs
}

// preambleRatio is the pulses' mean over the quiet's at the start t0, in samples.
func (d *Demod) preambleRatio(t0 float64) float64 {
	var p, q float64
	for _, iv := range preamblePulses {
		p += d.integral(t0+iv[1]*d.spu) - d.integral(t0+iv[0]*d.spu)
	}
	for _, iv := range preambleQuiet {
		q += d.integral(t0+iv[1]*d.spu) - d.integral(t0+iv[0]*d.spu)
	}
	return (p / pulseUs) / (q/quietUs + 1e-12)
}

// tryAt searches the start phases around the whole-sample candidate n, best preamble first, and
// returns the first reply whose parity is accepted with the scan position just past it.
func (d *Demod) tryAt(n int) (Frame, int, bool) {
	scores := d.scores[:0]
	for k := range 5 {
		t0 := float64(n) + float64(k)*phaseStep
		if r := d.preambleRatio(t0); r > phaseRatio {
			scores = append(scores, phaseScore{t0, r})
		}
	}
	slices.SortFunc(scores, func(a, b phaseScore) int {
		switch {
		case a.ratio > b.ratio:
			return -1
		case a.ratio < b.ratio:
			return 1
		}
		return 0
	})
	if len(scores) > phasesTried {
		scores = scores[:phasesTried]
	}
	next := func(t0 float64, f Frame) int {
		return int(math.Ceil(t0 + (preambleUs+float64(len(f.Msg)*8))*d.spu))
	}
	for _, s := range scores {
		if nb := d.sliceBox(s.phase); nb > 0 {
			if f, ok := d.accept(d.msg[:nb/8], s.phase, false); ok {
				return f, next(s.phase, f), true
			}
		}
	}
	if len(scores) == 0 {
		return Frame{}, 0, false
	}
	// The box decisions failed at every phase: the joint decision at the best phase, which costs
	// about ten times as much, and failing that one corrected bit of a DF17 or DF18.
	s := scores[0]
	nb := d.sliceViterbi(s.phase)
	if nb > 0 {
		if f, ok := d.accept(d.msg[:nb/8], s.phase, false); ok {
			return f, next(s.phase, f), true
		}
	}
	if nb == 112 {
		if f, ok := d.accept(d.msg[:], s.phase, true); ok {
			return f, next(s.phase, f), true
		}
	}
	return Frame{}, 0, false
}

// validDF reports whether df is a format the demodulator accepts.
func validDF(df int) bool {
	switch df {
	case 4, 5, 11, 17, 18, 20, 21:
		return true
	}
	return false
}

// sliceBox decides each bit by comparing the magnitude's integral over its two halves, into
// d.msg, and returns the frame's length in bits, 0 when the DF is not one accepted. It is the
// cheap decision, right when the signal stands well over the noise.
func (d *Demod) sliceBox(t0 float64) int {
	msg := d.msg[:]
	clear(msg)
	x := t0 + preambleUs*d.spu
	half := d.spu / 2
	prev := d.integral(x)
	slice := func(from, to int) {
		for k := from; k < to; k++ {
			mid := d.integral(x + half)
			x += d.spu
			next := d.integral(x)
			if mid-prev > next-mid {
				msg[k/8] |= 0x80 >> (k % 8)
			}
			prev = next
		}
	}
	slice(0, 5)
	df := int(msg[0] >> 3)
	if !validDF(df) {
		return 0
	}
	nbits := msgBits(df)
	slice(5, nbits)
	return nbits
}

// overlap is the length of [a0, a1) inside [b0, b1).
func overlap(a0, a1, b0, b1 float64) float64 {
	return max(0, min(a1, b1)-max(a0, b0))
}

// sliceViterbi decides the bits jointly, into d.msg, and returns the frame's length in bits, 0
// when the DF is not one accepted. At 2.4 MSPS a sample straddles two half-bits, so a pulse at
// the end of one bit spills into the sample that starts the next, and the box decision reads it
// as the next bit's pulse. Each sample depends only on the bit it ends in and the bit before, so
// the most likely bit sequence is a two-state Viterbi search: the expected magnitude of a sample
// is the floor plus the pulse amplitude times the part of the sample a pulse covers, and the
// cost is the squared error. The floor and amplitude come from the preamble at this phase.
func (d *Demod) sliceViterbi(t0 float64) int {
	lo, amp := d.levels(t0)
	if amp <= 0 {
		return 0
	}
	const inf = math.MaxFloat64
	// The preamble ends in quiet, as a 1 bit does.
	cost := [2]float64{inf, 0}
	var short [2]float64
	for k := range 112 {
		x := t0 + float64(preambleUs+k)*d.spu
		h := d.spu / 2
		var next [2]float64
		for c := range 2 {
			next[c] = inf
			pulse0, pulse1 := x+h, x+2*h // a 0: the second half
			if c == 1 {
				pulse0, pulse1 = x, x+h
			}
			for p := range 2 {
				if cost[p] == inf {
					continue
				}
				var e float64
				for j := int(x); float64(j) <= x+2*h-1; j++ {
					fj := float64(j)
					cov := overlap(fj, fj+1, pulse0, pulse1)
					if p == 0 { // the previous bit's pulse was in its second half
						cov += overlap(fj, fj+1, x-h, x)
					}
					r := float64(d.mag[j]) - lo - amp*cov
					e += r * r
				}
				if s := cost[p] + e; s < next[c] {
					next[c] = s
					d.back[k][c] = uint8(p)
				}
			}
		}
		cost = next
		if k == 55 {
			short = cost
		}
	}
	trace := func(last int, end [2]float64) {
		s := 0
		if end[1] < end[0] {
			s = 1
		}
		clear(d.msg[:])
		for k := last; k >= 0; k-- {
			if s == 1 {
				d.msg[k/8] |= 0x80 >> (k % 8)
			}
			s = int(d.back[k][s])
		}
	}
	trace(111, cost)
	df := int(d.msg[0] >> 3)
	if df < 16 {
		trace(55, short)
		df = int(d.msg[0] >> 3)
		if df >= 16 {
			return 0
		}
	}
	if !validDF(df) {
		return 0
	}
	return msgBits(df)
}

// levels estimates the noise floor and the pulse amplitude over it from the preamble at t0: the
// floor is the mean of the samples no pulse touches, and the amplitude the least-squares fit of
// the rest to the part of each sample the pulses cover.
func (d *Demod) levels(t0 float64) (lo, amp float64) {
	var qs float64
	var qn int
	var num, den float64
	end := t0 + preambleUs*d.spu
	for j := int(t0); float64(j) < end-1; j++ {
		fj := float64(j)
		var cov float64
		for _, iv := range preamblePulses {
			cov += overlap(fj, fj+1, t0+iv[0]*d.spu, t0+iv[1]*d.spu)
		}
		m := float64(d.mag[j])
		if cov == 0 {
			qs += m
			qn++
		} else {
			num += m * cov
			den += cov * cov
		}
		d.cov[j-int(t0)] = cov
	}
	if qn > 0 {
		lo = qs / float64(qn)
	}
	// Refit with the floor removed.
	num = 0
	for j := int(t0); float64(j) < end-1; j++ {
		if c := d.cov[j-int(t0)]; c > 0 {
			num += (float64(d.mag[j]) - lo) * c
		}
	}
	if den > 0 {
		amp = num / den
	}
	return lo, amp
}

// accept checks a sliced frame's parity and returns it as a Frame. With correct set it accepts
// only a DF17 or DF18 that one corrected bit makes whole.
func (d *Demod) accept(msg []byte, t0 float64, correct bool) (Frame, bool) {
	df := int(msg[0] >> 3)
	syn := Syndrome(msg)
	end := t0 + (preambleUs+float64(len(msg)*8))*d.spu
	f := Frame{End: d.base + int64(math.Ceil(end))}
	known := func(a uint32) bool { return d.Known != nil && d.Known(a) }
	switch {
	case correct:
		if (df != 17 && df != 18) || syn == 0 || !fixOneBit(msg, syn) {
			return Frame{}, false
		}
		f.Addr, f.Corrected = bits(msg, 8, 24), true
		if !known(f.Addr) {
			return Frame{}, false
		}
	case df == 17 || df == 18:
		if syn != 0 {
			return Frame{}, false
		}
		f.Addr = bits(msg, 8, 24)
	case df == 11:
		// The parity carries the interrogator's code in its low seven bits; a reply to an
		// interrogator other than code 0 is taken only from an aircraft already heard.
		f.Addr = bits(msg, 8, 24)
		if syn != 0 && (syn&^0x7F != 0 || !known(f.Addr)) {
			return Frame{}, false
		}
	default:
		if !known(syn) {
			return Frame{}, false
		}
		f.Addr = syn
	}
	f.Msg = slices.Clone(msg)
	return f, true
}
