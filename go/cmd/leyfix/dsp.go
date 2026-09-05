package main

import (
	"math"
	"math/cmplx"
)

// mixNCO multiplies x by exp(-j·2π·f/rate·n), shifting a signal at +f to DC.
func mixNCO(x []complex128, f, rate float64) []complex128 {
	out := make([]complex128, len(x))
	w := -2 * math.Pi * f / rate
	for i, v := range x {
		out[i] = v * cmplx.Rect(1, math.Mod(w*float64(i), 2*math.Pi))
	}
	return out
}

// lowpassTaps designs a Blackman-windowed sinc low-pass with the given cutoff
// and transition width (Hz) at rate; taps ≈ 4·rate/transition, odd, ≤ 1023.
func lowpassTaps(cutoff, transition, rate float64) []float64 {
	n := int(math.Ceil(4 * rate / transition))
	if n > 1023 {
		n = 1023
	}
	if n < 3 {
		n = 3
	}
	if n%2 == 0 {
		n++
	}
	h := make([]float64, n)
	fc := cutoff / rate
	m := float64(n - 1)
	sum := 0.0
	for i := range h {
		k := float64(i) - m/2
		var s float64
		if k == 0 {
			s = 2 * fc
		} else {
			s = math.Sin(2*math.Pi*fc*k) / (math.Pi * k)
		}
		w := 0.42 - 0.5*math.Cos(2*math.Pi*float64(i)/m) + 0.08*math.Cos(4*math.Pi*float64(i)/m)
		h[i] = s * w
		sum += h[i]
	}
	for i := range h {
		h[i] /= sum
	}
	return h
}

// firDecimate filters x with taps and keeps every d-th output, computing
// only the kept outputs. The first (len(taps)-1) inputs are treated as
// preceded by zeros; outputs are aligned so output k corresponds to input k·d.
func firDecimate(x []complex128, taps []float64, d int) []complex128 {
	n := len(x)
	out := make([]complex128, 0, n/d+1)
	for k := 0; k < n; k += d {
		var acc complex128
		for j, h := range taps {
			i := k - j
			if i < 0 {
				break
			}
			acc += x[i] * complex(h, 0)
		}
		out = append(out, acc)
	}
	return out
}

// firDecimateReal is firDecimate for real signals.
func firDecimateReal(x []float64, taps []float64, d int) []float64 {
	n := len(x)
	out := make([]float64, 0, n/d+1)
	for k := 0; k < n; k += d {
		var acc float64
		for j, h := range taps {
			i := k - j
			if i < 0 {
				break
			}
			acc += x[i] * h
		}
		out = append(out, acc)
	}
	return out
}

// discriminate is the quadrature FM discriminator arg(x[n]·conj(x[n-1])),
// scaled so that a deviation of dev Hz at rate maps to ±1.
func discriminate(x []complex128, dev, rate float64) []float64 {
	out := make([]float64, len(x))
	scale := rate / (2 * math.Pi * dev)
	var prev complex128
	for i, v := range x {
		out[i] = cmplx.Phase(v*cmplx.Conj(prev)) * scale
		prev = v
	}
	if len(out) > 0 {
		out[0] = 0
	}
	return out
}

// onePoleLP applies a 1-pole low-pass with cutoff fc (Hz).
func onePoleLP(x []float64, fc, rate float64) []float64 {
	a := math.Exp(-2 * math.Pi * fc / rate)
	out := make([]float64, len(x))
	var y float64
	for i, v := range x {
		y = (1-a)*v + a*y
		out[i] = y
	}
	return out
}

// onePoleHP applies a 1-pole DC-blocking high-pass with cutoff fc (Hz).
func onePoleHP(x []float64, fc, rate float64) []float64 {
	a := math.Exp(-2 * math.Pi * fc / rate)
	out := make([]float64, len(x))
	var y, px float64
	for i, v := range x {
		y = a*y + a*(v-px)
		px = v
		out[i] = y
	}
	return out
}

// envelope returns |x|.
func envelope(x []complex128) []float64 {
	out := make([]float64, len(x))
	for i, v := range x {
		out[i] = cmplx.Abs(v)
	}
	return out
}

// productDetect mixes x by +bfo Hz and takes the real part.
func productDetect(x []complex128, bfo, rate float64) []float64 {
	out := make([]float64, len(x))
	w := 2 * math.Pi * bfo / rate
	for i, v := range x {
		out[i] = real(v * cmplx.Rect(1, math.Mod(w*float64(i), 2*math.Pi)))
	}
	return out
}

// meanPowerDBFS is 10·log10(mean|x|²) with full scale 1.
func meanPowerDBFS(x []complex128) float64 {
	if len(x) == 0 {
		return math.Inf(-1)
	}
	var p float64
	for _, v := range x {
		p += real(v)*real(v) + imag(v)*imag(v)
	}
	return 10 * math.Log10(p/float64(len(x)))
}
