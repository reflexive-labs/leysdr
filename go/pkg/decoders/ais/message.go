// SPDX-License-Identifier: Apache-2.0

// Package ais decodes AIS (Automatic Identification System) marine traffic:
// GMSK at 9600 bit/s on the two VHF channels 161.975 MHz (AIS 1) and
// 162.025 MHz (AIS 2), framed exactly as AX.25 is -- HDLC flags, bit stuffing
// and the X.25 FCS -- which is why frame.go leans on pkg/decoders/ax25 rather
// than repeating it. What is not shared is the payload: AIS packs a big-endian
// bit field, read here MSB first, where APRS carries text.
//
// The receive chain is GMSK-from-discriminator (gmsk.go): the demod tap of an
// NFM channel is instantaneous frequency, and for MSK/GMSK a 1 and a 0 are
// plus and minus a quarter-baud of deviation, so slicing the sign of the
// integrated discriminator and clocking it with a PLL recovers the wire bits,
// then NRZI. This is the same idea as pkg/decoders/afsk, on one axis instead of
// two, and it is why the manifest asks for TAP_DEMOD, not TAP_AUDIO.
//
// Only the fields docs/design/decoders.md (driver A, "vessels") needs are
// parsed: position from types 1, 2, 3, 18 and 19, static data from 5 and 24.
// Nothing is guessed -- a type this parser does not model becomes kind "other"
// with its type number, which is the rule invariant 12 states for the detector.
package ais

import (
	"errors"
	"math"
)

// Protocol is the manifest name this parser fills into DecodeRecord.protocol.
const Protocol = "ais"

// Kinds of record, the values DecodeRecord.kind takes.
const (
	KindPosition = "position"
	KindStatic   = "static"
	KindOther    = "other"
)

// Message is a decoded AIS message, only the fields the record model needs. A
// value a field's "not available" sentinel would carry is left at its zero and
// its Has flag is false, so a consumer never mistakes 181 degrees for a fix.
type Message struct {
	Type      int
	MMSI      uint32
	Lat, Lon  float64 // degrees, north and east positive
	HasPos    bool
	SOG       float64 // knots
	HasSOG    bool
	COG       float64 // degrees true
	HasCOG    bool
	Heading   int // degrees true, 0-359
	HasHead   bool
	NavStatus int
	HasNav    bool
	Name      string
	Callsign  string
	ShipType  int
	HasType   bool
	Dest      string
	Raw       []byte
}

// Parse reads an AIS message from the de-stuffed frame bytes, whose FCS has
// already checked out. It errors only when the frame is too short to hold a
// message type and an MMSI; an unmodelled type is a Message of kind "other".
func Parse(raw []byte) (*Message, error) {
	if len(raw)*8 < 38 {
		return nil, errors.New("ais: frame shorter than a header")
	}
	m := &Message{Raw: raw}
	m.Type = int(u(raw, 0, 6))
	m.MMSI = uint32(u(raw, 8, 30))
	switch m.Type {
	case 1, 2, 3:
		m.parsePositionA(raw)
	case 18, 19:
		m.parsePositionB(raw)
		if m.Type == 19 && bitsAvailable(raw, 143, 120) {
			m.Name = sixBit(raw, 143, 20)
		}
	case 5:
		m.parseStaticA(raw)
	case 24:
		m.parseStaticB(raw)
	}
	return m, nil
}

func (m *Message) parsePositionA(raw []byte) {
	if len(raw)*8 < 168 {
		return
	}
	m.NavStatus, m.HasNav = int(u(raw, 38, 4)), true
	m.setSpeed(u(raw, 50, 10))
	m.setPos(i(raw, 61, 28), i(raw, 89, 27))
	m.setCourse(u(raw, 116, 12))
	m.setHeading(u(raw, 128, 9))
}

func (m *Message) parsePositionB(raw []byte) {
	if len(raw)*8 < 133 {
		return
	}
	m.setSpeed(u(raw, 46, 10))
	m.setPos(i(raw, 57, 28), i(raw, 85, 27))
	m.setCourse(u(raw, 112, 12))
	m.setHeading(u(raw, 124, 9))
}

func (m *Message) parseStaticA(raw []byte) {
	if bitsAvailable(raw, 70, 42) {
		m.Callsign = sixBit(raw, 70, 7)
	}
	if bitsAvailable(raw, 112, 120) {
		m.Name = sixBit(raw, 112, 20)
	}
	if bitsAvailable(raw, 232, 8) {
		m.ShipType, m.HasType = int(u(raw, 232, 8)), true
	}
	if bitsAvailable(raw, 302, 120) {
		m.Dest = sixBit(raw, 302, 20)
	}
}

func (m *Message) parseStaticB(raw []byte) {
	part := u(raw, 38, 2)
	if part == 0 && bitsAvailable(raw, 40, 120) {
		m.Name = sixBit(raw, 40, 20)
		return
	}
	if bitsAvailable(raw, 47, 1) {
		m.ShipType, m.HasType = int(u(raw, 40, 8)), true
	}
	if bitsAvailable(raw, 90, 42) {
		m.Callsign = sixBit(raw, 90, 7)
	}
}

func (m *Message) setSpeed(v uint64) {
	if v != 1023 {
		m.SOG, m.HasSOG = float64(v)/10, true
	}
}

func (m *Message) setCourse(v uint64) {
	if v != 3600 {
		m.COG, m.HasCOG = float64(v)/10, true
	}
}

func (m *Message) setHeading(v uint64) {
	if v != 511 {
		m.Heading, m.HasHead = int(v), true
	}
}

// setPos scales the 1/10000-minute lat/lon to degrees and rejects the
// not-available sentinels (lon 181, lat 91) and anything off the globe.
func (m *Message) setPos(lonRaw, latRaw int64) {
	lon := float64(lonRaw) / 600000
	lat := float64(latRaw) / 600000
	if math.Abs(lon) <= 180 && math.Abs(lat) <= 90 {
		m.Lon, m.Lat, m.HasPos = lon, lat, true
	}
}
