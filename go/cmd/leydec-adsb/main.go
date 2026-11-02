// SPDX-License-Identifier: Apache-2.0

// Command leydec-adsb is the ADS-B decoder plugin: the capture's complex baseband at 1090 MHz in
// on stdin (decode.proto, SIGNAL_IQ), DecodeRecords out on stdout, the contract in
// docs/design/decoders.md. It decodes Mode S replies and ADS-B extended squitters with
// go/pkg/decoders/modes. Run it with --manifest to print what it declares; the daemon spawns it
// with no arguments.
package main

import (
	"fmt"
	"os"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/modes"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

func main() {
	plugin.MainIQ(manifest(), func(rate uint32) plugin.IQDecoder {
		return newDecoder(rate)
	})
}

// minRate is the slowest capture the demodulator reads: a half-bit is 0.5 µs.
const minRate = 2_000_000

// decoder feeds the capture's IQ to a modes.Decoder and stamps each record with the sample just
// past the reply's last bit.
type decoder struct {
	dec     *modes.Decoder
	rate    uint32
	started bool
}

func newDecoder(rate uint32) *decoder {
	d := &decoder{rate: rate}
	if rate < minRate {
		fmt.Fprintf(os.Stderr, "leydec-adsb: the capture runs at %d S/s; a Mode S reply needs at least %d, so nothing will decode\n", rate, minRate)
		return d
	}
	d.dec = modes.NewDecoder(float64(rate))
	return d
}

// Start warns when the capture is not centred near 1090 MHz: a reply off the centre by more than
// the band allows is clipped.
func (d *decoder) Start(desc *leylinev1.StreamDescriptor) {
	const hz = 1_090_000_000
	c := int64(desc.GetCenterHz())
	if half := int64(d.rate)/2 - 1_000_000; c != 0 && (c-hz > half || hz-c > half) {
		fmt.Fprintf(os.Stderr, "leydec-adsb: the capture is centred on %d Hz, too far from 1090 MHz for a reply to fit in it\n", c)
	}
}

func (d *decoder) FeedIQ(iq []complex64, at *leylinev1.SampleTime, gap *leylinev1.Gap, emit func(*leylinev1.DecodeRecord)) {
	if d.dec == nil || at == nil {
		return
	}
	// The demodulator counts samples on the capture's timeline (for capture IQ the IQ rate is
	// the capture rate), so a reply's end is a sample index there. A gap, or a frame that does
	// not follow the last, starts it again at this frame.
	if idx := int64(at.GetSampleIndex()); !d.started || gap != nil || idx != d.dec.Next() {
		d.dec.Reset(idx)
		d.started = true
	}
	capture := at.GetCaptureId()
	d.dec.Feed(iq, func(f modes.Frame, rec *leylinev1.DecodeRecord) {
		rec.Time = &leylinev1.SampleTime{CaptureId: capture, SampleIndex: uint64(f.End)}
		emit(rec)
	})
}
