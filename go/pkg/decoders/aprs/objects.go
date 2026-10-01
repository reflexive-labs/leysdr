// SPDX-License-Identifier: Apache-2.0

package aprs

import (
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// parseObject reads ;NAME_____*DDHHMMz followed by a position. A star marks
// the object live and an underscore marks it killed; the name is
// exactly nine characters, padded with spaces.
func parseObject(rec *leylinev1.DecodeRecord, s string) {
	rec.Kind = KindObject
	if len(s) < 17 {
		other(rec, s)
		return
	}
	rec.Fields["object_name"] = text(strings.TrimRight(s[0:9], " "))
	switch s[9] {
	case '*':
		rec.Fields["alive"] = flag(true)
	case '_':
		rec.Fields["alive"] = flag(false)
	default:
		other(rec, s)
		return
	}
	kind := rec.Kind
	parsePosition(rec, trimTimestamp(s[10:]))
	// parsePosition sets the record kind from what it parsed; an object carrying
	// weather is still weather, but an object carrying a plain position is an
	// object rather than a position report.
	if rec.Kind == KindPosition {
		rec.Kind = kind
	}
}

// parseItem reads )NAME! or )NAME_ followed by a position. The name runs three
// to nine characters and the terminator shows whether the item is live.
func parseItem(rec *leylinev1.DecodeRecord, s string) {
	rec.Kind = KindItem
	end := -1
	for i := 0; i < len(s) && i < 10; i++ {
		if s[i] == '!' || s[i] == '_' {
			end = i
			break
		}
	}
	if end < 3 {
		other(rec, s)
		return
	}
	rec.Fields["object_name"] = text(s[:end])
	rec.Fields["alive"] = flag(s[end] == '!')
	kind := rec.Kind
	parsePosition(rec, s[end+1:])
	if rec.Kind == KindPosition {
		rec.Kind = kind
	}
}
