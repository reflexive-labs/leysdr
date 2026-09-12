// SPDX-License-Identifier: Apache-2.0

// Package same demodulates and modulates SAME/EAS, the AFSK burst NOAA weather
// radio keys before an alert (docs/design/decoders.md, driver C). The
// modulation is AFSK like APRS but its own animal: mark 2083.3 Hz is a 1 and
// space 1562.5 Hz a 0 at 520.83 baud, the bits are direct rather than NRZI, and
// bytes are eight bits least-significant-first, ASCII. A transmission is a
// preamble of sixteen 0xAB bytes then the header "ZCZC-ORG-EEE-...-CALLSIGN-",
// sent three times, and closes with the preamble then "NNNN", also three times.
//
// The receive chain mirrors pkg/decoders/afsk -- mark/space correlators one bit
// long, a normalising discriminator, a short smoother and a PLL bit clock --
// but decodes each sampled tone straight to a bit and frames bytes by locking
// onto the 0xAB preamble rather than an HDLC flag. Parse turns a decoded header
// into a Message.
//
// Measured by the round-trip tests here over the two example headers: 100/100
// clean decodes at 48 kHz. In white Gaussian noise (signal power over the whole
// 24 kHz audio band) it holds 100/100 down to -2 dB, 99/100 at -4 dB, 53/100 at
// -6 dB and nothing at -8 dB -- a few dB better than the APRS modem in the same
// terms, because a SAME header is a fifth the bits and the tone spacing is
// wider. SAME rides a strong local NOAA transmitter and repeats each header
// three times for a majority vote, so the operating point is far from this
// corner; the noise gate the test enforces is a comfortable 0 dB.
package same

import "math"

// SAME tones and bit rate. Mark is a 1 bit, space a 0 bit, sent directly (no
// NRZI). 520.83 baud is the NWS figure; the exact rate is 520 + 5/6.
const (
	MarkHz  = 2083.3
	SpaceHz = 1562.5
	BaudHz  = 520.8333333333334
)

// PreambleByte is the byte the preamble repeats sixteen times; the demodulator
// locks byte alignment on it.
const PreambleByte = 0xAB

// preambleBits is two PreambleByte in wire order (least-significant bit first):
// 0xAB is 1,1,0,1,0,1,0,1. Sixteen bits is a tight enough match that ASCII
// payload does not trip the sync.
var preambleBits = [16]bool{
	true, true, false, true, false, true, false, true,
	true, true, false, true, false, true, false, true,
}

// Frame is one decoded transmission: a header (ZCZC...) or an end-of-message
// (NNNN). Text is the ASCII with the preamble stripped; End is the absolute
// audio-sample index of the frame's last bit, for stamping.
type Frame struct {
	Header bool
	Text   string
	End    int64
}

// Demodulator turns audio into SAME frames. It streams: Feed takes any block
// size and carries state across calls.
type Demodulator struct {
	rate   float64
	window int

	markCos, markSin   []float64
	spaceCos, spaceSin []float64
	hist               []float64
	pos, filled        int

	smooth, smGain float64

	phase, step float64
	lastSign    bool
	haveSign    bool

	index int64

	// Bit framing.
	ring    [16]bool // last 16 bits, oldest at bit position (index-15)
	rcount  int
	synced  bool
	curByte byte
	bitIn   int
	payload []byte
	kind    byte // 'Z' header, 'N' eom, 0 undecided
	plus    bool
	dashes  int
}

// New builds a demodulator for an audio rate between 8 kHz and 96 kHz, the same
// bound the channel's audio rate lands in (about 48 kHz).
func New(rate float64) *Demodulator {
	if rate < 8000 || rate > 96000 {
		panic("same: rate outside 8 kHz to 96 kHz")
	}
	n := int(math.Round(rate / BaudHz))
	d := &Demodulator{
		rate: rate, window: n,
		markCos: make([]float64, n), markSin: make([]float64, n),
		spaceCos: make([]float64, n), spaceSin: make([]float64, n),
		hist: make([]float64, n),
		step: BaudHz / rate * 2,
	}
	for k := 0; k < n; k++ {
		tm := 2 * math.Pi * MarkHz * float64(k) / rate
		ts := 2 * math.Pi * SpaceHz * float64(k) / rate
		d.markCos[k], d.markSin[k] = math.Cos(tm), math.Sin(tm)
		d.spaceCos[k], d.spaceSin[k] = math.Cos(ts), math.Sin(ts)
	}
	d.smGain = 1 / (0.25 * rate / BaudHz)
	return d
}

