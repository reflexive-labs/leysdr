// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// display is how clients show APRS: one line per record kind in the order a person reads a
// packet, and the symbol and digipeater path beside each station in the table. A station is
// named by its callsign, the device_id, so there is no entity_name.
func display() *leylinev1.DecoderDisplay {
	const located = "{position}[ {altitude_m} m][ {object_name}][ {symbol}][ {speed_kmh} km/h][ @ {course_deg}°][ {comment}]"
	return &leylinev1.DecoderDisplay{
		Title:  "APRS",
		Symbol: "antenna.radiowaves.left.and.right",
		Summaries: map[string]string{
			"position":  located,
			"object":    located,
			"item":      located,
			"weather":   "[{temp_c} °C][ wind {wind_kmh} km/h][ @ {wind_dir_deg}°][ gust {gust_kmh} km/h][ rain {rain_mm_1h} mm/h][ humidity {humidity_pct}%][ {pressure_hpa} hPa]",
			"message":   "→ {addressee}[: {text}][ {{{msg_id}}}]",
			"ack":       "→ {addressee}: ack {msg_id}",
			"reject":    "→ {addressee}: rej {msg_id}",
			"status":    "{comment}",
			"telemetry": "T#{seq}[ {a1}][ {a2}][ {a3}][ {a4}][ {a5}][ {digital}]",
			"other":     "{comment}",
		},
		Columns: []string{"symbol", "path"},
	}
}
