// SPDX-License-Identifier: Apache-2.0

package same

import (
	"testing"
	"time"
)

// Two real-shaped SAME headers: a Required Weekly Test and a
// tornado warning with three counties.
const (
	rwtHeader = "ZCZC-WXR-RWT-020103-020209-020091-020121-029047-029165-029095-029037+0030-1051700-KEAX/NWS-"
	torHeader = "ZCZC-WXR-TOR-048113-048121-048139+0045-1421550-KFWS/NWS-"
)

func TestParseRWT(t *testing.T) {
	now := time.Date(2026, 4, 15, 12, 0, 0, 0, time.UTC)
	m, err := parseAt(rwtHeader, now)
	if err != nil {
		t.Fatal(err)
	}
	if m.Org != "WXR" || m.Event != "RWT" || m.EventName != "Required Weekly Test" {
		t.Errorf("org/event/name = %q/%q/%q", m.Org, m.Event, m.EventName)
	}
	if m.Callsign != "KEAX/NWS" || m.Purge != "0030" || m.Issued != "1051700" {
		t.Errorf("callsign/purge/issued = %q/%q/%q", m.Callsign, m.Purge, m.Issued)
	}
	if len(m.Locations) != 8 {
		t.Fatalf("got %d locations, want 8", len(m.Locations))
	}
	if got := m.FIPSList(); got != "20103,20209,20091,20121,29047,29165,29095,29037" {
		t.Errorf("fips = %q", got)
	}
	if m.Locations[0].Raw != "020103" || m.Locations[0].Part != "0" || m.Locations[0].FIPS != "20103" {
		t.Errorf("location 0 = %+v", m.Locations[0])
	}
	// Day 105 of 2026 is 15 April; 17:00 UTC + 30 min.
	wantStart := time.Date(2026, 4, 15, 17, 0, 0, 0, time.UTC)
	if !m.Start.Equal(wantStart) {
		t.Errorf("start = %v, want %v", m.Start, wantStart)
	}
	if !m.End.Equal(wantStart.Add(30 * time.Minute)) {
		t.Errorf("end = %v, want %v", m.End, wantStart.Add(30*time.Minute))
	}
}

func TestParseTOR(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	m, err := parseAt(torHeader, now)
	if err != nil {
		t.Fatal(err)
	}
	if m.Event != "TOR" || m.EventName != "Tornado Warning" {
		t.Errorf("event/name = %q/%q", m.Event, m.EventName)
	}
	if m.Callsign != "KFWS/NWS" || m.Purge != "0045" {
		t.Errorf("callsign/purge = %q/%q", m.Callsign, m.Purge)
	}
	if got := m.FIPSList(); got != "48113,48121,48139" {
		t.Errorf("fips = %q", got)
	}
	// Day 142, 15:50 UTC + 45 min = 16:35 UTC.
	if want := time.Date(2026, 5, 22, 16, 35, 0, 0, time.UTC); !m.End.Equal(want) {
		t.Errorf("end = %v, want %v", m.End, want)
	}
}

func TestParseRejectsGarbage(t *testing.T) {
	for _, bad := range []string{
		"NOTZCZC-WXR-RWT-020103+0030-1051700-KEAX/NWS-",
		"ZCZC-WXR-RWT-020103-1051700-KEAX/NWS-", // no +
		"ZCZC-WXR-RWT+0030-1051700-KEAX/NWS-",   // no locations
		"ZCZC-WXR-RWT-02010-0030-1051700-KEAX/NWS-",
	} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("Parse(%q) accepted a bad header", bad)
		}
	}
}

func TestEventName(t *testing.T) {
	if EventName("XYZ") != "XYZ" {
		t.Error("unknown code should return itself")
	}
	if EventName("EAN") != "Emergency Action Notification" {
		t.Error("EAN name wrong")
	}
}
