// SPDX-License-Identifier: Apache-2.0

package main

import (
	"math"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/same"
)

// samePacket FM-modulates one SAME alert burst onto a carrier, the same chain a
// NOAA transmitter drives, so the same_alert fixture exercises the whole path
// from IQ to DecodeRecord. Unlike the repeating afskPacket it plays the burst
// once at the start and is silent after: a real alert is a single event, and
// one header copy is all the decoder needs.
type samePacket struct {
	rate, carrierHz, devHz, dbfs float64
	header                       string
	callsign                     string

	audio []float32 // the modulating audio, built on first use
	phase float64
}

// build assembles the modulating audio once: one preamble plus the header. A
// single copy keeps the burst near one second so it fits a short fixture.
func (s *samePacket) build() {
	mod := same.NewModulator(s.rate, audioAmplitude)
	s.audio = mod.Header(nil, s.header)
}

func (s *samePacket) fill(dst []complex128, n0 int64) {
	if s.audio == nil {
		s.build()
	}
	a := ampFromDBFS(s.dbfs)
	wc := 2 * math.Pi * s.carrierHz / s.rate
	wd := 2 * math.Pi * s.devHz / s.rate
	n := int64(len(s.audio))
	ph := s.phase
	for i := range dst {
		var m float64
		if idx := n0 + int64(i); idx < n {
			m = float64(s.audio[idx])
		}
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

func (s *samePacket) describe() map[string]any {
	return map[string]any{
		"type": "same_packet", "carrier_hz": s.carrierHz, "deviation_hz": s.devHz,
		"dbfs": s.dbfs, "baud": same.BaudHz, "callsign": s.callsign, "header": s.header,
	}
}

// span is Carson's rule over the deviation and the highest SAME tone.
func (s *samePacket) span() (float64, float64) {
	return s.carrierHz, 2 * (s.devHz + same.MarkHz)
}

func (s *samePacket) deviceIDs() []string { return []string{s.callsign} }

// sameSource builds the same_alert fixture's transmitter: a Required Weekly
// Test for two Kansas-area counties from KEAX/NWS, one header copy.
func sameSource(rate float64) *samePacket {
	return &samePacket{
		rate: rate, carrierHz: 0, devHz: 3500, dbfs: signalDBFS,
		header:   "ZCZC-WXR-RWT-020103-020209+0030-1051700-KEAX/NWS-",
		callsign: "KEAX/NWS",
	}
}
