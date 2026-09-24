// SPDX-License-Identifier: Apache-2.0

// Package dcs is the DCS (Digital-Coded Squelch) word: the code list, the encoder the fixture
// generator uses, and the decoding rule the daemon applies, so the Go clients and the engine read
// one bit stream the same way. The format was settled from two recordings of the owner's handheld
// (docs/plans/signal-views.md, SV-7, "Recorded and read 2026-09-23"):
//
//   - 134.4 bit/s NRZ, a 23-bit word repeated with no gap while the transmitter is keyed;
//   - in transmitted order, with positive deviation as a one: nine code bits (three octal digits,
//     low bit first), the fixed bits 001, then eleven parity bits;
//   - the word is a Golay(23,12) codeword under g(x) = x^11 + x^9 + x^7 + x^6 + x^5 + x + 1
//     (0xAE3), with the first transmitted bit as the coefficient of x^22;
//   - an inverted code is the same stream complemented.
//
// A code here is the number itself (0o23 for DCS 023); the contract's dcs_code carries its octal
// digits read as decimal (23), which Wire and FromWire convert.
package dcs

import (
	"fmt"
	"slices"
)

// BitRate is the DCS bit rate in bits per second.
const BitRate = 134.4

// WordBits is the length of one DCS word.
const WordBits = 23

// Poly is the Golay(23,12) generator, g(x) = x^11 + x^9 + x^7 + x^6 + x^5 + x + 1.
const Poly = 0xAE3

// Word is one 23-bit word in transmitted order, one bit a byte (0 or 1), index 0 sent first.
type Word [WordBits]byte

// String renders the word as 23 characters of 0 and 1, first transmitted bit first.
func (w Word) String() string {
	b := make([]byte, WordBits)
	for i, v := range w {
		b[i] = '0' + v&1
	}
	return string(b)
}

// Codes are the 104 standard codes radio menus offer, in ascending order. It is the list the
// decoder names a code from: every rotation of a received word that shows the fixed bits reads as
// some code, and only the list tells the real one from the rest (754's word also reads 076 and
// 203). Checked on 2026-09-24 against the RadioReference wiki's DCS table, which holds these 104
// and eight extended codes (006 007 015 017 021 050 141 214) this list leaves out; the 83 codes
// of the older common chart are all on it.
var Codes = []int{
	0o023, 0o025, 0o026, 0o031, 0o032, 0o036, 0o043, 0o047, 0o051, 0o053, 0o054, 0o065, 0o071,
	0o072, 0o073, 0o074, 0o114, 0o115, 0o116, 0o122, 0o125, 0o131, 0o132, 0o134, 0o143, 0o145,
	0o152, 0o155, 0o156, 0o162, 0o165, 0o172, 0o174, 0o205, 0o212, 0o223, 0o225, 0o226, 0o243,
	0o244, 0o245, 0o246, 0o251, 0o252, 0o255, 0o261, 0o263, 0o265, 0o266, 0o271, 0o274, 0o306,
	0o311, 0o315, 0o325, 0o331, 0o332, 0o343, 0o346, 0o351, 0o356, 0o364, 0o365, 0o371, 0o411,
	0o412, 0o413, 0o423, 0o431, 0o432, 0o445, 0o446, 0o452, 0o454, 0o455, 0o462, 0o464, 0o465,
	0o466, 0o503, 0o506, 0o516, 0o523, 0o526, 0o532, 0o546, 0o565, 0o606, 0o612, 0o624, 0o627,
	0o631, 0o632, 0o654, 0o662, 0o664, 0o703, 0o712, 0o723, 0o731, 0o732, 0o734, 0o743, 0o754,
}

// IsStandard reports whether code is one of the 104 standard codes.
func IsStandard(code int) bool {
	_, ok := slices.BinarySearch(Codes, code)
	return ok
}

// Format renders a code as the three octal digits radios print: 0o23 is "023".
func Format(code int) string { return fmt.Sprintf("%03o", code) }

// Wire is a code as the contract's dcs_code carries it, its octal digits read as decimal:
// 0o23 is 23, 0o754 is 754.
func Wire(code int) uint32 {
	var out, scale uint32 = 0, 1
	for c := code; c > 0; c >>= 3 {
		out += uint32(c&7) * scale
		scale *= 10
	}
	return out
}

