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

// meterWithAudio is a meter carrying an audio level, which is what makes the
// detail rows appear.
func meterWithAudio(power, audio, peak float64, open bool) *leylinev1.Meter {
	return &leylinev1.Meter{PowerDbfs: power, SnrDb: 26, SquelchOpen: open, AudioDbfs: audio, AudioPeakDbfs: peak}
}

// The detail rows say what the radio hears and what the listener hears, which
// are different questions: a strong unmodulated carrier is loud on the first
// row and silent on the second.
func TestMeterDetailRowsAppearOnAWideTerminal(t *testing.T) {
	m := meterWithAudio(-38, -12, -4, true)
	got := ui.Strip(meterRender(ui.Style{Unicode: true, Width: 100}, 146_520_000, leylinev1.DemodMode_NFM, m, -46))
	lines := strings.Split(got, "\n")
	if len(lines) != 3 {
		t.Fatalf("want the contract line plus two detail rows, got %d:\n%s", len(lines), got)
	}
	// Line 1 stays exactly the contractual meter line: tests and docs pin it.
	if want := meterLine(146_520_000, leylinev1.DemodMode_NFM, m); lines[0] != want {
		t.Errorf("line 1 must be the contract line\n got %q\nwant %q", lines[0], want)
	}
	if !strings.Contains(lines[1], "signal") || !strings.Contains(lines[1], "-38 dBFS") {
		t.Errorf("signal row: %q", lines[1])
	}
	if !strings.Contains(lines[2], "audio") || !strings.Contains(lines[2], "-12 dBFS") {
		t.Errorf("audio row: %q", lines[2])
	}
	if !strings.Contains(lines[2], "peak -4 dBFS") {
		t.Errorf("the audio row carries the peak hold: %q", lines[2])
	}
	// The inline bar would repeat the signal row, so it is dropped.
	if strings.Count(got, "▲") > 2 {
		t.Errorf("one marker per row, not an inline bar as well:\n%s", got)
	}
}

// A narrow terminal keeps the one-line meter it always had, byte for byte.
func TestMeterNarrowTerminalIsUnchanged(t *testing.T) {
	m := meterWithAudio(-38, -12, -4, true)
	for _, w := range []int{0, 40, meterDetailMinWidth - 1} {
		got := meterRender(ui.Style{Unicode: true, Width: w}, 146_520_000, leylinev1.DemodMode_NFM, m, -46)
		if strings.Contains(got, "\n") {
			t.Errorf("width %d must stay one line, got:\n%s", w, got)
		}
	}
}

// NaN means "not measured" -- a raw-IQ channel has no audio, and neither does a
// channel whose first block has not landed. A row that printed 0.0 dBFS for it
// would be reporting a very loud signal.
func TestMeterNoDetailRowsWithoutAnAudioLevel(t *testing.T) {
	m := &leylinev1.Meter{PowerDbfs: -70, SnrDb: 2, SquelchOpen: false, AudioDbfs: math.NaN(), AudioPeakDbfs: math.NaN()}
	got := meterRender(ui.Style{Unicode: true, Width: 100}, 146_520_000, leylinev1.DemodMode_NFM, m, -46)
	if strings.Contains(got, "\n") {
		t.Errorf("an unmeasured audio level draws no rows, got:\n%s", got)
	}
	if strings.Contains(got, "NaN") {
		t.Errorf("NaN must never be printed: %q", got)
	}
}

// The style guide's first principle, on every row of the block.
func TestMeterDetailStripsToPlain(t *testing.T) {
	m := meterWithAudio(-38, -12, -4, true)
	for _, w := range []int{60, 80, 160} {
		for _, uni := range []bool{false, true} {
			plain := meterRender(ui.Style{Unicode: uni, Width: w}, 146_520_000, leylinev1.DemodMode_NFM, m, -46)
			styled := meterRender(ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: uni, Width: w},
				146_520_000, leylinev1.DemodMode_NFM, m, -46)
			if ui.Strip(styled) != plain {
				t.Errorf("width %d unicode %v:\n plain  %q\n styled %q", w, uni, plain, ui.Strip(styled))
			}
			for _, l := range strings.Split(plain, "\n") {
				if ui.Visible(l) > w {
					t.Errorf("width %d: a row of %d columns: %q", w, ui.Visible(l), l)
				}
			}
		}
	}
}

// Digital silence is a real answer and reads as a word, not as -inf or a huge
// negative number.
func TestMeterSilentAudioReadsQuiet(t *testing.T) {
	m := meterWithAudio(-38, math.Inf(-1), math.Inf(-1), true)
	got := ui.Strip(meterRender(ui.Style{Unicode: true, Width: 100}, 146_520_000, leylinev1.DemodMode_NFM, m, -46))
	if !strings.Contains(got, "quiet") {
		t.Errorf("want the silence to read as a word:\n%s", got)
	}
	if strings.Contains(got, "Inf") {
		t.Errorf("-inf must never be printed:\n%s", got)
	}
}
