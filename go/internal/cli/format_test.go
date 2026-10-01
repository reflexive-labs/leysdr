// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// An Anchor event is the capture's sample-timebase bookkeeping. It reaches
// --json like every other event, but a person watching a live verb has
// nothing to do with it, so the live view drops it.
func TestHumanEventDropsAnchor(t *testing.T) {
	anchor := &leylinev1.Event{Body: &leylinev1.Event_Anchor{Anchor: &leylinev1.CaptureAnchor{CaptureId: "cap_x", SampleRate: 2400000}}}
	if humanEvent(anchor) {
		t.Error("an anchor event must not reach the live human view")
	}
	ch := &leylinev1.Event{Body: &leylinev1.Event_Channel{Channel: &leylinev1.Channel{ChannelId: "chan_x"}}}
	if !humanEvent(ch) {
		t.Error("a channel event is exactly what the live view is for")
	}
}

// A device that tunes to exactly one frequency -- a file device plays back one
// centre -- must not read as "146.520 MHz to 146.520 MHz". Both `ley devices`
// and `ley state`'s tree render this through the same collapsing renderer.
func TestRangesPhraseCollapses(t *testing.T) {
	r := func(lo, hi uint64) *leylinev1.FrequencyRange {
		return &leylinev1.FrequencyRange{MinHz: lo, MaxHz: hi}
	}
	for _, tc := range []struct {
		name string
		in   []*leylinev1.FrequencyRange
		want string
	}{
		{"a real range", []*leylinev1.FrequencyRange{r(24_000_000, 1_766_000_000)}, "24.000 MHz to 1.766 GHz"},
		{"one frequency", []*leylinev1.FrequencyRange{r(146_520_000, 146_520_000)}, "146.520 MHz"},
		{"two ranges", []*leylinev1.FrequencyRange{r(1_000_000, 2_000_000), r(146_520_000, 146_520_000)}, "1.000 MHz to 2.000 MHz, 146.520 MHz"},
		// The absent form belongs to the caller, so this is empty rather than a glyph.
		{"none", nil, ""},
		// A nil element is skipped rather than dereferenced.
		{"a nil element", []*leylinev1.FrequencyRange{nil, r(146_520_000, 146_520_000)}, "146.520 MHz"},
	} {
		if got := rangesPhrase(tc.in); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
	// A dash always means "no value", so it may never appear as a separator.
	if got := rangesPhrase([]*leylinev1.FrequencyRange{r(1, 2)}); strings.Contains(got, "-") {
		t.Errorf("a range must not use a dash: %q", got)
	}
}
