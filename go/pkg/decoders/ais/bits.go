// SPDX-License-Identifier: Apache-2.0

package ais

import "strings"

// u reads width bits (1..64) from an AIS payload as a big-endian unsigned
// integer, bit 0 being the most significant bit of the first byte. AIS numbers
// every field this way (docs: "bits are numbered MSB first"), so the daemon's
// LSB-first HDLC byte assembly still yields the right octets and this reads
// across them.
func u(b []byte, off, width int) uint64 {
	var v uint64
	for k := 0; k < width; k++ {
		bit := off + k
		if bit/8 >= len(b) {
			break
		}
		v <<= 1
		v |= uint64(b[bit/8]>>(7-uint(bit%8))) & 1
	}
	return v
}

// i reads width bits as a two's-complement signed integer, which is how AIS
// carries latitude, longitude and rate of turn.
func i(b []byte, off, width int) int64 {
	v := u(b, off, width)
	if width < 64 && v&(1<<uint(width-1)) != 0 {
		return int64(v) - (1 << uint(width))
	}
	return int64(v)
}

// bitsAvailable reports whether the payload actually holds a field of width
// bits at off. AIS messages are often transmitted a few bits short of the full
// table, so an optional field is read only when the bits are there.
func bitsAvailable(b []byte, off, width int) bool {
	return off+width <= len(b)*8
}

// sixBitTable maps a 6-bit code to its character: 0-31 are @A-Z and five
// symbols, 32-63 are space and the printable ASCII that follows it (ITU-R
// M.1371, the "6-bit ASCII" alphabet).
const sixBitTable = "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_ !\"#$%&'()*+,-./0123456789:;<=>?"

// sixBit decodes n six-bit characters at off into a string, dropping the @
// padding and trailing spaces that fill an unused field (docs: "trailing unused
// characters ... will be represented by '@'").
func sixBit(b []byte, off, n int) string {
	var sb strings.Builder
	for k := 0; k < n; k++ {
		c := sixBitTable[u(b, off+6*k, 6)]
		if c == '@' {
			break
		}
		sb.WriteByte(c)
	}
	return strings.TrimRight(sb.String(), " ")
}
