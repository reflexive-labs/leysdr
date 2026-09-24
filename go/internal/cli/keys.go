// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"io"
	"os"
)

// keyPresses reads single key presses from stdin for a live view that takes one (`ley play`'s
// space). It returns nil when stdin is not a terminal, because a pipe or a file is not somebody
// pressing keys, and a script's input must not pause what it started. On a terminal, stdin is
// put in cbreak mode (no line buffering, no echo, signals kept, so Ctrl-C still stops the verb)
// until stop is called. The reading goroutine ends at EOF; on a terminal it is left blocked in
// its read when the verb ends, which is the process ending.
func keyPresses(app *App) (keys <-chan byte, stop func()) {
	if app.IsInTTY == nil || !app.IsInTTY() {
		return nil, func() {}
	}
	restore := func() {}
	if f, ok := app.Stdin.(*os.File); ok {
		if r, err := cbreak(int(f.Fd())); err == nil {
			restore = r
		}
	}
	out := make(chan byte, 8)
	go readKeys(app.Stdin, out)
	return out, restore
}

func readKeys(in io.Reader, out chan<- byte) {
	defer close(out)
	buf := make([]byte, 1)
	for {
		n, err := in.Read(buf)
		if n == 1 {
			select {
			case out <- buf[0]:
			default:
				// Keys pressed faster than the view acts on them are dropped, not queued: a held
				// space bar should not toggle for seconds after it is let go.
			}
		}
		if err != nil {
			return
		}
	}
}
