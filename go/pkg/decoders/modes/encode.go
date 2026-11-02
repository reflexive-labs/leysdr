// SPDX-License-Identifier: Apache-2.0

package modes

import (
	"math"
	"strings"
)

// The transmitter's side, for synthetic signals: the test fixtures and leyfix build replies with
// these and render them as pulses, so the generator and the decoder share one definition of each
// format.

// putBits writes the low n bits of v into msg starting at bit i, MSB first.
func putBits(msg []byte, i, n int, v uint32) {
	for k := range n {
		b := i + k
		if v>>(n-1-k)&1 != 0 {
			msg[b/8] |= 0x80 >> (b % 8)
		} else {
			msg[b/8] &^= 0x80 >> (b % 8)
		}
	}
}

// putME writes into the ME field, bits numbered from 1.
func putME(msg []byte, i, n int, v uint32) { putBits(msg, 32+i-1, n, v) }

// es starts a DF17 extended squitter from addr with capability 5 (airborne, level 2 or above).
func es(addr uint32, tc int) []byte {
	msg := make([]byte, 14)
	putBits(msg, 0, 5, 17)
	putBits(msg, 5, 3, 5)
	putBits(msg, 8, 24, addr)
	putME(msg, 1, 5, uint32(tc))
	return msg
}

// EncodeIdentification is a DF17 identification (TC 4, emitter category set A) with category code
// ca, 0 for none.
func EncodeIdentification(addr uint32, call string, ca int) []byte {
	msg := es(addr, 4)
	putME(msg, 6, 3, uint32(ca))
	call = strings.ToUpper(call)
	for k := range 8 {
		c := uint32(32) // space
		if k < len(call) {
			if i := strings.IndexByte(callsignChars, call[k]); i > 0 {
				c = uint32(i)
			}
		}
		putME(msg, 9+6*k, 6, c)
	}
	SetParity(msg, 0)
	return msg
}

// EncodeAirbornePosition is a DF17 airborne position with barometric altitude (TC 11) in the
// even or odd CPR format. The altitude is rounded to 25 ft.
func EncodeAirbornePosition(addr uint32, altFt float64, lat, lon float64, odd bool) []byte {
	msg := es(addr, 11)
	putME(msg, 9, 12, encodeAC12(altFt))
	if odd {
		putME(msg, 22, 1, 1)
	}
	la, lo := cprEncode(lat, lon, odd)
	putME(msg, 23, 17, la)
	putME(msg, 40, 17, lo)
	SetParity(msg, 0)
	return msg
}

// EncodeVelocity is a DF17 airborne velocity, subtype 1 (subsonic ground speed).
func EncodeVelocity(addr uint32, gsKn, trackDeg float64, vrFpm int) []byte {
	msg := es(addr, 19)
	putME(msg, 6, 3, 1)
	rad := trackDeg * math.Pi / 180
	vx, vy := math.Round(gsKn*math.Sin(rad)), math.Round(gsKn*math.Cos(rad))
	if vx < 0 {
		putME(msg, 14, 1, 1)
	}
	putME(msg, 15, 10, uint32(math.Abs(vx))+1)
	if vy < 0 {
		putME(msg, 25, 1, 1)
	}
	putME(msg, 26, 10, uint32(math.Abs(vy))+1)
	putME(msg, 36, 1, 1) // vertical rate source: barometric
	if vrFpm < 0 {
		putME(msg, 37, 1, 1)
	}
	putME(msg, 38, 9, uint32(math.Round(math.Abs(float64(vrFpm))/64))+1)
	SetParity(msg, 0)
	return msg
}

// EncodeAllCall is a DF11 all-call reply with interrogator code 0.
func EncodeAllCall(addr uint32) []byte {
	msg := make([]byte, 7)
	putBits(msg, 0, 5, 11)
	putBits(msg, 5, 3, 5)
	putBits(msg, 8, 24, addr)
	SetParity(msg, 0)
	return msg
}

// EncodeSurveillanceAltitude is a DF4 altitude reply, its address in the parity.
func EncodeSurveillanceAltitude(addr uint32, altFt float64) []byte {
	msg := make([]byte, 7)
	putBits(msg, 0, 5, 4)
	putBits(msg, 19, 13, encodeAC13(altFt))
	SetParity(msg, addr)
	return msg
}

// EncodeSurveillanceIdentity is a DF5 identity reply with the four octal digits of squawk, its
// address in the parity.
func EncodeSurveillanceIdentity(addr uint32, squawk string) []byte {
	msg := make([]byte, 7)
	putBits(msg, 0, 5, 5)
	dig := func(k int) uint32 { return uint32(squawk[k] - '0') }
	a, b, c, d := dig(0), dig(1), dig(2), dig(3)
	// Each digit's bits 1, 2 and 4 and where they sit in the field.
	var v uint32
	for _, p := range []struct {
		digit      uint32
		b1, b2, b4 uint
	}{{a, 11, 9, 7}, {b, 5, 3, 1}, {c, 12, 10, 8}, {d, 4, 2, 0}} {
		v |= p.digit&1<<p.b1 | p.digit>>1&1<<p.b2 | p.digit>>2&1<<p.b4
	}
	putBits(msg, 19, 13, v)
	SetParity(msg, addr)
	return msg
}

// encodeAC13 is a 13-bit altitude code in 25 ft steps (Q set).
func encodeAC13(altFt float64) uint32 {
	n := uint32(math.Round((altFt + 1000) / 25))
	return n&0x7E0<<2 | n&0x10<<1 | 0x10 | n&0xF
}

// encodeAC12 is encodeAC13 with the M bit removed.
func encodeAC12(altFt float64) uint32 {
	v := encodeAC13(altFt)
	return v&0x1F80>>1 | v&0x3F
}

// Pulses lists a reply's pulses, preamble included, as start and end in µs from the frame start,
// adjacent half-bits merged into one pulse.
func Pulses(msg []byte) [][2]float64 {
	out := append([][2]float64(nil), preamblePulses[:]...)
	for k := range len(msg) * 8 {
		s := preambleUs + float64(k)
		if msg[k/8]>>(7-k%8)&1 == 0 {
			s += 0.5
		}
		if last := &out[len(out)-1]; last[1] == s {
			last[1] = s + 0.5
		} else {
			out = append(out, [2]float64{s, s + 0.5})
		}
	}
	return out
}

// Render adds a reply's pulse envelope, sampled at rate, to env: env[i] is sample first+i, and
// the frame starts at sample position start, which may fall between samples. Each sample is the
// part of its interval the pulses cover, the output of an ideal integrate-and-dump receiver.
func Render(msg []byte, rate, start float64, env []float64, first int64) {
	spu := rate / 1e6
	for _, p := range Pulses(msg) {
		a, b := start+p[0]*spu, start+p[1]*spu
		for k := int64(math.Floor(a)); float64(k) < b; k++ {
			i := k - first
			if i < 0 || i >= int64(len(env)) {
				continue
			}
			lo, hi := math.Max(a, float64(k)), math.Min(b, float64(k+1))
			if hi > lo {
				env[i] += hi - lo
			}
		}
	}
}

// FrameUs is a reply's length in µs, preamble included.
func FrameUs(msg []byte) float64 { return preambleUs + float64(len(msg)*8) }
