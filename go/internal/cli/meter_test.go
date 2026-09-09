package cli

import (
	"bytes"
	"math"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
)

// meterFixture is one meter reading and the squelch it is judged against.
func meterFixture(db float64, open bool) *leylinev1.Meter {
	return &leylinev1.Meter{PowerDbfs: db, SquelchOpen: open}
}

// TestMeterRenderSurvivesColourOff is rule 1 of docs/cli-style.md on the
// screen that matters most: the bar, the marker and every word are there
// with the ink stripped. Colour is compared at a fixed glyph set, since the
// alphabet is the reader's terminal, not the emphasis.
func TestMeterRenderSurvivesColourOff(t *testing.T) {
	for _, unicode := range []bool{false, true} {
		for _, open := range []bool{false, true} {
			plain := ui.Style{Unicode: unicode, Width: 80}
			styled := ui.Style{Color: true, Unicode: unicode, Width: 80}
			m := meterFixture(-42.4, open)
			got := meterRender(styled, 146_620_000, leylinev1.DemodMode_NFM, m, -60)
			want := meterRender(plain, 146_620_000, leylinev1.DemodMode_NFM, m, -60)
			if got == want {
				t.Errorf("unicode=%v open=%v: a coloured style left the meter unstyled", unicode, open)
			}
			if ui.Strip(got) != want {
				t.Errorf("unicode=%v open=%v:\n Strip(styled) = %q\n plain         = %q", unicode, open, ui.Strip(got), want)
			}
			if !strings.Contains(want, meterLine(146_620_000, leylinev1.DemodMode_NFM, m)) {
				t.Errorf("the contractual meter string is not inside %q", want)
			}
		}
	}
}

// TestMeterRenderWidths keeps the meter inside the terminal: the bar is
// added only when there is room for it, and it never pushes the line past
// the resolved width.
func TestMeterRenderWidths(t *testing.T) {
	m := meterFixture(-30, true)
	for _, width := range []int{40, 80, 160} {
		st := ui.Style{Color: true, Unicode: true, Width: width}
		line := ui.Strip(meterRender(st, 146_620_000, leylinev1.DemodMode_NFM, m, -60))
		bare := meterLine(146_620_000, leylinev1.DemodMode_NFM, m)
		if got := ui.Visible(line); got > width && got != ui.Visible(bare) {
			t.Errorf("width %d: line is %d columns: %q", width, got, line)
		}
		if width == 40 && line != bare {
			// 40 columns is narrower than the words themselves; the bar has
			// to give way rather than wrap the line.
			t.Errorf("width 40 should be the plain line, got %q", line)
		}
		if width == 160 && !strings.HasPrefix(line, strings.Repeat("█", 1)) {
			t.Errorf("width 160 should lead with a bar, got %q", line)
		}
	}
	// An unknown width (a zero style) is the plain line.
	if got := meterRender(ui.Style{}, 146_620_000, leylinev1.DemodMode_NFM, m, -60); got != meterLine(146_620_000, leylinev1.DemodMode_NFM, m) {
		t.Errorf("unknown width should not draw a bar: %q", got)
	}
}

// TestMeterBar places the level and the squelch marker: an empty bar at the
// floor, a full one at 0 dBFS, and no marker for a squelch that is off.
func TestMeterBar(t *testing.T) {
	st := ui.Style{Unicode: true, Width: 80}
	tests := []struct {
		name           string
		power, squelch float64
		want           string
	}{
		{"floor", meterFloorDbfs, math.NaN(), "░░░░░░░░"},
		{"top", 0, math.NaN(), "████████"},
		{"half", -45, math.NaN(), "████░░░░"},
		{"marker in the empty run", -45, -22.5, "████░░▲░"},
		{"marker in the filled run", -45, -67.5, "██▲█░░░░"},
		{"squelch off draws no marker", -45, math.NaN(), "████░░░░"},
		{"squelch below the scale", -45, -120, "████░░░░"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := meterBar(st, tc.power, tc.squelch, false, 8); got != tc.want {
				t.Errorf("meterBar = %q, want %q", got, tc.want)
			}
		})
	}
	if got := meterBar(st, -45, math.NaN(), false, 0); got != "" {
		t.Errorf("no width, no bar: %q", got)
	}
}

// TestMeterSinkRedrawIsTTYOnly is the fix for a redirected session
// collapsing into one line: off a terminal the meter writes whole lines,
// throttled, and never a carriage return.
func TestMeterSinkRedrawIsTTYOnly(t *testing.T) {
	buf := &bytes.Buffer{}
	sink := &meterSink{w: buf, style: ui.Style{Width: 80}, tty: false}
	for i := 0; i < 5; i++ {
		sink.write(sink.line(146_620_000, leylinev1.DemodMode_NFM, meterFixture(-42.4, true), math.NaN()))
	}
	sink.clear()
	got := buf.String()
	if strings.Contains(got, "\r") {
		t.Errorf("a pipe must not see a carriage return: %q", got)
	}
	if lines := strings.Count(got, "\n"); lines != 1 {
		t.Errorf("five ticks inside one second should be one line, got %d: %q", lines, got)
	}
	if want := meterLine(146_620_000, leylinev1.DemodMode_NFM, meterFixture(-42.4, true)) + "\n"; got != want {
		t.Errorf("piped meter = %q, want %q", got, want)
	}
	// A tick after the interval is written; the interval itself is not
	// waited out here, it is moved.
	sink.last = time.Now().Add(-2 * meterPipeInterval)
	sink.write(sink.line(146_620_000, leylinev1.DemodMode_NFM, meterFixture(-30, true), math.NaN()))
	if lines := strings.Count(buf.String(), "\n"); lines != 2 {
		t.Errorf("a tick a second later should print, got %d lines", lines)
	}
}

// TestMeterSinkTerminalRedraw keeps the in-place behaviour a terminal has
// always had: one carriage return per tick, and enough padding that a
// shorter line leaves no residue behind it.
func TestMeterSinkTerminalRedraw(t *testing.T) {
	buf := &bytes.Buffer{}
	sink := &meterSink{w: buf, style: ui.Style{Width: 80}, tty: true}
	long := sink.line(146_620_000, leylinev1.DemodMode_NFM, meterFixture(-42.4, false), math.NaN())
	short := sink.line(146_620_000, leylinev1.DemodMode_NFM, meterFixture(-42.4, true), math.NaN())
	sink.write(long)
	sink.write(short)
	got := buf.String()
	if strings.Count(got, "\n") != 0 {
		t.Errorf("a terminal redraw writes no newline: %q", got)
	}
	if n := strings.Count(got, "\r"); n != 2 {
		t.Errorf("expected one carriage return per tick, got %d: %q", n, got)
	}
	pad := ui.Visible(long) - ui.Visible(short)
	if !strings.HasSuffix(got, strings.Repeat(" ", pad)) {
		t.Errorf("a shorter line must erase the longer one it replaced: %q", got)
	}
	sink.clear()
	if !strings.HasSuffix(buf.String(), "\r") {
		t.Errorf("clear should leave the cursor at the start of the line: %q", buf.String())
	}
}
