// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// display is how clients show APRS: one line per record kind in the order a person reads a
// packet, and the symbol and digipeater path beside each station in the table. A station is
// named by its callsign, the device_id, so there is no entity_name.
func display() *leylinev1.DecoderDisplay {
	const located = "{position}[ {altitude_m:0} m][ {object_name}][ {symbol}][ {speed_kmh:0} km/h @ {course_deg:0}°][ {comment}]"
	return &leylinev1.DecoderDisplay{
		Title:  "APRS",
		Symbol: "antenna.radiowaves.left.and.right",
		Summaries: map[string]string{
			"position":  located,
			"object":    located,
			"item":      located,
			"weather":   "[{temp_c:1} °C][ wind {wind_kmh:0} km/h][ @ {wind_dir_deg:0}°][ gust {gust_kmh:0} km/h][ rain {rain_mm_1h:1} mm/h][ humidity {humidity_pct:0}%][ {pressure_hpa:1} hPa]",
			"message":   `→ {addressee}[: {text}][ \{{msg_id}\}]`,
			"ack":       "→ {addressee}: ack {msg_id}",
			"reject":    "→ {addressee}: rej {msg_id}",
			"status":    "{comment}",
			"telemetry": "T#{seq}[ {a1:3}][ {a2:3}][ {a3:3}][ {a4:3}][ {a5:3}][ {digital}]",
			"other":     "{comment}",
		},
		Columns:   []string{"symbol", "path"},
		Positions: true,
	}
}
