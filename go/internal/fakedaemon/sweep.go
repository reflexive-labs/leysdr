// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"math"
	"sort"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// Where a sweep points the radio, and which part of each span it analyses -- the engine's
// SweepPlan geometry. Two facts drive it: the DC spike sits at the exact capture centre, and the
// span's outer edges roll off. So a step analyses only the two quarter-bands between guardFraction
// and edgeFraction either side of centre, and the sweep advances half a window, which puts the
// next step's lower quarter on this one's DC hole.
const (
	guardFraction = 0.05
	edgeFraction  = 0.45
)

type sweepWindow struct{ lo, hi uint64 }

func (w sweepWindow) contains(hz uint64) bool { return hz >= w.lo && hz < w.hi }

// clamped is the part of this window also inside other; empty when they do not overlap.
func (w sweepWindow) clamped(other sweepWindow) sweepWindow {
	return sweepWindow{lo: max(w.lo, other.lo), hi: min(w.hi, other.hi)}
}

type sweepStep struct {
	centerHz  uint64
	low, high sweepWindow
}

type sweepPlan struct {
	steps   []sweepStep
	covered sweepWindow
	// Set when the request was wider than the radio, so a caller can say so rather than quietly
	// returning less than was asked for.
	clipped bool
}

// planSweep builds the plan, or nil when the range and the radio do not overlap at all. Centres
// are kept inside the device's tuning ranges, so a file device that tunes to exactly one point
// sweeps around that point.
func planSweep(minHz, maxHz, rate uint64, ranges []*leylinev1.FrequencyRange) *sweepPlan {
	if maxHz <= minHz || rate == 0 {
		return nil
	}
	span := float64(rate)
	guardHz, edgeHz := guardFraction*span, edgeFraction*span
	advance := edgeHz - guardHz
	if advance <= 0 {
		return nil
	}
	lowestCenter, highestCenter := uint64(math.MaxUint64), uint64(0)
	for _, r := range ranges {
		// A point range is legitimate: a file device tunes to the frequency its recording was
		// made at, and a sweep over one is a single step.
		if r.GetMaxHz() < r.GetMinHz() || r.GetMaxHz() == 0 {
			continue
		}
		lowestCenter = min(lowestCenter, r.GetMinHz())
		highestCenter = max(highestCenter, r.GetMaxHz())
	}
	if highestCenter == 0 {
		return nil
	}
	// What the radio can actually hear, allowing for the half-span either side of a centre.
	audibleLow, audibleHigh := float64(lowestCenter)-edgeHz, float64(highestCenter)+edgeHz
	wantLow, wantHigh := float64(minHz), float64(maxHz)
	coverLow := math.Max(0, math.Max(wantLow, audibleLow))
	coverHigh := math.Min(wantHigh, audibleHigh)
	if coverHigh <= coverLow {
		return nil
	}
	// The ends first: a step whose upper window starts at the bottom of the range, and one whose
	// lower window ends at the top. They are also the whole plan when the range fits inside a
	// single window, which takes it twice at two tuner positions.
	centers := []float64{math.Max(0, coverLow-guardHz), coverHigh + guardHz}
	if coverHigh-coverLow > advance {
		for c := coverLow + edgeHz; c-edgeHz < coverHigh; c += advance {
			centers = append(centers, c)
			if len(centers) > 100_000 {
				break
			}
		}
	}
	sort.Float64s(centers)
	hzAt := func(v float64) uint64 {
		if v <= 0 {
			return 0
		}
		return uint64(math.Round(v))
	}
	p := &sweepPlan{
		covered: sweepWindow{lo: hzAt(coverLow), hi: hzAt(coverHigh)},
		clipped: coverLow > wantLow+1 || coverHigh < wantHigh-1,
	}
	seen := map[uint64]bool{}
	for _, raw := range centers {
		// Do not tune outside the device's range; a clamped centre still analyses correctly, it
		// just overlaps its neighbour more. A clamped run can repeat a centre, and sweeping the
		// same point twice is wasted dwell.
		hz := hzAt(math.Max(float64(lowestCenter), math.Min(float64(highestCenter), raw)))
		if seen[hz] {
			continue
		}
		seen[hz] = true
		p.steps = append(p.steps, sweepStep{
			centerHz: hz,
			low:      sweepWindow{lo: hzAt(float64(hz) - edgeHz), hi: hzAt(float64(hz) - guardHz)},
			high:     sweepWindow{lo: hzAt(float64(hz) + guardHz), hi: hzAt(float64(hz) + edgeHz)},
		})
	}
	return p
}

// analysedHz is how much of covered at least one window actually looks at. Normally that is all
// of it -- the geometry is for exactly this -- but a request that falls entirely inside one step's
// DC guard is a range the sweep cannot see, and reporting nothing found there would be wrong.
func (p *sweepPlan) analysedHz() uint64 {
	var spans []sweepWindow
	for _, s := range p.steps {
		for _, w := range []sweepWindow{s.low, s.high} {
			if c := w.clamped(p.covered); c.hi > c.lo {
				spans = append(spans, c)
			}
		}
	}
	sort.Slice(spans, func(i, j int) bool { return spans[i].lo < spans[j].lo })
	var total, cursor uint64
	for _, s := range spans {
		start := max(s.lo, cursor)
		if s.hi > start {
			total += s.hi - start
			cursor = s.hi
		}
	}
	return total
}

// looksAt is how many of the plan's analysis windows contain hz: the steps that had a chance to
// see a signal there, whether or not they found one.
func (p *sweepPlan) looksAt(hz uint64) int {
	var n int
	for _, s := range p.steps {
		if s.low.contains(hz) || s.high.contains(hz) {
			n++
		}
	}
	return n
}
