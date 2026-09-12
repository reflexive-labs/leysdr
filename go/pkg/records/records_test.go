// SPDX-License-Identifier: Apache-2.0

package records

import (
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
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
