// SPDX-License-Identifier: Apache-2.0

// Command leydec-ais is the AIS decoder plugin: an NFM channel's discriminator
// audio in on stdin, DecodeRecords out on stdout, the contract in
// docs/design/decoders.md. Run it with --manifest to print what it declares;
// the daemon spawns it with no arguments.
package main

import (
	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/decoders/ais"
	"github.com/dpup/leysdr/go/pkg/plugin"
)

func main() {
	plugin.Main(manifest(), func(rate uint32) plugin.Decoder {
		return newDecoder(float64(rate))
	})
}

// decoder is the chain: GMSK demodulator, HDLC deframer, AIS parser. It holds
// no state the daemon owns; a gap resets everything, because a bit clock and a
// half-assembled frame mean nothing across a hole in the samples.
type decoder struct {
	dem   *ais.Demodulator
	def   *ais.Deframer
	rate  float64 // audio rate
	capHz float64 // capture rate, from the descriptor's span_hz
}

func newDecoder(rate float64) *decoder {
	return &decoder{dem: ais.New(rate), def: ais.NewDeframer(), rate: rate, capHz: rate}
}

// Start takes the capture rate from the descriptor, which is what SampleTime
// counts in (docs/plans/decoders.md, DEC-1).
func (d *decoder) Start(desc *leylinev1.StreamDescriptor) {
	if hz := float64(desc.GetSpanHz()); hz > 0 {
		d.capHz = hz
	}
}

func (d *decoder) Feed(samples []float32, at *leylinev1.SampleTime, gap *leylinev1.Gap, emit func(*leylinev1.DecodeRecord)) {
	if gap != nil {
		d.dem.Reset()
		d.def.Reset()
	}
	// The demodulator counts samples from the first one it ever saw, so the
	// offset inside this frame is the difference from where the frame started.
	base := d.dem.Index()
	d.dem.Feed(samples, func(bit bool, idx int64) {
		d.def.Feed(bit, idx, func(raw []byte, end int64) {
			m, err := ais.Parse(raw)
			if err != nil {
				return
			}
			rec := m.Record()
			rec.Time = plugin.SampleTimeAt(at, int(end-base), d.rate, d.capHz)
			emit(rec)
		})
	})
}
