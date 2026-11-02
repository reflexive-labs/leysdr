// SPDX-License-Identifier: Apache-2.0

// Command leydec-adsb is the ADS-B decoder plugin: the capture's complex baseband at 1090 MHz in
// on stdin (decode.proto, SIGNAL_IQ), DecodeRecords out on stdout, the contract in
// docs/design/decoders.md. It decodes Mode S replies and ADS-B extended squitters with
// go/pkg/decoders/modes. Run it with --manifest to print what it declares; the daemon spawns it
// with no arguments.
package main

import (
	"strconv"

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

// newDecoder refuses a capture slower than minRate (plugin.RefuseInput): nothing in it would
// decode, and the job should say so rather than run.
func newDecoder(rate uint32) *decoder {
	if rate < minRate {
		plugin.RefuseInput("the capture runs at %s; a Mode S reply needs at least %s", msps(rate), msps(minRate))
	}
	return &decoder{rate: rate, dec: modes.NewDecoder(float64(rate))}
}

// Start refuses a capture not centred near 1090 MHz: a reply off the centre by more than the band
// allows is clipped, so nothing would decode.
func (d *decoder) Start(desc *leylinev1.StreamDescriptor) {
	const hz = 1_090_000_000
	c := int64(desc.GetCenterHz())
	if half := int64(d.rate)/2 - 1_000_000; c != 0 && (c-hz > half || hz-c > half) {
		plugin.RefuseInput("the capture is centred on %.3f MHz, too far from 1090.000 MHz for a reply to fit in it", float64(c)/1e6)
	}
}

// msps writes a sample rate the way a person reads one: 2.4 MSPS.
func msps(rate uint32) string {
	return strconv.FormatFloat(float64(rate)/1e6, 'f', -1, 64) + " MSPS"
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
