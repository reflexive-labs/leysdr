// SPDX-License-Identifier: Apache-2.0

package ais

import "github.com/dpup/leysdr/go/pkg/decoders/ax25"

// AIS frames its bursts exactly as AX.25 does: an HDLC 0x7E flag, the payload
// with a zero stuffed after every five ones, and a 16-bit X.25 FCS (CRC-16-CCITT,
// polynomial 0x8408, init 0xFFFF, complemented, low byte first). That is bit
// for bit what pkg/decoders/ax25 already implements, so the deframer, the FCS
// and the bit-stuffing encoder are reused rather than copied, so the repository
// has a single HDLC implementation. AIS does not share the payload format:
// bits.go reads the payload as a big-endian bit field where AX.25 reads
// octets; the byte assembly is identical because both send each octet LSB
// first, so the deframer's bytes are already the AIS octets Parse expects.
//
// The only AIS-specific twist is the training sequence: a burst opens with 24
// bits of 0101... before the flag. The deframer ignores everything up to the
// first flag, so the preamble needs no handling here; the modulator sends it so
// the demodulator's bit clock has something to lock to.

// Deframer is the HDLC deframer, an alias for the shared one.
type Deframer = ax25.Deframer

// NewDeframer returns a deframer waiting for its first flag.
func NewDeframer() *Deframer { return ax25.NewDeframer() }

// preambleBits is the AIS training sequence: 24 alternating bits. It is data
// (pre-NRZI, pre-flag) so the modulator can prepend it to a frame's bit stream.
func preambleBits() []bool {
	bits := make([]bool, 24)
	for i := range bits {
		bits[i] = i%2 == 0
	}
	return bits
}

// EncodeFrame builds the wire bits for one AIS message: the training sequence,
// then the HDLC-framed, bit-stuffed payload with its FCS between flags. The
// result is data bits in transmission order, before NRZI -- feed it through
// afsk.NRZI and Modulator.Modulate to synthesise a burst. ax25.Encode does the
// flags, stuffing and FCS. It exists, like Modulator, so tests and the leyfix
// fixture can make AIS signal without a radio.
func EncodeFrame(payload []byte, preambleFlags int) []bool {
	return append(preambleBits(), ax25.Encode(payload, preambleFlags)...)
}
