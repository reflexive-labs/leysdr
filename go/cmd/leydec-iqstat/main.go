// SPDX-License-Identifier: Apache-2.0

// Command leydec-iqstat is the IQ path's fake decoder: it does no protocol
// work, it proves the plumbing. Fed the capture's raw complex baseband
// (decode.proto, SIGNAL_IQ), it emits one "iqstat" record per block of samples
// carrying the block's power and sizes, so the daemon's IQ delivery can be
// tested against numbers a human can sanity-check -- analogous to the engine's
// fake decoder. Run with --manifest to print what it declares; the daemon
// spawns it with no arguments (docs/reference/writing-a-decoder.md, "The wire").
package main

import (
	"math"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

func main() {
	plugin.MainIQ(manifest(), func(rate uint32) plugin.IQDecoder {
		return newDecoder(rate)
	})
}

// floorDBFS is where a silent block reads instead of -Inf: 10*log10(0) has no
// value, and a floor is what a meter shows for silence anyway.
const floorDBFS = -200.0

// decoder accumulates power over a block of samples and emits when the block is
// full. It carries only what the descriptor named -- no protocol state -- so a
// gap just discards the partial block rather than resetting a demodulator.
type decoder struct {
	rate     float64 // IQ sample rate, from the descriptor
	capHz    float64 // capture rate (span_hz); equal to rate for capture IQ
	centerHz uint64  // capture center, from the descriptor
	block    int     // samples per record, ~half a second

	sumSq float64 // running sum of |x|^2 over the current block
	count int     // samples in the current block
}

func newDecoder(rate uint32) *decoder {
	block := int(rate) / 2 // ~half a second of samples
	if block < 1 {
		block = 1
	}
	return &decoder{rate: float64(rate), capHz: float64(rate), block: block}
}

// Start reads the capture rate and center from the descriptor: span_hz is what
// SampleTime counts in, and center_hz is the band's center, which the
// record reports so a reader knows where the power was measured.
func (d *decoder) Start(desc *leylinev1.StreamDescriptor) {
	if hz := float64(desc.GetSpanHz()); hz > 0 {
		d.capHz = hz
	}
	d.centerHz = desc.GetCenterHz()
}

func (d *decoder) FeedIQ(iq []complex64, at *leylinev1.SampleTime, gap *leylinev1.Gap, emit func(*leylinev1.DecodeRecord)) {
	if gap != nil {
		// A hole in the samples makes a partial block's mean meaningless.
		d.sumSq, d.count = 0, 0
	}
	for i, x := range iq {
		re, im := float64(real(x)), float64(imag(x))
		d.sumSq += re*re + im*im
		d.count++
		if d.count >= d.block {
			d.flush(at, i+1, emit)
			d.sumSq, d.count = 0, 0
		}
	}
}

// flush emits one record for the block that just filled. offset is where the
// block ends inside this frame, placed on the capture timeline via SampleTimeAt
// (for capture IQ the rates are equal, so this is a 1:1 add; kept for
// consistency with the audio path).
func (d *decoder) flush(at *leylinev1.SampleTime, offset int, emit func(*leylinev1.DecodeRecord)) {
	dbfs := floorDBFS
	if d.count > 0 {
		if mean := d.sumSq / float64(d.count); mean > 0 {
			if dbfs = 10 * math.Log10(mean); dbfs < floorDBFS {
				dbfs = floorDBFS
			}
		}
	}
	emit(&leylinev1.DecodeRecord{
		Protocol: "iqstat",
		Kind:     "power",
		DeviceId: "",
		Time:     plugin.SampleTimeAt(at, offset, d.rate, d.capHz),
		Fields: map[string]*leylinev1.FieldValue{
			"power_dbfs":  {Value: &leylinev1.FieldValue_Number{Number: dbfs}},
			"sample_rate": {Value: &leylinev1.FieldValue_Integer{Integer: int64(d.rate)}},
			"samples":     {Value: &leylinev1.FieldValue_Integer{Integer: int64(d.count)}},
			"center_hz":   {Value: &leylinev1.FieldValue_Integer{Integer: int64(d.centerHz)}},
		},
	})
}
