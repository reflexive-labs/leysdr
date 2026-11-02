// SPDX-License-Identifier: Apache-2.0

package main

import leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

// display is how clients show iqstat: the block's power and how many samples it covered.
func display() *leylinev1.DecoderDisplay {
	return &leylinev1.DecoderDisplay{
		Title:     "IQ power",
		Symbol:    "waveform",
		Summaries: map[string]string{"power": "{power_dbfs:1} dBFS[ over {samples} samples]"},
	}
}
