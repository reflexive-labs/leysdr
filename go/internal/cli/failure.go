// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"
	"strings"

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

// clipping reports whether a CaptureLevel says the radio is clipping: at least
// clippingFloor of the interval's samples at the rails, the app's rule
// (FailureState.name). Nil, or an empty interval, is not clipping, because
// nothing was measured.
func clipping(level *leylinev1.CaptureLevel) bool {
	total := level.GetTotalSamples()
	if total == 0 {
		return false
	}
	return float64(level.GetClippedSamples())/float64(total) >= clippingFloor
}

// failureWords describes what the capture's level and one spectrum row show is
// wrong, or "" when nothing is: the radio clipping (clippingWords), or what
// the row shows (bandWords). It is the one-shot reading a persistent tune and
// the MCP adapter's tune tool print; a live `ley tune` prints bandWords once
// in its banner and leaves clipping to clipHold, which says it once it has
// lasted.
func failureWords(bins []float64, level *leylinev1.CaptureLevel, gains []*leylinev1.GainState, elements []*leylinev1.GainElement) string {
	if words := clippingWords(level, gains, elements); words != "" {
		return words
	}
	return bandWords(bins, level != nil, gains, elements)
}

// clippingWords is the clipping line for one CaptureLevel, with the gain
// clause (gainAdvice), or "" when the level is not clipping. The app's
// FailureState.detail (app/Sources/LeylineClient/FailureState.swift) is the
// same sentence, so both clients report the same radio the same way.
func clippingWords(level *leylinev1.CaptureLevel, gains []*leylinev1.GainState, elements []*leylinev1.GainElement) string {
	if !clipping(level) {
		return ""
	}
	reads := fmt.Sprintf("The radio is clipping: %d of %d samples (%s) hit the converter's rails",
		level.GetClippedSamples(), level.GetTotalSamples(),
		percentWords(float64(level.GetClippedSamples())/float64(level.GetTotalSamples())))
	switch {
	case gainAtMinimum(gains, elements):
		return reads + " at the lowest gain. Move the antenna away from the transmitter, or add attenuation."
	case gainAuto(gains):
		return reads + " with the gain on auto. Take the gain by hand and lower it."
	default:
		return reads + ". " + lowerGainWords(gains, elements) + "."
	}
}

// bandWords is what one spectrum row shows is wrong, or "": nothing
// peakAboveFloorDb above the floor (the row's median), suggesting the gain
// when every stage is set by hand to its lowest. The level is the clipping
// authority: while one is in hand (haveLevel) a bin near full scale is not
// named at all, because a strong steady carrier sits there all day with
// nothing wrong. Only without a level (an older daemon) does the loudest bin
// within fullScaleMarginDb of full scale stand in for it. It reports a
// measurement and a suggestion, not a diagnosis: a quiet band and a missing
// antenna look the same from here.
func bandWords(bins []float64, haveLevel bool, gains []*leylinev1.GainState, elements []*leylinev1.GainElement) string {
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
	if !haveLevel && peak >= -fullScaleMarginDb {
		reads := fmt.Sprintf("A signal is within %d dB of full scale: the loudest bin reads %.0f dBFS", fullScaleMarginDb, peak)
		switch {
		case gainAtMinimum(gains, elements):
			return reads + " at the lowest gain. Move the antenna away from the transmitter, or add attenuation."
		case gainAuto(gains):
			return reads + " with the gain on auto. Take the gain by hand and lower it before the radio clips."
		default:
			return reads + ". " + lowerGainWords(gains, elements) + " before the radio clips."
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

// switchStage reports whether a gain element is a two-value switch rather
// than a gain to set: exactly two table entries and no step, as a HackRF
// advertises its AMP (0 or 11 dB). A switch is left out of "the lowest gain",
// because the HackRF at LNA 8, VGA 20 and the AMP off was once told it was at
// its lowest (plans/app.md, M2-10).
func switchStage(el *leylinev1.GainElement) bool {
	return len(el.GetValidDb()) == 2 && el.GetStepDb() == 0
}

// lowestDb is the lowest level a gain element offers: the bottom of its table,
// or its minimum.
func lowestDb(el *leylinev1.GainElement) float64 {
	if len(el.GetValidDb()) == 0 {
		return el.GetMinDb()
	}
	lowest := math.Inf(1)
	for _, v := range el.GetValidDb() {
		lowest = math.Min(lowest, v)
	}
	return lowest
}

// gainStates pairs each continuous or table stage, in the device's order,
// with the capture's state for it (nil when the capture reports none).
func gainStates(gains []*leylinev1.GainState, elements []*leylinev1.GainElement) (stages []*leylinev1.GainElement, states []*leylinev1.GainState) {
	for _, el := range elements {
		if switchStage(el) {
			continue
		}
		var state *leylinev1.GainState
		for _, g := range gains {
			if g.GetElement() == el.GetName() {
				state = g
				break
			}
		}
		stages = append(stages, el)
		states = append(states, state)
	}
	return stages, states
}

// gainAtMinimum reports whether every continuous or table stage is set by hand
// to its lowest level: then the radio cannot be turned down, and the advice is
// the antenna. A two-value stage does not count (switchStage), a stage on auto
// is never at its lowest whatever level it chose, and a radio with no stage to
// count has no gain to be at the bottom of. The app's
// FailureState.gainAtMinimum is the same rule.
func gainAtMinimum(gains []*leylinev1.GainState, elements []*leylinev1.GainElement) bool {
	stages, states := gainStates(gains, elements)
	for i, el := range stages {
		g := states[i]
		if g == nil || g.GetAuto() || g.GetDb() > lowestDb(el)+0.05 {
			return false
		}
	}
	return len(stages) > 0
}

// lowerGainWords is the advice for a radio set by hand above its lowest, with
// no full stop: "Lower the gain" on a radio with one stage to set, and on a
// radio with several the stages above their lowest in the device's order,
// "Lower the VGA gain" or "Lower the LNA or VGA gain". The app's
// FailureState.detail builds the same words.
func lowerGainWords(gains []*leylinev1.GainState, elements []*leylinev1.GainElement) string {
	stages, states := gainStates(gains, elements)
	if len(stages) < 2 {
		return "Lower the gain"
	}
	var above []string
	for i, el := range stages {
		if g := states[i]; g != nil && !g.GetAuto() && g.GetDb() > lowestDb(el)+0.05 {
			above = append(above, el.GetName())
		}
	}
	switch len(above) {
	case 0:
		return "Lower the gain"
	case 1:
		return "Lower the " + above[0] + " gain"
	}
	return "Lower the " + strings.Join(above[:len(above)-1], ", ") + " or " + above[len(above)-1] + " gain"
}
