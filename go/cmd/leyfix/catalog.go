// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"math"
	"math/rand/v2"
	"slices"

	"github.com/reflexive-labs/leysdr/go/pkg/dcs"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
	"github.com/reflexive-labs/leysdr/go/pkg/iqfile"
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
	// minDurationS is the shortest file the fixture's expectations hold for; a
	// packet fixture asserts a count, and a shorter file holds fewer packets.
	// 0 means any duration.
	minDurationS float64
	// fixedDurationS overrides --duration entirely: a fixture whose signal
	// follows a schedule in absolute seconds must be generated at that length.
	// 0 means --duration decides.
	fixedDurationS float64

	// set is the catalog set the fixture belongs to: "" for the fixtures `make fixtures`
	// writes, "scenes" for the site's screenshot scenes (scenes.go).
	set string
	// fixedRate overrides --rate, for a fixture whose carriers are placed for one span; 0
	// means --rate decides.
	fixedRate float64
	// format is the sample format written: cf32 when empty.
	format string
	// noiseDBFS is the floor under the signals; 0 means noiseDBFS. A cu8 fixture raises it so
	// the floor spans a few quantisation steps, as a dongle's does.
	noiseDBFS float64
	// label is the sidecar's label: the name the daemon gives the file device.
	label string
}

// rateFor is the rate the fixture is generated at when rate is asked for.
func (f *fixture) rateFor(rate float64) float64 {
	if f.fixedRate > 0 {
		return f.fixedRate
	}
	return rate
}

// noise is the fixture's floor in dBFS.
func (f *fixture) noise() float64 {
	if f.noiseDBFS != 0 {
		return f.noiseDBFS
	}
	return noiseDBFS
}

