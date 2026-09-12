// SPDX-License-Identifier: Apache-2.0

package aprs

import (
	"math"
	"strconv"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

const (
	knotsToKmh = 1.852
	feetToM    = 0.3048
)

// parsePosition reads either form of position report and whatever the comment
// carries with it: course and speed, an altitude, or weather.
func parsePosition(rec *leylinev1.DecodeRecord, s string) {
	rec.Kind = KindPosition
	if s == "" {
		other(rec, s)
		return
	}
	if isCompressedTable(s[0]) && len(s) >= 13 {
		parseCompressed(rec, s)
		return
	}
	if len(s) < 19 {
		other(rec, s)
		return
	}
	lat, latOK := parseLatitude(s[0:8])
	lon, lonOK := parseLongitude(s[9:18])
	if !latOK || !lonOK {
		other(rec, s)
		return
	}
	rec.Position = &leylinev1.Position{Latitude: lat, Longitude: lon}
	symTable, symCode := s[8], s[18]
	rec.Fields["symbol"] = text(string([]byte{symTable, symCode}))
	rest := s[19:]
	// Course and speed sit immediately after the symbol as CSE/SPD, three
	// digits each; a weather report puts wind direction and speed in the same
	// place and marks itself with the _ symbol.
	if len(rest) >= 7 && rest[3] == '/' && allDigits(rest[0:3]) && allDigits(rest[4:7]) {
		c, _ := strconv.Atoi(rest[0:3])
		sp, _ := strconv.Atoi(rest[4:7])
		if symCode == '_' {
			rec.Fields["wind_dir_deg"] = number(float64(c))
			rec.Fields["wind_kmh"] = number(float64(sp) * mphToKmh)
		} else {
			rec.Fields["course_deg"] = number(float64(c))
			rec.Fields["speed_kmh"] = number(float64(sp) * knotsToKmh)
		}
		rest = rest[7:]
	}
	finishComment(rec, rest, symCode == '_')
}

// isCompressedTable reports whether a byte is a compressed report's symbol
// table identifier, which is what tells the two position forms apart.
func isCompressedTable(c byte) bool {
	return c == '/' || c == '\\' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'j')
}

// parseCompressed reads the 13-character compressed form: table, four base-91
// latitude characters, four longitude, symbol code, two characters of course
// and speed or of altitude, and a compression type byte.
func parseCompressed(rec *leylinev1.DecodeRecord, s string) {
	latV := base91(s[1:5])
	lonV := base91(s[5:9])
	rec.Position = &leylinev1.Position{
		Latitude:  90 - float64(latV)/380926,
		Longitude: -180 + float64(lonV)/190463,
	}
	rec.Fields["symbol"] = text(string([]byte{s[0], s[9]}))
	c, sp, typ := s[10], s[11], s[12]
	switch {
	case c == ' ':
		// No course, speed or altitude in this report.
	case c == '{':
		// Pre-calculated radio range rather than movement.
		rec.Fields["range_km"] = number(2 * math.Pow(1.08, float64(sp-33)) * 1.609344)
	case int(typ-33)&0x18 == 0x10:
		// The compression type byte says the fix came from a GGA sentence, so
		// the cs pair is an altitude in feet rather than movement.
		m := math.Pow(1.002, float64(base91(s[10:12]))) * feetToM
		rec.Position.AltitudeM = &m
	case c >= '!' && c <= 'z':
		rec.Fields["course_deg"] = number(float64(c-33) * 4)
		rec.Fields["speed_kmh"] = number((math.Pow(1.08, float64(sp-33)) - 1) * knotsToKmh)
	}
	finishComment(rec, s[13:], s[9] == '_')
}

// base91 reads the printable base-91 encoding compressed reports use.
func base91(s string) int {
	v := 0
	for i := 0; i < len(s); i++ {
		v = v*91 + int(s[i]) - 33
	}
	return v
}

// finishComment pulls the things that can hide in a comment -- an altitude, a
// weather report -- and keeps the rest verbatim.
func finishComment(rec *leylinev1.DecodeRecord, s string, weather bool) {
	if i := strings.Index(s, "/A="); i >= 0 && len(s) >= i+9 && allDigits(s[i+3:i+9]) {
		ft, _ := strconv.Atoi(s[i+3 : i+9])
		m := float64(ft) * feetToM
		if rec.Position != nil {
			rec.Position.AltitudeM = &m
		}
		s = s[:i] + s[i+9:]
	}
	if weather {
		s = parseWeatherFields(rec, s)
		rec.Kind = KindWeather
	}
	if s = strings.TrimRight(s, " "); s != "" {
		rec.Fields["comment"] = text(s)
	}
}

// parseLatitude reads DDMM.hhN, where spaces in the minutes are the ambiguity
// the sender asked for; the position returned is the centre of that box.
func parseLatitude(s string) (float64, bool) {
	if len(s) != 8 || s[4] != '.' {
		return 0, false
	}
	deg, err := strconv.Atoi(s[0:2])
	if err != nil {
		return 0, false
	}
	min, ok := ambiguousMinutes(s[2:4] + s[5:7])
	if !ok {
		return 0, false
	}
	v := float64(deg) + min/60
	switch s[7] {
	case 'N', 'n':
	case 'S', 's':
		v = -v
	default:
		return 0, false
	}
	return v, true
}

// parseLongitude reads DDDMM.hhW.
func parseLongitude(s string) (float64, bool) {
	if len(s) != 9 || s[5] != '.' {
		return 0, false
	}
	deg, err := strconv.Atoi(s[0:3])
	if err != nil {
		return 0, false
	}
	min, ok := ambiguousMinutes(s[3:5] + s[6:8])
	if !ok {
		return 0, false
	}
	v := float64(deg) + min/60
	switch s[8] {
	case 'W', 'w':
		v = -v
	case 'E', 'e':
	default:
		return 0, false
	}
	return v, true
}

// ambiguousMinutes reads MMhh with trailing spaces standing for digits the
// sender withheld, and answers the middle of the range they cover.
func ambiguousMinutes(s string) (float64, bool) {
	digits := []byte(s)
	blanks := 0
	for i := len(digits) - 1; i >= 0; i-- {
		if digits[i] != ' ' {
			break
		}
		digits[i] = '5'
		blanks++
	}
	for i := 0; i < len(digits)-blanks; i++ {
		if digits[i] < '0' || digits[i] > '9' {
			return 0, false
		}
	}
	for i := len(digits) - blanks; i < len(digits); i++ {
		if i < 2 {
			digits[i] = '5' // a withheld whole minute
		}
	}
	mm, err := strconv.Atoi(string(digits[0:2]))
	if err != nil {
		return 0, false
	}
	hh, err := strconv.Atoi(string(digits[2:4]))
	if err != nil {
		return 0, false
	}
	return float64(mm) + float64(hh)/100, true
}
