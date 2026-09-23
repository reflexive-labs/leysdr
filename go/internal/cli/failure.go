// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// fullScaleMarginDb is how close to full scale the loudest bin may come before
// tune says so, when the daemon has not said whether the radio is clipping. A
// full-scale tone reads 0 dBFS at its bin; 3 dB is one step of an RTL-SDR's
// gain table, so the warning appears before the radio clips.
const fullScaleMarginDb = 3

// clippingFloor is the fraction of a CaptureLevel interval's samples at the
// converter's rails above which the radio is clipping. Not zero: an interval
// is 600 000 samples at 2.4 MSPS, and one of them at a rail is a noise
// excursion or a spur, not an overload. One in ten thousand is a clip every
// 4 ms, which is audible.
const clippingFloor = 1e-4

// clipping reports whether a CaptureLevel says the radio is clipping: more of
// the interval's samples at the rails than clippingFloor allows. Nil, or an
// empty interval, is not clipping, because nothing was measured.
func clipping(level *leylinev1.CaptureLevel) bool {
	total := level.GetTotalSamples()
	if total == 0 {
		return false
	}
	return float64(level.GetClippedSamples())/float64(total) > clippingFloor
}

// failureWords describes what the capture's level and one spectrum row show is
// wrong, or "" when nothing is: the radio clipping (the level's rail count),
// or nothing peakAboveFloorDb above the floor (the row's median), suggesting
// the gain when it is set by hand to its lowest.
// The level is the clipping authority: while one is in hand a bin near full
// scale is not named at all, because a strong steady carrier sits there all
// day with nothing wrong. Only without a level (an older daemon) does the
// loudest bin within fullScaleMarginDb of full scale stand in for it. The
// app's FailureState (app/Sources/LeylineClient/FailureState.swift) is the
// same rule, so both clients report the same band the same way. It reports a
// measurement and a suggestion, not a diagnosis: a quiet band and a missing
// antenna look the same from here.
func failureWords(bins []float64, level *leylinev1.CaptureLevel, gains []*leylinev1.GainState, elements []*leylinev1.GainElement) string {
	if clipping(level) {
		reads := fmt.Sprintf("The radio is clipping: %d of %d samples (%s) hit the converter's rails",
			level.GetClippedSamples(), level.GetTotalSamples(),
			percentWords(float64(level.GetClippedSamples())/float64(level.GetTotalSamples())))
		switch {
		case gainAtMinimum(gains, elements):
			return reads + " at the lowest gain. Move the antenna away from the transmitter, or add attenuation."
		case gainAuto(gains):
			return reads + " with the gain on auto. Take the gain by hand and lower it."
		default:
			return reads + ". Lower the gain."
		}
	}
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
	if level == nil && peak >= -fullScaleMarginDb {
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

// percentWords is a fraction as a percentage with one decimal, or two when
// one would round a fraction just over clippingFloor down to "0.0 %".
func percentWords(fraction float64) string {
	pct := fraction * 100
	if pct < 0.1 {
		return fmt.Sprintf("%.2f %%", pct)
	}
	return fmt.Sprintf("%.1f %%", pct)
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
