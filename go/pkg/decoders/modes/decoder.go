// SPDX-License-Identifier: Apache-2.0

// Package modes decodes Mode S and ADS-B (1090 MHz extended squitter) from complex baseband,
// written from the published formats: ICAO Annex 10 Volume IV for Mode S and DO-260B for the
// extended squitter, as summarised in public references such as Junzi Sun's "The 1090 MHz
// Riddle". It demodulates the pulse-position modulation (Demod), checks the 24-bit parity, parses
// identification, airborne position, airborne velocity and surveillance replies (Parse), and
// keeps the per-aircraft state a position and a surveillance reply need (Decoder): the even and
// odd CPR frames a global position decode pairs, the last position a local decode refers to, and
// the list of addresses heard in the clear that validates replies whose address is only in their
// parity.
package modes

import (
	"fmt"
	"math"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// Protocol is DecodeRecord.protocol and the manifest's name.
const Protocol = "adsb"

const (
	// pairWindowS is how far apart an even and an odd frame may be for a global decode: an
	// aircraft at 600 kn covers about 1.7 NM in 10 s, a small part of a 360 NM zone.
	pairWindowS = 10
	// localWindowS is how old the last position may be for a local decode against it; the
	// decode is right while the aircraft is within half a zone, about 180 NM, of it.
	localWindowS = 30
	// localMaxKm is the furthest a local decode may land from the position it refers to before
	// it is taken for a bad frame and the aircraft waits for a new pair.
	localMaxKm = 50
	// knownWindowS is how long an address heard in the clear validates replies that carry it
	// only in their parity.
	knownWindowS = 60
	// forgetS is how long an aircraft's state is kept after its last reply.
	forgetS = 300
)

// cprFrame is one airborne position frame's CPR fix and when it arrived.
type cprFrame struct {
	lat, lon uint32
	t        float64
	ok       bool
}

// aircraft is the decode state for one address.
type aircraft struct {
	clearT    float64 // the last reply carrying the address in the clear (DF11, DF17, DF18)
	lastT     float64 // the last reply of any kind
	even, odd cprFrame
	hasPos    bool
	lat, lon  float64
	posT      float64
}

// Decoder turns complex baseband into ADS-B and Mode S records, keeping the per-aircraft state
// between blocks.
type Decoder struct {
	demod    *Demod
	rate     float64
	aircraft map[uint32]*aircraft
	now      float64 // seconds on the sample timeline, at the block being scanned
	lastGC   float64
}

// NewDecoder makes a decoder for complex baseband at rate samples per second.
func NewDecoder(rate float64) *Decoder {
	d := &Decoder{demod: NewDemod(rate), rate: rate, aircraft: map[uint32]*aircraft{}}
	d.demod.Known = d.known
	return d
}

// Stats is the demodulator's counts.
func (d *Decoder) Stats() Stats { return d.demod.Stats }

func (d *Decoder) known(addr uint32) bool {
	a := d.aircraft[addr]
	return a != nil && a.clearT > 0 && d.now-a.clearT <= knownWindowS
}

// Reset drops the samples held, as after a gap, and continues at sample index at. Aircraft
// state is kept: it is measured in seconds, and a gap of a few blocks does not change it.
func (d *Decoder) Reset(at int64) { d.demod.Reset(at) }

// Next is the sample index the next sample fed will have.
func (d *Decoder) Next() int64 { return d.demod.Next() }

// Feed scans a block and calls emit with each reply's message and record, the record's time left
// for the caller to stamp from Frame.End.
func (d *Decoder) Feed(iq []complex64, emit func(Frame, *leylinev1.DecodeRecord)) {
	d.now = float64(d.demod.Next()) / d.rate
	d.demod.Feed(iq, func(f Frame) {
		if rec := d.handle(f); rec != nil {
			emit(f, rec)
		}
	})
	if d.now-d.lastGC > forgetS {
		for k, a := range d.aircraft {
			if d.now-a.lastT > forgetS {
				delete(d.aircraft, k)
			}
		}
		d.lastGC = d.now
	}
}

// handle parses an accepted frame, updates its aircraft and returns the record, nil for a format
// that makes none.
func (d *Decoder) handle(f Frame) *leylinev1.DecodeRecord {
	m, err := Parse(f.Msg, f.Addr)
	if err != nil {
		return nil
	}
	t := float64(f.End) / d.rate
	a := d.aircraft[m.Addr]
	if a == nil {
		a = &aircraft{}
		d.aircraft[m.Addr] = a
	}
	a.lastT = t
	if m.DF == 11 || m.DF == 17 || m.DF == 18 && m.Raw[0]&7 != 1 {
		a.clearT = t
	}
	rec := m.Record()
	if m.HasCPR {
		if lat, lon, ok := a.position(m, t); ok {
			rec.Position = &leylinev1.Position{Latitude: lat, Longitude: lon}
			if m.HasAlt {
				alt := float64(m.AltFt) * 0.3048
				rec.Position.AltitudeM = &alt
			}
		}
	}
	return rec
}

// position stores the frame's CPR fix and decodes a position from it: globally with the other
// format's frame when one arrived in the last 10 s, else locally against the aircraft's last
// position when that is recent. One frame with neither gives no position.
func (a *aircraft) position(m *Message, t float64) (float64, float64, bool) {
	fr := cprFrame{lat: m.LatCPR, lon: m.LonCPR, t: t, ok: true}
	other := a.even
	if m.Odd {
		a.odd = fr
	} else {
		a.even = fr
		other = a.odd
	}
	if other.ok && t-other.t <= pairWindowS && t >= other.t {
		var lat, lon float64
		var ok bool
		if m.Odd {
			lat, lon, ok = cprGlobal(other.lat, other.lon, fr.lat, fr.lon, true)
		} else {
			lat, lon, ok = cprGlobal(fr.lat, fr.lon, other.lat, other.lon, false)
		}
		if ok && (!a.hasPos || t-a.posT > localWindowS || distanceKm(lat, lon, a.lat, a.lon) <= localMaxKm) {
			a.setPos(lat, lon, t)
			return lat, lon, true
		}
		if ok {
			// A pair that disagrees with a recent position: one of the three is wrong, so
			// neither is trusted and the next pair decides.
			a.hasPos = false
			return 0, 0, false
		}
	}
	if a.hasPos && t-a.posT <= localWindowS {
		lat, lon := cprLocal(fr.lat, fr.lon, m.Odd, a.lat, a.lon)
		if distanceKm(lat, lon, a.lat, a.lon) <= localMaxKm {
			a.setPos(lat, lon, t)
			return lat, lon, true
		}
		a.hasPos = false
	}
	return 0, 0, false
}

func (a *aircraft) setPos(lat, lon, t float64) {
	a.hasPos, a.lat, a.lon, a.posT = true, lat, lon, t
}

func text(s string) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Text{Text: s}}
}

