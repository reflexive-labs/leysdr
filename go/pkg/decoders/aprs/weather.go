// SPDX-License-Identifier: Apache-2.0

package aprs

import (
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

const (
	mphToKmh       = 1.609344
	hundredthsInMM = 0.254
)

// parsePositionlessWeather reads the _ form: an eight-digit MDHM timestamp
// followed by the same weather groups a position report carries.
func parsePositionlessWeather(rec *leylinev1.DecodeRecord, s string) {
	rec.Kind = KindWeather
	if len(s) >= 8 && allDigits(s[:8]) {
		s = s[8:]
	}
	// The wind direction and speed lead the groups in this form too, either as
	// c and s groups or as the bare dir/speed pair.
	if len(s) >= 7 && s[3] == '/' && allDigits(s[0:3]) && allDigits(s[4:7]) {
		d, _ := strconv.Atoi(s[0:3])
		sp, _ := strconv.Atoi(s[4:7])
		rec.Fields["wind_dir_deg"] = number(float64(d))
		rec.Fields["wind_kmh"] = number(float64(sp) * mphToKmh)
		s = s[7:]
	}
	if rest := parseWeatherFields(rec, s); rest != "" {
		rec.Fields["comment"] = text(rest)
	}
}

// parseWeatherFields reads the letter-prefixed groups of a weather report and
// returns what was left over. Units follow the record's field names: degrees
// Celsius, km/h, millimetres, hPa.
func parseWeatherFields(rec *leylinev1.DecodeRecord, s string) string {
	var rest strings.Builder
	for i := 0; i < len(s); {
		key := s[i]
		width, ok := weatherWidth(key)
		if !ok || i+1+width > len(s) {
			rest.WriteByte(s[i])
			i++
			continue
		}
		raw := s[i+1 : i+1+width]
		v, err := strconv.Atoi(strings.TrimLeft(raw, " "))
		if err != nil {
			// A group whose digits are missing (". . ." or blanks) is a reading
			// the station did not take, not a parse failure.
			i += 1 + width
			continue
		}
		switch key {
		case 'c':
			rec.Fields["wind_dir_deg"] = number(float64(v))
		case 's':
			rec.Fields["wind_kmh"] = number(float64(v) * mphToKmh)
		case 'g':
			rec.Fields["gust_kmh"] = number(float64(v) * mphToKmh)
		case 't':
			rec.Fields["temp_c"] = number((float64(v) - 32) * 5 / 9)
		case 'r':
			rec.Fields["rain_mm_1h"] = number(float64(v) * hundredthsInMM)
		case 'p':
			rec.Fields["rain_mm_24h"] = number(float64(v) * hundredthsInMM)
		case 'P':
			rec.Fields["rain_mm_midnight"] = number(float64(v) * hundredthsInMM)
		case 'h':
			if v == 0 {
				v = 100 // h00 is 100% humidity, not none
			}
			rec.Fields["humidity_pct"] = number(float64(v))
		case 'b':
			rec.Fields["pressure_hpa"] = number(float64(v) / 10)
		case 'L', 'l':
			rec.Fields["luminosity_wm2"] = number(float64(v))
		case 'S':
			rec.Fields["snow_mm_24h"] = number(float64(v) * 25.4)
		}
		i += 1 + width
	}
	return strings.TrimRight(rest.String(), " ")
}

// weatherWidth is how many characters each group's value takes.
func weatherWidth(key byte) (int, bool) {
	switch key {
	case 'c', 's', 'g', 't', 'r', 'p', 'P', 'L', 'S':
		return 3, true
	case 'h':
		return 2, true
	case 'b':
		return 5, true
	case 'l':
		return 3, true
	}
	return 0, false
}
