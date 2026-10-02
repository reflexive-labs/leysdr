// SPDX-License-Identifier: Apache-2.0

// Package aprs turns an AX.25 UI frame's information field into a
// DecodeRecord. It covers these forms:
// uncompressed and compressed positions with and without a timestamp, Mic-E,
// objects, items, weather in both its forms, telemetry, messages with their
// acks and rejects, status, and a catch-all that keeps the text.
//
// Nothing here guesses. A field is set when the format says it is there, and a
// form the parser does not recognise becomes kind "other" with its text in
// `comment`, which is the same rule invariant 12 applies to the detector.
package aprs

import (
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
)

// Protocol is the manifest name this parser fills into DecodeRecord.protocol.
const Protocol = "aprs"

// Kinds of record, the values DecodeRecord.kind takes.
const (
	KindPosition  = "position"
	KindWeather   = "weather"
	KindTelemetry = "telemetry"
	KindMessage   = "message"
	KindAck       = "ack"
	KindReject    = "reject"
	KindStatus    = "status"
	KindObject    = "object"
	KindItem      = "item"
	KindOther     = "other"
)

func text(s string) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Text{Text: s}}
}

func number(v float64) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Number{Number: v}}
}

func flag(v bool) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Flag{Flag: v}}
}

// Parse builds a record from a frame whose FCS has already checked out. It
// returns nil for a frame that is not an APRS UI frame, which is how a decoder
// skips connected-mode AX.25 sharing the channel.
func Parse(f *ax25.Frame) *leylinev1.DecodeRecord {
	if f == nil || !f.UI() || f.PID != 0xF0 {
		return nil
	}
	rec := &leylinev1.DecodeRecord{
		Protocol: Protocol,
		DeviceId: f.Source.String(),
		Raw:      f.Raw,
		Fields:   map[string]*leylinev1.FieldValue{},
	}
	rec.Fields["destination"] = text(f.Dest.String())
	if p := f.PathString(); p != "" {
		rec.Fields["path"] = text(p)
	}
	info := string(f.Info)
	if info == "" {
		rec.Kind = KindOther
		return rec
	}
	switch info[0] {
	case '!', '=':
		parsePosition(rec, info[1:])
	case '/', '@':
		// A timestamp of seven characters sits between the data type
		// identifier and the position.
		parsePosition(rec, trimTimestamp(info[1:]))
	case '\'', '`', 0x1c, 0x1d:
		parseMicE(rec, f.Dest.Call, info[1:])
	case ';':
		parseObject(rec, info[1:])
	case ')':
		parseItem(rec, info[1:])
	case '_':
		parsePositionlessWeather(rec, info[1:])
	case 'T':
		if strings.HasPrefix(info, "T#") {
			parseTelemetry(rec, info[2:])
			return rec
		}
		other(rec, info)
	case ':':
		parseMessage(rec, info[1:])
	case '>':
		rec.Kind = KindStatus
		rec.Fields["comment"] = text(strings.TrimSpace(trimStatusTimestamp(info[1:])))
	default:
		other(rec, info)
	}
	return rec
}

func other(rec *leylinev1.DecodeRecord, info string) {
	rec.Kind = KindOther
	rec.Fields["comment"] = text(info)
}

// trimTimestamp drops the seven-character timestamp that follows / and @.
func trimTimestamp(s string) string {
	if len(s) >= 7 {
		switch s[6] {
		case 'z', '/', 'h':
			return s[7:]
		}
	}
	return s
}

// trimStatusTimestamp drops the optional timestamp a status report may carry,
// which is the only place APRS uses a bare DDHHMMz without a position.
func trimStatusTimestamp(s string) string {
	if len(s) >= 7 && s[6] == 'z' && allDigits(s[:6]) {
		return s[7:]
	}
	return s
}

func allDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return len(s) > 0
}