func number(v float64) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Number{Number: v}}
}

// Record is the message's DecodeRecord without a position or a time: device_id is the address as
// six upper-case hex digits, raw the reply's bytes.
func (m *Message) Record() *leylinev1.DecodeRecord {
	icao := fmt.Sprintf("%06X", m.Addr)
	rec := &leylinev1.DecodeRecord{
		Protocol: Protocol,
		DeviceId: icao,
		Kind:     m.Kind(),
		Raw:      m.Raw,
		Fields: map[string]*leylinev1.FieldValue{
			"icao": text(icao),
			"df":   number(float64(m.DF)),
		},
	}
	f := rec.Fields
	if m.TC != 0 {
		f["tc"] = number(float64(m.TC))
	}
	if m.Callsign != "" {
		f["callsign"] = text(m.Callsign)
	}
	if m.Category != "" {
		f["category"] = text(m.Category)
	}
	if m.HasAlt {
		f["altitude_ft"] = number(float64(m.AltFt))
	}
	if m.HasGS {
		f["ground_speed_kn"] = number(round(m.GSKn, 1))
		f["track_deg"] = number(round(m.TrackDeg, 1))
	}
	if m.HasAirspeed {
		f["airspeed_kn"] = number(m.AirspeedKn)
	}
	if m.HasHeading {
		f["heading_deg"] = number(round(m.HeadingDeg, 1))
	}
	if m.HasVR {
		f["vertical_rate_fpm"] = number(float64(m.VRFpm))
	}
	if m.Squawk != "" {
		f["squawk"] = text(m.Squawk)
	}
	return rec
}

func round(v float64, places int) float64 {
	p := math.Pow(10, float64(places))
	return math.Round(v*p) / p
}
