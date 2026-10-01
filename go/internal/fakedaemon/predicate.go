// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// matchPredicate is the daemon-side stateless filter the design doc calls for (docs/design/
// decoders.md, "Predicates and delivery"): every clause of an `all` predicate must hold, and an
// unset (or empty) predicate matches every record. This is the Go mirror of the operators the
// Swift daemon evaluates, so `ley watch` filters against the fake exactly as it will against the
// engine.
func matchPredicate(pred *leylinev1.Predicate, rec *leylinev1.DecodeRecord) bool {
	if pred == nil {
		return true
	}
	for _, c := range pred.GetAll() {
		if !matchClause(c, rec) {
			return false
		}
	}
	return true
}

func matchClause(c *leylinev1.Clause, rec *leylinev1.DecodeRecord) bool {
	switch t := c.GetTest().(type) {
	case *leylinev1.Clause_Field:
		return matchField(t.Field, rec)
	case *leylinev1.Clause_Geo:
		return matchGeo(t.Geo, rec)
	default:
		return true
	}
}

// matchGeo is the spatial clause: a record within radius_m of the centre. A record with no
// position never matches, as decode.proto states.
func matchGeo(g *leylinev1.GeoTest, rec *leylinev1.DecodeRecord) bool {
	p := rec.GetPosition()
	if p == nil || g.GetCenter() == nil || g.GetRadiusM() <= 0 {
		return false
	}
	return HaversineMetres(g.GetCenter(), p) <= g.GetRadiusM()
}

// matchField applies one FieldTest. The field is a promoted name (device_id, kind, protocol,
// record_id, position.*) or a `fields` key; numbers compare numerically and everything else as
// text, the rule decode.proto states for FieldTest.
func matchField(ft *leylinev1.FieldTest, rec *leylinev1.DecodeRecord) bool {
	sval, num, isNum, present := resolveField(rec, ft.GetField())
	vals := ft.GetValues()
	switch ft.GetOp() {
	case leylinev1.PredicateOp_PRED_EXISTS:
		return present && sval != ""
	case leylinev1.PredicateOp_PRED_EQ:
		return present && scalarEquals(sval, num, isNum, first(vals))
	case leylinev1.PredicateOp_PRED_NE:
		return !present || !scalarEquals(sval, num, isNum, first(vals))
	case leylinev1.PredicateOp_PRED_IN:
		return present && anyEquals(sval, num, isNum, vals)
	case leylinev1.PredicateOp_PRED_NOT_IN:
		return !present || !anyEquals(sval, num, isNum, vals)
	case leylinev1.PredicateOp_PRED_CONTAINS:
		// The field is a delimited list (a SAME alert's FIPS codes); it matches when any of the
		// test's values is contained in it, which is what --county over several codes asks for.
		if !present {
			return false
		}
		for _, v := range vals {
			if s := fieldValueString(v); s != "" && strings.Contains(sval, s) {
				return true
			}
		}
		return false
	case leylinev1.PredicateOp_PRED_LT, leylinev1.PredicateOp_PRED_LTE,
		leylinev1.PredicateOp_PRED_GT, leylinev1.PredicateOp_PRED_GTE:
		if !present {
			return false
		}
		want, ok := fieldValueNumber(first(vals))
		if !ok || !isNum {
			return false
		}
		return compareNum(ft.GetOp(), num, want)
	default:
		return false
	}
}

func compareNum(op leylinev1.PredicateOp, got, want float64) bool {
	switch op {
	case leylinev1.PredicateOp_PRED_LT:
		return got < want
	case leylinev1.PredicateOp_PRED_LTE:
		return got <= want
	case leylinev1.PredicateOp_PRED_GT:
		return got > want
	case leylinev1.PredicateOp_PRED_GTE:
		return got >= want
	default:
		return false
	}
}

// scalarEquals is EQ's test: numbers when both sides are numeric, text otherwise.
func scalarEquals(sval string, num float64, isNum bool, v *leylinev1.FieldValue) bool {
	if v == nil {
		return false
	}
	if isNum {
		if want, ok := fieldValueNumber(v); ok {
			return num == want
		}
	}
	return sval == fieldValueString(v)
}

