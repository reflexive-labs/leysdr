// SPDX-License-Identifier: Apache-2.0

package records

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// The shared vectors in testdata/decoders pin the display template language and the entity fold
// for every client: the app's Swift port reads the same files. Their shape is documented in
// testdata/decoders/README.md.

const vectorsDir = "../../../testdata/decoders"

type vecDisplay struct {
	Title      string            `json:"title"`
	Symbol     string            `json:"symbol"`
	Summaries  map[string]string `json:"summaries"`
	EntityName string            `json:"entity_name"`
	Columns    []string          `json:"columns"`
}

func (d vecDisplay) proto() *leylinev1.DecoderDisplay {
	return &leylinev1.DecoderDisplay{
		Title: d.Title, Symbol: d.Symbol, Summaries: d.Summaries, EntityName: d.EntityName, Columns: d.Columns,
	}
}

// vecFloat is a JSON number, or one of the strings "NaN", "Infinity" and "-Infinity" for the
// values JSON has no number for (Swift: JSONDecoder.NonConformingFloatDecodingStrategy
// .convertFromString with those three strings).
type vecFloat float64

func (f *vecFloat) UnmarshalJSON(b []byte) error {
	var s string
	if json.Unmarshal(b, &s) == nil {
		switch s {
		case "NaN":
			*f = vecFloat(math.NaN())
		case "Infinity":
			*f = vecFloat(math.Inf(1))
		case "-Infinity":
			*f = vecFloat(math.Inf(-1))
		default:
			return fmt.Errorf("%q is not a number", s)
		}
		return nil
	}
	var v float64
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}
	*f = vecFloat(v)
	return nil
}

type vecValue struct {
	Text    *string   `json:"text"`
	Integer *int64    `json:"integer"`
	Number  *vecFloat `json:"number"`
	Flag    *bool     `json:"flag"`
	Data    *string   `json:"data"`
}

func (v vecValue) proto(t *testing.T) *leylinev1.FieldValue {
	t.Helper()
	keys := 0
	for _, set := range []bool{v.Text != nil, v.Integer != nil, v.Number != nil, v.Flag != nil, v.Data != nil} {
		if set {
			keys++
		}
	}
	if keys != 1 {
		t.Fatalf("a field value carries exactly one key, and this one has %d", keys)
	}
	switch {
	case v.Text != nil:
		return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Text{Text: *v.Text}}
	case v.Integer != nil:
		return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Integer{Integer: *v.Integer}}
	case v.Number != nil:
		return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Number{Number: float64(*v.Number)}}
	case v.Flag != nil:
		return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Flag{Flag: *v.Flag}}
	}
	b, err := hex.DecodeString(*v.Data)
	if err != nil {
		t.Fatalf("data %q is not hex: %v", *v.Data, err)
	}
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Data{Data: b}}
}

type vecPosition struct {
	Latitude  vecFloat  `json:"latitude"`
	Longitude vecFloat  `json:"longitude"`
	AltitudeM *vecFloat `json:"altitude_m"`
}

func (p *vecPosition) proto() *leylinev1.Position {
	if p == nil {
		return nil
	}
	pos := &leylinev1.Position{Latitude: float64(p.Latitude), Longitude: float64(p.Longitude)}
	if p.AltitudeM != nil {
		alt := float64(*p.AltitudeM)
		pos.AltitudeM = &alt
	}
	return pos
}

type vecRecord struct {
	Protocol string              `json:"protocol"`
	Kind     string              `json:"kind"`
	DeviceID string              `json:"device_id"`
	Position *vecPosition        `json:"position"`
	RssiDbfs *vecFloat           `json:"rssi_dbfs"`
	SnrDb    *vecFloat           `json:"snr_db"`
	Fields   map[string]vecValue `json:"fields"`
	Raw      string              `json:"raw"`
}

func (r vecRecord) proto(t *testing.T) *leylinev1.DecodeRecord {
	rec := &leylinev1.DecodeRecord{
		Protocol: r.Protocol, Kind: r.Kind, DeviceId: r.DeviceID, Position: r.Position.proto(),
		RssiDbfs: math.NaN(), SnrDb: math.NaN(), Fields: fieldsProto(t, r.Fields), Raw: []byte(r.Raw),
	}
	if r.RssiDbfs != nil {
		rec.RssiDbfs = float64(*r.RssiDbfs)
	}
	if r.SnrDb != nil {
		rec.SnrDb = float64(*r.SnrDb)
	}
	return rec
}

