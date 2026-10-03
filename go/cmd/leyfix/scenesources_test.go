// SPDX-License-Identifier: Apache-2.0

package main

import (
	"math"
	"math/cmplx"
	"path/filepath"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/iqfile"
)

// silent is a source that adds nothing, so a wrapper's own contribution can be measured.
type silent struct{}

func (silent) fill([]complex128, int64) {}
func (silent) describe() map[string]any { return map[string]any{"type": "silent"} }
func (silent) span() (float64, float64) { return 0, 0 }

// render runs a source over n samples in blocks of blk, as generate does.
func render(s source, n, blk int) []complex128 {
	out := make([]complex128, n)
	for n0 := 0; n0 < n; n0 += blk {
		s.fill(out[n0:min(n0+blk, n)], int64(n0))
	}
	return out
}

// psd is a Welch average of Hann-windowed FFTs of x, as power per bin with bin 0 at DC and
// negative frequencies in the upper half.
func psd(x []complex128, size int) []float64 {
	out := make([]float64, size)
	buf := make([]complex128, size)
	frames := 0
	for start := 0; start+size <= len(x); start += size / 2 {
		for i := range buf {
			w := 0.5 - 0.5*math.Cos(2*math.Pi*float64(i)/float64(size))
			buf[i] = x[start+i] * complex(w, 0)
		}
		fft(buf)
		for i, v := range buf {
			out[i] += real(v)*real(v) + imag(v)*imag(v)
		}
		frames++
	}
	for i := range out {
		out[i] /= float64(frames)
	}
	return out
}

// bandFraction is the share of a psd's power within lo..hi Hz of DC.
func bandFraction(p []float64, rate, lo, hi float64) float64 {
	var in, all float64
	for i, v := range p {
		f := float64(i) * rate / float64(len(p))
		if f >= rate/2 {
			f -= rate
		}
		all += v
		if math.Abs(f) >= lo && math.Abs(f) <= hi {
			in += v
		}
	}
	return in / all
}

func meanPower(x []complex128) float64 {
	var p float64
	for _, v := range x {
		p += real(v)*real(v) + imag(v)*imag(v)
	}
	return p / float64(len(x))
}

// The skirt is at the level it claims, inside about its half-width, and the same samples come
// from the same seed however the stream is cut into blocks.
func TestSplatter(t *testing.T) {
	const rate = 480_000
	mk := func(seed uint64) *splatter {
		return &splatter{inner: silent{}, rate: rate, offsetHz: 0, widthHz: 15_000, carrierDBFS: -10, dbc: 37, seed: seed}
	}
	x := render(mk(28), 1<<19, 16384)
	if got := 10 * math.Log10(meanPower(x)); math.Abs(got-(-47)) > 0.5 {
		t.Errorf("skirt power %.2f dBFS, want -47", got)
	}
	p := psd(x, 4096)
	if f := bandFraction(p, rate, 0, 15_000); f < 0.85 {
		t.Errorf("%.1f%% of the skirt is within ±15 kHz, want at least 85%%", 100*f)
	}
	if f := bandFraction(p, rate, 30_000, rate/2); f > 0.005 {
		t.Errorf("%.2f%% of the skirt is beyond ±30 kHz, want under 0.5%%", 100*f)
	}
	y := render(mk(28), 1<<19, 1000)
	for i := range x {
		if x[i] != y[i] {
			t.Fatalf("sample %d is %v in 16384-sample blocks and %v in 1000-sample ones", i, x[i], y[i])
		}
	}
	if z := render(mk(29), 16, 16); z[10] == x[10] {
		t.Error("seeds 28 and 29 gave the same sample")
	}
}

