// SPDX-License-Identifier: Apache-2.0

package chirp

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/bookmarks"
)

const (
	fixtureCSV  = "../../../fixtures/chirp/sample.csv"
	fixtureJSON = "../../../fixtures/chirp/expected.json"
)

// parseFixture reads fixtures/chirp/sample.csv, the file both parsers are held to
// (docs/design/channels.md, "CHIRP import").
func parseFixture(t *testing.T) ([]Row, []Skipped) {
	t.Helper()
	f, err := os.Open(fixtureCSV)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	rows, skipped, err := Parse(f)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return rows, skipped
}

// openStore opens a store on a temp path with a held clock, so the stamps are known.
func openStore(t *testing.T) (*bookmarks.Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "bookmarks.json")
	s, err := bookmarks.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s.Now = func() time.Time { return time.Unix(1_758_200_000, 0) }
	return s, path
}

// normalise is the rule both suites apply to a bookmarks file before diffing it against
// fixtures/chirp/expected.json, so the fixture can hold fixed tokens where the store writes an
// id and a clock: the entries are ordered as the store lists them (frequency ascending, then
// name), the n-th entry counting from 1 is re-keyed "bm_<n>", and every updated_ns is set to 0.
// Nothing else changes. The result is compared as decoded JSON values, not bytes, so the
// fixture's whitespace and key order are free (fixtures/chirp/README.md).
func normalise(t *testing.T, path string) map[string]any {
	t.Helper()
	s, err := bookmarks.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	entries := map[string]any{}
	for i, bm := range s.List() {
		bm.UpdatedNs = 0
		b, err := json.Marshal(bm)
		if err != nil {
			t.Fatal(err)
		}
		var rec map[string]any
		if err := json.Unmarshal(b, &rec); err != nil {
			t.Fatal(err)
		}
		entries[fmt.Sprintf("bm_%d", i+1)] = rec
	}
	return map[string]any{"bookmarks": entries}
}

// Each row of the fixture maps as the design says: the tone by the Tone column's mode, FM and
// NFM to NFM at 25 and 12.5 kHz, an unknown mode to the band's default, the duplex sign onto
// the offset, and a frequency that is not a number to a skipped line.
func TestParseFixture(t *testing.T) {
	rows, skipped := parseFixture(t)
	if len(skipped) != 1 || skipped[0].Line != 9 || skipped[0].Reason != `frequency "abc" is not a number` {
		t.Fatalf("the abc row is skipped with its line and reason, got %+v", skipped)
	}
	type want struct {
		line     int
		name     string
		hz       uint64
		mode     leylinev1.DemodMode
		bw       uint32
		tone     string
		note     string
		duplex   string
		offset   int64
		fromBand bool
	}
	wants := []want{
		{2, "Club", 146_940_000, leylinev1.DemodMode_NFM, 25_000, "100.0", "club repeater", "-", -600_000, false},
		{3, "Simplex", 146_520_000, leylinev1.DemodMode_NFM, 12_500, "", "", "", 0, false},
		{4, "Tsql", 147_000_000, leylinev1.DemodMode_NFM, 25_000, "123.0", "", "+", 600_000, false},
		{5, "Dcs", 442_100_000, leylinev1.DemodMode_NFM, 25_000, "D023N", "", "+", 5_000_000, false},
		{6, "Cross", 443_500_000, leylinev1.DemodMode_NFM, 25_000, "D754N", "", "+", 5_000_000, false},
		{7, "", 462_662_500, leylinev1.DemodMode_NFM, 12_500, "", "", "", 0, false},
		{8, "", 445_925_000, leylinev1.DemodMode_NFM, 12_500, "", "", "", 0, false},
		{10, "Digital", 145_670_000, leylinev1.DemodMode_NFM, 12_500, "", "", "", 0, true},
		{11, "Club", 146_940_000, leylinev1.DemodMode_NFM, 25_000, "100.0", "club repeater", "-", -600_000, false},
	}
	if len(rows) != len(wants) {
		t.Fatalf("got %d rows, want %d: %+v", len(rows), len(wants), rows)
	}
	for i, w := range wants {
		r := rows[i]
		got := want{r.Line, r.Name, r.Hz, r.Mode, r.BandwidthHz, r.Tone, r.Note, r.Duplex, r.OffsetHz, r.ModeFromBand}
		if got != w {
			t.Errorf("row %d:\n got %+v\nwant %+v", i, got, w)
		}
	}
	// The DV row says where its mode came from; every other row has nothing to say.
	for _, r := range rows {
		if r.ModeFromBand != (len(r.Warnings) == 1) {
			t.Errorf("line %d: warnings %q, mode from band %v", r.Line, r.Warnings, r.ModeFromBand)
		}
	}
	if w := rows[7].Warnings; len(w) != 1 || !strings.Contains(w[0], `"DV"`) || !strings.Contains(w[0], "nfm") {
		t.Errorf("the DV row's warning names the mode and what was used: %q", w)
	}
}

