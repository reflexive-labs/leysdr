// SPDX-License-Identifier: Apache-2.0

package modes

import (
	"encoding/hex"
	"math"
	mbits "math/bits"
	"testing"
)

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// parseClean checks a published extended squitter's parity and parses it.
func parseClean(t *testing.T, s string) *Message {
	t.Helper()
	raw := mustHex(t, s)
	if syn := Syndrome(raw); syn != 0 {
		t.Fatalf("%s: syndrome %06X, want 0", s, syn)
	}
	m, err := Parse(raw, 0)
	if err != nil {
		t.Fatalf("%s: %v", s, err)
	}
	return m
}

// The published identification example reads KLM1023 from 4840D6.
func TestIdentificationVector(t *testing.T) {
	m := parseClean(t, "8D4840D6202CC371C32CE0576098")
	if m.DF != 17 || m.Addr != 0x4840D6 || m.TC != 4 || m.Callsign != "KLM1023" {
		t.Errorf("got DF%d %06X TC%d %q, want DF17 4840D6 TC4 KLM1023", m.DF, m.Addr, m.TC, m.Callsign)
	}
	if m.Kind() != KindIdentification {
		t.Errorf("kind %q", m.Kind())
	}
}

// The published position pair: 38000 ft, and 52.2572, 3.91937 when the even frame is the later.
func TestPositionPairVector(t *testing.T) {
	a := parseClean(t, "8D40621D58C382D690C8AC2863A7")
	b := parseClean(t, "8D40621D58C386435CC412692AD6")
	if a.Odd || !b.Odd {
		t.Fatalf("format bits: first odd=%v, second odd=%v; want even then odd", a.Odd, b.Odd)
	}
	for _, m := range []*Message{a, b} {
		if !m.HasAlt || m.AltFt != 38000 || m.TC != 11 || !m.HasCPR {
			t.Errorf("%06X: alt %d (has %v) TC%d, want 38000 ft TC11", m.Addr, m.AltFt, m.HasAlt, m.TC)
		}
	}
	lat, lon, ok := cprGlobal(a.LatCPR, a.LonCPR, b.LatCPR, b.LonCPR, false)
	if !ok || math.Abs(lat-52.2572) > 1e-4 || math.Abs(lon-3.91937) > 1e-5 {
		t.Errorf("global decode (even last) %v, %v ok=%v; want 52.2572, 3.91937", lat, lon, ok)
	}
	// The odd frame's own position is its latitude 52.26578, 1.6 km from the even's: the
	// published frames were not sent together.
	lat2, lon2, ok := cprGlobal(a.LatCPR, a.LonCPR, b.LatCPR, b.LonCPR, true)
	if !ok || math.Abs(lat2-52.26578) > 1e-5 || distanceKm(lat, lon, lat2, lon2) > 2 {
		t.Errorf("global decode (odd last) %v, %v ok=%v; want near %v, %v", lat2, lon2, ok, lat, lon)
	}
	// A local decode of the even frame against a reference near it gives the same position.
	llat, llon := cprLocal(a.LatCPR, a.LonCPR, false, 52.258, 3.918)
	if math.Abs(llat-lat) > 1e-9 || math.Abs(llon-lon) > 1e-9 {
		t.Errorf("local decode %v, %v; want %v, %v", llat, llon, lat, lon)
	}
}

// The published velocity example: about 159 kn on a track of 182.9 degrees, descending at 832 ft
// a minute.
func TestVelocityVector(t *testing.T) {
	m := parseClean(t, "8D485020994409940838175B284F")
	if m.TC != 19 || !m.HasGS || !m.HasVR {
		t.Fatalf("TC%d gs=%v vr=%v", m.TC, m.HasGS, m.HasVR)
	}
	if math.Abs(m.GSKn-159.2) > 0.1 || math.Abs(m.TrackDeg-182.88) > 0.01 || m.VRFpm != -832 {
		t.Errorf("got %.2f kn, %.2f deg, %d fpm; want 159.20, 182.88, -832", m.GSKn, m.TrackDeg, m.VRFpm)
	}
	rec := m.Record()
	if rec.GetKind() != KindVelocity || rec.GetDeviceId() != "485020" ||
		rec.GetFields()["ground_speed_kn"].GetNumber() != 159.2 || rec.GetFields()["track_deg"].GetNumber() != 182.9 {
		t.Errorf("record %v", rec)
	}
}

// A corrupted bit in a 112-bit message leaves the syndrome of that bit alone, and fixOneBit
// restores the message; the DF field is never touched.
func TestSingleBitCorrection(t *testing.T) {
	good := mustHex(t, "8D4840D6202CC371C32CE0576098")
	for i := 5; i < 112; i++ {
		msg := append([]byte(nil), good...)
		msg[i/8] ^= 0x80 >> (i % 8)
		if !fixOneBit(msg, Syndrome(msg)) || string(msg) != string(good) {
			t.Fatalf("bit %d was not corrected", i)
		}
	}
	msg := append([]byte(nil), good...)
	msg[0] ^= 0x80
	if fixOneBit(msg, Syndrome(msg)) {
		t.Error("a flipped DF bit was corrected")
	}
}

