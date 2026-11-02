// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/modes"
	"github.com/reflexive-labs/leysdr/go/pkg/iqfile"
)

// adsbTraffic is aircraft on straight tracks sending Mode S replies and ADS-B squitters at
// 1090 MHz, the capture's centre: pulse-position modulated pulses at 1 µs a bit, each aircraft
// on its own carrier offset within a transponder's ±1 MHz tolerance. The replies and their
// timing come from pkg/decoders/modes (Schedule), so the fixture and the decoder share one
// definition of every format. The schedule covers durationS; a file played in a loop repeats it.
type adsbTraffic struct {
	rate, dbfs float64
	durationS  float64
	flights    []modes.Flight

	tx  []modes.Transmission
	env []float64
}

// adsbCarrierHz is flight k's carrier offset from 1090 MHz: -60 kHz to +60 kHz, so a reply's
// 2 MHz stays inside a 2.4 MSPS capture.
func adsbCarrierHz(k int) float64 { return float64(k%5-2) * 30_000 }

func (s *adsbTraffic) fill(dst []complex128, n0 int64) {
	if s.tx == nil {
		s.tx = modes.Schedule(s.flights, s.durationS)
	}
	if len(s.env) < len(dst) {
		s.env = make([]float64, len(dst))
	}
	a := ampFromDBFS(s.dbfs)
	spu := s.rate / 1e6
	end := n0 + int64(len(dst))
	// The first reply that may reach into this block: one starting up to a frame's length
	// before it.
	from := sort.Search(len(s.tx), func(i int) bool {
		return s.tx[i].T*s.rate+modes.FrameUs(s.tx[i].Msg)*spu+1 >= float64(n0)
	})
	for _, t := range s.tx[from:] {
		start := t.T * s.rate
		if start >= float64(end) {
			break
		}
		k := s.flightIndex(t.Addr)
		w := 2 * math.Pi * adsbCarrierHz(k) / s.rate
		// The carrier's phase is a function of the absolute sample, so a reply split across
		// two blocks stays continuous.
		ph0 := float64(k) * 1.3
		lo := max(int64(start), n0)
		hi := min(int64(math.Ceil(start+modes.FrameUs(t.Msg)*spu))+1, end)
		env := s.env[:hi-lo]
		clear(env)
		modes.Render(t.Msg, s.rate, start, env, lo)
		for i, v := range env {
			if v == 0 {
				continue
			}
			ph := ph0 + w*float64(lo+int64(i))
			dst[lo-n0+int64(i)] += complex(a*v*math.Cos(ph), a*v*math.Sin(ph))
		}
	}
}

func (s *adsbTraffic) flightIndex(addr uint32) int {
	for k, f := range s.flights {
		if f.Addr == addr {
			return k
		}
	}
	return 0
}

func (s *adsbTraffic) describe() map[string]any {
	ids := s.deviceIDs()
	calls := make([]string, 0, len(s.flights))
	for _, f := range s.flights {
		calls = append(calls, f.Callsign)
	}
	return map[string]any{
		"type": "adsb_traffic", "dbfs": s.dbfs, "duration_s": s.durationS,
		"aircraft": strings.Join(ids, ","), "callsigns": strings.Join(calls, ","),
	}
}

// span is the replies' 2 MHz around the centre.
func (s *adsbTraffic) span() (float64, float64) { return 0, 2_000_000 }

// deviceIDs is the aircraft as DecodeRecord.device_id has them: six upper-case hex digits.
func (s *adsbTraffic) deviceIDs() []string {
	out := make([]string, 0, len(s.flights))
	for _, f := range s.flights {
		out = append(out, fmt.Sprintf("%06X", f.Addr))
	}
	return out
}

// adsbBurstFlights are the adsb_burst fixture's two aircraft. Every address, callsign and
// position is made up.
var adsbBurstFlights = []modes.Flight{
	{Addr: 0xA0B1C2, Callsign: "LEY1", Squawk: "1200", Lat: 37.62, Lon: -122.38, AltFt: 4500, GSKn: 210, TrackDeg: 280, VRFpm: 1800},
	{Addr: 0xA3D4E5, Callsign: "LEY2", Squawk: "4521", Lat: 37.45, Lon: -122.05, AltFt: 35000, GSKn: 460, TrackDeg: 120},
}

// adsbBurstSource is the adsb_burst fixture's traffic: one second of the two aircraft.
func adsbBurstSource(rate float64) *adsbTraffic {
	return &adsbTraffic{rate: rate, dbfs: signalDBFS, durationS: 1, flights: adsbBurstFlights}
}

// sceneADSBFlights are scene_adsb's aircraft around San Francisco Bay: departures climbing out,
// arrivals descending, overflights at cruise. Every address and callsign is made up.
var sceneADSBFlights = []modes.Flight{
	{Addr: 0xA1F001, Callsign: "LEY101", Squawk: "3201", Lat: 37.640, Lon: -122.380, AltFt: 2800, GSKn: 190, TrackDeg: 284, VRFpm: 2200},
	{Addr: 0xA1F002, Callsign: "LEY202", Squawk: "4512", Lat: 37.720, Lon: -122.150, AltFt: 7000, GSKn: 230, TrackDeg: 200, VRFpm: -1100},
	{Addr: 0xA1F003, Callsign: "LEY303", Squawk: "2761", Lat: 37.900, Lon: -122.600, AltFt: 36000, GSKn: 470, TrackDeg: 135},
	{Addr: 0xA1F004, Callsign: "LEY404", Squawk: "6633", Lat: 37.500, Lon: -122.000, AltFt: 24000, GSKn: 380, TrackDeg: 320, VRFpm: -1800},
	{Addr: 0xA1F005, Callsign: "N0CALL", Squawk: "1200", Lat: 37.800, Lon: -122.300, AltFt: 3500, GSKn: 110, TrackDeg: 45},
}

const (
	sceneADSBRate      = 2_400_000
	sceneADSBDurationS = 30
)

// sceneADSBSource is scene_adsb's traffic, 15 dB under full scale over the scenes' floor.
func sceneADSBSource(rate float64) *adsbTraffic {
	return &adsbTraffic{rate: rate, dbfs: -15, durationS: sceneADSBDurationS, flights: sceneADSBFlights}
}

// adsbMetadata is the sidecar metadata of a 1090 MHz fixture.
func adsbMetadata() map[string]string {
	return map[string]string{"mode": "AM", "frequency_hz": hz(1_090_000_000)}
}

// expect is the fixture's one expectation: every reply the schedule holds decodes to a record,
// from the aircraft in the order each first transmits. Its channel, AM 10 kHz at the centre, is
// there because an expectation names one; the replies are 2 MHz wide, and leydec-adsb reads the
// capture's IQ, not a channel.
func (s *adsbTraffic) expect() iqfile.Expect {
	return iqfile.Expect{
		Mode: "AM", OffsetHz: 0, BandwidthHz: 10_000,
		Decode: &iqfile.DecodeExpect{
			Protocol: modes.Protocol, Records: len(modes.Schedule(s.flights, s.durationS)), DeviceIDs: s.deviceIDs(),
		},
	}
}
