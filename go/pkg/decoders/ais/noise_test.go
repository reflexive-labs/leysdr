// SPDX-License-Identifier: Apache-2.0

package ais

import (
	"math"
	"math/rand/v2"
	"testing"
)

// sigPowerAndNoise returns the mean-square power of a burst and the noise
// standard deviation that would place it snrDB below the signal.
func noiseSigma(audio []float32, snrDB float64) float64 {
	var p float64
	for _, s := range audio {
		p += float64(s) * float64(s)
	}
	p /= float64(len(audio))
	return math.Sqrt(p / math.Pow(10, snrDB/10))
}

// TestRoundTripNoise sweeps additive white Gaussian noise on the discriminator
// output and reports how many of 100 bursts survive at each SNR, the numbers
// the package doc comment quotes. The hard assertion is loose -- most of a
// batch at a comfortable SNR -- so a demodulator regression is caught without
// the test flaking on the tail of the distribution.
func TestRoundTripNoise(t *testing.T) {
	for _, snr := range []float64{14, 12, 10, 8, 6} {
		rng := rand.New(rand.NewPCG(uint64(snr), 7))
		ok := 0
		for i := 0; i < 100; i++ {
			mmsi := uint32(200_000_000 + rng.IntN(700_000_000))
			lat := rng.Float64()*180 - 90
			lon := rng.Float64()*360 - 180
			audio := modulate(buildType1(mmsi, lat, lon, 0, 0))
			sigma := noiseSigma(audio, snr)
			for j := range audio {
				audio[j] += float32(rng.NormFloat64() * sigma)
			}
			if m := demod(audio); m != nil && m.MMSI == mmsi && m.HasPos &&
				math.Abs(m.Lat-lat) < 0.0001 && math.Abs(m.Lon-lon) < 0.0001 {
				ok++
			}
		}
		t.Logf("SNR %4.1f dB: %3d/100", snr, ok)
		if snr == 14 && ok < 90 {
			t.Errorf("at 14 dB SNR only %d/100 survived; the chain has regressed", ok)
		}
	}
}
