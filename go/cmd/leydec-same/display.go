// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// display is how clients show SAME: one line per alert with the originator, the event and the
// counties it covers.
func display() *leylinev1.DecoderDisplay {
	return &leylinev1.DecoderDisplay{
		Title:     "Weather alerts",
		Symbol:    "exclamationmark.triangle",
		Summaries: map[string]string{"alert": "{org} {event_name} ({event})[ for {fips}]"},
	}
}