// sampleFormat is the fixture's sample format.
func (f *fixture) sampleFormat() string {
	if f.format != "" {
		return f.format
	}
	return iqfile.FormatCF32
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

// plSNRDB is the audio SNR to expect from a fixture carrying a CTCSS tone.
// It is far below the 30 dB a clean tone fixture asserts, and that is a fact
// about the signal rather than a slack expectation: a 700 Hz sub-audible
// deviation is only 11 dB under the 2.5 kHz voice deviation, the 300 Hz
// high-pass takes about 20 dB off it at 100 Hz, and de-emphasis then pulls the
// 1 kHz tone down by another 10 dB while leaving the sub-audible residue alone.
// Measured across the pl fixtures at ~11 dB. These exist to exercise the tone
// detector; nfm_tone remains the fixture that pins audio quality.
const plSNRDB = 8

func hz(v float64) string { return fmt.Sprintf("%.0f", v) }

// dcsDeviationHz is the DCS deviation a GMRS handheld was measured sending, on two recordings
// (DCS 023 and DCS 754) made on 2026-09-23.
const dcsDeviationHz = 550

// dcsFixture is the voice tone of the pl fixtures with a DCS word under it in place of the CTCSS
// tone.
func dcsFixture(rate float64, code int, inverted bool) *dcsCode {
	return &dcsCode{
		rate: rate, carrierHz: 100_000, toneHz: 1000, devHz: 2500, dbfs: signalDBFS,
		code: code, inverted: inverted, subDevHz: dcsDeviationHz,
	}
}

// dcsExpect is a DCS fixture's expectation: the voice tone at the pl fixtures' SNR, and the code a
// decoder names, octal-as-decimal as the contract carries it.
func dcsExpect(code int, inverted bool, why string) []iqfile.Expect {
	e := toneExpect("NFM", 100_000, 12_500, 1000, plSNRDB)
	e.SubAudible = &iqfile.SubExpect{
		DeviationHz: dcsDeviationHz, Detect: true,
		DCSCode: int(dcs.Wire(code)), DCSInverted: inverted, Why: why,
	}
	return []iqfile.Expect{e}
}

// The keying schedule of nfm_keyed, and the file length it needs. Absolute
// rather than proportional to --duration: the 3.0 s gaps are what make the
// fixture prove the hang rules, so the file is always generated at its own
// length however short the rest of the set is asked for.
var keyedSegments = []keySegment{{1.0, 2.0}, {5.0, 5.5}, {8.5, 10.5}}

const keyedDurationS = 10.5

// catalog is every fixture leyfix can write: the default set and the scenes.
var catalog = slices.Concat(defaultFixtures, sceneFixtures)

// defaultFixtures are the fixtures `make fixtures` writes.
var defaultFixtures = []fixture{
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
		// Three transmissions with silence between them: the fixture a gated
		// recording is graded against (docs/design/recording.md, "Testing
		// without hardware"). The gaps are 3.0 s, which is inside the default
		// 5 s hang and outside a 1 s one, so the same file proves both rules --
		// an exchange keeps its overs in one part, and a short hang cuts one
		// part per transmission.
		name: "nfm_keyed", centerHz: 146_520_000,
		description:    "NFM 1 kHz tone at +100 kHz keyed for 1.0 s, 0.5 s and 2.0 s with 3.0 s of floor between",
		metadata:       map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		fixedDurationS: keyedDurationS,
		build: func(rate float64) []source {
			return []source{&keyed{
				rate:     rate,
				segments: keyedSegments,
				inner:    &fmTone{rate: rate, carrierHz: 100_000, toneHz: 1000, devHz: 2500, dbfs: signalDBFS},
			}}
		},
		expect: func(float64) []iqfile.Expect {
			e := iqfile.Expect{Mode: "NFM", OffsetHz: 100_000, BandwidthHz: 12_500}
			segments := make([]iqfile.RecordSegment, 0, len(keyedSegments))
			for _, seg := range keyedSegments {
				segments = append(segments, iqfile.RecordSegment{StartS: seg.startS, EndS: seg.endS})
			}
			e.Record = &iqfile.RecordExpect{Gate: "squelch", SquelchDBFS: squelchRefDBFS, Segments: segments}
			return []iqfile.Expect{e}
		},
	},
	{
		// The everyday case: a repeater transmission carrying PL 100.0 under
		// the voice. 700 Hz deviation is 14% of the 5 kHz NFM full scale,
		// squarely in the range a real transmitter uses.
		name: "nfm_pl", centerHz: 146_520_000,
		description: "NFM 1 kHz tone at +100 kHz with a 100.0 Hz CTCSS tone at 700 Hz deviation",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build: func(rate float64) []source {
			return []source{&fmTone{
				rate: rate, carrierHz: 100_000, toneHz: 1000, devHz: 2500, dbfs: signalDBFS,
				subToneHz: 100.0, subDevHz: 700,
			}}
		},
		expect: func(float64) []iqfile.Expect {
			e := toneExpect("NFM", 100_000, 12_500, 1000, plSNRDB)
			e.SubAudible = &iqfile.SubExpect{ToneHz: 100.0, DeviationHz: 700, Detect: true}
			return []iqfile.Expect{e}
		},
	},
	{
		// Half of the discrimination pair. 67.0 and 69.3 are 2.3 Hz apart, the
		// tightest spacing on the EIA ladder: a detector whose resolution is a
		// bin width cannot tell them apart, and one that snaps to the nearest
		// standard tone will report the wrong one.
		name: "nfm_pl_67", centerHz: 146_520_000,
		description: "NFM voice with a 67.0 Hz CTCSS tone; the low end of the ladder, 2.3 Hz from 69.3",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build: func(rate float64) []source {
			return []source{&fmTone{
				rate: rate, carrierHz: 100_000, toneHz: 1000, devHz: 2500, dbfs: signalDBFS,
				subToneHz: 67.0, subDevHz: 700,
			}}
		},
		expect: func(float64) []iqfile.Expect {
			e := toneExpect("NFM", 100_000, 12_500, 1000, plSNRDB)
			e.SubAudible = &iqfile.SubExpect{ToneHz: 67.0, DeviationHz: 700, Detect: true}
			return []iqfile.Expect{e}
		},
	},
	{
		name: "nfm_pl_69", centerHz: 146_520_000,
		description: "NFM voice with a 69.3 Hz CTCSS tone; the other half of the 67.0/69.3 pair",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build: func(rate float64) []source {
			return []source{&fmTone{
				rate: rate, carrierHz: 100_000, toneHz: 1000, devHz: 2500, dbfs: signalDBFS,
				subToneHz: 69.3, subDevHz: 700,
			}}
		},
		expect: func(float64) []iqfile.Expect {
			e := toneExpect("NFM", 100_000, 12_500, 1000, plSNRDB)
			e.SubAudible = &iqfile.SubExpect{ToneHz: 69.3, DeviationHz: 700, Detect: true}
			return []iqfile.Expect{e}
		},
	},
	{
		// The documented false positive as a fixture. 50 Hz mains hum lands
		// on exactly 100.0 Hz at its second harmonic, is perfectly stable, and
		// passes every frequency test a detector can apply. Only its deviation
		// distinguishes it: hum is tens of Hz where PL is hundreds.
		name: "nfm_hum", centerHz: 146_520_000,
		description: "NFM voice with 100.0 Hz mains hum at 40 Hz deviation and no CTCSS: the false positive to reject",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build: func(rate float64) []source {
			return []source{&fmTone{
				rate: rate, carrierHz: 100_000, toneHz: 1000, devHz: 2500, dbfs: signalDBFS,
				subToneHz: 100.0, subDevHz: 40,
			}}
		},
		expect: func(float64) []iqfile.Expect {
			// Hum at 40 Hz deviation barely touches the audio, so this one
			// keeps the full SNR bar.
			e := toneExpect("NFM", 100_000, 12_500, 1000, 25)
			e.SubAudible = &iqfile.SubExpect{
				ToneHz: 100.0, DeviationHz: 40, Detect: false,
				Why: "40 Hz deviation is mains hum, not CTCSS; a transmitter sends 200-1200 Hz",
			}
			return []iqfile.Expect{e}
		},
	},
	{
		// A keyed carrier with PL and no speech: the start of every
		// transmission, and the case where a detector has the least to
		// distinguish a tone from.
		name: "nfm_pl_only", centerHz: 146_520_000,
		description: "NFM carrier with a 123.0 Hz CTCSS tone and no voice",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build: func(rate float64) []source {
			return []source{&fmTone{
				rate: rate, carrierHz: 100_000, toneHz: 0, devHz: 0, dbfs: signalDBFS,
				subToneHz: 123.0, subDevHz: 700,
			}}
		},
		expect: func(float64) []iqfile.Expect {
			return []iqfile.Expect{{
				Mode: "NFM", OffsetHz: 100_000, BandwidthHz: 12_500,
				Meter:      &iqfile.MeterExpect{PowerDBFSMin: f64(-30), SquelchOpen: bp(true)},
				SubAudible: &iqfile.SubExpect{ToneHz: 123.0, DeviationHz: 700, Detect: true},
			}}
		},
	},
	{
		// DCS 023, the first code on every radio's list, at the ±550 Hz a GMRS handheld was
		// measured sending (dcsDeviationHz). No CTCSS rides with it: a DCS lock suppresses
		// the CTCSS claim, so tone_hz is 0 and detect is true for the code.
		name: "nfm_dcs", centerHz: 146_520_000,
		description: "NFM 1 kHz tone at +100 kHz with DCS 023 normal at 550 Hz deviation",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build: func(rate float64) []source {
			return []source{dcsFixture(rate, 0o23, false)}
		},
		expect: func(float64) []iqfile.Expect { return dcsExpect(0o23, false, "") },
	},
	{
		// DCS 023 sent inverted. Every standard code's complemented word reads as exactly one
		// other standard code, and 023 inverted is the bit stream of 047 normal, so a decoder
		// that prefers the received polarity names 047 (go/pkg/dcs, Decode). The expectation is
		// what that rule reads, and why says what was sent.
		name: "nfm_dcs_inverted", centerHz: 146_520_000,
		description: "NFM 1 kHz tone at +100 kHz with DCS 023 inverted at 550 Hz deviation",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build: func(rate float64) []source {
			return []source{dcsFixture(rate, 0o23, true)}
		},
		expect: func(float64) []iqfile.Expect {
			return dcsExpect(0o47, false, "sent as 023 inverted, which is the bit stream of 047 normal; the decoder prefers the received polarity")
		},
	},
	{
		// DCS 754, the second recorded code: its word also reads 076 and 203 with the fixed
		// bits in place, so only the standard list names it.
		name: "nfm_dcs_754", centerHz: 146_520_000,
		description: "NFM 1 kHz tone at +100 kHz with DCS 754 normal at 550 Hz deviation; the word also reads 076 and 203",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(146_620_000)},
		build: func(rate float64) []source {
			return []source{dcsFixture(rate, 0o754, false)}
		},
		expect: func(float64) []iqfile.Expect { return dcsExpect(0o754, false, "") },
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
		// The decoder fixture. It sits on 144.39 MHz with the carrier at the
		// capture's centre so `ley decode aprs` with no arguments finds the
		// capture `ley play` makes for it; a file device has no DC spike to
		// stay clear of, which is the only reason the other fixtures offset
		// theirs.
		name: "aprs_afsk", centerHz: 144_390_000,
		description: "three APRS packets as NFM AFSK 1200 at the centre frequency, 3.5 kHz deviation, -20 dBFS",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(144_390_000)},
		build: func(rate float64) []source {
			return []source{aprsSource(rate)}
		},
		expect: func(rate float64) []iqfile.Expect {
			return []iqfile.Expect{{
				Mode: "NFM", OffsetHz: 0, BandwidthHz: 15_000,
				Meter: &iqfile.MeterExpect{PowerDBFSMin: f64(-30), SquelchOpen: bp(true)},
				Decode: &iqfile.DecodeExpect{
					Protocol: "aprs", Records: 3, DeviceIDs: aprsSource(rate).deviceIDs(),
				},
			}}
		},
		// The three frames are 0.93 s of signal at 1200 baud, so the pattern is
		// a second long and a shorter file would hold fewer than three records.
		minDurationS: 1,
	},
	{
		// The SAME decoder fixture. A Required Weekly Test on the 162.400 MHz
		// NWR channel, carrier at the capture centre so `ley decode same` with
		// no arguments finds the capture `ley play` makes for it. It carries a
		// single header copy: three copies at 520.83 baud run past four seconds
		// and one is all the decoder needs, so the file states records: 1.
		name: "same_alert", centerHz: 162_400_000,
		description: "a SAME Required Weekly Test as NFM AFSK at 520.83 baud at the centre frequency, 3.5 kHz deviation, -20 dBFS",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(162_400_000)},
		build: func(rate float64) []source {
			return []source{sameSource(rate)}
		},
		expect: func(rate float64) []iqfile.Expect {
			return []iqfile.Expect{{
				Mode: "NFM", OffsetHz: 0, BandwidthHz: 15_000,
				Meter: &iqfile.MeterExpect{PowerDBFSMin: f64(-30), SquelchOpen: bp(true)},
				Decode: &iqfile.DecodeExpect{
					Protocol: "same", Records: 1, DeviceIDs: sameSource(rate).deviceIDs(),
				},
			}}
		},
		// One header copy is about one second of AFSK; a shorter file would
		// clip it. 1.5 s leaves room and lets a --duration 0.5 run skip it.
		minDurationS: 1.5,
	},
	{
		// The AIS decoder fixture. Two Type 1 position reports as NFM GMSK 9600
		// on AIS 1 (161.975 MHz), carrier at the capture centre so `ley decode
		// ais` with no arguments finds the capture `ley play` makes for it, the
		// same placement aprs_afsk and same_alert use.
		name: "ais_burst", centerHz: 161_975_000,
		description: "two AIS Type 1 position reports as NFM GMSK 9600 at the centre frequency, 2.4 kHz deviation, -20 dBFS",
		metadata:    map[string]string{"mode": "NFM", "frequency_hz": hz(161_975_000)},
		build: func(rate float64) []source {
			return []source{aisSource(rate)}
		},
		expect: func(rate float64) []iqfile.Expect {
			return []iqfile.Expect{{
				Mode: "NFM", OffsetHz: 0, BandwidthHz: 25_000,
				Meter: &iqfile.MeterExpect{PowerDBFSMin: f64(-30), SquelchOpen: bp(true)},
				Decode: &iqfile.DecodeExpect{
					Protocol: "ais", Records: 2, DeviceIDs: aisSource(rate).deviceIDs(),
				},
			}}
		},
		// The two bursts are a few tens of ms of a one-second pattern, but the
		// pattern is a second long; 1 s holds each report once and lets a
		// --duration 0.5 run skip it.
		minDurationS: 1,
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
	{
		name: "scan_band", centerHz: 146_000_000,
		description: "four carriers for the sweep detector: NFM at -800/-400 kHz, AM at +400 kHz and a wide FM at +800 kHz, " +
			"from -20 to -44 dBFS over a -60 dBFS floor, all outside the sweep's 5% DC guard",
		metadata: map[string]string{"mode": "NFM", "frequency_hz": hz(145_600_000)},
		build: func(rate float64) []source {
			// Placed clear of the DC guard (5% of span either side of centre) and clear of the
			// 45% analysis edge, so a single-step sweep over this file sees all four. The levels
			// walk down 8 dB at a time so the weakest is near the detector's sensitivity and the
			// strongest is loud enough to plant an IQ image on a real radio.
			return []source{
				&fmTone{rate: rate, carrierHz: -800_000, toneHz: 1000, devHz: 2500, dbfs: signalDBFS},
				&fmTone{rate: rate, carrierHz: -400_000, toneHz: 1500, devHz: 2500, dbfs: signalDBFS - 8},
				&amTone{rate: rate, carrierHz: 400_000, toneHz: 1000, depth: 0.8, dbfs: signalDBFS - 16},
				&fmTone{rate: rate, carrierHz: 800_000, toneHz: 400, devHz: 75_000, dbfs: signalDBFS - 24},
			}
		},
		// No per-channel expectations: this fixture exists for the spectrum, not for a demod, and
		// the sidecar has no vocabulary for expected detections. The carriers are documented above
		// and asserted by the detector's own tests.
		expect: func(float64) []iqfile.Expect { return nil },
	},
}

