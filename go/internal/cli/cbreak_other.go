// SPDX-License-Identifier: Apache-2.0

//go:build !darwin && !linux

package cli

import "errors"

// cbreak is not available here; a live view that takes keys then reads them a line at a time.
func cbreak(int) (func(), error) {
	return nil, errors.New("cbreak mode is not supported on this platform")
}