// A tone that is not one ParseTone reads is left empty and noted on the row, which is still
// imported: a mistyped tone should not lose the frequency beside it.
func TestParseBadToneIsAWarningNotASkip(t *testing.T) {
	csv := "Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,RxDtcsCode,CrossMode,Mode\n" +
		"0,Odd,146.940000,-,0.600000,Tone,99.9,88.5,023,NN,023,Tone->Tone,FM\n" +
		"1,Inv,146.960000,-,0.600000,DTCS,88.5,88.5,023,RN,023,Tone->Tone,FM\n" +
		"2,None,146.980000,-,0.600000,Cross,88.5,88.5,023,NN,023,->Tone,FM\n"
	rows, skipped, err := Parse(strings.NewReader(csv))
	if err != nil || len(skipped) != 0 || len(rows) != 3 {
		t.Fatalf("rows=%d skipped=%v err=%v", len(rows), skipped, err)
	}
	if rows[0].Tone != "" || len(rows[0].Warnings) != 1 || !strings.Contains(rows[0].Warnings[0], `"99.9"`) {
		t.Errorf("a tone off the table is a warning: %+v", rows[0])
	}
	if rows[1].Tone != "D023I" || len(rows[1].Warnings) != 0 {
		t.Errorf("R in the transmit polarity is an inverted code: %+v", rows[1])
	}
	if rows[2].Tone != "" || len(rows[2].Warnings) != 0 {
		t.Errorf("a cross mode that transmits nothing has no tone: %+v", rows[2])
	}
}

// Columns are found by name, so an export with the columns in another order, or with columns
// this version does not read, parses the same.
func TestParseColumnsByName(t *testing.T) {
	csv := "Name,Mode,Frequency,Extra\nA,AM,121.500000,x\n"
	rows, skipped, err := Parse(strings.NewReader(csv))
	if err != nil || len(skipped) != 0 || len(rows) != 1 {
		t.Fatalf("rows=%+v skipped=%v err=%v", rows, skipped, err)
	}
	if r := rows[0]; r.Name != "A" || r.Hz != 121_500_000 || r.Mode != leylinev1.DemodMode_AM || r.BandwidthHz != 10_000 || r.Tone != "" {
		t.Errorf("row = %+v", r)
	}
}

// A file with no Frequency column is not a CHIRP export, and is an error rather than a file
// of skipped rows; a header with nothing under it is an empty import.
func TestParseHeaderRules(t *testing.T) {
	_, _, err := Parse(strings.NewReader("Name,Mode\nA,FM\n"))
	if !errors.Is(err, ErrNoFrequency) {
		t.Fatalf("no Frequency column: err = %v", err)
	}
	rows, skipped, err := Parse(strings.NewReader("Location,Name,Frequency\n"))
	if err != nil || len(rows) != 0 || len(skipped) != 0 {
		t.Fatalf("header only: rows=%v skipped=%v err=%v", rows, skipped, err)
	}
	if _, _, err := Parse(strings.NewReader("")); !errors.Is(err, ErrNoFrequency) {
		t.Fatalf("an empty file has no Frequency column either: %v", err)
	}
}

