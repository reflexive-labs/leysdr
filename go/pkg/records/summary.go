// SPDX-License-Identifier: Apache-2.0

// Package records folds decode records into the two shapes a client renders: one line per record
// (Summary) and the entity table `ley track` keeps (Table). Both are presentation over the
// daemon's records -- no decoding happens here (AGENTS.md invariant 2), and a field a decoder
// does not send is left out rather than invented.
package records

import (
	"fmt"
	"math"
	"strings"
	"unicode"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// Summary renders one record as the line `ley decode` and `ley track` print, using the
// protocol's own terms. The record's `kind` chooses the form;
// a kind nothing here knows falls back to the raw text, which is always kept.
func Summary(rec *leylinev1.DecodeRecord) string {
	switch rec.GetKind() {
	case "position", "object", "item":
		return positionSummary(rec)
	case "weather":
		return weatherSummary(rec)
	case "message":
		return messageSummary(rec)
	case "status":
		return firstNonEmpty(Text(rec, "text"), Text(rec, "status"), Text(rec, "comment"), rawText(rec))
	case "telemetry":
		return telemetrySummary(rec)
	}
	if rec.GetPosition() != nil {
		return positionSummary(rec)
	}
	return firstNonEmpty(Text(rec, "text"), Text(rec, "comment"), rawText(rec))
}

// positionSummary prints the position, altitude, object name, symbol, course and speed, and comment.
func positionSummary(rec *leylinev1.DecodeRecord) string {
	parts := []string{}
	if p := rec.GetPosition(); p != nil {
		parts = append(parts, FormatPosition(p))
		if p.AltitudeM != nil {
			parts = append(parts, fmt.Sprintf("%.0f m", p.GetAltitudeM()))
		}
	}
	if name := Text(rec, "object_name"); name != "" {
		parts = append(parts, name)
	}
	if sym := Text(rec, "symbol"); sym != "" {
		parts = append(parts, sym)
	}
	if course, ok := Number(rec, "course_deg"); ok {
		if speed, sok := Number(rec, "speed_kmh"); sok {
			parts = append(parts, fmt.Sprintf("%.0f km/h @ %.0f°", speed, course))
		} else {
			parts = append(parts, fmt.Sprintf("@ %.0f°", course))
		}
	}
	if c := Text(rec, "comment"); c != "" {
		parts = append(parts, c)
	}
	return strings.Join(parts, " ")
}

// FormatPosition renders a position the way a chart's axis would: degrees with the hemisphere
// letter, so a minus sign can never be read as a range dash.
func FormatPosition(p *leylinev1.Position) string {
	if p == nil {
		return ""
	}
	ns, ew := "N", "E"
	if p.GetLatitude() < 0 {
		ns = "S"
	}
	if p.GetLongitude() < 0 {
		ew = "W"
	}
	return fmt.Sprintf("%.4f%s %.4f%s", math.Abs(p.GetLatitude()), ns, math.Abs(p.GetLongitude()), ew)
}

// weatherSummary reports the measurements the station sent, in the order a person reads a
// weather report, and nothing it did not send.
func weatherSummary(rec *leylinev1.DecodeRecord) string {
	var parts []string
	if v, ok := Number(rec, "temp_c"); ok {
		parts = append(parts, fmt.Sprintf("%.1f °C", v))
	}
	if v, ok := Number(rec, "wind_kmh"); ok {
		wind := fmt.Sprintf("wind %.0f km/h", v)
		if dir, dok := Number(rec, "wind_dir_deg"); dok {
			wind += fmt.Sprintf(" @ %.0f°", dir)
		}
		parts = append(parts, wind)
	}
	if v, ok := Number(rec, "gust_kmh"); ok {
		parts = append(parts, fmt.Sprintf("gust %.0f km/h", v))
	}
	if v, ok := Number(rec, "rain_mm_1h"); ok {
		parts = append(parts, fmt.Sprintf("rain %.1f mm/h", v))
	}
	if v, ok := Number(rec, "humidity_pct"); ok {
		parts = append(parts, fmt.Sprintf("humidity %.0f%%", v))
	}
	if v, ok := Number(rec, "pressure_hpa"); ok {
		parts = append(parts, fmt.Sprintf("%.1f hPa", v))
	}
	if len(parts) == 0 {
		return rawText(rec)
	}
	return strings.Join(parts, " ")
}

// messageSummary prints the addressee, then the message text and id.
func messageSummary(rec *leylinev1.DecodeRecord) string {
	to, text := Text(rec, "addressee"), Text(rec, "text")
	if to == "" {
		return firstNonEmpty(text, rawText(rec))
	}
	line := "→ " + to
	if text != "" {
		line += ": " + text
	}
	if id := Text(rec, "msg_id"); id != "" {
		line += " {" + id + "}"
	}
	return line
}

// telemetrySummary keeps the protocol's own spelling of a telemetry frame, because that is what
// the station's own documentation names its channels by.
func telemetrySummary(rec *leylinev1.DecodeRecord) string {
	head := "T#"
	if seq, ok := Integer(rec, "seq"); ok {
		head += fmt.Sprintf("%03d", seq)
	}
	var vals []string
	for _, name := range []string{"a1", "a2", "a3", "a4", "a5"} {
		if v, ok := Number(rec, name); ok {
			vals = append(vals, fmt.Sprintf("%g", v))
		}
	}
	if d := Text(rec, "digital"); d != "" {
		vals = append(vals, d)
	}
	if len(vals) == 0 {
		return firstNonEmpty(head, rawText(rec))
	}
	return head + " " + strings.Join(vals, " ")
}

// Text is the text value of a field, empty when it is absent or of another type.
func Text(rec *leylinev1.DecodeRecord, name string) string {
	return rec.GetFields()[name].GetText()
}

// Number is the numeric value of a field: a number as sent, or an integer widened to one, since
// a decoder is free to send 21 where another sends 21.0.
func Number(rec *leylinev1.DecodeRecord, name string) (float64, bool) {
	switch v := rec.GetFields()[name].GetValue().(type) {
	case *leylinev1.FieldValue_Number:
		return v.Number, true
	case *leylinev1.FieldValue_Integer:
		return float64(v.Integer), true
	}
	return 0, false
}

// Integer is the integer value of a field, and a whole number sent as a number.
func Integer(rec *leylinev1.DecodeRecord, name string) (int64, bool) {
	switch v := rec.GetFields()[name].GetValue().(type) {
	case *leylinev1.FieldValue_Integer:
		return v.Integer, true
	case *leylinev1.FieldValue_Number:
		return int64(v.Number), v.Number == math.Trunc(v.Number)
	}
	return 0, false
}

// rawText is the payload as text, which every record keeps. Control bytes are dropped rather
// than written to a terminal: an AX.25 frame carries bytes no font has a glyph for.
func rawText(rec *leylinev1.DecodeRecord) string {
	var b strings.Builder
	for _, r := range string(rec.GetRaw()) {
		if r == unicode.ReplacementChar || (unicode.IsControl(r) && r != '\t') {
			continue
		}
		b.WriteRune(r)
	}
	return strings.TrimSpace(b.String())
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
