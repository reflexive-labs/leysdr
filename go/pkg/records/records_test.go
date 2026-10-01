// SPDX-License-Identifier: Apache-2.0

package records

import (
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

func text(s string) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Text{Text: s}}
}

func number(v float64) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Number{Number: v}}
}

func integer(v int64) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Integer{Integer: v}}
}

func TestSummaryPerKind(t *testing.T) {
	cases := []struct {
		name string
		rec  *leylinev1.DecodeRecord
		want string
	}{
		{"position", &leylinev1.DecodeRecord{
			Kind:     "position",
			Position: &leylinev1.Position{Latitude: 37.76, Longitude: -122.42},
			Fields:   map[string]*leylinev1.FieldValue{"symbol": text("/>"), "comment": text("mobile")},
		}, "37.7600N 122.4200W /> mobile"},
		{"weather", &leylinev1.DecodeRecord{
			Kind: "weather",
			Fields: map[string]*leylinev1.FieldValue{
				"temp_c": number(21), "wind_kmh": number(12), "wind_dir_deg": number(270),
			},
		}, "21.0 °C wind 12 km/h @ 270°"},
		{"message", &leylinev1.DecodeRecord{
			Kind:   "message",
			Fields: map[string]*leylinev1.FieldValue{"addressee": text("LEYTST-1"), "text": text("ping")},
		}, "→ LEYTST-1: ping"},
		{"status", &leylinev1.DecodeRecord{
			Kind: "status", Fields: map[string]*leylinev1.FieldValue{"text": text("monitoring 146.52")},
		}, "monitoring 146.52"},
		{"telemetry", &leylinev1.DecodeRecord{
			Kind: "telemetry",
			Fields: map[string]*leylinev1.FieldValue{
				"seq": integer(5), "a1": number(12), "a2": number(34), "digital": text("10110000"),
			},
		}, "T#005 12 34 10110000"},
		{"other", &leylinev1.DecodeRecord{Kind: "other", Raw: []byte("\x03\xf0hello there")}, "hello there"},
	}
	for _, c := range cases {
		if got := Summary(c.rec); got != c.want {
			t.Errorf("%s: Summary = %q, want %q", c.name, got, c.want)
		}
	}
}

// A record with no kind but a position still reads as one: the fold renders what the record
// carries rather than refusing a decoder that names only one kind of record.
func TestSummaryFallsBackToPositionThenRaw(t *testing.T) {
	pos := &leylinev1.DecodeRecord{Position: &leylinev1.Position{Latitude: -1.5, Longitude: 2.25}}
	if got := Summary(pos); got != "1.5000S 2.2500E" {
		t.Errorf("bare position: %q", got)
	}
	if got := Summary(&leylinev1.DecodeRecord{Raw: []byte("raw text")}); got != "raw text" {
		t.Errorf("bare raw: %q", got)
	}
}

func rec(id, kind string, sample uint64, fields map[string]*leylinev1.FieldValue) *leylinev1.DecodeRecord {
	return &leylinev1.DecodeRecord{
		Protocol: "aprs", DeviceId: id, Kind: kind, Fields: fields,
		Time: &leylinev1.SampleTime{CaptureId: "cap_1", SampleIndex: sample},
	}
}

// The fold keeps the newest value of every field across records, the newest position, the first
// and last time it heard the station, and how many records it has been in.
func TestTableMergesPerDevice(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	tb := NewTable()
	tb.Now = func() time.Time { return now }
	tb.Anchor(&leylinev1.CaptureAnchor{CaptureId: "cap_1", HostTimeNs: now.UnixNano(), SampleRate: 1_000_000})

	tb.Apply(rec("LEYTST-2", "weather", 0, map[string]*leylinev1.FieldValue{"temp_c": number(21)}))
	now = now.Add(2 * time.Second)
	tb.Apply(rec("LEYTST-2", "weather", 2_000_000, map[string]*leylinev1.FieldValue{"wind_kmh": number(12)}))
	e := tb.Rows()[0]
	if e.Count != 2 || e.Fields["temp_c"].GetNumber() != 21 || e.Fields["wind_kmh"].GetNumber() != 12 {
		t.Fatalf("merge: count=%d fields=%v", e.Count, e.Fields)
	}
	if e.FirstSeen.GetSampleIndex() != 0 || e.LastSeen.GetSampleIndex() != 2_000_000 {
		t.Errorf("sample times: %v %v", e.FirstSeen, e.LastSeen)
	}
	if got := e.LastWall.Sub(e.FirstWall); got != 2*time.Second {
		t.Errorf("wall span = %v, want 2s (anchor at 1 MSPS)", got)
	}
	// A record with no device_id has no row to land in: the protocol has no identity concept.
	if tb.Apply(rec("", "status", 0, nil)) != nil || tb.Len() != 1 {
		t.Errorf("a record with no device_id must not make a row")
	}
}

// Rows are newest first, and Expire drops a station silent for longer than the decoder's
// entity_silence_s.
func TestTableRowOrderAndExpiry(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	tb := NewTable()
	tb.Now = func() time.Time { return now }
	tb.Apply(rec("LEYTST-1", "position", 0, nil))
	now = now.Add(time.Minute)
	tb.Apply(rec("LEYTST-3", "status", 0, nil))
	if rows := tb.Rows(); rows[0].DeviceID != "LEYTST-3" || rows[1].DeviceID != "LEYTST-1" {
		t.Fatalf("rows are not newest first: %v %v", rows[0].DeviceID, rows[1].DeviceID)
	}
	if gone := tb.Expire(now.Add(90*time.Second), 0); gone != 0 || tb.Len() != 2 {
		t.Errorf("a silence of 0 means never: %d gone", gone)
	}
	if gone := tb.Expire(now.Add(90*time.Second), 2*time.Minute); gone != 1 || tb.Len() != 1 {
		t.Errorf("expire: %d gone, %d left", gone, tb.Len())
	}
	if tb.Rows()[0].DeviceID != "LEYTST-3" {
		t.Errorf("the station still talking must survive")
	}
}

