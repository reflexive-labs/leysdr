// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// display is how clients show AIS: a vessel is named by the name its static report carries, and
// the table shows its callsign, speed, course and destination.
func display() *leylinev1.DecoderDisplay {
	return &leylinev1.DecoderDisplay{
		Title:  "Vessels",
		Symbol: "ferry",
		Summaries: map[string]string{
			"position": "{position}[ {sog_kn:1} kn][ @ {cog_deg:0}°]",
			"static":   "[{name}][ {callsign}][ → {destination}]",
			"other":    "message type {msg_type}",
		},
		EntityName: "{name}",
		Columns:    []string{"callsign", "sog_kn:1", "cog_deg:0", "destination"},
	}
}
