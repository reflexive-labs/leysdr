// SPDX-License-Identifier: Apache-2.0

package modes

import (
	"errors"
	"fmt"
	"math"
	"strings"
)

// Message is one Mode S reply, parsed. The parser does not check parity: the demodulator has
// already accepted the message on its syndrome and recovered Addr for the formats that carry the
// address in the parity.
type Message struct {
	Raw  []byte // the 7 or 14 bytes
	DF   int    // downlink format
	Addr uint32 // the 24-bit aircraft address
	// TC is the extended squitter's type code (DF17 and DF18), 0 for other formats.
	TC int

	Callsign string // identification, trailing spaces trimmed
	Category string // identification: emitter category set and code, "A3"; empty when none is sent

	HasAlt bool
	AltFt  int // barometric altitude, or GNSS height for TC 20 to 22, in feet

	// HasCPR marks an airborne position's CPR fix: Odd is the format bit, LatCPR and LonCPR the
	// 17-bit encoded fractions. Surface marks a surface position (TC 5 to 8), whose CPR this
	// package does not decode.
	HasCPR         bool
	Odd            bool
	LatCPR, LonCPR uint32
	Surface        bool

	HasGS    bool
	GSKn     float64 // ground speed
	TrackDeg float64 // track over ground, degrees true
	HasVR    bool
	VRFpm    int // vertical rate, feet per minute, negative descending

	HasAirspeed bool
	AirspeedKn  float64 // velocity subtypes 3 and 4: indicated or true airspeed
	HasHeading  bool
	HeadingDeg  float64 // velocity subtypes 3 and 4: magnetic heading

	Squawk string // DF5 and DF21: the identity code, four octal digits
}

// Kind is the record kind the message makes: identification, position, velocity or
// surveillance.
func (m *Message) Kind() string {
	switch {
	case m.TC >= 1 && m.TC <= 4:
		return KindIdentification
	case m.TC >= 5 && m.TC <= 18, m.TC >= 20 && m.TC <= 22:
		return KindPosition
	case m.TC == 19:
		return KindVelocity
	}
	return KindSurveillance
}

// Record kinds.
const (
	KindIdentification = "identification"
	KindPosition       = "position"
	KindVelocity       = "velocity"
	KindSurveillance   = "surveillance"
)

// bits reads n bits of msg starting at bit i, MSB first, bit 0 the first bit of the message.
func bits(msg []byte, i, n int) uint32 {
	var v uint32
	for k := i; k < i+n; k++ {
		v = v<<1 | uint32(msg[k/8]>>(7-k%8)&1)
	}
	return v
}

// me reads n bits of an extended squitter's ME field starting at ME bit i, numbered from 1 as the
// published tables number them.
func me(msg []byte, i, n int) uint32 { return bits(msg, 32+i-1, n) }

// msgBits is the length of a reply in bits by its downlink format: formats 16 and up are long.
func msgBits(df int) int {
	if df >= 16 {
		return 112
	}
	return 56
}

// errUnhandled is a format or type code this package does not decode.
var errUnhandled = errors.New("modes: format not decoded")

// Parse reads a reply whose parity the caller has accepted. addr is the address the parity
// recovered, used for DF4, DF5, DF20 and DF21; the other formats carry their own.
func Parse(raw []byte, addr uint32) (*Message, error) {
	if len(raw) != 7 && len(raw) != 14 {
		return nil, fmt.Errorf("modes: a reply is 7 or 14 bytes, not %d", len(raw))
	}
	m := &Message{Raw: raw, DF: int(raw[0] >> 3)}
	if msgBits(m.DF) != len(raw)*8 {
		return nil, fmt.Errorf("modes: DF%d is %d bits, not %d", m.DF, msgBits(m.DF), len(raw)*8)
	}
	switch m.DF {
	case 11:
		m.Addr = bits(raw, 8, 24)
	case 4, 20:
		m.Addr = addr
		m.AltFt, m.HasAlt = decodeAC13(bits(raw, 19, 13))
	case 5, 21:
		m.Addr = addr
		m.Squawk = squawk(bits(raw, 19, 13))
	case 17, 18:
		if m.DF == 18 {
			// CF 0 and 6 carry an ICAO address, CF 1 a non-ICAO one; the TIS-B formats carry
			// another layout.
			if cf := raw[0] & 7; cf != 0 && cf != 1 && cf != 6 {
				return nil, errUnhandled
			}
		}
		m.Addr = bits(raw, 8, 24)
		m.TC = int(me(raw, 1, 5))
		if err := m.parseES(); err != nil {
			return nil, err
		}
	default:
		return nil, errUnhandled
	}
	return m, nil
}

// parseES decodes the ME field of an extended squitter by its type code.
func (m *Message) parseES() error {
	r := m.Raw
	switch tc := m.TC; {
	case tc >= 1 && tc <= 4:
		m.Callsign = callsign(r)
		if ca := me(r, 6, 3); ca != 0 {
			m.Category = fmt.Sprintf("%c%d", "DCBA"[tc-1], ca)
		}
	case tc >= 5 && tc <= 8:
		m.Surface = true
	case tc >= 9 && tc <= 18, tc >= 20 && tc <= 22:
		alt := me(r, 9, 12)
		if tc >= 20 {
			// GNSS height above the ellipsoid, in metres.
			if alt != 0 {
				m.AltFt, m.HasAlt = int(math.Round(float64(alt)/0.3048)), true
			}
		} else {
			m.AltFt, m.HasAlt = decodeAC12(alt)
		}
		m.HasCPR = true
		m.Odd = me(r, 22, 1) == 1
		m.LatCPR = me(r, 23, 17)
		m.LonCPR = me(r, 40, 17)
	case tc == 19:
		return m.parseVelocity()
	default:
		return errUnhandled
	}
	return nil
}