// anchorFor is the RecordAnchor the registry dates records by, one capture at a known rate.
func anchorFor(captureID string, hostNs int64, rate uint64) *leylinev1.RecordAnchor {
	return &leylinev1.RecordAnchor{
		Anchor: &leylinev1.CaptureAnchor{CaptureId: captureID, HostTimeNs: hostNs, SampleRate: rate},
	}
}

// The registry keeps one row per device: first and last seen by wall time, an observation count,
// and the newest record's kind and summary. It is a fold over the kept log, which arrives newest
// first, so order of application must not change the result (docs/design/decoders.md, section 5).
func TestRegistryFoldsPerDevice(t *testing.T) {
	base := time.Unix(1_700_000_000, 0)
	reg := NewRegistry()
	reg.Anchor(anchorFor("cap_1", base.UnixNano(), 1_000_000))

	// Applied newest first, as QueryRecords returns them: sample 3_000_000 is 3 s after the anchor.
	reg.Apply(rec("LEYTST-2", "weather", 3_000_000, map[string]*leylinev1.FieldValue{"temp_c": number(25)}))
	reg.Apply(rec("LEYTST-2", "weather", 0, map[string]*leylinev1.FieldValue{"temp_c": number(21)}))
	reg.Apply(rec("LEYTST-1", "status", 1_000_000, map[string]*leylinev1.FieldValue{"text": text("hi")}))

	d := deviceByID(reg, "LEYTST-2")
	if d == nil || d.Count != 2 {
		t.Fatalf("LEYTST-2 count: %+v", d)
	}
	if got := d.LastWall.Sub(d.FirstWall); got != 3*time.Second {
		t.Errorf("first..last span = %v, want 3s", got)
	}
	// The newest record (25 °C) wins the summary, though it was applied first.
	if d.Summary != "25.0 °C" {
		t.Errorf("summary is not the newest record's: %q", d.Summary)
	}
	// Rows are last-heard first: LEYTST-2 (3 s) before LEYTST-1 (1 s).
	rows := reg.Rows()
	if len(rows) != 2 || rows[0].DeviceID != "LEYTST-2" || rows[1].DeviceID != "LEYTST-1" {
		t.Errorf("rows are not last-heard first: %v", rows)
	}
	// A record with no device_id makes no row.
	if reg.Apply(rec("", "status", 0, nil)) != nil || reg.Len() != 2 {
		t.Errorf("a record with no device_id must not register")
	}
}

// A record no anchor covers cannot be dated, so it counts but sets no wall time and cannot count
// as the most recent (AGENTS.md invariant 5).
func TestRegistryUndatedRecord(t *testing.T) {
	reg := NewRegistry() // no anchors
	reg.Apply(rec("LEYTST-3", "status", 0, map[string]*leylinev1.FieldValue{"text": text("undated")}))
	d := reg.Rows()[0]
	if d.Count != 1 || !d.LastWall.IsZero() || !d.FirstWall.IsZero() {
		t.Errorf("an undated record must count but carry no wall time: %+v", d)
	}
}

func deviceByID(reg *Registry, id string) *Device {
	for _, d := range reg.Rows() {
		if d.DeviceID == id {
			return d
		}
	}
	return nil
}

// Heard is the arrival series behind a row's activity sparkline: Expire trims it to the silence
// window, and a table that never expires keeps the newest heardCap so it stays bounded.
func TestTableHeardSeries(t *testing.T) {
	t0 := time.Unix(1_700_000_000, 0)
	clock := t0
	table := NewTable()
	table.Now = func() time.Time { return clock }
	rec := &leylinev1.DecodeRecord{Protocol: "aprs", DeviceId: "LEYTST-1", Kind: "status"}
	for _, m := range []int{0, 10, 20} {
		clock = t0.Add(time.Duration(m) * time.Minute)
		table.Apply(rec)
	}
	e := table.Rows()[0]
	if len(e.Heard) != 3 || !e.Heard[0].Equal(t0) || !e.Heard[2].Equal(t0.Add(20*time.Minute)) {
		t.Fatalf("Heard = %v, want the three arrival times oldest first", e.Heard)
	}
	if got := e.HeardSince(t0.Add(5 * time.Minute)); len(got) != 2 || !got[0].Equal(t0.Add(10*time.Minute)) {
		t.Errorf("HeardSince(+5m) = %v, want the two later arrivals", got)
	}
	table.Expire(t0.Add(25*time.Minute), 12*time.Minute)
	if e := table.Rows()[0]; len(e.Heard) != 1 || !e.Heard[0].Equal(t0.Add(20*time.Minute)) {
		t.Errorf("after Expire with a 12 m window, Heard = %v, want only the arrival inside it", e.Heard)
	}
	for i := 0; i < heardCap+10; i++ {
		clock = clock.Add(time.Second)
		table.Apply(rec)
	}
	if e := table.Rows()[0]; len(e.Heard) != heardCap {
		t.Errorf("Heard should be capped at %d, got %d", heardCap, len(e.Heard))
	}
}