// Window is the correlator length in samples, one bit time.
func (d *Demodulator) Window() int { return d.window }

// Index is how many samples the demodulator has consumed.
func (d *Demodulator) Index() int64 { return d.index }

// Reset clears everything; a gap in the stream invalidates the bit clock and
// any half-assembled frame.
func (d *Demodulator) Reset() {
	for i := range d.hist {
		d.hist[i] = 0
	}
	d.pos, d.filled = 0, 0
	d.smooth, d.phase = 0, 0
	d.haveSign = false
	d.resetFrame()
	d.rcount = 0
}

func (d *Demodulator) resetFrame() {
	d.synced = false
	d.curByte, d.bitIn = 0, 0
	d.payload = d.payload[:0]
	d.kind = 0
	d.plus = false
	d.dashes = 0
}

// Feed runs a block of audio through the chain and calls emit for every frame
// completed. maxHeader bounds a header so a false lock cannot grow forever.
const maxHeader = 268

// Feed demodulates a block and emits the frames it completes.
func (d *Demodulator) Feed(samples []float32, emit func(Frame)) {
	for _, s := range samples {
		d.hist[d.pos] = float64(s)
		d.pos++
		if d.pos == d.window {
			d.pos = 0
		}
		if d.filled < d.window {
			d.filled++
			d.index++
			continue
		}
		var mi, mq, si, sq float64
		j := d.pos
		for k := 0; k < d.window; k++ {
			v := d.hist[j]
			mi += v * d.markCos[k]
			mq += v * d.markSin[k]
			si += v * d.spaceCos[k]
			sq += v * d.spaceSin[k]
			j++
			if j == d.window {
				j = 0
			}
		}
		mm, sm := math.Hypot(mi, mq), math.Hypot(si, sq)
		disc := (mm - sm) / (mm + sm + 1e-12)
		d.smooth += (disc - d.smooth) * d.smGain

		sign := d.smooth >= 0
		if d.haveSign && sign != d.lastSign {
			d.phase *= 1 - 0.25
		}
		d.lastSign, d.haveSign = sign, true

		d.phase += d.step
		if d.phase >= 1 {
			d.phase -= 2
			// Mark is a 1, space a 0; no NRZI.
			d.feedBit(sign, d.index, emit)
		}
		d.index++
	}
}

// feedBit frames a decoded bit: it locks byte alignment on the preamble, then
// assembles bytes least-significant-first and hands complete frames to emit.
func (d *Demodulator) feedBit(bit bool, at int64, emit func(Frame)) {
	// Slide the 16-bit sync window.
	copy(d.ring[:], d.ring[1:])
	d.ring[15] = bit
	if d.rcount < 16 {
		d.rcount++
	}
	if !d.synced {
		if d.rcount == 16 && d.ring == preambleBits {
			// The newest bit is the last bit of a preamble byte, so the next
			// bit starts a fresh byte.
			d.synced = true
			d.curByte, d.bitIn = 0, 0
			d.payload = d.payload[:0]
			d.kind = 0
			d.plus, d.dashes = false, 0
		}
		return
	}
	if bit {
		d.curByte |= 1 << uint(d.bitIn)
	}
	d.bitIn++
	if d.bitIn < 8 {
		return
	}
	b := d.curByte
	d.curByte, d.bitIn = 0, 0
	d.consumeByte(b, at, emit)
}

func (d *Demodulator) consumeByte(b byte, at int64, emit func(Frame)) {
	if d.kind == 0 {
		switch b {
		case PreambleByte: // still in the preamble run
			return
		case 'Z':
			d.kind = 'Z'
		case 'N':
			d.kind = 'N'
		default:
			d.resetFrame() // not a header we know; hunt for the next preamble
			return
		}
	}
	d.payload = append(d.payload, b)
	switch d.kind {
	case 'N':
		if len(d.payload) >= 4 {
			emit(Frame{Header: false, Text: string(d.payload[:4]), End: at})
			d.resetFrame()
		}
	case 'Z':
		if b == '+' {
			d.plus = true
		}
		if d.plus && b == '-' {
			d.dashes++
			if d.dashes == 3 { // the dash closing the callsign field
				emit(Frame{Header: true, Text: string(d.payload), End: at})
				d.resetFrame()
				return
			}
		}
		if len(d.payload) > maxHeader {
			d.resetFrame()
		}
	}
}
