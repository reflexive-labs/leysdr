// SPDX-License-Identifier: Apache-2.0

package same

import (
	"math"
	"math/rand/v2"
	"testing"
)

// decodeHeader modulates one header copy (preamble + text) at rate, adds white
// Gaussian noise at snrDB (math.Inf for none), demodulates, and returns the
// first decoded header frame's text, or "" for none.
func decodeHeader(rng *rand.Rand, header string, rate, snrDB float64) string {
	mod := NewModulator(rate, 0.5)
	var audio []float32
	audio = mod.Silence(audio, int(rate*0.02))
	audio = mod.Header(audio, header)
	audio = mod.Silence(audio, int(rate*0.02))
	if !math.IsInf(snrDB, 1) {
		sigma := math.Sqrt(0.125 / math.Pow(10, snrDB/10)) // 0.5-amplitude sine has power 0.125
		for i := range audio {
			audio[i] += float32(sigma * rng.NormFloat64())
		}
	}
	var got string
	New(rate).Feed(audio, func(f Frame) {
		if f.Header && got == "" {
			got = f.Text
		}
	})
	return got
}

func TestRoundTripClean(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2))
	ok := 0
	for i := 0; i < 100; i++ {
		h := rwtHeader
		if i%2 == 1 {
			h = torHeader
		}
		if decodeHeader(rng, h, 48000, math.Inf(1)) == h {
			ok++
		}
	}
	t.Logf("clean round trip at 48 kHz: %d/100", ok)
	if ok < 100 {
		t.Errorf("decoded %d/100 clean headers, want 100", ok)
	}
}

// TestRoundTripInNoise records the sensitivity for the package doc comment. The
// gate is a comfortable 0 dB: SAME rides a strong local NOAA transmitter and
// repeats each header three times, so the operating point is far from the
// -6 dB corner where the decode rate collapses.
func TestRoundTripInNoise(t *testing.T) {
	for _, snr := range []float64{3, 0, -4} {
		rng := rand.New(rand.NewPCG(3, 4))
		ok := 0
		for i := 0; i < 100; i++ {
			if decodeHeader(rng, rwtHeader, 48000, snr) == rwtHeader {
				ok++
			}
		}
		t.Logf("round trip at 48 kHz, %+.0f dB SNR over the audio band: %d/100", snr, ok)
		if snr == 0 && ok < 100 {
			t.Errorf("decoded %d/100 at 0 dB, want 100", ok)
		}
	}
}

func TestDemodDecodesEOM(t *testing.T) {
	mod := NewModulator(48000, 0.5)
	var audio []float32
	audio = mod.Silence(audio, 960)
	audio = mod.EOM(audio)
	audio = mod.Silence(audio, 960)
	var frames []Frame
	New(48000).Feed(audio, func(f Frame) { frames = append(frames, f) })
	if len(frames) != 1 || frames[0].Header || frames[0].Text != "NNNN" {
		t.Fatalf("EOM decode = %+v", frames)
	}
}

// TestFullMessageThreeCopies decodes a whole transmission and confirms the
// three header copies each parse identically, which is the majority-vote input.
func TestFullMessageThreeCopies(t *testing.T) {
	mod := NewModulator(48000, 0.5)
	audio := mod.Message(nil, torHeader, 3)
	var headers, eoms int
	New(48000).Feed(audio, func(f Frame) {
		if f.Header {
			if f.Text != torHeader {
				t.Errorf("copy decoded as %q", f.Text)
			}
			headers++
		} else {
			eoms++
		}
	})
	if headers != 3 || eoms != 3 {
		t.Fatalf("got %d headers and %d EOMs, want 3 and 3", headers, eoms)
	}
}
