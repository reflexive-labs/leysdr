package main

import (
	"fmt"
	"math"
	"math/rand/v2"

	"github.com/dpup/leysdr/go/pkg/iqfile"
)

const (
	refRate    = 2_400_000.0
	noiseDBFS  = -60.0
	signalDBFS = -20.0
	// squelchRefDBFS is the reference squelch threshold the checker evaluates
	// `squelch_open` against.
	squelchRefDBFS = -40.0
)

// fixture is one catalog entry.
type fixture struct {
	name        string
	centerHz    float64
	description string
	metadata    map[string]string
	// build creates the fixture's signal sources (excluding the noise floor).
	build func(rate float64) []source
	// expect returns the assertions for a file generated at rate.
	expect func(rate float64) []iqfile.Expect
}

func f64(v float64) *float64 { return &v }
func bp(v bool) *bool        { return &v }

// inBandFloorDBFS is the expected post-filter noise power for a channel of
// bandwidth bw on a white floor of noiseDBFS spread over rate.
func inBandFloorDBFS(bw, rate float64) float64 {
	return noiseDBFS + 10*math.Log10(bw/rate)
}

func toneExpect(mode string, offset, bw, tone, minSNR float64) iqfile.Expect {
	return iqfile.Expect{
		Mode: mode, OffsetHz: offset, BandwidthHz: bw,
		Audio: &iqfile.AudioExpect{ToneHz: tone, MinSNRDB: minSNR},
		Meter: &iqfile.MeterExpect{PowerDBFSMin: f64(-30), SquelchOpen: bp(true)},
	}
}

func hz(v float64) string { return fmt.Sprintf("%.0f", v) }

var catalog = []fixture{
	{
		name: "nfm_tone", centerHz: 146_520_000,
		description: "NFM 1 kHz tone at +100 kHz, 2.5 kHz deviation, -20 dBFS over a -60 dBFS floor",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build: func(rate float64) []source {
			return []source{&fmTone{rate: rate, carrierHz: 100_000, toneHz: 1000, devHz: 2500, dbfs: signalDBFS}}
		},
		expect: func(float64) []iqfile.Expect { return []iqfile.Expect{toneExpect("NFM", 100_000, 12_500, 1000, 30)} },
	},
	{
		name: "am_tone", centerHz: 1_000_000,
		description: "AM 1 kHz tone, 80 % depth, carrier at -250 kHz, -20 dBFS over a -60 dBFS floor",
		metadata:    map[string]string{"mode": "AM", "frequency_hz": hz(750_000)},
		build: func(rate float64) []source {
			return []source{&amTone{rate: rate, carrierHz: -250_000, toneHz: 1000, depth: 0.8, dbfs: signalDBFS}}
		},
		expect: func(float64) []iqfile.Expect { return []iqfile.Expect{toneExpect("AM", -250_000, 10_000, 1000, 25)} },
	},
	{
		name: "usb_tone", centerHz: 14_200_000,
		description: "USB 1 kHz tone (carrier suppressed) at +50 kHz, -20 dBFS over a -60 dBFS floor",
		metadata:    map[string]string{"mode": "USB", "frequency_hz": hz(14_250_000)},
		build: func(rate float64) []source {
			return []source{&ssbTone{rate: rate, carrierHz: 50_000, toneHz: 1000, dbfs: signalDBFS, upper: true}}
		},
		expect: func(float64) []iqfile.Expect { return []iqfile.Expect{toneExpect("USB", 50_000, 2_800, 1000, 25)} },
	},
	{
		name: "cw", centerHz: 7_050_000,
		description: "CW keyed carrier at -40 kHz, 10 wpm \"CQ\", 5 ms raised-cosine edges, -20 dBFS over a -60 dBFS floor",
		metadata:    map[string]string{"mode": "CW", "frequency_hz": hz(7_010_000)},
		build: func(rate float64) []source {
			return []source{newCW(rate, -40_000, signalDBFS, 10, 0.005, "CQ")}
		},
		expect: func(float64) []iqfile.Expect { return []iqfile.Expect{toneExpect("CW", -40_000, 500, 700, 20)} },
	},
	{
		name: "wfm_tone", centerHz: 100_000_000,
		description: "WFM 1 kHz tone at +400 kHz, 75 kHz deviation, -20 dBFS over a -60 dBFS floor",
		metadata:    map[string]string{"mode": "WFM", "frequency_hz": hz(100_400_000)},
		build: func(rate float64) []source {
			return []source{&fmTone{rate: rate, carrierHz: 400_000, toneHz: 1000, devHz: 75_000, dbfs: signalDBFS, wide: true}}
		},
		expect: func(float64) []iqfile.Expect { return []iqfile.Expect{toneExpect("WFM", 400_000, 200_000, 1000, 30)} },
	},
	{
		name: "noise_floor", centerHz: 146_520_000,
		description: "complex white noise only, -60 dBFS",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build:       func(float64) []source { return nil },
		expect: func(rate float64) []iqfile.Expect {
			fl := inBandFloorDBFS(12_500, rate)
			return []iqfile.Expect{{
				Mode: "NFM", OffsetHz: 100_000, BandwidthHz: 12_500,
				Meter: &iqfile.MeterExpect{PowerDBFSMin: f64(fl - 1.5), PowerDBFSMax: f64(fl + 1.5), SquelchOpen: bp(false)},
			}}
		},
	},
	{
		name: "two_nfm", centerHz: 146_520_000,
		description: "two NFM tones: 1 kHz at +100 kHz and 2 kHz at -300 kHz, 2.5 kHz deviation, -20 dBFS over a -60 dBFS floor",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build: func(rate float64) []source {
			return []source{
				&fmTone{rate: rate, carrierHz: 100_000, toneHz: 1000, devHz: 2500, dbfs: signalDBFS},
				&fmTone{rate: rate, carrierHz: -300_000, toneHz: 2000, devHz: 2500, dbfs: signalDBFS},
			}
		},
		expect: func(float64) []iqfile.Expect {
			// The 2 kHz tone at 2.5 kHz deviation (β = 1.25) has Bessel sidebands
			// at ±6 kHz that sit on the 12.5 kHz channel edge; the channel filter
			// clips them, so its distortion-limited SNR is ≈ 30 dB in the
			// reference chain. Assert 20 dB to leave margin for the engine's filter.
			return []iqfile.Expect{toneExpect("NFM", 100_000, 12_500, 1000, 30), toneExpect("NFM", -300_000, 12_500, 2000, 20)}
		},
	},
}

// fits reports whether every expected channel lies inside the usable band
// (|offset| + bw/2 < 0.45·rate) at rate.
func (f *fixture) fits(rate float64) bool {
	for _, e := range f.expect(rate) {
		if math.Abs(e.OffsetHz)+e.BandwidthHz/2 >= 0.45*rate {
			return false
		}
	}
	return true
}

func newNoise(seed uint64) *gaussNoise {
	return &gaussNoise{dbfs: noiseDBFS, rng: rand.New(rand.NewPCG(seed, 0x6c65796c696e65))}
}
