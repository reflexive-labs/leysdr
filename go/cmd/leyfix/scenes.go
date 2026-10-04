// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"math"
	"strings"

	"github.com/reflexive-labs/leysdr/go/pkg/dcs"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
	"github.com/reflexive-labs/leysdr/go/pkg/iqfile"
)

// The scenes set: the fixtures the site's screenshots play (docs/plans/site-shots.md, "Scene
// fixtures"). `leyfix generate --set scenes` writes them and `make fixtures` does not, because
// they are long and wide. Each is cu8 at a fixed rate and length, sized to stay under 300 MB, with
// the floor at sceneNoiseDBFS so it spans a few quantisation steps of the 8-bit samples. Every
// callsign is N0CALL-n and every MMSI is made up.
const (
	sceneSet       = "scenes"
	sceneNoiseDBFS = -40.0
	// sceneDevHz is the voice's peak deviation: the limiter keeps the audio inside ±1.
	sceneDevHz = 3000
	// sceneSubDevHz is the CTCSS deviation the pl fixtures use.
	sceneSubDevHz = 700
)

// sceneCarrier is one station in a scene: a voice on a carrier at an offset from the scene's
// centre, with a CTCSS tone or a DCS code or neither, keyed in segs (always on when segs is nil).
type sceneCarrier struct {
	offsetHz, dbfs float64
	// voiceSeed seeds the voice, or the symbols when fsk is set.
	voiceSeed uint64
	toneHz    float64
	dcsCode   int // octal; 0 for none
	segs      []keySegment
	// pulse, when set, keys the carrier for pulse[1] s at the start of every pulse[0] s.
	pulse [2]float64
	// devHz is the voice's peak deviation; 0 is sceneDevHz.
	devHz float64
	// splatterHz, when set, puts a splatter skirt of that half-width splatterDB under the carrier
	// around it while it is keyed.
	splatterHz, splatterDB float64
	// tailS, when set, makes the station a repeater: after each over in segs the carrier stays up
	// for tailS with a courtesy beep in it.
	tailS float64
	// fsk makes the carrier a four-level FSK burst in place of a voice.
	fsk bool
}

// The courtesy beep in a repeater's tail: 1 kHz for 150 ms, starting 0.6 s after the over, at
// half the voice's deviation.
const (
	sceneBeepHz    = 1000
	sceneBeepAtS   = 0.6
	sceneBeepS     = 0.15
	sceneBeepLevel = 0.5
)

func (c sceneCarrier) dev() float64 {
	if c.devHz != 0 {
		return c.devHz
	}
	return sceneDevHz
}

// keying is when the carrier is up: segs, each with its tail when the station is a repeater.
func (c sceneCarrier) keying() []keySegment {
	if c.tailS > 0 {
		return withTails(c.segs, c.tailS)
	}
	return c.segs
}

func (c sceneCarrier) source(rate float64) source {
	var s source
	if c.fsk {
		s = &fsk4{rate: rate, carrierHz: c.offsetHz, dbfs: c.dbfs, seed: c.voiceSeed}
	} else {
		v := &fmVoice{
			rate: rate, carrierHz: c.offsetHz, devHz: c.dev(), dbfs: c.dbfs, voiceSeed: c.voiceSeed,
			subToneHz: c.toneHz,
		}
		switch {
		case c.dcsCode != 0:
			v.dcsCode, v.dcsSet, v.subDevHz = c.dcsCode, true, dcsDeviationHz
		case c.toneHz != 0:
			v.subDevHz = sceneSubDevHz
		}
		if c.tailS > 0 {
			v.tail = &courtesyTail{
				rate: rate, overs: c.segs, tailS: c.tailS, beepAtS: sceneBeepAtS, beepS: sceneBeepS,
				beepHz: sceneBeepHz, beepLevel: sceneBeepLevel,
			}
		}
		s = v
	}
	if c.splatterHz > 0 {
		s = &splatter{
			inner: s, rate: rate, offsetHz: c.offsetHz, widthHz: c.splatterHz,
			carrierDBFS: c.dbfs, dbc: c.splatterDB, seed: c.voiceSeed,
		}
	}
	switch {
	case c.segs != nil:
		return &keyed{rate: rate, segments: c.keying(), inner: s}
	case c.pulse[0] > 0:
		return &pulsed{rate: rate, periodS: c.pulse[0], widthS: c.pulse[1], inner: s}
	}
	return s
}

