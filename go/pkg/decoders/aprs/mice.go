// SPDX-License-Identifier: Apache-2.0

package aprs

import (
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// micEMessages are the standard message texts the three message bits select.
// Bit values 0..7 run from emergency upwards in the spec's table; the custom
// set is reported as its number because only the sender knows what it means.
var micEMessages = [8]string{
	"emergency", "priority", "special", "committed",
	"returning", "in service", "en route", "off duty",
}

// parseMicE reads the form that encodes the latitude, the message bits, the N/S
// and E/W hemispheres and the longitude +100 offset in the AX.25 destination
// address. dest is the destination callsign, info the data after
// the type identifier.
func parseMicE(rec *leylinev1.DecodeRecord, dest, info string) {
	if len(dest) < 6 || len(info) < 8 {
		other(rec, info)
		return
	}
	rec.Kind = KindPosition

	var digits [6]byte
	var msgBits [3]bool
	custom := false
	for i := 0; i < 6; i++ {
		c := dest[i]
		switch {
		case c >= '0' && c <= '9':
			digits[i] = c
		case c >= 'A' && c <= 'J':
			digits[i], custom = c-'A'+'0', true
			if i < 3 {
				msgBits[i] = true
			}
		case c >= 'P' && c <= 'Y':
			digits[i] = c - 'P' + '0'
			if i < 3 {
				msgBits[i] = true
			}
		case c == 'K' || c == 'L' || c == 'Z':
			// The three ambiguity characters: K is custom, Z standard, L the
			// zero bit, and all three stand for a withheld digit.
			digits[i] = ' '
			if c == 'K' {
				custom = true
			}
			if i < 3 && c != 'L' {
				msgBits[i] = true
			}
		default:
			other(rec, info)
			return
		}
	}
	lat, ok := parseLatitude(string([]byte{
		digits[0], digits[1], digits[2], digits[3], '.', digits[4], digits[5], 'N',
	}))
	if !ok {
		other(rec, info)
		return
	}
	if !between(dest[3], 'P', 'Z') {
		lat = -lat
	}

	deg := int(info[0]) - 28
	if between(dest[4], 'P', 'Z') {
		deg += 100
	}
	switch {
	case deg >= 180 && deg <= 189:
		deg -= 80
	case deg >= 190 && deg <= 199:
		deg -= 190
	}
	min := int(info[1]) - 28
	if min >= 60 {
		min -= 60
	}
	hun := int(info[2]) - 28
	lon := float64(deg) + (float64(min)+float64(hun)/100)/60
	if between(dest[5], 'P', 'Z') {
		lon = -lon
	}
	rec.Position = &leylinev1.Position{Latitude: lat, Longitude: lon}

	speed := (int(info[3]) - 28) * 10
	dc := int(info[4]) - 28
	speed += dc / 10
	course := (dc%10)*100 + int(info[5]) - 28
	if speed >= 800 {
		speed -= 800
	}
	if course >= 400 {
		course -= 400
	}
	rec.Fields["speed_kmh"] = number(float64(speed) * knotsToKmh)
	rec.Fields["course_deg"] = number(float64(course))
	rec.Fields["symbol"] = text(string([]byte{info[7], info[6]}))

	// The three message bits read most significant first, and a custom set is
	// the sender's own vocabulary rather than the standard table.
	m := 0
	for i, b := range msgBits {
		if b {
			m |= 1 << (2 - i)
		}
	}
	if custom {
		// The custom table counts the other way: bits 111 are Custom-0.
		rec.Fields["mic_e_message"] = text("custom " + string(rune('0'+7-m)))
	} else {
		rec.Fields["mic_e_message"] = text(micEMessages[m])
	}

	rest := info[8:]
	// The comment can open with a Mic-E altitude: three base-91 characters and
	// a }, metres above 10 km below sea level.
	if i := strings.IndexByte(rest, '}'); i == 3 {
		alt := float64(base91(rest[:3]) - 10000)
		rec.Position.AltitudeM = &alt
		rest = rest[4:]
	}
	finishComment(rec, rest, info[6] == '_')
}

func between(c, lo, hi byte) bool { return c >= lo && c <= hi }
