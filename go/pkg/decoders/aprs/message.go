// SPDX-License-Identifier: Apache-2.0

package aprs

import (
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// parseTelemetry reads T#seq,a1,a2,a3,a4,a5,bbbbbbbb. The sequence is not
// always a number -- a station may send MIC -- so it is kept as text.
func parseTelemetry(rec *leylinev1.DecodeRecord, s string) {
	rec.Kind = KindTelemetry
	parts := strings.Split(s, ",")
	if len(parts) < 2 {
		other(rec, "T#"+s)
		return
	}
	rec.Fields["seq"] = text(strings.TrimSpace(parts[0]))
	names := []string{"a1", "a2", "a3", "a4", "a5"}
	for i, name := range names {
		if i+1 >= len(parts) {
			break
		}
		v, err := strconv.ParseFloat(strings.TrimSpace(parts[i+1]), 64)
		if err != nil {
			continue
		}
		rec.Fields[name] = number(v)
	}
	if len(parts) >= 7 {
		bits := strings.TrimSpace(parts[6])
		if i := strings.IndexAny(bits, " "); i >= 0 {
			bits = bits[:i]
		}
		rec.Fields["digital"] = text(bits)
	}
}

// parseMessage reads :ADDRESSEE:text{id, and the acks and rejects that share
// the form. The addressee field is exactly nine characters.
func parseMessage(rec *leylinev1.DecodeRecord, s string) {
	if len(s) < 10 || s[9] != ':' {
		other(rec, ":"+s)
		return
	}
	rec.Kind = KindMessage
	rec.Fields["addressee"] = text(strings.TrimRight(s[:9], " "))
	body := s[10:]
	switch {
	case strings.HasPrefix(body, "ack"):
		rec.Kind = KindAck
		rec.Fields["msg_id"] = text(body[3:])
		return
	case strings.HasPrefix(body, "rej"):
		rec.Kind = KindReject
		rec.Fields["msg_id"] = text(body[3:])
		return
	}
	if i := strings.LastIndexByte(body, '{'); i >= 0 {
		rec.Fields["msg_id"] = text(body[i+1:])
		body = body[:i]
	}
	rec.Fields["text"] = text(body)
}