// parseVelocity decodes an airborne velocity: subtypes 1 and 2 give ground speed as east-west and
// north-south components, 3 and 4 give airspeed and heading; 2 and 4 count in 4 kn steps.
func (m *Message) parseVelocity() error {
	r := m.Raw
	st := me(r, 6, 3)
	scale := 1.0
	if st == 2 || st == 4 {
		scale = 4
	}
	switch st {
	case 1, 2:
		vew, vns := me(r, 15, 10), me(r, 26, 10)
		if vew != 0 && vns != 0 {
			vx := float64(vew-1) * scale
			if me(r, 14, 1) == 1 { // westward
				vx = -vx
			}
			vy := float64(vns-1) * scale
			if me(r, 25, 1) == 1 { // southward
				vy = -vy
			}
			m.HasGS = true
			m.GSKn = math.Hypot(vx, vy)
			m.TrackDeg = math.Mod(math.Atan2(vx, vy)*180/math.Pi+360, 360)
		}
	case 3, 4:
		if me(r, 14, 1) == 1 {
			m.HasHeading = true
			m.HeadingDeg = float64(me(r, 15, 10)) * 360 / 1024
		}
		if as := me(r, 26, 10); as != 0 {
			m.HasAirspeed = true
			m.AirspeedKn = float64(as-1) * scale
		}
	default:
		return errUnhandled
	}
	if vr := me(r, 38, 9); vr != 0 {
		m.HasVR = true
		m.VRFpm = int(vr-1) * 64
		if me(r, 37, 1) == 1 {
			m.VRFpm = -m.VRFpm
		}
	}
	return nil
}

// callsignChars is the 6-bit character set of an identification message; '#' marks a code with
// no character.
const callsignChars = "#ABCDEFGHIJKLMNOPQRSTUVWXYZ##### ###############0123456789######"

func callsign(r []byte) string {
	var b strings.Builder
	for k := range 8 {
		b.WriteByte(callsignChars[me(r, 9+6*k, 6)])
	}
	return strings.TrimRight(b.String(), " ")
}

// decodeAC12 reads the 12-bit altitude of an airborne position: the 13-bit altitude code with
// its M bit removed.
func decodeAC12(v uint32) (int, bool) {
	return decodeAC13(v&0xFC0<<1 | v&0x3F)
}

// decodeAC13 reads a 13-bit altitude code, bits C1 A1 C2 A2 C4 A4 M B1 Q B2 D2 B4 D4. With Q set
// the other eleven bits count 25 ft from -1000 ft; with Q clear they are the Gillham code (the Q
// position then holds D1). A metric altitude (M set) and an all-zero code are not decoded.
func decodeAC13(v uint32) (int, bool) {
	if v == 0 || v&0x40 != 0 {
		return 0, false
	}
	if v&0x10 != 0 {
		n := v&0x1F80>>2 | v&0x20>>1 | v&0xF
		return int(n)*25 - 1000, true
	}
	return gillham(v)
}

// gillham decodes a Mode C (Gillham) altitude from the 13-bit code. The 500 ft steps are a Gray
// code on D1 D2 D4 A1 A2 A4 B1 B2 B4; the 100 ft steps within them are the C bits, which run
// 001, 011, 010, 110, 100 and are read backwards in odd 500 ft steps.
func gillham(v uint32) (int, bool) {
	bit := func(i uint) uint32 { return v >> i & 1 }
	c1, a1, c2, a2, c4, a4 := bit(12), bit(11), bit(10), bit(9), bit(8), bit(7)
	b1, d1, b2, d2, b4, d4 := bit(5), bit(4), bit(3), bit(2), bit(1), bit(0)
	g500 := d1<<8 | d2<<7 | d4<<6 | a1<<5 | a2<<4 | a4<<3 | b1<<2 | b2<<1 | b4
	n500 := grayToBinary(g500)
	n100 := grayToBinary(c1<<2 | c2<<1 | c4)
	switch n100 {
	case 0, 5, 6:
		return 0, false
	case 7:
		n100 = 5
	}
	if n500%2 == 1 {
		n100 = 6 - n100
	}
	return int(n500)*500 + int(n100)*100 - 1300, true
}

func grayToBinary(g uint32) uint32 {
	for s := g >> 1; s != 0; s >>= 1 {
		g ^= s
	}
	return g
}

// squawk reads the identity code from the 13-bit ID field, bits C1 A1 C2 A2 C4 A4 X B1 D1 B2 D2
// B4 D4, as the four octal digits ABCD.
func squawk(v uint32) string {
	bit := func(i uint) uint32 { return v >> i & 1 }
	a := bit(7)<<2 | bit(9)<<1 | bit(11)
	b := bit(1)<<2 | bit(3)<<1 | bit(5)
	c := bit(8)<<2 | bit(10)<<1 | bit(12)
	d := bit(0)<<2 | bit(2)<<1 | bit(4)
	return fmt.Sprintf("%d%d%d%d", a, b, c, d)
}
