// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"math"
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

// referenceChain runs the float64 reference chain from docs/engine-internals.md
// "Channelizer plan" and "Demodulators": NCO mix → stage-1 FIR/decimate to
// r1 ≥ 240 kHz → stage-2 FIR/decimate to ≈ 48 kHz → demod.
func referenceChain(x []complex128, rate float64, mode string, offset, bw float64) (*channelResult, error) {
	mode = strings.ToUpper(mode)
	d1 := max(1, int(math.Floor(rate/240_000)))
	r1 := rate / float64(d1)
	d2 := max(1, int(math.Round(r1/48_000)))
	r2 := r1 / float64(d2)

	nco := offset
	var bfo float64
	switch mode {
	case "USB":
		nco += bw / 2
		bfo = bw / 2
	case "LSB":
		nco -= bw / 2
		bfo = -bw / 2
	case "CW":
		bfo = 700
	}

	var cut1 float64
	if mode == "WFM" {
		cut1 = bw / 2
	} else {
		cut1 = math.Min(bw/2+5000, 0.4*r1)
	}
	if cut1 >= 0.5*r1 {
		return nil, fmt.Errorf("bandwidth %.0f Hz does not fit stage-1 rate %.0f Hz", bw, r1)
	}
	mixed := mixNCO(x, nco, rate)
	var s1 []complex128
	if d1 > 1 || cut1 < 0.4*r1 {
		s1 = firDecimate(mixed, lowpassTaps(cut1, math.Max(0.1*r1, 0.5*(0.5*r1-cut1)), rate), d1)
	} else {
		s1 = mixed
	}

	res := &channelResult{}
	if mode == "WFM" {
		res.iq, res.iqRate = s1, r1
		disc := discriminate(s1, 75_000, r1)
		deemph := onePoleLP(disc, 1/(2*math.Pi*75e-6), r1)
		res.audio = firDecimateReal(deemph, lowpassTaps(15_000, 5_000, r1), d2)
		res.audioRate = r2
		return res, nil
	}

	cut2 := bw / 2
	s2 := firDecimate(s1, lowpassTaps(cut2, math.Max(bw/8, 0.01*r1), r1), d2)
	res.iq, res.iqRate = s2, r2
	res.audioRate = r2
	switch mode {
	case "NFM":
		res.audio = onePoleLP(discriminate(s2, 5000, r2), 4000, r2)
	case "AM":
		res.audio = onePoleLP(onePoleHP(envelope(s2), 50, r2), 5000, r2)
	case "USB", "LSB", "CW":
		res.audio = productDetect(s2, bfo, r2)
	case "RAWIQ", "RAW_IQ", "IQ":
		res.audio = nil
	default:
		return nil, fmt.Errorf("unsupported mode %q", mode)
	}
	return res, nil
}