// The surveillance formats carry the address in the parity: the syndrome recovers it.
func TestSurveillanceRoundTrip(t *testing.T) {
	const addr = 0xA1B2C3
	alt := EncodeSurveillanceAltitude(addr, 12375)
	if syn := Syndrome(alt); syn != addr {
		t.Fatalf("DF4 syndrome %06X, want %06X", syn, addr)
	}
	m, err := Parse(alt, Syndrome(alt))
	if err != nil || m.DF != 4 || m.Addr != addr || !m.HasAlt || m.AltFt != 12375 {
		t.Errorf("DF4: %+v %v", m, err)
	}
	for _, sq := range []string{"7700", "1200", "0000", "4321", "7777"} {
		id := EncodeSurveillanceIdentity(addr, sq)
		m, err := Parse(id, Syndrome(id))
		if err != nil || m.DF != 5 || m.Squawk != sq || m.Addr != addr {
			t.Errorf("DF5 %s: %+v %v", sq, m, err)
		}
	}
	ac := EncodeAllCall(addr)
	if Syndrome(ac) != 0 {
		t.Error("DF11 with interrogator code 0 must have syndrome 0")
	}
	if m, err := Parse(ac, 0); err != nil || m.DF != 11 || m.Addr != addr || m.Kind() != KindSurveillance {
		t.Errorf("DF11: %+v %v", m, err)
	}
}

// The Gillham code covers -1200 to 126700 ft in 100 ft steps, one code each, and neighbouring
// altitudes differ in one bit: that is what the reflected 100 ft steps are for.
func TestGillham(t *testing.T) {
	codes := map[int]uint32{}
	for v := uint32(0); v < 1<<13; v++ {
		if v&0x50 != 0 { // M and Q (D1) clear
			continue
		}
		if alt, ok := decodeAC13(v); ok {
			if prev, dup := codes[alt]; dup {
				t.Fatalf("%d ft from %013b and %013b", alt, prev, v)
			}
			codes[alt] = v
		}
	}
	for alt := -1200; alt <= 126700; alt += 100 {
		c, ok := codes[alt]
		if !ok {
			t.Fatalf("no code for %d ft", alt)
		}
		if n, ok := codes[alt+100]; ok && mbits.OnesCount32(c^n) != 1 {
			t.Errorf("%d and %d ft differ in %d bits", alt, alt+100, mbits.OnesCount32(c^n))
		}
	}
	if len(codes) != (126700+1200)/100+1 {
		t.Errorf("%d altitudes decoded", len(codes))
	}
}

// What the encoders write, Parse reads back.
func TestEncodeRoundTrip(t *testing.T) {
	const addr = 0xACEB61
	m, err := Parse(EncodeIdentification(addr, "N123AB", 3), 0)
	if err != nil || m.Callsign != "N123AB" || m.Category != "A3" {
		t.Errorf("identification: %+v %v", m, err)
	}
	for _, alt := range []float64{-1000, 0, 2525, 38000, 45000} {
		for _, odd := range []bool{false, true} {
			raw := EncodeAirbornePosition(addr, alt, 37.6189, -122.3750, odd)
			if Syndrome(raw) != 0 {
				t.Fatal("bad parity")
			}
			m, err := Parse(raw, 0)
			if err != nil || !m.HasAlt || m.AltFt != int(alt) || m.Odd != odd {
				t.Errorf("position %v ft odd=%v: %+v %v", alt, odd, m, err)
			}
		}
	}
	m, err = Parse(EncodeVelocity(addr, 250, 290, -1216), 0)
	if err != nil || math.Abs(m.GSKn-250) > 1 || math.Abs(m.TrackDeg-290) > 0.5 || m.VRFpm != -1216 {
		t.Errorf("velocity: %+v %v", m, err)
	}
}

// Encoding then decoding a pair anywhere on the globe returns the position to within the CPR
// resolution, about 5 m.
func TestCPRRoundTrip(t *testing.T) {
	for _, p := range [][2]float64{{37.6189, -122.375}, {-33.9, 151.2}, {0.1, 0.1}, {-0.1, -179.9}, {71.3, 25.8}, {86.5, -45}, {52.2572, 3.91937}} {
		le, oe := cprEncode(p[0], p[1], false)
		lo, oo := cprEncode(p[0], p[1], true)
		for _, oddLast := range []bool{false, true} {
			lat, lon, ok := cprGlobal(le, oe, lo, oo, oddLast)
			if !ok || distanceKm(lat, lon, p[0], p[1]) > 0.01 {
				t.Errorf("%v oddLast=%v: %v, %v ok=%v", p, oddLast, lat, lon, ok)
			}
		}
		lat, lon := cprLocal(le, oe, false, p[0]+0.3, p[1]-0.3)
		if distanceKm(lat, lon, p[0], p[1]) > 0.01 {
			t.Errorf("%v local: %v, %v", p, lat, lon)
		}
	}
}

// A local decode near the antimeridian lands in [-180, 180) whichever side the reference is on.
func TestCPRLocalAntimeridian(t *testing.T) {
	cases := []struct{ refLon, lon float64 }{
		{-179.99, 179.995}, // reference west of the line, aircraft east of it
		{179.99, -179.995}, // reference east of the line, aircraft west of it
	}
	for _, c := range cases {
		for _, odd := range []bool{false, true} {
			latCPR, lonCPR := cprEncode(50.01, c.lon, odd)
			lat, lon := cprLocal(latCPR, lonCPR, odd, 50, c.refLon)
			if lon < -180 || lon >= 180 || distanceKm(lat, lon, 50.01, c.lon) > 0.01 {
				t.Errorf("ref lon %v, odd=%v: %v, %v; want 50.01, %v", c.refLon, odd, lat, lon, c.lon)
			}
		}
	}
}

// A 6-bit code with no character reads as '?', so the callsign shows it as unknown.
func TestCallsignInvalidCode(t *testing.T) {
	msg := EncodeIdentification(0xACEB61, "N123AB", 0)
	putME(msg, 9+6*1, 6, 0)  // code 0: no character
	putME(msg, 9+6*3, 6, 27) // code 27: no character
	SetParity(msg, 0)
	m, err := Parse(msg, 0)
	if err != nil || m.Callsign != "N?2?AB" {
		t.Errorf("callsign %q, err %v; want N?2?AB", m.Callsign, err)
	}
}
