// SPDX-License-Identifier: Apache-2.0

// Command leydec-same is the SAME/EAS decoder plugin (docs/design/decoders.md,
// driver C): NFM weather-radio audio in on stdin, a DecodeRecord per alert out
// on stdout, the contract in docs/reference/writing-a-decoder.md. Run it with
// --manifest to print what it declares; the daemon spawns it with no arguments.
package main

import (
	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/decoders/same"
	"github.com/dpup/leysdr/go/pkg/plugin"
)

func main() {
	plugin.Main(manifest(), func(rate uint32) plugin.Decoder {
		return newDecoder(float64(rate))
	})
}

// decoder is the chain: SAME demodulator, header parser, record builder. It
// holds no state the daemon owns; a gap resets the demodulator and the burst
// dedupe, because a bit clock and a half-heard alert mean nothing across a hole
// in the samples.
type decoder struct {
	dem   *same.Demodulator
	rate  float64 // audio rate
	capHz float64 // capture rate, from the descriptor's span_hz

	lastKey string // dedupe: the semantic key of the alert last emitted
	lastEnd int64  // and the sample index it ended at
}

func newDecoder(rate float64) *decoder {
	return &decoder{dem: same.New(rate), rate: rate, capHz: rate}
}

// Start takes the capture rate from the descriptor, which is what SampleTime
// counts in (docs/plans/decoders.md, DEC-1).
func (d *decoder) Start(desc *leylinev1.StreamDescriptor) {
	if hz := float64(desc.GetSpanHz()); hz > 0 {
		d.capHz = hz
	}
}

// dedupeGap is how far apart, in audio-sample time, two decodes of the same
// alert must be to count as separate messages rather than the three repeats of
// one. A SAME message and its three header copies span a few seconds; ten is
// clear of that and short of any plausible re-issue.
func (d *decoder) dedupeGap() int64 { return int64(10 * d.rate) }

func (d *decoder) Feed(samples []float32, at *leylinev1.SampleTime, gap *leylinev1.Gap, emit func(*leylinev1.DecodeRecord)) {
	if gap != nil {
		d.dem.Reset()
		d.lastKey = ""
	}
	base := d.dem.Index()
	d.dem.Feed(samples, func(f same.Frame) {
		if !f.Header {
			// An EOM closes the burst; the next matching header is a new alert.
			d.lastKey = ""
			return
		}
		m, err := same.Parse(f.Text)
		if err != nil {
			return
		}
		key := m.Event + "|" + m.Issued + "|" + m.Callsign + "|" + m.FIPSList()
		if key == d.lastKey && f.End-d.lastEnd < d.dedupeGap() {
			d.lastEnd = f.End // a repeat of the alert already emitted
			return
		}
		d.lastKey, d.lastEnd = key, f.End
		rec := buildRecord(m)
		rec.Time = plugin.SampleTimeAt(at, int(f.End-base), d.rate, d.capHz)
		emit(rec)
	})
}
