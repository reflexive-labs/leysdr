// SPDX-License-Identifier: Apache-2.0

package ui

import "testing"

// The floor is blank so an empty band shows the terminal's own background and
// only what is above the floor takes ink. Rounding to nearest would paint the
// bottom half of the first step, which is the mass problem the spectrum chart
// already had.
func TestShadeFloorIsBlank(t *testing.T) {
	for _, uni := range []bool{false, true} {
		st := Style{Unicode: uni}
		if got := st.Shade(0); got != " " {
			t.Errorf("unicode %v: Shade(0) = %q, want a space", uni, got)
		}
		if got := st.Shade(-1); got != " " {
			t.Errorf("unicode %v: a level under the floor is blank, got %q", uni, got)
		}
		if got := st.Shade(1); got == " " {
			t.Errorf("unicode %v: full scale must not be blank", uni)
		}
		if got := st.Shade(2); got != st.Shade(1) {
			t.Errorf("unicode %v: over full scale clamps, got %q", uni, got)
		}
	}
}

// Level survives with colour off, which is why the cell carries a
// texture as well as a hue: the ramp must be monotonic and use every step.
func TestShadeUsesEveryStep(t *testing.T) {
	for _, uni := range []bool{false, true} {
		st := Style{Unicode: uni}
		seen := map[string]bool{}
		for i := 0; i <= 100; i++ {
			seen[st.Shade(float64(i)/100)] = true
		}
		if want := len([]rune(st.Glyphs().Shade)); len(seen) != want {
			t.Errorf("unicode %v: the ramp used %d of %d steps", uni, len(seen), want)
		}
	}
}