// fits reports whether the fixture lies inside the usable band
// (|offset| + bw/2 < 0.45·rate) at rate. Both the expected channels and the
// generated signals are measured: a fixture that declares no expectations —
// one that exists for the spectrum rather than for a demod — is still refused
// at a rate its carriers would alias in.
func (f *fixture) fits(rate float64) bool {
	edge := 0.45 * rate
	for _, e := range f.expect(rate) {
		if math.Abs(e.OffsetHz)+e.BandwidthHz/2 >= edge {
			return false
		}
	}
	for _, s := range f.build(rate) {
		offset, bw := s.span()
		if math.Abs(offset)+bw/2 >= edge {
			return false
		}
	}
	return true
}

// aprsSource builds the aprs_afsk fixture's transmitter. The three frames are
// a position, a weather report and a status, from three stations, which is the
// set the sidecar expects.
func aprsSource(rate float64) *afskPacket {
	return &afskPacket{
		rate: rate, carrierHz: 0, devHz: 3500, dbfs: signalDBFS,
		preambleFlags: 8,
		packets: []packet{
			{source: ax25.Address{Call: "LEYTST", SSID: 1}, dest: "APZLEY", info: "!3745.60N/12225.00W>test position"},
			{source: ax25.Address{Call: "LEYTST", SSID: 2}, dest: "APZLEY", info: "_09121200c220s004t077"},
			{source: ax25.Address{Call: "LEYTST", SSID: 3}, dest: "APZLEY", info: ">test status"},
		},
	}
}

// newNoise is the seeded floor at noiseDBFS.
func newNoise(seed uint64) *gaussNoise { return newNoiseAt(seed, noiseDBFS) }

// newNoiseAt is the seeded floor at dbfs.
func newNoiseAt(seed uint64, dbfs float64) *gaussNoise {
	return &gaussNoise{dbfs: dbfs, rng: rand.New(rand.NewPCG(seed, 0x6c65796c696e65))}
}