// expect is the carrier's expect entry: the channel, the keying as a record expectation when it
// is keyed in overs, the sub-audible signalling it carries, and a meter reading when withMeter.
// A wide-deviation voice gets a 25 kHz channel, the width a radio set to wide FM uses.
func (c sceneCarrier) expect(withMeter bool) iqfile.Expect {
	bw := 12_500.0
	if c.dev() > sceneDevHz {
		bw = 25_000
	}
	e := iqfile.Expect{Mode: "NFM", OffsetHz: c.offsetHz, BandwidthHz: bw}
	if withMeter {
		// -30 dBFS is the default fixtures' bar; a weaker carrier is held 5 dB under its own level.
		e.Meter = &iqfile.MeterExpect{PowerDBFSMin: f64(math.Min(-30, c.dbfs-5)), SquelchOpen: bp(true)}
	}
	if c.segs != nil {
		keying := c.keying()
		segments := make([]iqfile.RecordSegment, 0, len(keying))
		for _, s := range keying {
			segments = append(segments, iqfile.RecordSegment{StartS: s.startS, EndS: s.endS})
		}
		e.Record = &iqfile.RecordExpect{Gate: "squelch", SquelchDBFS: squelchRefDBFS, Segments: segments}
	}
	switch {
	case c.dcsCode != 0:
		e.SubAudible = &iqfile.SubExpect{DeviationHz: dcsDeviationHz, Detect: true, DCSCode: int(dcs.Wire(c.dcsCode))}
	case c.toneHz != 0:
		e.SubAudible = &iqfile.SubExpect{ToneHz: c.toneHz, DeviationHz: sceneSubDevHz, Detect: true}
	}
	return e
}

func sources(rate float64, cs []sceneCarrier) []source {
	out := make([]source, 0, len(cs))
	for _, c := range cs {
		out = append(out, c.source(rate))
	}
	return out
}

// The scene_2m stations, around a centre of 146.400 MHz. 2.88 MSPS puts 145.230 and 147.330
// inside the 45% analysis edge, which 2.4 MSPS does not. Fifty seconds at 2 bytes a sample is
// 288 MB, and every carrier keys at least three times in it. The site's hero shot zooms the
// waterfall to 4x around 146.520, about 146.16 to 146.88 MHz, so 146.430 to 146.640 are packed
// with the traffic a busy simplex and repeater cluster carries.
const (
	scene2mCenterHz  = 146_400_000
	scene2mRate      = 2_880_000
	scene2mDurationS = 50
)

// 146.550's splatter skirt, and the repeater's tail. Through the checker's 12.5 kHz channel on
// 146.520, 30 kHz away, the skirt sits about 60 dB under the hero.
const (
	scene2mSplatterHz = 15_000
	scene2mSplatterDB = 37
	scene2mTailS      = 1.5
)

