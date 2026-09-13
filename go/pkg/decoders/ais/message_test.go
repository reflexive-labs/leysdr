// SPDX-License-Identifier: Apache-2.0

package ais

import (
	"math"
	"testing"
)

// unarmor turns an AIVDM payload string into the message bytes: each character
// carries six bits (subtract 48, subtract another 8 if the result exceeds 40),
// concatenated MSB first, then packed into octets MSB first -- which is the
// same byte order the HDLC deframer produces on the air.
func unarmor(s string) []byte {
	bits := make([]bool, 0, len(s)*6)
	for _, c := range s {
		v := int(c) - 48
		if v > 40 {
			v -= 8
		}
		for k := 5; k >= 0; k-- {
			bits = append(bits, v>>uint(k)&1 != 0)
		}
	}
	out := make([]byte, (len(bits)+7)/8)
	for i, b := range bits {
		if b {
			out[i/8] |= 1 << (7 - uint(i%8))
		}
	}
	return out
}

// TestParseType1 decodes the published gpsd Type 1 example
// (!AIVDM,1,1,,B,177KQJ5000G?tO`K>RA1wUbN0TKH,0*5C): MMSI 477553000, moored in
// Puget Sound. The values here are the exact decode of that payload, which is
// what pins the big-endian bit-field reader.
func TestParseType1(t *testing.T) {
	m, err := Parse(unarmor("177KQJ5000G?tO`K>RA1wUbN0TKH"))
	if err != nil {
		t.Fatal(err)
	}
	if m.Type != 1 {
		t.Errorf("type %d, want 1", m.Type)
	}
	if m.MMSI != 477553000 {
		t.Errorf("mmsi %d, want 477553000", m.MMSI)
	}
	if !m.HasPos {
		t.Fatal("no position decoded")
	}
	if math.Abs(m.Lat-47.58283) > 0.0001 || math.Abs(m.Lon-(-122.34583)) > 0.0001 {
		t.Errorf("position %.5f,%.5f, want ~47.58283,-122.34583", m.Lat, m.Lon)
	}
	if !m.HasSOG || m.SOG != 0 {
		t.Errorf("sog %v (has %v), want 0", m.SOG, m.HasSOG)
	}
	if !m.HasCOG || math.Abs(m.COG-51.0) > 0.05 {
		t.Errorf("course %v (has %v), want 51.0", m.COG, m.HasCOG)
	}
	if !m.HasNav || m.NavStatus != 5 {
		t.Errorf("nav status %d (has %v), want 5 (moored)", m.NavStatus, m.HasNav)
	}
}

// TestParseType5 decodes the canonical two-part Type 5 example, EVER DIADEM
// bound for New York. The two AIVDM payloads are concatenated before decoding,
// which is how a multi-sentence message is reassembled.
func TestParseType5(t *testing.T) {
	const p1 = "55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8"
	const p2 = "88888888880"
	m, err := Parse(unarmor(p1 + p2))
	if err != nil {
		t.Fatal(err)
	}
	if m.Type != 5 {
		t.Errorf("type %d, want 5", m.Type)
	}
	if m.MMSI != 351759000 {
		t.Errorf("mmsi %d, want 351759000", m.MMSI)
	}
	if m.Name != "EVER DIADEM" {
		t.Errorf("name %q, want %q", m.Name, "EVER DIADEM")
	}
	if m.Callsign != "3FOF8" {
		t.Errorf("callsign %q, want %q", m.Callsign, "3FOF8")
	}
	if m.Dest != "NEW YORK" {
		t.Errorf("destination %q, want %q", m.Dest, "NEW YORK")
	}
	if !m.HasType || m.ShipType != 70 {
		t.Errorf("ship type %d (has %v), want 70 (cargo)", m.ShipType, m.HasType)
	}
}

// TestRecordShape checks the record a position message becomes: kind, the MMSI
// as device_id, and a filled position.
func TestRecordShape(t *testing.T) {
	m, err := Parse(unarmor("177KQJ5000G?tO`K>RA1wUbN0TKH"))
	if err != nil {
		t.Fatal(err)
	}
	rec := m.Record()
	if rec.Protocol != "ais" || rec.DeviceId != "477553000" || rec.Kind != KindPosition {
		t.Errorf("record is protocol=%q device=%q kind=%q", rec.Protocol, rec.DeviceId, rec.Kind)
	}
	if rec.Position == nil {
		t.Error("position report produced a record with no position")
	}
}
