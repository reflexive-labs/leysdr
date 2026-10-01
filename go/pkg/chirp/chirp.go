// SPDX-License-Identifier: Apache-2.0

// Package chirp reads CHIRP's CSV export into bookmarks. CHIRP is where a ham's memories already
// are, so an import is how a hundred repeaters reach the sidebar without being typed twice;
// the mapping is the design's (docs/design/channels.md, "CHIRP import") and the Mac app's
// parser (LeylineClient/CHIRP.swift) applies the same rules, both held to
// fixtures/chirp/sample.csv and expected.json. Parse turns the file into rows and Apply files
// the rows in a store through its own add-or-update, so the update semantics are the store's.
package chirp

import (
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"math"
	"path/filepath"
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/bookmarks"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// ErrNoFrequency is Parse's error for a file whose header has no Frequency column: it is not
// a CHIRP export, and nothing is imported rather than every row skipped.
var ErrNoFrequency = errors.New("no Frequency column")

// Row is one memory as the bookmark it becomes. Name may be blank, in which case Apply names
// it. Hz is the Frequency column (MHz) rounded to whole hertz. Mode and BandwidthHz are CHIRP's
// Mode mapped: FM is NFM at 25 kHz and NFM is NFM at 12.5 kHz, since CHIRP's two are the same
// demodulator at two widths; AM, USB, LSB, CW and WFM are themselves at the mode's default
// width; anything else (DV, DN, P25, a digital mode ley does not decode) is the band's default
// mode and width, and ModeFromBand says so. Tone is the store's spelling, validated by
// leyline.ParseTone, or empty. Warnings are the fields that could not be taken as written, one
// sentence each, for the person: the row is still imported without them.
type Row struct {
	Line         int
	Name         string
	Hz           uint64
	Mode         leylinev1.DemodMode
	BandwidthHz  uint32
	ModeFromBand bool
	Tone         string
	Note         string
	// Duplex is CHIRP's, "+", "-", "split" or "off", or empty for simplex. OffsetHz is the
	// signed offset in hertz under "+" and "-"; under "split" CHIRP's Offset column holds the
	// transmit frequency itself, so OffsetHz is that frequency minus Hz. Under "off" and blank
	// it is 0: CHIRP writes its 0.600000 default into the column of a simplex row too, so the
	// column is only read when the duplex says it applies.
	Duplex   string
	OffsetHz int64
	Warnings []string
}

// Skipped is a row that became no bookmark, with the file line it was on and why.
type Skipped struct {
	Line   int    `json:"line"`
	Reason string `json:"reason"`
}

// Parse reads a CHIRP CSV export. Columns are found by name in the header row, so the order
// does not matter and columns this version does not read are ignored. A row whose frequency
// is not a positive number is skipped, and everything else about a row is a warning on it.
func Parse(r io.Reader) (rows []Row, skipped []Skipped, err error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	cr.LazyQuotes = true
	header, err := cr.Read()
	if errors.Is(err, io.EOF) {
		return nil, nil, ErrNoFrequency
	}
	if err != nil {
		return nil, nil, err
	}
	cols := map[string]int{}
	for i, name := range header {
		// A BOM on the first cell is what a spreadsheet leaves when it re-saves the file.
		name = strings.TrimPrefix(strings.TrimSpace(name), "\ufeff")
		cols[strings.ToLower(name)] = i
	}
	if _, ok := cols["frequency"]; !ok {
		return nil, nil, ErrNoFrequency
	}
	for {
		rec, err := cr.Read()
		if errors.Is(err, io.EOF) {
			return rows, skipped, nil
		}
		if err != nil {
			return nil, nil, err
		}
		line, _ := cr.FieldPos(0)
		field := func(name string) string {
			i, ok := cols[name]
			if !ok || i >= len(rec) {
				return ""
			}
			return strings.TrimSpace(rec[i])
		}
		if len(rec) == 1 && rec[0] == "" {
			continue // a blank line, which a hand-edited export may end with
		}
		row, reason := parseRow(line, field)
		if reason != "" {
			skipped = append(skipped, Skipped{Line: line, Reason: reason})
			continue
		}
		rows = append(rows, row)
	}
}

// parseRow maps one record; a non-empty reason means the row is skipped.
func parseRow(line int, field func(string) string) (Row, string) {
	row := Row{Line: line, Name: field("name"), Note: field("comment")}
	hz, reason := parseMHz(field("frequency"))
	if reason != "" {
		return Row{}, reason
	}
	row.Hz = hz
	row.Mode, row.BandwidthHz, row.ModeFromBand = mapMode(field("mode"), hz)
	if row.ModeFromBand {
		what := "no band recognised"
		if _, band := leyline.DefaultMode(hz); band != nil {
			what = "the " + band.Name + " band's default"
		}
		row.warn("mode %q is not one ley decodes; kept as %s, %s", field("mode"), leyline.ModeName(row.Mode), what)
	}
	if tone, spelled := mapTone(field); tone != "" {
		if _, err := leyline.ParseTone(tone); err != nil {
			row.warn("tone %q is not a CTCSS tone or a DCS code; left empty", spelled)
		} else {
			row.Tone = tone
		}
	}
	row.mapDuplex(field("duplex"), field("offset"))
	return row, ""
}

func (r *Row) warn(format string, args ...any) {
	r.Warnings = append(r.Warnings, fmt.Sprintf(format, args...))
}

// parseMHz reads CHIRP's Frequency column, megahertz with six decimals, to whole hertz.
func parseMHz(s string) (uint64, string) {
	if s == "" {
		return 0, "frequency is blank"
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
		return 0, fmt.Sprintf("frequency %q is not a number", s)
	}
	if f <= 0 {
		return 0, fmt.Sprintf("frequency %q is not above 0", s)
	}
	return uint64(math.Round(f * 1e6)), ""
}

// mapMode is the Mode column as the design maps it; the third result says the band decided.
func mapMode(mode string, hz uint64) (leylinev1.DemodMode, uint32, bool) {
	switch strings.ToUpper(mode) {
	case "FM":
		return leylinev1.DemodMode_NFM, 25_000, false
	case "NFM":
		return leylinev1.DemodMode_NFM, 12_500, false
	case "AM", "USB", "LSB", "CW", "WFM":
		m, _ := leyline.ParseMode(mode)
		return m, leyline.DefaultBandwidth(m), false
	}
	m, _ := leyline.DefaultMode(hz)
	return m, leyline.BandwidthFor(hz, m), true
}

// mapTone picks the tone the radio transmits, by the Tone column's mode: Tone takes rToneFreq,
// TSQL takes cToneFreq, DTCS takes DtcsCode with the transmit half of DtcsPolarity, Cross takes
// the transmit side of CrossMode (the part before "->"), and anything else has no tone. The
// second result is the column's own spelling, for the warning when the tone does not validate.
func mapTone(field func(string) string) (tone, spelled string) {
	ctcss := func(col string) (string, string) {
		s := field(col)
		return s, s
	}
	dcs := func() (string, string) {
		code := field("dtcscode")
		if code == "" {
			return "", ""
		}
		// CHIRP writes the code as three digits and the polarity as two letters, transmit then
		// receive, N for normal and R for reversed; the store spells reversed as I.
		if len(code) < 3 {
			code = strings.Repeat("0", 3-len(code)) + code
		}
		pol := "N"
		if p := field("dtcspolarity"); strings.HasPrefix(p, "R") {
			pol = "I"
		}
		return "D" + code + pol, code + " " + field("dtcspolarity")
	}
	switch field("tone") {
	case "Tone":
		return ctcss("rtonefreq")
	case "TSQL":
		return ctcss("ctonefreq")
	case "DTCS":
		return dcs()
	case "Cross":
		tx, _, _ := strings.Cut(field("crossmode"), "->")
		switch tx {
		case "Tone":
			return ctcss("rtonefreq")
		case "DTCS":
			return dcs()
		}
	}
	return "", ""
}

// mapDuplex reads the Duplex and Offset columns into the row as the Row's fields describe.
func (r *Row) mapDuplex(duplex, offset string) {
	switch duplex {
	case "":
		return
	case "off":
		r.Duplex = duplex
		return
	case "+", "-", "split":
	default:
		r.warn("duplex %q is not one of +, -, split or off; left empty", duplex)
		return
	}
	mhz, err := strconv.ParseFloat(offset, 64)
	if err != nil || math.IsNaN(mhz) || math.IsInf(mhz, 0) || mhz < 0 {
		r.warn("offset %q is not a number; duplex %s left empty", offset, duplex)
		return
	}
	hz := int64(math.Round(mhz * 1e6))
	r.Duplex = duplex
	switch duplex {
	case "-":
		r.OffsetHz = -hz
	case "+":
		r.OffsetHz = hz
	case "split":
		r.OffsetHz = hz - int64(r.Hz)
	}
}

// Result is what Apply did: the bookmarks it made, the ones it updated, and the rows the store
// refused (a row Parse produced is always nameable, so this is empty unless the store changes).
type Result struct {
	Added   []bookmarks.Bookmark
	Updated []bookmarks.Bookmark
	Skipped []Skipped
}

// Apply files rows in the store through Keep, its add-or-update, and saves nothing: the caller
// saves, and a dry run does not. tag joins every bookmark's tags, the file's basename without
// its extension, so `ley bookmarks --tag <file>` lists what one import filed. A row's name is
// its own when it has one, else the plan channel's radio-printed name when the frequency sits
// on one (the sidebar's naming rule, docs/design/channels.md, "Bookmarks gain three fields"),
// else the frequency as ley prints it, so a blank name is never an empty row.
func Apply(store *bookmarks.Store, rows []Row, tag string) (Result, error) {
	var res Result
	for _, row := range rows {
		bm := bookmarks.Bookmark{
			Name:        row.Name,
			Hz:          row.Hz,
			Mode:        row.Mode.String(),
			BandwidthHz: row.BandwidthHz,
			Tone:        row.Tone,
			Note:        row.Note,
			OffsetHz:    row.OffsetHz,
			Duplex:      row.Duplex,
		}
		if strings.TrimSpace(bm.Name) == "" {
			bm.Name = NameFor(row.Hz)
		}
		if tag != "" {
			bm.Tags = []string{tag}
		}
		kept, updated, err := store.Keep(bm)
		if err != nil {
			res.Skipped = append(res.Skipped, Skipped{Line: row.Line, Reason: err.Error()})
			continue
		}
		if updated {
			res.Updated = append(res.Updated, kept)
		} else {
			res.Added = append(res.Added, kept)
		}
	}
	return res, nil
}

// NameFor is the name a blank-named row takes: the plan channel it sits on, as its radios print
// it (GMRS channel 5 is "ch5"), else the frequency as ley prints it ("445.925 MHz").
func NameFor(hz uint64) string {
	if _, c, ok := leyline.ChannelAt(hz); ok {
		return c.Name
	}
	return leyline.FormatFrequency(hz)
}

// Tag is the tag an import files its rows under: the file's basename without its extension,
// so memories.csv is listed by `ley bookmarks --tag memories`.
func Tag(path string) string {
	base := filepath.Base(path)
	return strings.TrimSuffix(base, filepath.Ext(base))
}