func scene2mCarriers() []sceneCarrier {
	end := scene2mDurationS - 1.0
	return []sceneCarrier{
		// 146.520 simplex, PL 100.0: the hero, and the first expect entry, so ley play tunes it.
		{offsetHz: 120_000, dbfs: -12, voiceSeed: 21, toneHz: 100.0, segs: overs(1, 0.6, end, 6, 9, 2.5, 4)},
		// 146.940 repeater output, PL 127.3.
		{offsetHz: 540_000, dbfs: -20, voiceSeed: 22, toneHz: 127.3, segs: overs(2, 2.0, end, 5, 10, 3, 6)},
		// 147.180 net, DCS 023.
		{offsetHz: 780_000, dbfs: -24, voiceSeed: 23, dcsCode: 0o23, segs: overs(3, 1.2, end, 4, 9, 3, 6)},
		// 145.230 and 147.330: short keyups.
		{offsetHz: -1_170_000, dbfs: -28, voiceSeed: 24, segs: overs(4, 3.0, end, 1, 2.5, 7, 12)},
		{offsetHz: 930_000, dbfs: -30, voiceSeed: 25, segs: overs(5, 6.0, end, 1, 2, 8, 13)},
		// 146.430: a weak simplex station in short overs.
		{offsetHz: 30_000, dbfs: -34, voiceSeed: 26, segs: overs(7, 4.0, end, 1.5, 3.5, 5, 10)},
		// 146.460 simplex, no tone.
		{offsetHz: 60_000, dbfs: -24, voiceSeed: 27, segs: overs(8, 1.5, end, 3, 7, 4, 9)},
		// 146.550: a strong handheld on wide deviation, splattering. Its overs overlap the
		// hero's in part, so both show at once.
		{
			offsetHz: 150_000, dbfs: -10, voiceSeed: 28, devHz: 5000,
			splatterHz: scene2mSplatterHz, splatterDB: scene2mSplatterDB,
			segs: overs(6, 2.0, end, 4, 8, 3, 7),
		},
		// 146.580: digital voice bursts.
		{offsetHz: 180_000, dbfs: -20, voiceSeed: 29, fsk: true, segs: overs(9, 5.0, end, 3, 8, 3, 8)},
		// 146.640 repeater output, PL 146.2, with a courtesy tail after each over.
		{
			offsetHz: 240_000, dbfs: -18, voiceSeed: 30, toneHz: 146.2, tailS: scene2mTailS,
			segs: overs(10, 0.8, end-scene2mTailS, 4, 9, 4, 8),
		},
	}
}

// The scene_net schedule: eight overs of 4 to 30 s with 6 to 8 s between them, so a gated
// recording with the default 5 s hang cuts one part per over. The 3 s before the first and 4 s
// after the last make the gap at the loop's join 7 s as well.
var sceneNetOvers = []keySegment{
	{3, 15}, {22, 26}, {32, 54}, {62, 70}, {76.5, 106.5}, {114, 120}, {126, 142}, {149, 159},
}

const sceneNetDurationS = 163

func sceneNetCarrier() sceneCarrier {
	return sceneCarrier{offsetHz: 0, dbfs: -18, voiceSeed: 31, dcsCode: 0o23, segs: sceneNetOvers}
}

// The scene_scan stations, around 146.000 MHz at 5 MSPS: one file wide enough for `ley scan
// 144M..148M` to sweep in a single step, because a file device cannot be retuned. The step's
// windows reach 2.25 MHz either side of the centre and its DC guard is 250 kHz, so every carrier
// is placed outside 145.750 to 146.250. Twenty seconds is 200 MB.
const (
	sceneScanCenterHz  = 146_000_000
	sceneScanRate      = 5_000_000
	sceneScanDurationS = 20
)

func sceneScanCarriers() []sceneCarrier {
	return []sceneCarrier{
		{offsetHz: 520_000, dbfs: -18, voiceSeed: 41, toneHz: 100.0},
		{offsetHz: 940_000, dbfs: -22, voiceSeed: 42, toneHz: 127.3},
		{offsetHz: 1_180_000, dbfs: -26, voiceSeed: 43, dcsCode: 0o23},
		{offsetHz: -770_000, dbfs: -30, voiceSeed: 44},
		// 144.390: 25 ms in every 210 ms. A sweep's spectrum rows at 5 MSPS are 16 blocks of
		// 16384 samples, 52 ms, so the burst fills part of about one row per default dwell.
		{offsetHz: -1_610_000, dbfs: -20, voiceSeed: 45, pulse: [2]float64{0.210, 0.015}},
	}
}

// aprsStation is one station in scene_aprs.
type aprsStation struct {
	ssid int
	info string
}

