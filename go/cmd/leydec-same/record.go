// SPDX-License-Identifier: Apache-2.0

package main

import (
	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/same"
)

// KindAlert is the one kind of record SAME produces.
const KindAlert = "alert"

func text(s string) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Text{Text: s}}
}

// buildRecord turns a parsed SAME header into a DecodeRecord. device_id is the
// sender's callsign, the validity window is the alert's, and the FIPS list is
// joined with commas so a CONTAINS predicate can match a single county
// The daemon fills the ids and levels.
func buildRecord(m *same.Message) *leylinev1.DecodeRecord {
	rec := &leylinev1.DecodeRecord{
		Protocol: same.Protocol,
		DeviceId: m.Callsign,
		Kind:     KindAlert,
		Raw:      []byte(m.Header),
		Validity: &leylinev1.Validity{
			StartNs: m.Start.UnixNano(),
			EndNs:   m.End.UnixNano(),
		},
		Fields: map[string]*leylinev1.FieldValue{
			"org":        text(m.Org),
			"event":      text(m.Event),
			"event_name": text(m.EventName),
			"fips":       text(m.FIPSList()),
			"fips_raw":   text(m.RawList()),
			"callsign":   text(m.Callsign),
			"purge":      text(m.Purge),
			"issued":     text(m.Issued),
		},
	}
	return rec
}