// The FSK carrier sits on its four levels in the second half of every symbol, stays inside about
// 8 kHz, and is the same from the same seed, including after reading backwards.
func TestFSK4(t *testing.T) {
	const rate = 96_000 // 20 samples a symbol
	s := &fsk4{rate: rate, carrierHz: 0, dbfs: -20, seed: 29}
	x := render(s, 1<<18, 4096)
	if got := 10 * math.Log10(meanPower(x)); math.Abs(got-(-20)) > 0.01 {
		t.Errorf("power %.2f dBFS, want -20", got)
	}
	counts := map[float64]int{}
	const sps = rate / fsk4SymbolRate
	for k := 1; k < len(x)/sps-1; k++ {
		n := k*sps + 3*sps/4
		f := cmplx.Phase(x[n]*cmplx.Conj(x[n-1])) * rate / (2 * math.Pi)
		level := math.NaN()
		for _, d := range fsk4Deviations {
			if math.Abs(f-d) < 1 {
				level = d
			}
		}
		if math.IsNaN(level) {
			t.Fatalf("symbol %d is at %.1f Hz, off every level", k, f)
		}
		counts[level]++
	}
	for _, d := range fsk4Deviations {
		if n := counts[d]; n < 2950 || n > 3600 {
			t.Errorf("level %+.0f Hz in %d of about 3277 symbols", d, n)
		}
	}
	if f := bandFraction(psd(x, 4096), rate, 0, 4200); f < 0.99 {
		t.Errorf("%.2f%% of the power is within ±4.2 kHz, want 99%%", 100*f)
	}
	again := &fsk4{rate: rate, carrierHz: 0, dbfs: -20, seed: 29}
	first := again.devAt(5000)
	_ = again.devAt(90_000)
	if d := again.devAt(5000); d != first {
		t.Errorf("sample 5000 at %.1f Hz, then %.1f Hz after a later one", first, d)
	}
}

// subTone is the peak deviation, in Hz, of a tone at hz in NFM audio from the reference chain
// (normalised to 5 kHz) between samples lo and hi.
func subTone(audio []float32, rate float64, lo, hi int, hz float64) float64 {
	var acc complex128
	for i := lo; i < hi; i++ {
		acc += complex(float64(audio[i]), 0) * cmplx.Rect(1, -2*math.Pi*hz*float64(i)/rate)
	}
	return 2 * cmplx.Abs(acc) / float64(hi-lo) * 5000
}

// A repeater's over is followed by a tail of carrier with the PL still on it, silent but for a
// 1 kHz beep 0.6 s in, and the carrier drops when the tail ends.
func TestCourtesyTail(t *testing.T) {
	const rate = 48_000
	c := sceneCarrier{offsetHz: 0, dbfs: -18, voiceSeed: 30, toneHz: 146.2, tailS: 1.5, segs: []keySegment{{0.5, 2.5}}}
	if k := c.keying(); len(k) != 1 || k[0] != (keySegment{0.5, 4.0}) {
		t.Fatalf("keying %v, want [{0.5 4}]", k)
	}
	x := render(c.source(rate), 5*rate, 4096)
	disc := make([]float64, len(x))
	for i := 1; i < len(x); i++ {
		disc[i] = cmplx.Phase(x[i]*cmplx.Conj(x[i-1])) * rate / (2 * math.Pi)
	}
	// The deviation that is not the PL tone, in a window: the voice, the beep, or nothing.
	rest := func(a, b float64) (rms float64, beep float64) {
		lo, hi := int(a*rate), int(b*rate)
		var acc complex128
		for i := lo; i < hi; i++ {
			v := disc[i] - sceneSubDevHz*math.Sin(2*math.Pi*146.2*float64(i)/rate)
			rms += v * v
			acc += complex(disc[i], 0) * cmplx.Rect(1, -2*math.Pi*sceneBeepHz*float64(i)/rate)
		}
		return math.Sqrt(rms / float64(hi-lo)), 2 * cmplx.Abs(acc) / float64(hi-lo)
	}
	if v, _ := rest(0.6, 2.4); v < 300 {
		t.Errorf("the over carries %.0f Hz rms of voice", v)
	}
	if v, _ := rest(2.55, 3.05); v > 5 {
		t.Errorf("the tail before the beep carries %.1f Hz rms besides the PL", v)
	}
	if _, b := rest(3.11, 3.24); math.Abs(b-sceneBeepLevel*sceneDevHz) > 50 {
		t.Errorf("the beep deviates %.0f Hz, want %.0f", b, sceneBeepLevel*sceneDevHz)
	}
	if v, _ := rest(3.3, 3.95); v > 5 {
		t.Errorf("the tail after the beep carries %.1f Hz rms besides the PL", v)
	}
	if p := meanPower(x[int(4.05*rate) : 5*rate]); p != 0 {
		t.Errorf("the carrier is still up after the tail: %g", p)
	}
	d := c.source(rate).describe()["carrier"].(map[string]any)
	if _, ok := d["courtesy_tail"]; !ok {
		t.Errorf("the sidecar does not record the tail: %v", d)
	}
}

