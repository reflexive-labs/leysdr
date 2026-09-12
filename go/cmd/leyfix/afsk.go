// SPDX-License-Identifier: Apache-2.0

package main

import (
	"math"
	"strings"

	"github.com/dpup/leysdr/go/pkg/decoders/afsk"
	"github.com/dpup/leysdr/go/pkg/decoders/ax25"
)

// packet is one AX.25 UI frame the aprs_afsk fixture transmits.
type packet struct {
	source ax25.Address
	dest   string
	info   string
}

// afskPacket FM-modulates a Bell 202 AFSK audio stream onto a carrier: the
// same chain a handheld TNC drives, so the fixture exercises the whole path
// from IQ to DecodeRecord rather than the demodulator alone.
//
// The pattern is one second long and repeats, so a longer fixture holds the
// same three packets again rather than trailing off into silence. The silence
// between packets is whatever the second has left over after the frames, which
// is about 17 ms: at 1200 baud the three frames are already 0.93 s, and the
// 200 ms docs/plans/decoders.md asked for does not exist inside a one-second
// fixture. Twenty bit times is ample for HDLC to resynchronise.
type afskPacket struct {
	rate, carrierHz, devHz, dbfs float64
	packets                      []packet
	preambleFlags                int

	audio []float32 // one period of modulating audio, built on first use
	phase float64
}

// audioAmplitude is the peak modulating level the AFSK tones reach, which is
// what devHz is the deviation of.
const audioAmplitude = 0.9

// build assembles one period of modulating audio: silence, frame, silence,
// frame, silence, frame, silence, exactly rate samples long.
func (s *afskPacket) build() {
	mod := afsk.NewModulator(s.rate, audioAmplitude)
	tones := make([][]float32, 0, len(s.packets))
	total := 0
	for _, p := range s.packets {
		frame := ax25.BuildUI(ax25.Address{Call: p.dest}, p.source, nil, 0xF0, []byte(p.info))
		t := mod.Modulate(nil, afsk.NRZI(ax25.Encode(frame, s.preambleFlags)))
		tones = append(tones, t)
		total += len(t)
	}
	period := int(s.rate)
	gap := (period - total) / (len(tones) + 1)
	if gap < 0 {
		panic("leyfix: the aprs_afsk packets do not fit in one second")
	}
	s.audio = make([]float32, 0, period)
	for _, t := range tones {
		s.audio = append(s.audio, make([]float32, gap)...)
		s.audio = append(s.audio, t...)
	}
	s.audio = append(s.audio, make([]float32, period-len(s.audio))...)
}

func (s *afskPacket) fill(dst []complex128, n0 int64) {
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

func (s *afskPacket) describe() map[string]any {
	calls := make([]string, 0, len(s.packets))
	for _, p := range s.packets {
		calls = append(calls, p.source.String())
	}
	return map[string]any{
		"type": "afsk_packet", "carrier_hz": s.carrierHz, "deviation_hz": s.devHz,
		"dbfs": s.dbfs, "baud": afsk.BaudHz, "stations": strings.Join(calls, ","),
	}
}

// span is Carson's rule over the deviation and the highest AFSK tone.
func (s *afskPacket) span() (float64, float64) {
	return s.carrierHz, 2 * (s.devHz + afsk.SpaceHz)
}

// deviceIDs is what the sidecar's decode expectation names, in transmission
// order.
func (s *afskPacket) deviceIDs() []string {
	out := make([]string, 0, len(s.packets))
	for _, p := range s.packets {
		out = append(out, p.source.String())
	}
	return out
}
