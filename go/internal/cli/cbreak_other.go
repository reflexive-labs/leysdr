// SPDX-License-Identifier: Apache-2.0

//go:build !darwin && !linux

package cli

import "errors"

// cbreak is not available here; a live view that takes keys then reads them a line at a time.
func cbreak(int) (func(), error) {
	return nil, errors.New("cbreak mode is not supported on this platform")
}

// noEcho is not available here; a key typed at the prompt is shown as it is typed.
func noEcho(int) (func(), error) {
	return nil, errors.New("turning echo off is not supported on this platform")
}
