// SPDX-License-Identifier: Apache-2.0

//go:build darwin || linux

package cli

import "golang.org/x/sys/unix"

// cbreak turns off line buffering and echo on the terminal at fd and keeps signal keys, so a
// live view reads one key at a time and Ctrl-C still interrupts. restore puts the terminal back
// as it was.
func cbreak(fd int) (restore func(), err error) {
	old, err := unix.IoctlGetTermios(fd, ioctlGetTermios)
	if err != nil {
		return nil, err
	}
	raw := *old
	raw.Lflag &^= unix.ICANON | unix.ECHO
	raw.Cc[unix.VMIN] = 1
	raw.Cc[unix.VTIME] = 0
	if err := unix.IoctlSetTermios(fd, ioctlSetTermios, &raw); err != nil {
		return nil, err
	}
	return func() { _ = unix.IoctlSetTermios(fd, ioctlSetTermios, old) }, nil
}
