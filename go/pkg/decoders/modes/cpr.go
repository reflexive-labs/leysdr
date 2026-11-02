// SPDX-License-Identifier: Apache-2.0

package modes

import "math"

// Compact Position Reporting for airborne positions (DO-260B, appendix A): each position frame
// carries 17 bits of latitude and longitude as a fraction of a zone, and the zone itself is
// recovered from a pair of frames in the two formats (global decoding) or from a nearby reference
// position (local decoding). One frame alone never fixes a position.
const (
	cprNZ    = 15
	cprScale = 1 << 17
)

// nl is the number of longitude zones at latitude lat: 59 at the equator, falling to 1 at the
// poles.
func nl(lat float64) int {
	lat = math.Abs(lat)
	switch {
	case lat == 0:
		return 59
	case lat == 87:
		return 2
	case lat > 87:
		return 1
	}
	a := 1 - math.Cos(math.Pi/(2*cprNZ))
	c := math.Cos(math.Pi / 180 * lat)
	return int(math.Floor(2 * math.Pi / math.Acos(1-a/(c*c))))
}

// mod is the modulus with the sign of the divisor, as the CPR equations define it.
func mod(a, b float64) float64 {
	r := math.Mod(a, b)
	if r < 0 {
		r += b
	}
	return r
}

// cprGlobal decodes an even and an odd frame (17-bit fractions) received close together. oddLast
// says which arrived last; the position is that frame's. ok is false when the two frames fall in
// different longitude-zone bands, which happens when the aircraft crossed one between them.
func cprGlobal(latE, lonE, latO, lonO uint32, oddLast bool) (lat, lon float64, ok bool) {
	const dlatE, dlatO = 360.0 / 60, 360.0 / 59
	yE, yO := float64(latE)/cprScale, float64(latO)/cprScale
	xE, xO := float64(lonE)/cprScale, float64(lonO)/cprScale
	j := math.Floor(59*yE - 60*yO + 0.5)
	rlatE := dlatE * (mod(j, 60) + yE)
	rlatO := dlatO * (mod(j, 59) + yO)
	if rlatE >= 270 {
		rlatE -= 360
	}
	if rlatO >= 270 {
		rlatO -= 360
	}
	if rlatE < -90 || rlatE > 90 || rlatO < -90 || rlatO > 90 || nl(rlatE) != nl(rlatO) {
		return 0, 0, false
	}
	lat = rlatE
	x, i := xE, 0
	if oddLast {
		lat, x, i = rlatO, xO, 1
	}
	n := nl(lat)
	ni := max(n-i, 1)
	m := math.Floor(xE*float64(n-1) - xO*float64(n) + 0.5)
	lon = 360 / float64(ni) * (mod(m, float64(ni)) + x)
	if lon >= 180 {
		lon -= 360
	}
	return lat, lon, true
}

// cprLocal decodes one frame against a reference position within half a zone (about 180 NM) of
// it, which the aircraft's own last position is.
func cprLocal(latCPR, lonCPR uint32, odd bool, refLat, refLon float64) (lat, lon float64) {
	i := 0.0
	if odd {
		i = 1
	}
	y, x := float64(latCPR)/cprScale, float64(lonCPR)/cprScale
	dlat := 360 / (60 - i)
	j := math.Floor(refLat/dlat) + math.Floor(0.5+mod(refLat, dlat)/dlat-y)
	lat = dlat * (j + y)
	dlon := 360 / math.Max(float64(nl(lat))-i, 1)
	m := math.Floor(refLon/dlon) + math.Floor(0.5+mod(refLon, dlon)/dlon-x)
	lon = dlon * (m + x)
	lon = mod(lon+180, 360) - 180
	return lat, lon
}

// cprEncode is the transmitter's side: the 17-bit fractions of an airborne position in the even
// or odd format.
func cprEncode(lat, lon float64, odd bool) (latCPR, lonCPR uint32) {
	i := 0.0
	if odd {
		i = 1
	}
	dlat := 360 / (60 - i)
	yz := math.Floor(cprScale*mod(lat, dlat)/dlat + 0.5)
	rlat := dlat * (yz/cprScale + math.Floor(lat/dlat))
	dlon := 360 / math.Max(float64(nl(rlat))-i, 1)
	xz := math.Floor(cprScale*mod(lon, dlon)/dlon + 0.5)
	return uint32(int64(yz) & (cprScale - 1)), uint32(int64(xz) & (cprScale - 1))
}

// distanceKm is the great-circle distance between two positions.
func distanceKm(lat1, lon1, lat2, lon2 float64) float64 {
	const r = 6371.0
	p1, p2 := lat1*math.Pi/180, lat2*math.Pi/180
	dp, dl := p2-p1, (lon2-lon1)*math.Pi/180
	a := math.Sin(dp/2)*math.Sin(dp/2) + math.Cos(p1)*math.Cos(p2)*math.Sin(dl/2)*math.Sin(dl/2)
	return 2 * r * math.Asin(math.Min(1, math.Sqrt(a)))
}
