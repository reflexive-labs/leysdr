package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/dpup/leysdr/go/internal/fakedaemon"
)

// The watch writer redraws in place with cursor-up, which is only correct while
// its bookkeeping and the screen agree about how many lines the block occupies.
// A reported symptom of them disagreeing is two status lines on screen counting
// different numbers of frames, so this replays the ANSI the writer actually
// emits onto a virtual screen and counts what a person would see.
//
// It cannot catch the environmental half of that hazard: cursor-up clamps at
// the top of the screen, so a block taller than the terminal strands its first
// lines however good the arithmetic is. The block is 19 rows.
func TestSpectrumWatchDrawsOneStatusLine(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	app := ttyApp(sock)
	app.TermWidth = func() int { return 100 }
	app.LookupEnv = func(name string) (string, bool) {
		switch name {
		case "LANG":
			return "en_US.UTF-8", true
		case "TERM":
			return "xterm-256color", true
		}
		return "", false
	}
	out, errOut, err := runApp(t, app, "spectrum", "146.52", "--watch", "--rate", "4", "--count", "6")
	if err != nil {
		t.Fatalf("spectrum: %v\n%s\n%s", err, out, errOut)
	}
	screen := replayANSI(out)
	var status []string
	for _, l := range screen {
		if strings.Contains(l, "frame ") && strings.Contains(l, "elapsed") {
			status = append(status, l)
		}
	}
	if len(status) != 1 {
		t.Errorf("want one status line on screen, got %d: %q\nscreen:\n%s",
			len(status), status, strings.Join(screen, "\n"))
	}
	// And the block must not grow without bound: every frame overwrites the last.
	if len(screen) > 30 {
		t.Errorf("the chart should redraw in place, but the screen grew to %d rows", len(screen))
	}
}

// replayANSI renders the cursor-up / erase-line / newline sequences the watch
// writer emits onto a virtual screen, so a test can see what a person sees
// rather than the byte stream.
func replayANSI(s string) []string {
	var screen []string
	row := 0
	var cur strings.Builder
	flush := func() {
		for len(screen) <= row {
			screen = append(screen, "")
		}
		screen[row] = cur.String()
		cur.Reset()
	}
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '\x1b' && i+1 < len(s) && s[i+1] == '[' {
			j := i + 2
			for j < len(s) && (s[j] >= '0' && s[j] <= '9' || s[j] == ';' || s[j] == '?') {
				j++
			}
			if j < len(s) {
				verb := s[j]
				params := s[i+2 : j]
				switch verb {
				case 'A': // cursor up
					n := 1
					if params != "" {
						n = 0
						for _, d := range params {
							if d >= '0' && d <= '9' {
								n = n*10 + int(d-'0')
							}
						}
					}
					flush()
					row -= n
					if row < 0 {
						row = 0
					}
				case 'K': // erase to end of line -- the writer's content already replaced it
				case 'm', 'l', 'h': // SGR / cursor visibility
				}
				i = j + 1
				continue
			}
		}
		if c == '\n' {
			flush()
			row++
			i++
			continue
		}
		if c == '\r' {
			cur.Reset()
			i++
			continue
		}
		cur.WriteByte(c)
		i++
	}
	flush()
	return screen
}