// sceneAPRSStations are seven stations around San Francisco Bay, each a position report with a
// symbol and a comment. The positions are made up.
var sceneAPRSStations = []aprsStation{
	{1, "!3745.60N/12225.00W>mobile, monitoring 146.520"},
	{2, "!3748.12N/12227.45W-home station"},
	{3, "!3752.30N/12215.80W#fill-in digipeater"},
	{4, "!3741.10N/12232.20W_090/005g010t062"},
	{5, "!3739.90N/12208.40W[on the ridge trail"},
	{6, "!3755.00N/12219.70Wb cycling the bay"},
	{7, "!3744.80N/12223.10Wk event support"},
}

// aprsStationsSource is a transmitter sending the stations once per periodS.
func aprsStationsSource(rate, periodS float64, stations []aprsStation) *afskPacket {
	pkts := make([]packet, 0, len(stations))
	for _, s := range stations {
		pkts = append(pkts, packet{source: ax25.Address{Call: "N0CALL", SSID: s.ssid}, dest: "APZLEY", info: s.info})
	}
	return &afskPacket{
		rate: rate, carrierHz: 0, devHz: 3500, dbfs: signalDBFS,
		preambleFlags: 8, packets: pkts, periodS: periodS,
	}
}

const (
	sceneAPRSRate      = 960_000
	sceneAPRSDurationS = 21
	sceneAISRate       = 960_000
	sceneAISDurationS  = 20
)

// sceneAISVessels are the scene_ais reports, all on AIS 1 (161.975 MHz): a decode job listens on
// its recipe's first frequency only, so a report on AIS 2 would never be heard.
var sceneAISVessels = []aisReport{
	{mmsi: 366999101, lat: 37.8105, lon: -122.3820, sogKn: 12.4, cogDeg: 254.0},
	{mmsi: 366999102, lat: 37.7952, lon: -122.3601, sogKn: 0.1, cogDeg: 0},
	{mmsi: 538999103, lat: 37.8263, lon: -122.4237, sogKn: 8.7, cogDeg: 71.5},
	{mmsi: 366999104, lat: 37.7718, lon: -122.3874, sogKn: 5.2, cogDeg: 182.3},
	{mmsi: 477999105, lat: 37.8441, lon: -122.4672, sogKn: 14.9, cogDeg: 300.8},
}

// sceneAISSource sends the vessels' reports once per periodS, 25 kHz below the 162.000 MHz
// centre.
func sceneAISSource(rate, periodS float64) *aisPacket {
	return &aisPacket{
		rate: rate, carrierHz: -25_000, devHz: 2400, dbfs: signalDBFS,
		preambleFlags: 1, reports: sceneAISVessels, periodS: periodS,
	}
}

// sceneRadio is the name every scene's file device shows in place of its filename: the radio
// the site's screenshots name in the toolbar and the Library.
const sceneRadio = "NESDR SMArt v5"

func sceneMetadata(hz float64) map[string]string {
	return map[string]string{"mode": "NFM", "frequency_hz": fmt.Sprintf("%.0f", hz)}
}

