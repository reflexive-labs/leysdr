// SPDX-License-Identifier: Apache-2.0

package modes

// The Mode S parity is a 24-bit CRC over the message's first 32 or 88 bits with the generator
// polynomial 0x1FFF409 (ICAO Annex 10, Volume IV, 3.1.2.3.3), sent in the last 24 bits. A DF11,
// DF17 or DF18 reply sends the CRC itself, so its syndrome (the CRC of the data XOR the parity
// field) is 0, or for DF11 the interrogator code; a DF4, DF5, DF20 or DF21 reply sends the CRC
// XOR the aircraft's address, so its syndrome is the address.
const crcPoly = 0xFFF409

var crcTable = func() (t [256]uint32) {
	for i := range t {
		c := uint32(i) << 16
		for range 8 {
			if c&0x800000 != 0 {
				c = c<<1 ^ crcPoly
			} else {
				c <<= 1
			}
		}
		t[i] = c & 0xFFFFFF
	}
	return t
}()

// Checksum is the CRC-24 of data, MSB first, from a zero register.
func Checksum(data []byte) uint32 {
	var c uint32
	for _, b := range data {
		c = (c<<8 ^ crcTable[byte(c>>16)^b]) & 0xFFFFFF
	}
	return c
}

// Syndrome is the CRC of msg's data bits XOR its parity field: 0 for an intact DF17 or DF18, the
// address for a DF4, DF5, DF20 or DF21 reply. msg is 7 or 14 bytes.
func Syndrome(msg []byte) uint32 {
	n := len(msg) - 3
	return Checksum(msg[:n]) ^ (uint32(msg[n])<<16 | uint32(msg[n+1])<<8 | uint32(msg[n+2]))
}

// SetParity writes the CRC of msg's data bits XOR xor into its last three bytes: xor is 0 for an
// extended squitter or an all-call reply with interrogator code 0, and the address for a
// surveillance reply.
func SetParity(msg []byte, xor uint32) {
	n := len(msg) - 3
	p := Checksum(msg[:n]) ^ xor
	msg[n], msg[n+1], msg[n+2] = byte(p>>16), byte(p>>8), byte(p)
}

// bitSyndromes maps the syndrome a single flipped bit leaves in a 112-bit message to that bit's
// index. The CRC is linear, so a message with one bit wrong has the syndrome of that bit alone,
// and the 112 syndromes are distinct.
var bitSyndromes = func() map[uint32]int {
	m := make(map[uint32]int, 112)
	var msg [14]byte
	for i := range 112 {
		msg[i/8] ^= 0x80 >> (i % 8)
		m[Syndrome(msg[:])] = i
		msg[i/8] ^= 0x80 >> (i % 8)
	}
	return m
}()

// fixOneBit flips the bit of a 112-bit msg whose syndrome is syn and reports whether syn was a
// single-bit error's. The DF field (bits 0 to 4) is never corrected: a flip there would turn the
// message into another format.
func fixOneBit(msg []byte, syn uint32) bool {
	i, ok := bitSyndromes[syn]
	if !ok || i < 5 || len(msg) != 14 {
		return false
	}
	msg[i/8] ^= 0x80 >> (i % 8)
	return true
}
