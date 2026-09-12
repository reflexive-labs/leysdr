// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import "testing"

// The sentences a finished sweep ends on, as JobStore writes them: a plain count, the clipping
// note when the radio could not reach all of the range, and the steps whose rows were too few to
// be believed and so are missing from the coverage.
func TestCompletedDetail(t *testing.T) {
	for _, tc := range []struct {
		found, stepsDone, steps int
		clipped                 bool
		want                    string
	}{
		{found: 3, stepsDone: 4, steps: 4, want: "3 found in 4 steps"},
		{found: 0, stepsDone: 1, steps: 1, want: "0 found in 1 step"},
		{found: 2, stepsDone: 6, steps: 6, clipped: true, want: "2 found in 6 steps, clipped to what the radio can tune"},
		{found: 1, stepsDone: 3, steps: 5, want: "1 found; 2 of 5 steps saw too few rows to trust and were left out"},
	} {
		if got := completedDetail(tc.found, tc.stepsDone, tc.steps, tc.clipped); got != tc.want {
			t.Errorf("completedDetail(%d, %d, %d, %v) = %q, want %q", tc.found, tc.stepsDone, tc.steps, tc.clipped, got, tc.want)
		}
	}
}
