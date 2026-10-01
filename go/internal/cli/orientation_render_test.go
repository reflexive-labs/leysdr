// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"errors"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// fixedOrientClock freezes the uptime the orientation screen prints, so two
// renders of the same state cannot differ by a ticking second.
func fixedOrientClock(t *testing.T) {
	t.Helper()
	old := orientNow
	orientNow = func() time.Time { return time.Unix(0, 0).Add(46 * time.Second) }
	t.Cleanup(func() { orientNow = old })
}

// orientStates are the three states of bare `ley`: no daemon, a daemon with no
// radio, and a radio with channels playing.
func orientStates() []struct {
	name  string
	state *leylinev1.GetStateResponse
	err   error
} {
	busy := busyState()
	empty := &leylinev1.GetStateResponse{Daemon: busy.Daemon}
	return []struct {
		name  string
		state *leylinev1.GetStateResponse
		err   error
	}{
		{"not running", nil, &ExitError{Code: ExitNotRunning, Message: "the Leyline daemon is not running (socket x). Start it with: ley daemon start"}},
		{"other error", nil, errors.New("boom")},
		{"no devices", empty, nil},
		{"playing", busy, nil},
	}
}

// TestOrientationSurvivesColourOff is the render-twice proof for bare `ley`:
// ink is the only difference between the terminal screen and the piped one.
func TestOrientationSurvivesColourOff(t *testing.T) {
	fixedOrientClock(t)
	for _, tc := range orientStates() {
		t.Run(tc.name, func(t *testing.T) {
			plain := renderOrientation(ui.Style{}, tc.state, tc.err)
			styled := renderOrientation(ui.Style{Color: true, Unicode: true, Width: 100}, tc.state, tc.err)
			if styled == plain {
				t.Fatal("a coloured style left the screen unstyled")
			}
			if got := ui.Strip(styled); got != plain {
				t.Fatalf("Strip(styled) != plain\n--- got\n%s\n--- want\n%s", got, plain)
			}
		})
	}
}

// TestOrientationWordingIsUnchanged holds the sentences docs/reference/cli.md
// pins: styling may add ink and may not rewrite a line.
func TestOrientationWordingIsUnchanged(t *testing.T) {
	fixedOrientClock(t)
	st := busyState()
	out := renderOrientation(ui.Style{}, st, nil)
	for _, want := range []string{
		"Daemon    daemon 0.1.0-dev pid 4711 up 46s socket /tmp/leyline.sock\n",
		"Devices   Generic RTL2832U (R820T) (rtlsdr, serial 00000001) in use, tunes 24.000 MHz to 1.766 GHz\n",
		"Playing   146.520 MHz NFM, squelch -40.0 dB, active (chan_01M224S60EG37HPKYSEH0CQZZA)\n",
		"\nNext:\n  ley set squelch -40          mute the audio below a level (or: auto)\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("orientation missing %q:\n%s", want, out)
		}
	}
	// The continuation rows for a second device or channel stay blank-labelled
	// and aligned under the first.
	if !strings.Contains(out, "\n          146.420 MHz AM") {
		t.Errorf("second channel row is not aligned under the first:\n%s", out)
	}
	nothing := renderOrientation(ui.Style{}, &leylinev1.GetStateResponse{Daemon: st.Daemon}, nil)
	if !strings.Contains(nothing, "Devices   none found\n") {
		t.Errorf("no-device screen:\n%s", nothing)
	}
}

// TestOrientationInkRoles checks the ink lands where the style guide says: the
// left column bold, the diagnostics dim, the state word green, and every
// command in the Next block cyan and copy-pasteable.
func TestOrientationInkRoles(t *testing.T) {
	fixedOrientClock(t)
	out := renderOrientation(ui.Style{Color: true, Width: 100}, busyState(), nil)
	for _, want := range []string{
		"\x1b[1mDaemon\x1b[0m", "\x1b[2mpid 4711 up 46s socket /tmp/leyline.sock\x1b[0m",
		"\x1b[32mactive\x1b[0m", "\x1b[36mley set squelch -40\x1b[0m",
		"\x1b[2m(chan_01M224S60EG37HPKYSEH0CQZZA)\x1b[0m",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("orientation missing ink %q:\n%q", want, out)
		}
	}
	// An id never has a character inserted into it: the ink wraps the whole
	// token, so a mouse selection still yields a valid chan_...
	if strings.Contains(out, "chan_\x1b") {
		t.Errorf("ink inside an id:\n%q", out)
	}
	down := renderOrientation(ui.Style{Color: true}, nil, &ExitError{Code: ExitNotRunning, Message: "the Leyline daemon is not running (socket x). Start it with: ley daemon start"})
	if !strings.Contains(down, "\x1b[31mnot running\x1b[0m") {
		t.Errorf("a dead daemon must read in Err ink:\n%q", down)
	}
}

// TestVersionSurvivesColourOff: one line, one fact, and the build details dim.
func TestVersionSurvivesColourOff(t *testing.T) {
	plain, _, err := runApp(t, &App{}, "version")
	if err != nil {
		t.Fatalf("version: %v", err)
	}
	styled, _, err := runApp(t, &App{Style: ui.Style{Color: true, Unicode: true}}, "version", "--color=always")
	if err != nil {
		t.Fatalf("version --color=always: %v", err)
	}
	if styled == plain {
		t.Fatal("a coloured style left the version unstyled")
	}
	if got := ui.Strip(styled); got != plain {
		t.Fatalf("Strip(styled) = %q, want %q", got, plain)
	}
	if !strings.HasPrefix(styled, "\x1b[1mley\x1b[0m ") {
		t.Errorf("version: %q", styled)
	}
}
