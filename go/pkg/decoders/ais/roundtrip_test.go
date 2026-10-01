// SPDX-License-Identifier: Apache-2.0

package ais

import (
	"math"
	"math/rand/v2"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/afsk"
)

// bitWriter packs fields MSB first into an AIS payload, the mirror of bits.go's
// reader, so the round-trip test can build a message to transmit.
type bitWriter struct {
	bits []bool
}

func (w *bitWriter) put(v uint64, width int) {
	for k := width - 1; k >= 0; k-- {
		w.bits = append(w.bits, v>>uint(k)&1 != 0)
	}
}

func (w *bitWriter) puti(v int64, width int) {
	w.put(uint64(v)&(1<<uint(width)-1), width)
}

func (w *bitWriter) bytes() []byte {
	out := make([]byte, (len(w.bits)+7)/8)
	for i, b := range w.bits {
		if b {
			out[i/8] |= 1 << (7 - uint(i%8))
		}
	}
	return out
}

// buildType1 packs a 168-bit Type 1 position report.
func buildType1(mmsi uint32, latDeg, lonDeg, sogKn, cogDeg float64) []byte {
	var w bitWriter
	w.put(1, 6)                                  // message type
	w.put(0, 2)                                  // repeat indicator
	w.put(uint64(mmsi), 30)                      // MMSI
	w.put(0, 4)                                  // nav status (under way)
	w.puti(128, 8)                               // rate of turn: not available
	w.put(uint64(math.Round(sogKn*10)), 10)      // SOG
	w.put(0, 1)                                  // position accuracy
	w.puti(int64(math.Round(lonDeg*600000)), 28) // longitude
	w.puti(int64(math.Round(latDeg*600000)), 27) // latitude
	w.put(uint64(math.Round(cogDeg*10)), 12)     // COG
	w.put(511, 9)                                // true heading: not available
	w.put(0, 6)                                  // timestamp
	w.put(0, 2)                                  // maneuver
	w.put(0, 3)                                  // spare
	w.put(0, 1)                                  // RAIM
	w.put(0, 19)                                 // radio status
	return w.bytes()
}

// demod runs one modulated burst back through the receive chain and returns the
// first message it recovers, or nil.
func demod(audio []float32) *Message {
	var got *Message
	def := NewDeframer()
	New(48000).Feed(audio, func(bit bool, at int64) {
		def.Feed(bit, at, func(raw []byte, _ int64) {
			if m, err := Parse(raw); err == nil && got == nil {
				got = m
			}
		})
	})
	return got
}

// modulate builds the discriminator-output audio for one AIS message: leading
// silence, the training sequence and framed burst, trailing silence.
func modulate(payload []byte) []float32 {
	mod := NewModulator(48000, 0.9)
	audio := make([]float32, 480) // 10 ms of quiet to settle the DC tracker
	audio = mod.Modulate(audio, afsk.NRZI(EncodeFrame(payload, 1)))
	return append(audio, make([]float32, 240)...)
}

// TestRoundTripClean modulates 100 random position reports and demodulates each
// at 48 kHz with no noise: every one must come back with its MMSI and fix
// intact.
func TestRoundTripClean(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2))
	ok := 0
	for i := 0; i < 100; i++ {
		mmsi := uint32(200_000_000 + rng.IntN(700_000_000))
		lat := rng.Float64()*180 - 90
		lon := rng.Float64()*360 - 180
		sog := float64(rng.IntN(300)) / 10
		cog := float64(rng.IntN(3600)) / 10
		m := demod(modulate(buildType1(mmsi, lat, lon, sog, cog)))
		if m == nil || m.MMSI != mmsi || !m.HasPos ||
			math.Abs(m.Lat-lat) > 0.0001 || math.Abs(m.Lon-lon) > 0.0001 {
			t.Errorf("trip %d: sent mmsi=%d lat=%.4f lon=%.4f, got %+v", i, mmsi, lat, lon, m)
			continue
		}
		ok++
	}
	if ok != 100 {
		t.Errorf("clean round trip recovered %d/100", ok)
	}
}
