package main

import (
	"math"
	"math/cmplx"
	"sort"
)

// fft is an in-place radix-2 FFT; len(x) must be a power of two.
func fft(x []complex128) {
	n := len(x)
	for i, j := 1, 0; i < n; i++ {
		bit := n >> 1
		for ; j&bit != 0; bit >>= 1 {
			j ^= bit
		}
		j ^= bit
		if i < j {
			x[i], x[j] = x[j], x[i]
		}
	}
	for size := 2; size <= n; size <<= 1 {
		w := cmplx.Rect(1, -2*math.Pi/float64(size))
		for start := 0; start < n; start += size {
			wk := complex(1, 0)
			for k := range size / 2 {
				a, b := x[start+k], x[start+k+size/2]*wk
				x[start+k], x[start+k+size/2] = a+b, a-b
				wk *= w
			}
		}
	}
}

// toneMeasure is the result of measuring the dominant tone of an audio signal.
type toneMeasure struct {
	peakHz   float64 // interpolated frequency of the dominant peak
	snrDB    float64 // peak (main lobe) power over the rest of the audio band
	frames   int     // frames analysed after gating
	gatedOut int     // frames discarded by the keying gate
}

const (
	analyzeFFT   = 4096
	mainLobeBins = 4 // Blackman-Harris main lobe half-width
	bandLowHz    = 50
)

// measureTone estimates the dominant spectral peak of audio and its SNR over
// the rest of the band [bandLowHz, 0.45·rate] using a Welch average of
// Blackman-Harris-windowed frames (50 % overlap). Frames whose power is below
// 90 % of the 90th-percentile frame power are gated out so keyed signals (CW) are
// measured while keyed. The peak's ±mainLobeBins are counted as signal.
func measureTone(audio []float64, rate float64) toneMeasure {
	n := analyzeFFT
	for len(audio) < n && n > 64 {
		n /= 2
	}
	win := make([]float64, n)
	for i := range win {
		t := 2 * math.Pi * float64(i) / float64(n-1)
		win[i] = 0.35875 - 0.48829*math.Cos(t) + 0.14128*math.Cos(2*t) - 0.01168*math.Cos(3*t)
	}
	hop := n / 2
	type frame struct {
		power float64
		spec  []float64
	}
	var frames []frame
	buf := make([]complex128, n)
	for start := 0; start+n <= len(audio); start += hop {
		var p float64
		for i := range n {
			v := audio[start+i]
			p += v * v
			buf[i] = complex(v*win[i], 0)
		}
		fft(buf)
		spec := make([]float64, n/2)
		for i := range spec {
			spec[i] = real(buf[i])*real(buf[i]) + imag(buf[i])*imag(buf[i])
		}
		frames = append(frames, frame{p / float64(n), spec})
	}
	if len(frames) == 0 {
		return toneMeasure{snrDB: math.Inf(-1)}
	}
	powers := make([]float64, len(frames))
	for i, f := range frames {
		powers[i] = f.power
	}
	sort.Float64s(powers)
	ref := powers[len(powers)*9/10]
	avg := make([]float64, n/2)
	var m toneMeasure
	for _, f := range frames {
		if f.power < 0.9*ref {
			m.gatedOut++
			continue
		}
		for i, v := range f.spec {
			avg[i] += v
		}
		m.frames++
	}
	binHz := rate / float64(n)
	lo := int(math.Ceil(bandLowHz / binHz))
	hi := int(0.45 * rate / binHz)
	if hi > len(avg)-1 {
		hi = len(avg) - 1
	}
	pk := lo
	for i := lo; i <= hi; i++ {
		if avg[i] > avg[pk] {
			pk = i
		}
	}
	// Parabolic interpolation on log magnitude for sub-bin frequency.
	delta := 0.0
	if pk > 0 && pk < len(avg)-1 && avg[pk] > 0 {
		a, b, c := math.Log(avg[pk-1]+1e-300), math.Log(avg[pk]+1e-300), math.Log(avg[pk+1]+1e-300)
		if den := a - 2*b + c; den != 0 {
			delta = 0.5 * (a - c) / den
		}
	}
	m.peakHz = (float64(pk) + delta) * binHz
	var sig, rest float64
	for i := lo; i <= hi; i++ {
		if i >= pk-mainLobeBins && i <= pk+mainLobeBins {
			sig += avg[i]
		} else {
			rest += avg[i]
		}
	}
	m.snrDB = 10 * math.Log10(sig/(rest+1e-300))
	return m
}
