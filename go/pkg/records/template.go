// SPDX-License-Identifier: Apache-2.0

package records

import (
	"encoding/hex"
	"errors"
	"math"
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// The display template language a manifest's DecoderDisplay is written in. The rules are in
// proto/leyline/v1/decode.proto above DecoderDisplay, and testdata/decoders/summary-cases.json
// pins them for every client that implements them.

// SummaryFor is the line for one record under a decoder's display: the template for the record's
// kind, else the "" template, else Summary. A template that does not render (an unresolved name
// outside a group, or nothing but spaces) gives way to Summary too, so a manifest can only add to
// what a client prints. label is the person's name for the transmitter, "" when there is none.
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

// Column is one cell of a transmitter table's display.columns: the named value as a template
// would print it, and false when the transmitter has not sent it.
func Column(e *Entity, name, label string) (string, bool) {
	return resolve(e.Record(), label, name)
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
				v, ok := resolve(rec, label, s.text)
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
	kind segKind
	text string
}

var errTemplate = errors.New("malformed display template")

// parseTemplate splits a template into literal text, names and group marks, reading left to
// right so "{{{x}}}" is a brace, the name x, and a brace.
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
		c := t[i]
		doubled := i+1 < len(t) && t[i+1] == c
		switch c {
		case '{':
			if doubled {
				lit.WriteByte(c)
				i++
				continue
			}
			end := strings.IndexByte(t[i+1:], '}')
			if end <= 0 {
				return nil, errTemplate
			}
			name := t[i+1 : i+1+end]
			if strings.ContainsAny(name, "{[]") {
				return nil, errTemplate
			}
			flush()
			segs = append(segs, segment{kind: segName, text: name})
			i += end + 1
		case '}':
			if !doubled {
				return nil, errTemplate
			}
			lit.WriteByte(c)
			i++
		case '[':
			if doubled {
				lit.WriteByte(c)
				i++
				continue
			}
			if inGroup {
				return nil, errTemplate
			}
			flush()
			segs = append(segs, segment{kind: segOpen})
			inGroup = true
		case ']':
			if doubled {
				lit.WriteByte(c)
				i++
				continue
			}
			if !inGroup {
				return nil, errTemplate
			}
			flush()
			segs = append(segs, segment{kind: segClose})
			inGroup = false
		default:
			lit.WriteByte(c)
		}
	}
	if inGroup {
		return nil, errTemplate
	}
	flush()
	return segs, nil
}

// resolve is one name's text: a promoted name first, then a field.
func resolve(rec *leylinev1.DecodeRecord, label, name string) (string, bool) {
	switch name {
	case "device_id":
		return rec.GetDeviceId(), rec.GetDeviceId() != ""
	case "kind":
		return rec.GetKind(), rec.GetKind() != ""
	case "label":
		return label, label != ""
	case "position":
		if p := rec.GetPosition(); p != nil {
			return FormatPosition(p), true
		}
		return "", false
	case "altitude_m":
		if p := rec.GetPosition(); p != nil && p.AltitudeM != nil {
			return formatNumber(p.GetAltitudeM())
		}
		return "", false
	case "rssi_dbfs":
		return formatNumber(rec.GetRssiDbfs())
	case "snr_db":
		return formatNumber(rec.GetSnrDb())
	}
	return FormatField(name, rec.GetFields()[name])
}

// FormatField is a field's value as a template prints it: TEXT as sent, INTEGER in decimal,
// NUMBER with at most two decimals, FLAG as the field's name when true, DATA as hex. It returns
// false for an absent field, empty text, a NaN or infinite number and a false flag.
func FormatField(name string, v *leylinev1.FieldValue) (string, bool) {
	switch x := v.GetValue().(type) {
	case *leylinev1.FieldValue_Text:
		return x.Text, x.Text != ""
	case *leylinev1.FieldValue_Integer:
		return strconv.FormatInt(x.Integer, 10), true
	case *leylinev1.FieldValue_Number:
		return formatNumber(x.Number)
	case *leylinev1.FieldValue_Flag:
		if x.Flag {
			return name, true
		}
	case *leylinev1.FieldValue_Data:
		return hex.EncodeToString(x.Data), len(x.Data) > 0
	}
	return "", false
}

// formatNumber prints a number with the decimals it needs, at most two: 21, 21.5, 21.46.
func formatNumber(v float64) (string, bool) {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return "", false
	}
	r := math.Round(v*100) / 100
	if r == 0 {
		r = 0 // no "-0" for a small negative value
	}
	return strconv.FormatFloat(r, 'f', -1, 64), true
}
