// SPDX-License-Identifier: Apache-2.0

package records

import (
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// The display template language a manifest's DecoderDisplay is written in. The rules are in
// proto/leyline/v1/decode.proto above DecoderDisplay, and testdata/decoders/summary-cases.json
// pins them for every client that implements them.

// defaultDecimals is how many decimals a NUMBER keeps when its name carries no precision.
const defaultDecimals = 2

// maxDecimals is the largest precision `{name:N}` accepts.
const maxDecimals = 6

// SummaryFor is the line for one record under a decoder's display: the template for the record's
// kind, else the "" template, else Summary. A template that does not render (an unresolved name
// outside a group, nothing but whitespace, or a malformed template) gives way to Summary too, so
// a manifest can only add to what a client prints. label is the person's name for the
// transmitter, "" when there is none.
func SummaryFor(d *leylinev1.DecoderDisplay, rec *leylinev1.DecodeRecord, label string) string {
	tmpl, ok := d.GetSummaries()[rec.GetKind()]
	if !ok {
		tmpl, ok = d.GetSummaries()[""]
	}
	if ok {
		if line, rendered := Render(tmpl, rec, label); rendered {
			return line
		}
	}
	return Summary(rec)
}

// EntityName is a transmitter's name under a decoder's display: the entity_name template over the
// newest value of every field the transmitter has sent, else its device_id.
func EntityName(d *leylinev1.DecoderDisplay, e *Entity, label string) string {
	if t := d.GetEntityName(); t != "" {
		if name, ok := Render(t, e.Record(), label); ok {
			return name
		}
	}
	return e.DeviceID
}

// Column is one cell of a transmitter table's display.columns: the entry, "name" or "name:N", as
// a template would print {name} or {name:N}, and false when the transmitter has not sent it or the
// entry is malformed.
func Column(e *Entity, entry, label string) (string, bool) {
	name, decimals, err := parseName(entry)
	if err != nil {
		return "", false
	}
	return resolve(e.Record(), label, name, decimals)
}

// ColumnName is the field a display.columns entry names, its precision dropped: the name a
// column is headed by.
func ColumnName(entry string) string {
	name, _, _ := strings.Cut(entry, ":")
	return name
}

// Record is the entity as one record, for rendering a template over it: its device_id, its last
// kind and position, and the newest value of every field. It has no signal levels, because a
// level belongs to one packet and not to the transmitter.
func (e *Entity) Record() *leylinev1.DecodeRecord {
	return &leylinev1.DecodeRecord{
		Protocol: e.Protocol, DeviceId: e.DeviceID, Kind: e.Kind, Position: e.Position,
		Fields: e.Fields, RssiDbfs: math.NaN(), SnrDb: math.NaN(),
	}
}

// ValidateDisplay reports the first template in a display that does not parse, so a manifest
// with a broken template fails a test instead of falling back on every record.
func ValidateDisplay(d *leylinev1.DecoderDisplay) error {
	for kind, t := range d.GetSummaries() {
		if _, err := parseTemplate(t); err != nil {
			return fmt.Errorf("summaries[%q]: %w", kind, err)
		}
	}
	if t := d.GetEntityName(); t != "" {
		if _, err := parseTemplate(t); err != nil {
			return fmt.Errorf("entity_name: %w", err)
		}
	}
	for _, c := range d.GetColumns() {
		if _, _, err := parseName(c); err != nil {
			return fmt.Errorf("columns[%q]: %w", c, err)
		}
	}
	return nil
}

// Render renders one template over one record. It returns false when the template is malformed,
// when a name outside an optional group did not resolve, or when the line is empty once trimmed.
func Render(tmpl string, rec *leylinev1.DecodeRecord, label string) (string, bool) {
	segs, err := parseTemplate(tmpl)
	if err != nil {
		return "", false
	}
	var out, group strings.Builder
	inGroup, groupOK := false, true
	for _, s := range segs {
		switch s.kind {
		case segOpen:
			inGroup, groupOK = true, true
			group.Reset()
		case segClose:
			if groupOK {
				out.WriteString(group.String())
			}
			inGroup = false
		case segText, segName:
			text := s.text
			if s.kind == segName {
				v, ok := resolve(rec, label, s.text, s.decimals)
				if !ok {
					if !inGroup {
						return "", false
					}
					groupOK = false
				}
				text = v
			}
			if inGroup {
				group.WriteString(text)
			} else {
				out.WriteString(text)
			}
		}
	}
	line := strings.TrimSpace(out.String())
	return line, line != ""
}

type segKind int

const (
	segText segKind = iota
	segName
	segOpen
	segClose
)

type segment struct {
	kind     segKind
	text     string
	decimals int
}

// errTemplate is every way a template can be malformed.
var errTemplate = errors.New("malformed display template")

// parseTemplate splits a template into literal text, names and group marks. A backslash escapes
// the next {, }, [, ] or \; any other character after a backslash is an error.
func parseTemplate(t string) ([]segment, error) {
	var segs []segment
	var lit strings.Builder
	flush := func() {
		if lit.Len() > 0 {
			segs = append(segs, segment{kind: segText, text: lit.String()})
			lit.Reset()
		}
	}
	inGroup := false
	for i := 0; i < len(t); i++ {
		switch c := t[i]; c {
		case '\\':
			if i+1 >= len(t) || !strings.ContainsRune(`{}[]\`, rune(t[i+1])) {
				return nil, fmt.Errorf("%w: a backslash escapes only { } [ ] and \\", errTemplate)
			}
			lit.WriteByte(t[i+1])
			i++
		case '{':
			end := strings.IndexByte(t[i+1:], '}')
			if end < 0 {
				return nil, fmt.Errorf("%w: an unclosed {", errTemplate)
			}
			name, decimals, err := parseName(t[i+1 : i+1+end])
			if err != nil {
				return nil, err
			}
			flush()
			segs = append(segs, segment{kind: segName, text: name, decimals: decimals})
			i += end + 1
		case '}':
			return nil, fmt.Errorf("%w: a } with no {", errTemplate)
		case '[':
			if inGroup {
				return nil, fmt.Errorf("%w: groups do not nest", errTemplate)
			}
			flush()
			segs = append(segs, segment{kind: segOpen})
			inGroup = true
		case ']':
			if !inGroup {
				return nil, fmt.Errorf("%w: a ] with no [", errTemplate)
			}
			flush()
			segs = append(segs, segment{kind: segClose})
			inGroup = false
		default:
			lit.WriteByte(c)
		}
	}
	if inGroup {
		return nil, fmt.Errorf("%w: an unclosed [", errTemplate)
	}
	flush()
	return segs, nil
}

// parseName reads "name" or "name:N", N a precision from 0 to maxDecimals.
func parseName(s string) (string, int, error) {
	name, spec, hasSpec := strings.Cut(s, ":")
	if name == "" || strings.ContainsAny(name, `{[]\`) {
		return "", 0, fmt.Errorf("%w: a bad name {%s}", errTemplate, s)
	}
	if !hasSpec {
		return name, defaultDecimals, nil
	}
	if len(spec) != 1 || spec[0] < '0' || spec[0] > '0'+maxDecimals {
		return "", 0, fmt.Errorf("%w: the precision in {%s} is not 0 to %d", errTemplate, s, maxDecimals)
	}
	return name, int(spec[0] - '0'), nil
}

// resolve is one name's text: a promoted name first, then a field. decimals is the precision a
// number prints with.
func resolve(rec *leylinev1.DecodeRecord, label, name string, decimals int) (string, bool) {
	switch name {
	case "device_id":
		return nonEmpty(sanitize(rec.GetDeviceId()))
	case "kind":
		return nonEmpty(sanitize(rec.GetKind()))
	case "label":
		return nonEmpty(sanitize(label))
	case "position":
		p := rec.GetPosition()
		if p == nil || !finite(p.GetLatitude()) || !finite(p.GetLongitude()) {
			return "", false
		}
		return FormatPosition(p), true
	case "altitude_m":
		if p := rec.GetPosition(); p != nil && p.AltitudeM != nil {
			return formatNumber(p.GetAltitudeM(), decimals)
		}
		return "", false
	case "rssi_dbfs":
		return formatNumber(rec.GetRssiDbfs(), decimals)
	case "snr_db":
		return formatNumber(rec.GetSnrDb(), decimals)
	}
	return formatField(name, rec.GetFields()[name], decimals)
}

// FormatField is a field's value as a template prints it with no precision given: TEXT as sent
// with control characters as spaces, INTEGER in decimal, NUMBER with at most two decimals, FLAG
// as the field's name when true, DATA as hex. It returns false for an absent field, empty text, a
// NaN or infinite number and a false flag.
func FormatField(name string, v *leylinev1.FieldValue) (string, bool) {
	return formatField(name, v, defaultDecimals)
}

func formatField(name string, v *leylinev1.FieldValue, decimals int) (string, bool) {
	switch x := v.GetValue().(type) {
	case *leylinev1.FieldValue_Text:
		return nonEmpty(sanitize(x.Text))
	case *leylinev1.FieldValue_Integer:
		return strconv.FormatInt(x.Integer, 10), true
	case *leylinev1.FieldValue_Number:
		return formatNumber(x.Number, decimals)
	case *leylinev1.FieldValue_Flag:
		if x.Flag {
			return name, true
		}
	case *leylinev1.FieldValue_Data:
		return hex.EncodeToString(x.Data), len(x.Data) > 0
	}
	return "", false
}

// sanitize turns every control character (C0, DEL and C1, newline and tab among them) into one
// space, so a value cannot break the line it is printed in.
func sanitize(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
}

func nonEmpty(s string) (string, bool) { return s, s != "" }

func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }

// formatNumber prints a number with up to decimals decimals, trailing zeros and a bare point
// dropped: 21, 21.5, 21.46. It is printf's %.Nf, so it never scales the value and a client in
// another language gets the same digits from the same double.
func formatNumber(v float64, decimals int) (string, bool) {
	if !finite(v) {
		return "", false
	}
	s := strconv.FormatFloat(v, 'f', decimals, 64)
	if strings.ContainsRune(s, '.') {
		s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	}
	if s == "-0" {
		s = "0"
	}
	return s, true
}