// A short cluster built like scene_2m's around 146.520 -- the hero with a strong splattering
// neighbour overlapping it, the FSK bursts, the repeater with its tail and the weak simplex
// stations -- passes leyfix check through the cu8 quantisation, and the hero's PL 100.0 and the
// repeater's PL 146.2 keep their deviation while the neighbour is keyed.
func TestShortClusterChecks(t *testing.T) {
	const rate = 960_000
	carriers := []sceneCarrier{
		{offsetHz: 0, dbfs: -12, voiceSeed: 21, toneHz: 100.0, segs: []keySegment{{0.6, 4.5}, {6, 9}}},
		{
			offsetHz: 30_000, dbfs: -10, voiceSeed: 28, devHz: 5000,
			splatterHz: scene2mSplatterHz, splatterDB: scene2mSplatterDB, segs: []keySegment{{2, 7}},
		},
		{offsetHz: 60_000, dbfs: -20, voiceSeed: 29, fsk: true, segs: []keySegment{{1, 4}, {6.5, 9.5}}},
		{offsetHz: 120_000, dbfs: -18, voiceSeed: 30, toneHz: 146.2, tailS: scene2mTailS, segs: []keySegment{{0.8, 3.5}, {6, 7.5}}},
		{offsetHz: -90_000, dbfs: -34, voiceSeed: 26, segs: []keySegment{{1, 2.5}, {5, 7}}},
		{offsetHz: -60_000, dbfs: -24, voiceSeed: 27, segs: []keySegment{{0.5, 5}, {7, 9.5}}},
	}
	f := &fixture{
		name: "short_cluster", centerHz: 146_520_000, set: sceneSet, format: iqfile.FormatCU8,
		fixedRate: rate, fixedDurationS: 10, noiseDBFS: sceneNoiseDBFS,
		build: func(rate float64) []source { return sources(rate, carriers) },
		expect: func(float64) []iqfile.Expect {
			var out []iqfile.Expect
			for i, c := range carriers {
				out = append(out, c.expect(i == 0))
			}
			return out
		},
	}
	if !f.fits(rate) {
		t.Fatal("the cluster does not fit its rate")
	}
	path := filepath.Join(t.TempDir(), "short_cluster.cu8")
	if err := generateOne(f, genOptions{seed: 1}, path); err != nil {
		t.Fatal(err)
	}
	results, err := checkFile(iqfile.SidecarPath(path))
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range results {
		if !r.pass {
			t.Errorf("FAIL [%d] %s", r.index, r.detail)
		}
	}
	exp := f.expect(rate)
	// The hero from 2.5 to 4.4 s, while 146.550 is keyed beside it; the repeater's first over
	// and tail, 1 to 4.2 s.
	for _, w := range []struct {
		i      int
		tone   float64
		lo, hi float64
		near   []float64
	}{
		{0, 100.0, 2.5, 4.4, []float64{94.8, 103.5}},
		{3, 146.2, 1.0, 4.2, []float64{141.3, 151.4}},
	} {
		audio, ar := decodeAt(t, path, exp[w.i])
		lo, hi := int(w.lo*ar), int(w.hi*ar)
		dev := subTone(audio, ar, lo, hi, w.tone)
		t.Logf("%.1f Hz deviates %.0f Hz", w.tone, dev)
		if math.Abs(dev-sceneSubDevHz) > 0.1*sceneSubDevHz {
			t.Errorf("%.1f Hz deviates %.0f Hz, want %d ±10%%", w.tone, dev, sceneSubDevHz)
		}
		for _, n := range w.near {
			if other := subTone(audio, ar, lo, hi, n); 20*math.Log10(dev/other) < 20 {
				t.Errorf("%.1f Hz is %.1f dB over %.1f Hz, want 20", w.tone, 20*math.Log10(dev/other), n)
			}
		}
	}
}
