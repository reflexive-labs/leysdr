// SPDX-License-Identifier: Apache-2.0

package modes

import (
	"math"
	"sort"
)

// Flight is a synthetic aircraft on a straight track, for the fixtures and tests: where it is at
// time 0 and how it moves.
type Flight struct {
	Addr     uint32
	Callsign string
	Squawk   string
	Lat, Lon float64
	AltFt    float64
	GSKn     float64
	TrackDeg float64
	VRFpm    int
}

// At is the flight's position and altitude t seconds after time 0, dead-reckoned on a flat earth,
// which over a few minutes is within metres of the great circle.
func (f Flight) At(t float64) (lat, lon, altFt float64) {
	const mPerKn, mPerDegLat = 1852.0 / 3600, 111_320.0
	d := f.GSKn * mPerKn * t
	rad := f.TrackDeg * math.Pi / 180
	lat = f.Lat + d*math.Cos(rad)/mPerDegLat
	lon = f.Lon + d*math.Sin(rad)/(mPerDegLat*math.Cos(f.Lat*math.Pi/180))
	return lat, lon, f.AltFt + float64(f.VRFpm)*t/60
}

// Transmission is one reply a synthetic flight sends, T seconds from time 0.
type Transmission struct {
	T    float64
	Addr uint32
	Msg  []byte
}

// Schedule is what the flights send in durationS seconds, in time order. Each flight sends an
// airborne position every 0.5 s, even and odd in turn; a velocity every second; an
// identification every 5 s; and every 2 s an all-call reply and, a second later, a surveillance
// altitude and an identity reply, as an aircraft under a ground radar does. Flight k's schedule
// starts 13.7 ms after flight k-1's, so no two replies overlap.
func Schedule(flights []Flight, durationS float64) []Transmission {
	var out []Transmission
	add := func(t float64, f Flight, msg []byte) {
		if t < durationS {
			out = append(out, Transmission{T: t, Addr: f.Addr, Msg: msg})
		}
	}
	for k, f := range flights {
		off := 0.0137 * float64(k)
		for i := 0; float64(i)*0.5 < durationS; i++ {
			t := off + float64(i)*0.5
			lat, lon, alt := f.At(t)
			add(t, f, EncodeAirbornePosition(f.Addr, alt, lat, lon, i%2 == 1))
		}
		for i := 0; float64(i) < durationS; i++ {
			t := off + float64(i) + 0.25
			add(t, f, EncodeVelocity(f.Addr, f.GSKn, f.TrackDeg, f.VRFpm))
			if i%5 == 0 {
				add(t+0.1, f, EncodeIdentification(f.Addr, f.Callsign, 3))
			}
			switch i % 2 {
			case 0:
				add(t+0.12, f, EncodeAllCall(f.Addr))
			case 1:
				_, _, alt := f.At(t + 0.12)
				add(t+0.12, f, EncodeSurveillanceAltitude(f.Addr, alt))
				if f.Squawk != "" {
					add(t+0.13, f, EncodeSurveillanceIdentity(f.Addr, f.Squawk))
				}
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].T < out[j].T })
	return out
}