func anyEquals(sval string, num float64, isNum bool, vals []*leylinev1.FieldValue) bool {
	for _, v := range vals {
		if scalarEquals(sval, num, isNum, v) {
			return true
		}
	}
	return false
}

func first(vals []*leylinev1.FieldValue) *leylinev1.FieldValue {
	if len(vals) == 0 {
		return nil
	}
	return vals[0]
}

// resolveField reads one field from a record: its string form, its numeric form when it has one,
// whether it is numeric, and whether it is present. Promoted names are resolved first, then a
// `fields` key. A field with no value is not present.
func resolveField(rec *leylinev1.DecodeRecord, name string) (sval string, num float64, isNum, present bool) {
	switch name {
	case "protocol":
		return rec.GetProtocol(), 0, false, rec.GetProtocol() != ""
	case "device_id":
		return rec.GetDeviceId(), 0, false, rec.GetDeviceId() != ""
	case "kind":
		return rec.GetKind(), 0, false, rec.GetKind() != ""
	case "record_id":
		return rec.GetRecordId(), 0, false, rec.GetRecordId() != ""
	case "channel_id":
		return rec.GetChannelId(), 0, false, rec.GetChannelId() != ""
	case "job_id":
		return rec.GetJobId(), 0, false, rec.GetJobId() != ""
	case "rssi_dbfs":
		return numString(rec.GetRssiDbfs()), rec.GetRssiDbfs(), true, true
	case "snr_db":
		return numString(rec.GetSnrDb()), rec.GetSnrDb(), true, true
	case "position.latitude":
		if p := rec.GetPosition(); p != nil {
			return numString(p.GetLatitude()), p.GetLatitude(), true, true
		}
		return "", 0, false, false
	case "position.longitude":
		if p := rec.GetPosition(); p != nil {
			return numString(p.GetLongitude()), p.GetLongitude(), true, true
		}
		return "", 0, false, false
	case "position.altitude_m":
		if p := rec.GetPosition(); p != nil && p.AltitudeM != nil {
			return numString(p.GetAltitudeM()), p.GetAltitudeM(), true, true
		}
		return "", 0, false, false
	}
	v, ok := rec.GetFields()[name]
	if !ok || v == nil {
		return "", 0, false, false
	}
	if n, isN := fieldValueNumber(v); isN {
		return numString(n), n, true, true
	}
	return fieldValueString(v), 0, false, true
}

// fieldValueString is a FieldValue as text: what a text clause compares against and what a
// CONTAINS clause searches in. A number is formatted the way resolveField formats a numeric
// field, so `--where temp_c=21` and a stored 21.0 read alike.
func fieldValueString(v *leylinev1.FieldValue) string {
	switch t := v.GetValue().(type) {
	case *leylinev1.FieldValue_Text:
		return t.Text
	case *leylinev1.FieldValue_Integer:
		return strconv.FormatInt(t.Integer, 10)
	case *leylinev1.FieldValue_Number:
		return numString(t.Number)
	case *leylinev1.FieldValue_Flag:
		return strconv.FormatBool(t.Flag)
	default:
		return ""
	}
}

// fieldValueNumber is a FieldValue as a number when it is one: an integer, a number, or a text
// value that parses as a number (a --where token carries its value as text). Reports false
// otherwise.
func fieldValueNumber(v *leylinev1.FieldValue) (float64, bool) {
	switch t := v.GetValue().(type) {
	case *leylinev1.FieldValue_Integer:
		return float64(t.Integer), true
	case *leylinev1.FieldValue_Number:
		return t.Number, true
	case *leylinev1.FieldValue_Text:
		n, err := strconv.ParseFloat(strings.TrimSpace(t.Text), 64)
		return n, err == nil
	default:
		return 0, false
	}
}

func numString(f float64) string { return strconv.FormatFloat(f, 'f', -1, 64) }
