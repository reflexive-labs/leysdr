// SPDX-License-Identifier: Apache-2.0

package main

import (
	"math"
	"strconv"
	"strings"

	"github.com/dpup/leysdr/go/pkg/decoders/afsk"
	"github.com/dpup/leysdr/go/pkg/decoders/ais"
)

// aisReport is one AIS Type 1 position report the ais_burst fixture transmits.
type aisReport struct {
	mmsi     uint32
	lat, lon float64
}

// packType1 packs a 168-bit AIS Type 1 position report, MSB first: enough of
// the message for the decoder to recover the MMSI and the fix, the rest of the
// fields left at their not-available sentinels.
func packType1(r aisReport) []byte {
	var bits []bool
	put := func(v uint64, w int) {
		for k := w - 1; k >= 0; k-- {
			bits = append(bits, v>>uint(k)&1 != 0)
		}
	}
	mask := func(v int64, w int) uint64 { return uint64(v) & (1<<uint(w) - 1) }
	put(1, 6) // message type
	put(0, 2) // repeat indicator
	put(uint64(r.mmsi), 30)
	put(0, 4)            // nav status: under way using engine
	put(mask(128, 8), 8) // rate of turn: not available
	put(0, 10)           // SOG
	put(0, 1)            // position accuracy
	put(mask(int64(math.Round(r.lon*600000)), 28), 28)
	put(mask(int64(math.Round(r.lat*600000)), 27), 27)
	put(0, 12)  // COG
	put(511, 9) // true heading: not available
	put(0, 6+2+3+1+19)
	out := make([]byte, (len(bits)+7)/8)
	for i, b := range bits {
		if b {
			out[i/8] |= 1 << (7 - uint(i%8))
		}
	}
	return out
}

// aisPacket FM-modulates AIS GMSK onto a carrier, the same chain a ship's
// transponder drives, so the fixture exercises the whole path from IQ to
// DecodeRecord. The GMSK waveform is built by pkg/decoders/ais's own modulator,
// so the fixture and the decoder share one definition of the modulation.
//
// The pattern is one second long and repeats: the two bursts are a few tens of
// milliseconds of the second, and the rest is silence, as on a real channel
// most of the time.
type aisPacket struct {
	rate, carrierHz, devHz, dbfs float64
	reports                      []aisReport
	preambleFlags                int

	audio []float32
	phase float64
}

// build assembles one period of modulating audio: the bursts spaced out across
// exactly rate samples.
func (s *aisPacket) build() {
	mod := ais.NewModulator(s.rate, 1.0)
	bursts := make([][]float32, 0, len(s.reports))
	total := 0
	for _, r := range s.reports {
		b := mod.Modulate(nil, afsk.NRZI(ais.EncodeFrame(packType1(r), s.preambleFlags)))
		bursts = append(bursts, b)
		total += len(b)
	}
	period := int(s.rate)
	gap := (period - total) / (len(bursts) + 1)
	if gap < 0 {
		panic("leyfix: the ais_burst reports do not fit in one second")
	}
	s.audio = make([]float32, 0, period)
	for _, b := range bursts {
		s.audio = append(s.audio, make([]float32, gap)...)
		s.audio = append(s.audio, b...)
	}
	s.audio = append(s.audio, make([]float32, period-len(s.audio))...)
}

func (s *aisPacket) fill(dst []complex128, n0 int64) {
	if s.audio == nil {
		s.build()
	}
	a := ampFromDBFS(s.dbfs)
	wc := 2 * math.Pi * s.carrierHz / s.rate
	wd := 2 * math.Pi * s.devHz / s.rate
	period := int64(len(s.audio))
	ph := s.phase
	for i := range dst {
		m := float64(s.audio[(n0+int64(i))%period])
		ph += wc + wd*m
		if ph > math.Pi {
			ph -= 2 * math.Pi
		} else if ph < -math.Pi {
			ph += 2 * math.Pi
		}
		dst[i] += complex(a*math.Cos(ph), a*math.Sin(ph))
	}
	s.phase = ph
}

func (s *aisPacket) describe() map[string]any {
	return map[string]any{
		"type": "ais_packet", "carrier_hz": s.carrierHz, "deviation_hz": s.devHz,
		"dbfs": s.dbfs, "baud": ais.BaudHz, "vessels": strings.Join(s.deviceIDs(), ","),
	}
}

// span is Carson's rule over the deviation and the line rate.
func (s *aisPacket) span() (float64, float64) {
	return s.carrierHz, 2 * (s.devHz + ais.BaudHz)
}

// deviceIDs is what the sidecar's decode expectation names, in transmission
// order: the MMSIs as strings, which is DecodeRecord.device_id.
func (s *aisPacket) deviceIDs() []string {
	out := make([]string, 0, len(s.reports))
	for _, r := range s.reports {
		out = append(out, strconv.FormatUint(uint64(r.mmsi), 10))
	}
	return out
}

// aisSource builds the ais_burst fixture's transmitter: two Type 1 position
// reports from two vessels, at MSK's quarter-baud deviation of 2400 Hz.
func aisSource(rate float64) *aisPacket {
	return &aisPacket{
		rate: rate, carrierHz: 0, devHz: 2400, dbfs: signalDBFS,
		preambleFlags: 1,
		reports: []aisReport{
			{mmsi: 366123456, lat: 47.6039, lon: -122.3395},
			{mmsi: 316001234, lat: 49.2891, lon: -123.1120},
		},
	}
}
