// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// display is how clients show ADS-B: an aircraft is named by the callsign its identification
// carries, and the table shows its callsign, altitude, speed, track and squawk. A position record
// carries a position only once a pair of frames has fixed it, so the position summary prints
// whichever of position and altitude it has.
func display() *leylinev1.DecoderDisplay {
	return &leylinev1.DecoderDisplay{
		Title:  "Aircraft",
		Symbol: "airplane",
		Summaries: map[string]string{
			"identification": "{callsign}[ category {category}]",
			"position":       "[{position}][ {altitude_ft} ft]",
			"velocity":       "[{ground_speed_kn} kn][ @ {track_deg}°][ {airspeed_kn} kn airspeed][ heading {heading_deg}°][ {vertical_rate_fpm} ft/min]",
			"surveillance":   "DF{df}[ {altitude_ft} ft][ squawk {squawk}]",
		},
		EntityName: "[{callsign}]",
		Columns:    []string{"callsign", "altitude_ft", "ground_speed_kn", "track_deg", "squawk"},
	}
}
