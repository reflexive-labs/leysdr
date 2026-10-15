// SPDX-License-Identifier: Apache-2.0

package plugin

import "io"

// SetSegmentLog points the segment assembler's log at w for one test and
// returns the function that puts it back.
func SetSegmentLog(w io.Writer) func() {
	old := segmentLog
	segmentLog = w
	return func() { segmentLog = old }
}