var sceneFixtures = []fixture{
	{
		name: "scene_2m", centerHz: scene2mCenterHz, set: sceneSet, format: iqfile.FormatCU8,
		fixedRate: scene2mRate, fixedDurationS: scene2mDurationS, noiseDBFS: sceneNoiseDBFS,
		label:       sceneRadio,
		description: "the 2 m band in overs: 146.520 PL 100.0 among 146.430, 146.460, a splattering wide-deviation 146.550, digital voice bursts on 146.580 and a 146.640 repeater with PL 146.2 and a courtesy tail; 146.940 PL 127.3, 147.180 DCS 023, short keyups on 145.230 and 147.330; speech-shaped voice",
		metadata:    sceneMetadata(146_520_000),
		build:       func(rate float64) []source { return sources(rate, scene2mCarriers()) },
		expect: func(float64) []iqfile.Expect {
			var out []iqfile.Expect
			for i, c := range scene2mCarriers() {
				out = append(out, c.expect(i == 0))
			}
			return out
		},
	},
	{
		name: "scene_net", centerHz: 147_180_000, set: sceneSet, format: iqfile.FormatCU8,
		fixedRate: 480_000, fixedDurationS: sceneNetDurationS, noiseDBFS: sceneNoiseDBFS,
		label:       sceneRadio,
		description: "a net on 147.180 DCS 023: eight overs of 4 to 30 s with 6 to 8 s between them; speech-shaped voice",
		metadata:    sceneMetadata(147_180_000),
		build:       func(rate float64) []source { return []source{sceneNetCarrier().source(rate)} },
		expect: func(float64) []iqfile.Expect {
			return []iqfile.Expect{sceneNetCarrier().expect(true)}
		},
	},
	{
		name: "scene_scan", centerHz: sceneScanCenterHz, set: sceneSet, format: iqfile.FormatCU8,
		fixedRate: sceneScanRate, fixedDurationS: sceneScanDurationS, noiseDBFS: sceneNoiseDBFS,
		label:       sceneRadio,
		description: "five carriers for ley scan 144M..148M in one step: 146.520, 146.940, 147.180 and 145.230 on the air throughout, 144.390 keyed for 15 ms in every 210 ms",
		metadata:    sceneMetadata(146_520_000),
		build:       func(rate float64) []source { return sources(rate, sceneScanCarriers()) },
		expect: func(float64) []iqfile.Expect {
			var out []iqfile.Expect
			for _, c := range sceneScanCarriers() {
				if c.pulse[0] > 0 {
					// Its mean power is the burst's 7% duty cycle, so a meter reading of it
					// says nothing; the scan's SEEN column is what the scene shows.
					continue
				}
				out = append(out, c.expect(true))
			}
			return out
		},
	},
	{
		name: "scene_aprs", centerHz: 144_390_000, set: sceneSet, format: iqfile.FormatCU8,
		fixedRate: sceneAPRSRate, fixedDurationS: sceneAPRSDurationS, noiseDBFS: sceneNoiseDBFS,
		label:       sceneRadio,
		description: "APRS on 144.390: position reports from N0CALL-1 to N0CALL-7, one every 3 s",
		metadata:    sceneMetadata(144_390_000),
		build: func(rate float64) []source {
			return []source{aprsStationsSource(rate, sceneAPRSDurationS, sceneAPRSStations)}
		},
		expect: func(rate float64) []iqfile.Expect {
			return []iqfile.Expect{{
				Mode: "NFM", OffsetHz: 0, BandwidthHz: 15_000,
				Meter: &iqfile.MeterExpect{PowerDBFSMin: f64(-30), SquelchOpen: bp(true)},
				Decode: &iqfile.DecodeExpect{
					Protocol: "aprs", Records: len(sceneAPRSStations),
					DeviceIDs: aprsStationsSource(rate, sceneAPRSDurationS, sceneAPRSStations).deviceIDs(),
				},
			}}
		},
	},
	{
		name: "scene_ais", centerHz: 162_000_000, set: sceneSet, format: iqfile.FormatCU8,
		fixedRate: sceneAISRate, fixedDurationS: sceneAISDurationS, noiseDBFS: sceneNoiseDBFS,
		label:       sceneRadio,
		description: "AIS on 161.975: Type 1 position reports from five vessels with made-up MMSIs, spread over the 20 s loop",
		metadata:    sceneMetadata(161_975_000),
		build: func(rate float64) []source {
			return []source{sceneAISSource(rate, sceneAISDurationS)}
		},
		expect: func(rate float64) []iqfile.Expect {
			p := sceneAISSource(rate, sceneAISDurationS)
			return []iqfile.Expect{{
				Mode: "NFM", OffsetHz: p.carrierHz, BandwidthHz: 25_000,
				Meter:  &iqfile.MeterExpect{PowerDBFSMin: f64(-30), SquelchOpen: bp(true)},
				Decode: &iqfile.DecodeExpect{Protocol: "ais", Records: len(p.reports), DeviceIDs: p.deviceIDs()},
			}}
		},
	},
}

// sceneNames lists the scenes set, for usage text.
func sceneNames() string {
	var names []string
	for _, f := range sceneFixtures {
		names = append(names, f.name)
	}
	return strings.Join(names, ", ")
}
