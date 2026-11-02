// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// display is how clients show a speech record: its words.
func display() *leylinev1.DecoderDisplay {
	return &leylinev1.DecoderDisplay{
		Title:     "Speech",
		Symbol:    "text.bubble",
		Summaries: map[string]string{"": "{text}"},
	}
}
