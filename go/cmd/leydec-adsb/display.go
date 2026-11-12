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
			"position":       "[{position}][ {altitude_ft:0} ft]",
			"velocity":       "[{ground_speed_kn:0} kn][ @ {track_deg:0}°][ {airspeed_kn:0} kn airspeed][ heading {heading_deg:0}°][ {vertical_rate_fpm:0} ft/min]",
			"surveillance":   "DF{df}[ {altitude_ft:0} ft][ squawk {squawk}]",
		},
		EntityName: "[{callsign}]",
		Columns:    []string{"callsign", "altitude_ft:0", "ground_speed_kn:0", "track_deg:0", "squawk"},
		Positions:  true,
	}
}
