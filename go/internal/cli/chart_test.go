// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"math"
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/internal/ui"
)

// One normalisation serves every chart, so the same colour means the same
// thing whichever picture a reader is looking at: the value's distance from
// what that chart calls nothing, clamped to the ends of the ramp.
func TestRampFracIsOneRule(t *testing.T) {
	for _, tc := range []struct {
		name              string
		value, floor, top float64
		want              float64
	}{
		{"cold end", -90, -90, -30, 0},
		{"hot end", -30, -90, -30, 1},
		{"halfway", -60, -90, -30, 0.5},
		{"under the floor", -120, -90, -30, 0},
		{"over the top", 0, -90, -30, 1},
		{"silence to a waveform's scale", 0, 0, 0.5, 0},
		{"a waveform at its scale", 0.5, 0, 0.5, 1},
		{"no span to place it on", -40, -90, -90, 0},
		{"references not measured yet", -40, math.NaN(), math.NaN(), 0},
		{"nothing to place", math.NaN(), -90, -30, 0},
	} {
		if got := rampFrac(tc.value, tc.floor, tc.top); math.Abs(got-tc.want) > 1e-9 {
			t.Errorf("%s: rampFrac(%g, %g, %g) = %g, want %g", tc.name, tc.value, tc.floor, tc.top, got, tc.want)
		}
	}
}

// Each chart keys the ramp to its own cold end, which is what section 3a of
// the style guide states: the noise line for a spectrum, the bottom of the
// held scale for a meter, silence for a clip. All three reach the same hot
// end, so a full-scale anything is the same red.
func TestEveryChartRampsFromItsOwnFloor(t *testing.T) {
	v := newSpectrumView(ui.Style{Unicode: true}, 80, 0, false, false)
	v.noise, v.peak = -90, -30
	if got := v.levelBand(v.noise); got != 0 {
		t.Errorf("a column on the noise line takes ramp step %d, want the cold end", got)
	}
	if got := v.levelBand(v.peak); got != chartLevelSteps-1 {
		t.Errorf("the loudest column takes ramp step %d, want the hot end %d", got, chartLevelSteps-1)
	}
	if got := levelsFrac(levelsFloorDb); got != 0 {
		t.Errorf("the meter's floor is at %g of the ramp, want the cold end", got)
	}
	if got := levelsFrac(levelsTopDb); got != 1 {
		t.Errorf("full scale is at %g of the ramp, want the hot end", got)
	}
	if got := waveformFrac(0, 0.5); got != 0 {
		t.Errorf("silence is at %g of the ramp, want the cold end", got)
	}
	if got := waveformFrac(-0.5, 0.5); got != 1 {
		t.Errorf("a column at the scale is at %g of the ramp, want the hot end", got)
	}
}

// Every chart's gutter is the width its view budgeted for it and ends in the
// axis column, so a spectrum, a meter and a trace asked for the same --width
// line their plots up on the same column.
func TestChartGuttersEndAtTheAxis(t *testing.T) {
	st := ui.Style{Unicode: true}
	axis := string(st.Glyphs().TreeTrunk)
	spectrum := newSpectrumView(st, 80, 0, false, false)
	levels := newLevelsView(st, 80, levelsHeight, false, false)
	scope := newScopeView(st, 80, scopeScale{fixed: 1}, false)
	for _, tc := range []struct {
		name  string
		line  string
		width int
	}{
		// A spectrum writes its own axis column, so its gutter is a column
		// short and the level is plain rather than muted.
		{"spectrum", spectrum.gutter(fmtDb(-30), true) + axis, spectrumGutter},
		{"levels", levels.gutter(0), levelsGutterW},
		{"scope", scopeGutter(st, scope.gutterW, 0, 1), scope.gutterW},
	} {
		if got := ui.Visible(tc.line); got != tc.width {
			t.Errorf("%s: the gutter is %d columns, want %d (%q)", tc.name, got, tc.width, ui.Strip(tc.line))
		}
		if !strings.HasSuffix(ui.Strip(tc.line), axis) {
			t.Errorf("%s: the gutter ends %q, want the axis column", tc.name, ui.Strip(tc.line))
		}
	}
}

// Labels under an axis never run together: two numbers with no space between
// them read as a third that is neither. A label at the right edge is pulled
// back inside the row instead of being dropped, because the last mark is the
// one the header's own figure names.
func TestAxisLabelRowKeepsLabelsApart(t *testing.T) {
	ticks := []axisTick{{col: 0, text: "-10 s"}, {col: 1, text: "-9 s"}, {col: 19, text: "-0 s"}}
	row := axisLabelRow(4, 24, ticks)
	if got := strings.Count(row, "-9 s"); got != 0 {
		t.Errorf("a colliding label was written anyway: %q", row)
	}
	if !strings.HasPrefix(row, "    -10 s") {
		t.Errorf("the first label does not start at the gutter: %q", row)
	}
	if !strings.HasSuffix(row, "-0 s") || len(row) > 24 {
		t.Errorf("the last label is not pulled inside the row: %q", row)
	}
}

// A stream the daemon ends on its own is never a finished job: Ctrl-C is
// silent, the daemon's own error is passed through, and a clean close is
// reported whether or not anything was drawn -- a reader must never be left
// with a frozen picture and a zero exit.
func TestLiveStreamEndIsNeverSilent(t *testing.T) {
	live := context.Background()
	stopped, cancel := context.WithCancel(live)
	cancel()
	daemon := errors.New("CHANNEL_NOT_FOUND")
	cases := []struct {
		name  string
		ctx   context.Context
		err   error
		drawn int
		want  string
	}{
		{"Ctrl-C", stopped, nil, 3, ""},
		{"Ctrl-C with the daemon's error", stopped, daemon, 3, ""},
		{"the daemon's error", live, daemon, 3, "CHANNEL_NOT_FOUND"},
		{"nothing drawn", live, nil, 0, "before a window could be drawn"},
		{"ended by the daemon", live, nil, 12, "the daemon ended the audio stream after 12 windows"},
		{"ended after one", live, nil, 1, "after 1 window:"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := liveStreamEnd(tc.ctx, tc.err, tc.drawn, "audio stream", "window")
			if tc.want == "" {
				if err != nil {
					t.Fatalf("got %v, want a silent end", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("got %v, want it to say %q", err, tc.want)
			}
		})
	}
	// The three views share the rule, each naming its own picture.
	if err := scopeEnd(live, nil, 2); err == nil || !strings.Contains(err.Error(), "2 windows") {
		t.Errorf("scope: %v", err)
	}
	if err := levelsEnd(live, nil, 2); err == nil || !strings.Contains(err.Error(), "audio spectrum after 2 rows") {
		t.Errorf("levels: %v", err)
	}
	if err := waveformEnd(live, nil, 2); err == nil || !strings.Contains(err.Error(), "2 columns") {
		t.Errorf("waveform: %v", err)
	}
}
