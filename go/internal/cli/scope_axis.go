// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"

	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// scopeStepsMs are the tick spacings the time axis may use: the round numbers
// a person counts milliseconds in.
var scopeStepsMs = []int{1, 2, 5, 10, 20, 50, 100}

// scopeTick is one instant the axis names: milliseconds from the start of the
// window, and the trace column it falls in.
type scopeTick struct {
	ms  int
	col int
}

// scopeTickStep picks the spacing: the finest round step that keeps the axis
// to eight marks and still leaves the width room to write them all.
func scopeTickStep(windowMs, cols int) int {
	room := cols / (len(fmt.Sprintf("%d ms", windowMs)) + 2)
	for _, step := range scopeStepsMs {
		n := windowMs/step + 1
		if windowMs%step != 0 {
			n++
		}
		if n <= 8 && n <= room {
			return step
		}
	}
	return scopeStepsMs[len(scopeStepsMs)-1]
}

// scopeTicks is the marks the axis draws: the round steps across the window,
// and the window's own length at the right edge, which is the figure the
// header states. Two steps that land in one column are one mark.
func scopeTicks(windowMs, cols int) []scopeTick {
	if windowMs <= 0 || cols <= 0 {
		return nil
	}
	step := scopeTickStep(windowMs, cols)
	col := func(ms int) int { return min(ms*cols/windowMs, cols-1) }
	end := col(windowMs)
	ticks, last := []scopeTick{}, -1
	for ms := 0; ms < windowMs; ms += step {
		c := col(ms)
		if c <= last || c >= end {
			continue
		}
		ticks = append(ticks, scopeTick{ms: ms, col: c})
		last = c
	}
	return append(ticks, scopeTick{ms: windowMs, col: end})
}

// scopeGutter is the vertical scale beside one row of a trace or a clip: the
// top, the axis and the bottom, rather than all eight rows, because three
// numbers are what a scale is read from. The numbers are the tap's own units
// -- hertz are the header's tuning line -- and under the fitted scale they
// are whichever step the fit has snapped to, rather than a fixed ±1.0.
func scopeGutter(st ui.Style, gutterW, row int, scale float64) string {
	label := ""
	switch row {
	case 0:
		label = scopeScaleLabel(scale)
	case scopeHeight / 2:
		label = "0"
	case scopeHeight - 1:
		label = scopeScaleLabel(-scale)
	}
	// An amplitude has no unit to write: the header names the tap the numbers
	// are in.
	return chartGutter(st, gutterW, label, "")
}

func (v *scopeView) gutter(row int, scale float64) string {
	return scopeGutter(v.st, v.gutterW, row, scale)
}

// axis draws the timebase under the trace: a rule with a mark at every
// labelled instant, then the labels. Time runs from the start of the frame
// whether or not --trigger auto moved where that start is, because what the
// axis measures is the window, and the window is what the header states.
func (v *scopeView) axis(windowMs int) []string {
	cols := v.cols()
	ticks := scopeTicks(windowMs, cols)
	marks := make([]axisTick, len(ticks))
	for i, t := range ticks {
		marks[i] = axisTick{col: t.col, text: fmt.Sprintf("%d ms", t.ms)}
	}
	return chartAxis(v.st, v.gutterW, cols, marks)
}
