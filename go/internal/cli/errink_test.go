// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"os"
	"strings"
	"syscall"
	"testing"

	"github.com/dpup/leysdr/go/internal/ui"
)

// TestErrorLinePlainAndStyled: the ink is redundant emphasis on the sentence
// the verb wrote. Strip it and the line is the documented one, byte for byte.
func TestErrorLinePlainAndStyled(t *testing.T) {
	msgs := []string{
		"the Leyline daemon is not running (socket /tmp/leyline.sock). Start it with: ley daemon start",
		"the Leyline daemon is not running (stale socket /tmp/leyline.sock; a previous daemon left it behind). Run: ley daemon stop && ley daemon start",
		"9.999 GHz is outside what nfm_tone.cf32 can tune (146.520 MHz to 146.520 MHz); this device cannot tune above 146.520 MHz [FREQ_OUT_OF_RANGE]",
		"cannot run the daemon binary /nope/leylined: no such file or directory. Pass --bin, set $LEYLINE_DAEMON_BIN, or put leylined on PATH",
		"the daemon (pid 4242) has not exited yet; it may be finishing a write. Check with: ley daemon status",
		"leylined exited during startup (exit status 1). Look at its log: ley daemon logs (/tmp/leylined.log)",
		"--mode: unknown demodulator \"FOO\" (am, nfm, wfm, usb, lsb, cw, raw_iq); also accepted: fm, ssb",
		"interrupted",
		"",
	}
	styled := ui.Style{Color: true, Unicode: true, Width: 80}
	for _, msg := range msgs {
		plain := errorLine(ui.Style{Unicode: true, Width: 80}, msg)
		inked := errorLine(styled, msg)
		if got := ui.Strip(inked); got != plain {
			t.Errorf("Strip(styled) = %q, want %q", got, plain)
		}
		if !strings.HasPrefix(plain, "ley:") {
			t.Errorf("error line lost its prefix: %q", plain)
		}
		if !strings.HasPrefix(inked, "\x1b[31mley:\x1b[0m") {
			t.Errorf("the ley: prefix is not Err ink: %q", inked)
		}
	}
}

// TestErrorLineInkTargets pins which spans take ink: the state words, the
// parenthetical path, the remedy command and the machine code.
func TestErrorLineInkTargets(t *testing.T) {
	st := ui.Style{Color: true, Unicode: true, Width: 80}
	tests := []struct {
		msg  string
		want []string
	}{
		{
			"the Leyline daemon is not running (socket /tmp/leyline.sock). Start it with: ley daemon start",
			[]string{"\x1b[31mnot running\x1b[0m", "\x1b[2m(socket /tmp/leyline.sock)\x1b[0m", "\x1b[36mley daemon start\x1b[0m"},
		},
		{
			"146.520 MHz is busy [DEVICE_BUSY]",
			[]string{"\x1b[2m[DEVICE_BUSY]\x1b[0m"},
		},
		{
			// A parenthetical that lists accepted values is not a path and
			// keeps its weight: the reader is meant to read it.
			"--mode: unknown demodulator \"FOO\" (am, nfm, wfm)",
			[]string{"(am, nfm, wfm)"},
		},
	}
	for _, tc := range tests {
		got := errorLine(st, tc.msg)
		for _, want := range tc.want {
			if !strings.Contains(got, want) {
				t.Errorf("errorLine(%q) lacks %q\ngot: %q", tc.msg, want, got)
			}
		}
	}
	// A verb that never resolved a style (a flag error, say) prints plain.
	if got := (&App{}).ErrorLine("boom"); got != "ley: boom" {
		t.Errorf("plain error line = %q, want %q", got, "ley: boom")
	}
}

// TestUnknownVerbIsHouseVoice: `ley frobnicate` recovers the way `ley help
// frobnicate` does -- name the failure, then show the way out.
func TestUnknownVerbIsHouseVoice(t *testing.T) {
	_, _, err := runApp(t, helpApp(), "frobnicate")
	if exitCode(err) != ExitUsage {
		t.Fatalf("exit %d, want %d (%v)", exitCode(err), ExitUsage, err)
	}
	for _, want := range []string{`no command or topic named "frobnicate"`, "Topics:", "squelch", "Run 'ley --help' for the commands."} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("unknown verb message lacks %q:\n%s", want, err)
		}
	}
	// Cobra's suggestion mechanism is contractual and survives; when it
	// fires, the topic list stands aside for it.
	_, _, err = runApp(t, helpApp(), "spectrun")
	msg := err.Error()
	if !strings.Contains(msg, "Did you mean this?\n  spectrum") {
		t.Errorf("no suggestion for a near miss:\n%s", msg)
	}
	if strings.Contains(msg, "Topics:") {
		t.Errorf("the suggestion was buried under the topic list:\n%s", msg)
	}
}

// TestStartFailureIsHouseVoice: a missing daemon binary says what to do, and
// says the path once, without os/exec's "fork/exec" wording.
func TestStartFailureIsHouseVoice(t *testing.T) {
	err := startFailure("/nope/leylined", &os.PathError{Op: "fork/exec", Path: "/nope/leylined", Err: syscall.ENOENT})
	got := err.Error()
	want := "cannot run the daemon binary /nope/leylined: no such file or directory. Pass --bin, set $LEYLINE_DAEMON_BIN, or put leylined on PATH"
	if got != want {
		t.Errorf("startFailure = %q, want %q", got, want)
	}
	if strings.Count(got, "/nope/leylined") != 1 || strings.Contains(got, "fork/exec") {
		t.Errorf("the path is repeated or the exec wording leaked: %q", got)
	}
}