func fieldsProto(t *testing.T, fields map[string]vecValue) map[string]*leylinev1.FieldValue {
	out := map[string]*leylinev1.FieldValue{}
	for name, v := range fields {
		out[name] = v.proto(t)
	}
	return out
}

func readVector(t *testing.T, name string, into any) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(vectorsDir, name))
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(into); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
}

// checkManifestDisplay keeps a vector's copy of a decoder's display identical to the manifest the
// daemon reads, so the vectors pin what ships. A name with no directory under decoders/ is a
// display written for the vectors alone.
func checkManifestDisplay(t *testing.T, decoder string, d vecDisplay) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("../../../decoders", decoder, "manifest.json"))
	if os.IsNotExist(err) {
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	var m leylinev1.DecoderManifest
	if err := protojson.Unmarshal(data, &m); err != nil {
		t.Fatalf("decoders/%s/manifest.json: %v", decoder, err)
	}
	if !proto.Equal(m.GetDisplay(), d.proto()) {
		t.Errorf("the vectors' %s display and decoders/%s/manifest.json differ:\nvectors:  %v\nmanifest: %v",
			decoder, decoder, d.proto(), m.GetDisplay())
	}
}

func TestSummaryVectors(t *testing.T) {
	var file struct {
		Displays map[string]vecDisplay `json:"displays"`
		Cases    []struct {
			Name     string    `json:"name"`
			Display  string    `json:"display"`
			Record   vecRecord `json:"record"`
			Label    string    `json:"label"`
			Summary  string    `json:"summary"`
			Fallback bool      `json:"fallback"`
		} `json:"cases"`
	}
	readVector(t, "summary-cases.json", &file)
	for name, d := range file.Displays {
		checkManifestDisplay(t, name, d)
	}
	for _, c := range file.Cases {
		t.Run(c.Name, func(t *testing.T) {
			d, ok := file.Displays[c.Display]
			if !ok {
				t.Fatalf("no display %q", c.Display)
			}
			rec := c.Record.proto(t)
			if got := SummaryFor(d.proto(), rec, c.Label); got != c.Summary {
				t.Errorf("summary %q, want %q", got, c.Summary)
			}
			// A fallback case is one no template renders: the line is the client's own.
			if c.Fallback {
				if got := Summary(rec); got != c.Summary {
					t.Errorf("a fallback case's summary is Summary's line %q, but the case says %q", got, c.Summary)
				}
				if tmpl, ok := templateFor(d.proto(), rec.GetKind()); ok {
					if line, rendered := Render(tmpl, rec, c.Label); rendered {
						t.Errorf("a fallback case rendered %q", line)
					}
				}
			}
		})
	}
}

func templateFor(d *leylinev1.DecoderDisplay, kind string) (string, bool) {
	if t, ok := d.GetSummaries()[kind]; ok {
		return t, true
	}
	t, ok := d.GetSummaries()[""]
	return t, ok
}

type vecRow struct {
	DeviceID    string              `json:"device_id"`
	Protocol    string              `json:"protocol"`
	Name        string              `json:"name"`
	Kind        string              `json:"kind"`
	Summary     string              `json:"summary"`
	Count       int                 `json:"count"`
	FirstHeardS float64             `json:"first_heard_s"`
	LastHeardS  float64             `json:"last_heard_s"`
	Position    *vecPosition        `json:"position"`
	Fields      map[string]vecValue `json:"fields"`
	Columns     map[string]string   `json:"columns"`
}

