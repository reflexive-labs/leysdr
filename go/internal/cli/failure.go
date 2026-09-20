// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// fullScaleMarginDb is how close to full scale the loudest bin may come before
// tune says so. A full-scale tone reads 0 dBFS at its bin; 3 dB is one step of
// an RTL-SDR's gain table, so the words arrive before the clip does.
const fullScaleMarginDb = 3

// failureWords names what one spectrum row says is wrong, or "" when it says
// nothing: the loudest bin within fullScaleMarginDb of full scale, or nothing
// peakAboveFloorDb above the floor (the row's median), with the gain named as
// the thing to try when it is set by hand to its lowest. The app's
// FailureState (app/Sources/LeylineClient/FailureState.swift) is the same rule
// over its held floor and peak, so both clients say the same thing about the
// same band. A measurement with the thing to try, not a diagnosis: a quiet
// band and a missing antenna read the same from here.
func failureWords(bins []float64, gains []*leylinev1.GainState, elements []*leylinev1.GainElement) string {
	if len(bins) == 0 {
		return ""
	}
	peak := math.Inf(-1)
	for _, v := range bins {
		if v > peak {
			peak = v
		}
	}
	if math.IsInf(peak, 0) || math.IsNaN(peak) {
		return ""
	}
	if peak >= -fullScaleMarginDb {
		reads := fmt.Sprintf("A signal is within %d dB of full scale: the loudest bin reads %.0f dBFS", fullScaleMarginDb, peak)
		switch {
		case gainAtMinimum(gains, elements):
			return reads + " at the lowest gain. Move the antenna away from the transmitter, or add attenuation."
		case gainAuto(gains):
			return reads + " with the gain on auto. Take the gain by hand and lower it before the radio clips."
		default:
			return reads + ". Lower the gain before the radio clips."
		}
	}
	floor := medianDb(bins)
	if math.IsNaN(floor) || peak-floor >= peakAboveFloorDb {
		return ""
	}
	measured := fmt.Sprintf("Nothing is above the noise: no bin is %d dB above the floor (%.0f dBFS)", peakAboveFloorDb, floor)
	if gainAtMinimum(gains, elements) {
		return measured + ", and the gain is at its lowest. Turn it up, or set it to auto."
	}
	return measured + ". Check the antenna; FM broadcast is the band most antennas hear."
}

// gainAuto reports whether any gain element is on auto: then "lower the gain"
// means taking it by hand first, which the sentence says.
func gainAuto(gains []*leylinev1.GainState) bool {
	for _, g := range gains {
		if g.GetAuto() {
			return true
		}
	}
	return false
}

// gainAtMinimum reports whether any gain element is set by hand to the lowest
// level it offers: the bottom of its table, or its minimum. Auto is never at
// the minimum, whatever level it chose.
func gainAtMinimum(gains []*leylinev1.GainState, elements []*leylinev1.GainElement) bool {
	for _, g := range gains {
		if g.GetAuto() {
			continue
		}
		for _, el := range elements {
			if el.GetName() != g.GetElement() {
				continue
			}
			lowest := el.GetMinDb()
			if len(el.GetValidDb()) > 0 {
				lowest = math.Inf(1)
				for _, v := range el.GetValidDb() {
					lowest = math.Min(lowest, v)
				}
			}
			if g.GetDb() <= lowest+0.05 {
				return true
			}
		}
	}
	return false
}