// FromWire is the inverse of Wire. It fails on a number with a digit of 8 or 9, or with more than
// three digits, which no DCS code has.
func FromWire(v uint32) (int, bool) {
	if v > 777 {
		return 0, false
	}
	code, shift := 0, 0
	for ; v > 0; v /= 10 {
		d := v % 10
		if d > 7 {
			return 0, false
		}
		code |= int(d) << shift
		shift += 3
	}
	return code, true
}

// data is the twelve data bits of a code as the coefficients of x^22..x^11, most significant
// first: the nine code bits low bit first, then 001.
func data(code int) uint32 {
	var v uint32
	for i := range 9 {
		v = v<<1 | uint32(code>>i&1)
	}
	return v<<3 | 0b001
}

// remainder is p(x) mod g(x) for a 23-bit polynomial p.
func remainder(p uint32) uint32 {
	for i := WordBits - 1; i >= 11; i-- {
		if p>>i&1 == 1 {
			p ^= Poly << (i - 11)
		}
	}
	return p
}

// Parity is the eleven parity bits of code, the first transmitted in bit 10: the remainder that
// makes the whole word divisible by g(x).
func Parity(code int) uint16 {
	return uint16(remainder(data(code) << 11))
}

// Encode is the word a transmitter sends for code, complemented when inverted. code must be in
// 0..0o777; the fixed bits and the parity are added here.
func Encode(code int, inverted bool) Word {
	if code < 0 || code > 0o777 {
		panic(fmt.Sprintf("dcs: code %o out of range", code))
	}
	p := data(code)<<11 | uint32(Parity(code))
	var w Word
	for i := range w {
		w[i] = byte(p >> (WordBits - 1 - i) & 1)
		if inverted {
			w[i] ^= 1
		}
	}
	return w
}

// poly is the word as a polynomial, the first bit the coefficient of x^22.
func (w Word) poly() uint32 {
	var p uint32
	for _, b := range w {
		p = p<<1 | uint32(b&1)
	}
	return p
}

// Valid reports whether w is a Golay(23,12) codeword under Poly. Every rotation of a codeword is
// one too, and so is its complement, which is why an inverted stream also passes.
func (w Word) Valid() bool { return remainder(w.poly()) == 0 }

// Rotate returns the word read starting k bits later: the 23 bits a receiver holds when its
// alignment is k bits off the transmitter's.
func (w Word) Rotate(k int) Word {
	k = ((k % WordBits) + WordBits) % WordBits
	var out Word
	for i := range out {
		out[i] = w[(i+k)%WordBits]
	}
	return out
}

// Complement is the word with every bit flipped.
func (w Word) Complement() Word {
	for i := range w {
		w[i] ^= 1
	}
	return w
}

// Reads lists the code w reads as at each rotation that is a codeword with 001 in place, standard
// or not, in rotation order. It is what Decode chooses from, and it shows why the fixed bits alone
// do not frame a word: 754's word reads 754, 076 and 203.
func (w Word) Reads() []int {
	var out []int
	for k := range WordBits {
		r := w.Rotate(k)
		if r[9] != 0 || r[10] != 0 || r[11] != 1 || !r.Valid() {
			continue
		}
		code := 0
		for i := range 9 {
			code |= int(r[i]) << i
		}
		out = append(out, code)
	}
	return out
}

// Decode names the code a received word carries, by the daemon's rule
// (docs/plans/signal-views.md, SV-7): of every rotation in the received polarity, the first whose
// code is standard, with inverted false; failing that, the same in the complemented polarity, with
// inverted true; failing both, ok is false and no code is named, rather than the nearest.
//
// The standard list is closed under inversion: every code's complemented word reads as exactly one
// other standard code (023 inverted reads 047, 754 inverted reads 116). Under this rule a standard
// code sent inverted is therefore named as its partner sent normal, and inverted comes back false
// for every word. The two readings are one signal on the air; TestListIsClosedUnderInversion pins
// the fact.
func Decode(w Word) (code int, inverted, ok bool) {
	for _, pol := range []struct {
		w   Word
		inv bool
	}{{w, false}, {w.Complement(), true}} {
		for _, c := range pol.w.Reads() {
			if IsStandard(c) {
				return c, pol.inv, true
			}
		}
	}
	return 0, false, false
}