func TestFoldVectors(t *testing.T) {
	files, err := filepath.Glob(filepath.Join(vectorsDir, "fold-*.json"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no fold vectors in %s (%v)", vectorsDir, err)
	}
	for _, path := range files {
		t.Run(filepath.Base(path), func(t *testing.T) {
			var v struct {
				Name           string     `json:"name"`
				Decoder        string     `json:"decoder"`
				Display        vecDisplay `json:"display"`
				EntitySilenceS float64    `json:"entity_silence_s"`
				Steps          []struct {
					AtS    float64    `json:"at_s"`
					Record *vecRecord `json:"record"`
					Expire bool       `json:"expire"`
				} `json:"steps"`
				Rows []vecRow `json:"rows"`
			}
			readVector(t, filepath.Base(path), &v)
			checkManifestDisplay(t, v.Decoder, v.Display)
			epoch := time.Unix(1_700_000_000, 0)
			at := func(s float64) time.Time { return epoch.Add(time.Duration(s * float64(time.Second))) }
			var now time.Time
			table := NewTable()
			table.Now = func() time.Time { return now }
			table.Display = v.Display.proto()
			silence := time.Duration(v.EntitySilenceS * float64(time.Second))
			for _, step := range v.Steps {
				now = at(step.AtS)
				if step.Record != nil {
					table.Apply(step.Record.proto(t))
				}
				if step.Expire {
					table.Expire(now, silence)
				}
			}
			rows := table.Rows()
			if len(rows) != len(v.Rows) {
				t.Fatalf("%d rows, want %d", len(rows), len(v.Rows))
			}
			for i, want := range v.Rows {
				e := rows[i]
				columns := map[string]string{}
				for _, name := range table.Display.GetColumns() {
					if val, ok := Column(e, name, ""); ok {
						columns[name] = val
					}
				}
				type scalars struct {
					id, protocol, name, kind, summary string
					count                             int
					first, last                       float64
				}
				got := scalars{
					e.DeviceID, e.Protocol, EntityName(table.Display, e, ""), e.Kind, e.Summary, e.Count,
					e.FirstHeard.Sub(epoch).Seconds(), e.LastHeard.Sub(epoch).Seconds(),
				}
				w := scalars{
					want.DeviceID, want.Protocol, want.Name, want.Kind, want.Summary, want.Count,
					want.FirstHeardS, want.LastHeardS,
				}
				if got != w {
					t.Errorf("row %d:\ngot  %+v\nwant %+v", i, got, w)
				}
				if !proto.Equal(e.Position, want.Position.proto()) {
					t.Errorf("row %d position %v, want %v", i, e.Position, want.Position.proto())
				}
				wantFields := fieldsProto(t, want.Fields)
				if len(e.Fields) != len(wantFields) {
					t.Errorf("row %d fields %v, want %v", i, e.Fields, wantFields)
				}
				for name, fv := range wantFields {
					if !proto.Equal(e.Fields[name], fv) {
						t.Errorf("row %d field %s = %v, want %v", i, name, e.Fields[name], fv)
					}
				}
				if len(columns) != len(want.Columns) {
					t.Errorf("row %d columns %v, want %v", i, columns, want.Columns)
				}
				for name, val := range want.Columns {
					if columns[name] != val {
						t.Errorf("row %d column %s = %q, want %q", i, name, columns[name], val)
					}
				}
			}
		})
	}
}

func TestColumnVectors(t *testing.T) {
	var file struct {
		Cases []struct {
			Name   string    `json:"name"`
			Column string    `json:"column"`
			Record vecRecord `json:"record"`
			Value  *string   `json:"value"`
			Valid  bool      `json:"valid"`
		} `json:"cases"`
	}
	readVector(t, "column-cases.json", &file)
	if len(file.Cases) < 10 {
		t.Fatalf("%d column cases", len(file.Cases))
	}
	for _, c := range file.Cases {
		t.Run(c.Name, func(t *testing.T) {
			table := NewTable()
			table.Apply(c.Record.proto(t))
			rows := table.Rows()
			if len(rows) != 1 {
				t.Fatalf("%d rows, want 1", len(rows))
			}
			got, ok := Column(rows[0], c.Column, "")
			switch {
			case c.Value == nil && ok:
				t.Errorf("Column(%q) = %q, want absent", c.Column, got)
			case c.Value != nil && (!ok || got != *c.Value):
				t.Errorf("Column(%q) = %q, %v, want %q", c.Column, got, ok, *c.Value)
			}
			valid := ValidateDisplay(&leylinev1.DecoderDisplay{Columns: []string{c.Column}}) == nil
			if valid != c.Valid {
				t.Errorf("ValidateDisplay(columns %q) valid = %v, want %v", c.Column, valid, c.Valid)
			}
		})
	}
}
