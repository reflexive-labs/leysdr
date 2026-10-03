// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"math"
	"math/cmplx"
	"strings"
)

// channelResult is the output of the reference channel chain.
type channelResult struct {
	// iq is the post-filter channel IQ the meters are computed from.
	iq []complex128
	// iqRate is the sample rate of iq (r2, or r1 for WFM).
	iqRate float64
	// audio is the demodulated audio (nil for rawIQ).
	audio []float64
	// audioRate is the sample rate of audio (≈ 48 kHz).
	audioRate float64
}

// chainPlan is the reference chain's arithmetic for one channel of a file at one rate: the
// decimations, the NCO and BFO, and the stage-1 filter.
type chainPlan struct {
	mode         string
	rate, r1, r2 float64
	d1, d2       int
	nco, bfo, bw float64
	// taps1 is nil when stage 1 passes the mixed signal through.
	taps1 []float64
}

// planChain lays out the float64 reference chain from docs/dev/engine-internals.md
// "Channelizer plan" and "Demodulators": NCO mix → stage-1 FIR/decimate to
// r1 ≥ 240 kHz → stage-2 FIR/decimate to ≈ 48 kHz → demod.
func planChain(rate float64, mode string, offset, bw float64) (*chainPlan, error) {
	mode = strings.ToUpper(mode)
	p := &chainPlan{mode: mode, rate: rate, bw: bw}
	p.d1 = max(1, int(math.Floor(rate/240_000)))
	p.r1 = rate / float64(p.d1)
	p.d2 = max(1, int(math.Round(p.r1/48_000)))
	p.r2 = p.r1 / float64(p.d2)

	p.nco = offset
	switch mode {
	case "USB":
		p.nco += bw / 2
		p.bfo = bw / 2
	case "LSB":
		p.nco -= bw / 2
		p.bfo = -bw / 2
	case "CW":
		p.bfo = 700
	}

	var cut1 float64
	if mode == "WFM" {
		cut1 = bw / 2
	} else {
		cut1 = math.Min(bw/2+5000, 0.4*p.r1)
	}
	if cut1 >= 0.5*p.r1 {
		return nil, fmt.Errorf("bandwidth %.0f Hz does not fit stage-1 rate %.0f Hz", bw, p.r1)
	}
	if p.d1 > 1 || cut1 < 0.4*p.r1 {
		p.taps1 = lowpassTaps(cut1, math.Max(0.1*p.r1, 0.5*(0.5*p.r1-cut1)), rate)
	}
	return p, nil
}

// stage1 is the chain's NCO mix and first decimation as a stream, so a file larger than memory
// is checked block by block. Fed the whole file in one call or in many, it produces the same
// samples: the NCO phase is computed from the absolute sample index, and the filter keeps the
// inputs its taps reach back over.
type stage1 struct {
	p *chainPlan
	// n is the absolute index of the next input sample.
	n int64
	// hist holds the last len(taps1)-1 mixed inputs.
	hist []complex128
	buf  []complex128
	out  []complex128
}

func (p *chainPlan) stage1() *stage1 { return &stage1{p: p} }

// feed mixes and decimates the next block of the file.
func (s *stage1) feed(x []complex128) {
	w := -2 * math.Pi * s.p.nco / s.p.rate
	s.buf = append(s.buf[:0], s.hist...)
	base := s.n - int64(len(s.hist)) // absolute index of s.buf[0]
	for i, v := range x {
		s.buf = append(s.buf, v*cmplx.Rect(1, math.Mod(w*float64(s.n+int64(i)), 2*math.Pi)))
	}
	end := s.n + int64(len(x))
	if s.p.taps1 == nil {
		s.out = append(s.out, s.buf[len(s.hist):]...)
	} else {
		d := int64(s.p.d1)
		// Output k is taken at input k·d, so the first one this block owns is the next
		// multiple of d at or after s.n. Inputs before the file's start count as zeros.
		for k := (s.n + d - 1) / d * d; k < end; k += d {
			idx := int(k - base)
			var acc complex128
			for j, h := range s.p.taps1 {
				i := idx - j
				if i < 0 {
					break
				}
				acc += s.buf[i] * complex(h, 0)
			}
			s.out = append(s.out, acc)
		}
	}
	s.n = end
	keep := max(0, len(s.p.taps1)-1)
	s.hist = append(s.hist[:0], s.buf[max(0, len(s.buf)-keep):]...)
}

// finish runs the rest of the chain over stage 1's output.
func (p *chainPlan) finish(s1 []complex128) (*channelResult, error) {
	res := &channelResult{}
	if p.mode == "WFM" {
		res.iq, res.iqRate = s1, p.r1
		disc := discriminate(s1, 75_000, p.r1)
		deemph := onePoleLP(disc, 1/(2*math.Pi*75e-6), p.r1)
		res.audio = firDecimateReal(deemph, lowpassTaps(15_000, 5_000, p.r1), p.d2)
		res.audioRate = p.r2
		return res, nil
	}

	cut2 := p.bw / 2
	s2 := firDecimate(s1, lowpassTaps(cut2, math.Max(p.bw/8, 0.01*p.r1), p.r1), p.d2)
	res.iq, res.iqRate = s2, p.r2
	res.audioRate = p.r2
	switch p.mode {
	case "NFM":
		res.audio = onePoleLP(discriminate(s2, 5000, p.r2), 4000, p.r2)
	case "AM":
		res.audio = onePoleLP(onePoleHP(envelope(s2), 50, p.r2), 5000, p.r2)
	case "USB", "LSB", "CW":
		res.audio = productDetect(s2, p.bfo, p.r2)
	case "RAWIQ", "RAW_IQ", "IQ":
		res.audio = nil
	default:
		return nil, fmt.Errorf("unsupported mode %q", p.mode)
	}
	return res, nil
}

// referenceChain runs the whole chain (planChain) over samples already in memory.
func referenceChain(x []complex128, rate float64, mode string, offset, bw float64) (*channelResult, error) {
	p, err := planChain(rate, mode, offset, bw)
	if err != nil {
		return nil, err
	}
	s := p.stage1()
	s.feed(x)
	return p.finish(s.out)
}
