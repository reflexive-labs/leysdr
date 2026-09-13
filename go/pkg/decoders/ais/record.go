// SPDX-License-Identifier: Apache-2.0

package ais

import (
	"strconv"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

func text(s string) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Text{Text: s}}
}

func number(v float64) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Number{Number: v}}
}

// Record turns a parsed message into a DecodeRecord. device_id is the MMSI as a
// string -- the stable per-vessel id the entity table folds on -- and Time is
// left for the plugin to stamp from the frame the message finished in. The
// daemon's own fields (rssi, snr, ids, seq) stay unset per the plugin contract.
func (m *Message) Record() *leylinev1.DecodeRecord {
	rec := &leylinev1.DecodeRecord{
		Protocol: Protocol,
		DeviceId: strconv.FormatUint(uint64(m.MMSI), 10),
		Raw:      m.Raw,
		Fields: map[string]*leylinev1.FieldValue{
			"mmsi":     number(float64(m.MMSI)),
			"msg_type": number(float64(m.Type)),
		},
	}
	switch m.Type {
	case 1, 2, 3, 18, 19:
		rec.Kind = KindPosition
	case 5, 24:
		rec.Kind = KindStatic
	default:
		rec.Kind = KindOther
	}
	if m.HasPos {
		rec.Position = &leylinev1.Position{Latitude: m.Lat, Longitude: m.Lon}
	}
	if m.HasSOG {
		rec.Fields["sog_kn"] = number(m.SOG)
	}
	if m.HasCOG {
		rec.Fields["cog_deg"] = number(m.COG)
	}
	if m.HasHead {
		rec.Fields["heading_deg"] = number(float64(m.Heading))
	}
	if m.HasNav {
		rec.Fields["nav_status"] = number(float64(m.NavStatus))
	}
	if m.Name != "" {
		rec.Fields["name"] = text(m.Name)
	}
	if m.Callsign != "" {
		rec.Fields["callsign"] = text(m.Callsign)
	}
	if m.HasType {
		rec.Fields["ship_type"] = number(float64(m.ShipType))
	}
	if m.Dest != "" {
		rec.Fields["destination"] = text(m.Dest)
	}
	return rec
}