// One import into an empty store is the expected file, after both are normalised.
func TestApplyMatchesExpected(t *testing.T) {
	rows, skipped := parseFixture(t)
	s, path := openStore(t)
	res, err := Apply(s, rows, "sample")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Added) != 8 || len(res.Updated) != 1 || len(res.Skipped) != 0 || len(skipped) != 1 {
		t.Fatalf("added %d updated %d skipped %d (+%d at parse)", len(res.Added), len(res.Updated), len(res.Skipped), len(skipped))
	}
	// Apply writes nothing: the caller saves, and a dry run does not.
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("Apply must not write the file: %v", err)
	}
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	got := normalise(t, path)
	b, err := os.ReadFile(fixtureJSON)
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]any
	if err := json.Unmarshal(b, &want); err != nil {
		t.Fatalf("%s: %v", fixtureJSON, err)
	}
	if !reflect.DeepEqual(got, want) {
		gotB, _ := json.MarshalIndent(got, "", "  ")
		t.Errorf("the import of %s is not %s after normalisation\n--- got\n%s\n--- want\n%s", fixtureCSV, fixtureJSON, gotB, bytes.TrimSpace(b))
	}
	// The names: the row's own, the plan channel's where the name is blank, else the frequency.
	names := map[uint64]string{}
	for _, bm := range s.List() {
		names[bm.Hz] = bm.Name
	}
	if names[462_662_500] != "ch5" || names[445_925_000] != "445.925 MHz" || names[146_940_000] != "Club" {
		t.Errorf("names = %v", names)
	}
}

// A second import of the same file adds nothing, updates every row, and the tag set does not
// grow.
func TestApplyTwice(t *testing.T) {
	rows, _ := parseFixture(t)
	s, path := openStore(t)
	if _, err := Apply(s, rows, "sample"); err != nil {
		t.Fatal(err)
	}
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	first := normalise(t, path)
	res, err := Apply(s, rows, "sample")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Added) != 0 || len(res.Updated) != len(rows) {
		t.Fatalf("second import: added %d updated %d, want 0 and %d", len(res.Added), len(res.Updated), len(rows))
	}
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	if second := normalise(t, path); !reflect.DeepEqual(first, second) {
		t.Errorf("a second import changed the file:\n%v\n%v", first, second)
	}
	for _, bm := range s.List() {
		if !reflect.DeepEqual(bm.Tags, []string{"sample"}) {
			t.Errorf("%s: tags %v, want [sample]", bm.Name, bm.Tags)
		}
	}
}

// A blank column never clears a value typed in the inspector (docs/design/channels.md, "CHIRP
// import"): the Club that carries a note and a tone keeps both when the row has neither.
func TestApplyKeepsTypedValues(t *testing.T) {
	s, _ := openStore(t)
	if _, err := s.Add("Club", 146_940_000, leylinev1.DemodMode_NFM, 0); err != nil {
		t.Fatal(err)
	}
	tone, note := "71.9", "typed"
	if _, err := s.SetFields("Club", &tone, &note, []string{"home"}); err != nil {
		t.Fatal(err)
	}
	rows := []Row{{Line: 2, Name: "Club", Hz: 146_940_000, Mode: leylinev1.DemodMode_NFM, BandwidthHz: 25_000}}
	res, err := Apply(s, rows, "sample")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Updated) != 1 || len(res.Added) != 0 {
		t.Fatalf("result = %+v", res)
	}
	bm := res.Updated[0]
	if bm.Tone != "71.9" || bm.Note != "typed" || !reflect.DeepEqual(bm.Tags, []string{"home", "sample"}) || bm.BandwidthHz != 25_000 {
		t.Errorf("the update kept neither the tone nor the note: %+v", bm)
	}
	// A row that carries a tone replaces the typed one: the file is what the radio has.
	rows[0].Tone = "100.0"
	if res, err = Apply(s, rows, "sample"); err != nil || res.Updated[0].Tone != "100.0" {
		t.Errorf("a tone the row carries is set: %+v %v", res, err)
	}
}
