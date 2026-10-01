// SPDX-License-Identifier: Apache-2.0

package afsk_test

import (
	"bytes"
	"fmt"
	"math"
	"math/rand/v2"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/afsk"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
)

// randomFrame builds a UI frame with random callsigns and a random info field,
// so the round trip is measured over the bit patterns a real channel carries
// rather than one lucky packet.
func randomFrame(rng *rand.Rand) []byte {
	call := func() ax25.Address {
		letters := []byte("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
		var b []byte
		for i := 0; i < 4+rng.IntN(3); i++ {
			b = append(b, letters[rng.IntN(len(letters))])
		}
		return ax25.Address{Call: string(b), SSID: rng.IntN(16)}
	}
	info := make([]byte, 10+rng.IntN(50))
	for i := range info {
		info[i] = byte(0x20 + rng.IntN(0x5f))
	}
	return ax25.BuildUI(call(), call(), []ax25.Address{call()}, 0xF0, info)
}

// roundTrip modulates one frame at rate, adds white Gaussian noise at snrDB
// (math.Inf for none) and reports whether the deframer recovered it exactly.
// snrDB is signal power over total noise power across the whole audio band,
// which at 48 kHz is 13 dB more Eb/N0 than the number says.
func roundTrip(rng *rand.Rand, frame []byte, rate, snrDB float64) bool {
	mod := afsk.NewModulator(rate, 0.5)
	var audio []float32
	audio = mod.Silence(audio, int(rate*0.02))
	audio = mod.Modulate(audio, afsk.NRZI(ax25.Encode(frame, 24)))
	audio = mod.Silence(audio, int(rate*0.02))
	if !math.IsInf(snrDB, 1) {
		// Signal power of a 0.5-amplitude sine is 0.125.
		sigma := math.Sqrt(0.125 / math.Pow(10, snrDB/10))
		for i := range audio {
			audio[i] += float32(sigma * rng.NormFloat64())
		}
	}
	var got [][]byte
	dem := afsk.New(rate)
	def := ax25.NewDeframer()
	dem.Feed(audio, func(bit bool, at int64) {
		def.Feed(bit, at, func(raw []byte, _ int64) {
			got = append(got, raw)
		})
	})
	for _, g := range got {
		if bytes.Equal(g, frame) {
			return true
		}
	}
	return false
}

func TestRoundTrip(t *testing.T) {
	for _, rate := range []float64{48000, 12000} {
		t.Run(fmt.Sprintf("%.0fHz", rate), func(t *testing.T) {
			rng := rand.New(rand.NewPCG(1, 2))
			ok := 0
			for i := 0; i < 100; i++ {
				if roundTrip(rng, randomFrame(rng), rate, math.Inf(1)) {
					ok++
				}
			}
			t.Logf("clean round trip at %.0f Hz: %d/100", rate, ok)
			if ok < 100 {
				t.Errorf("decoded %d/100 clean frames at %.0f Hz, want 100", ok, rate)
			}
		})
	}
}

// TestRoundTripInNoise pins the sensitivity. The gate is 0 dB rather than the
// -10 dB docs/plans/decoders.md asked for because -10 dB over the audio band
// is 3 dB of Eb/N0, and non-coherent FSK needs about 12.3 dB of it to hold a
// 500-bit frame together at all, so no demodulator could pass a -10 dB gate.
// 0 dB here is 13 dB of Eb/N0, within about 1 dB of the theoretical limit,
// and the measured curve either side of it
// is in the package doc comment.
func TestRoundTripInNoise(t *testing.T) {
	rng := rand.New(rand.NewPCG(3, 4))
	ok := 0
	for i := 0; i < 100; i++ {
		if roundTrip(rng, randomFrame(rng), 48000, 0) {
			ok++
		}
	}
	t.Logf("round trip at 48 kHz with 0 dB SNR over the audio band: %d/100", ok)
	if ok < 95 {
		t.Errorf("decoded %d/100 frames at 0 dB SNR, want at least 95", ok)
	}
}
