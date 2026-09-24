// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// tableApp is an app whose stdout is a buffer and whose style is dictated: a
// screen renderer is called directly, without a daemon or a terminal.
func tableApp(s ui.Style) (*App, *bytes.Buffer) {
	buf := &bytes.Buffer{}
	return &App{Stdout: buf, Stderr: &bytes.Buffer{}, Style: s, IsTTY: func() bool { return true }}, buf
}

// styledAndPlain renders one screen twice in the same alphabet and at the
// same width, once plain and once coloured, and returns both. Colour is the
// only variable: a different glyph set legitimately draws different
// characters (the ASCII ellipsis is three columns, the UTF-8 one is one), so
// the alphabet is held fixed and both are exercised in turn.
func styledAndPlain(t *testing.T, width int, unicode bool, render func(*App)) (plain, styled string) {
	t.Helper()
	app, buf := tableApp(ui.Style{Unicode: unicode, Width: width})
	render(app)
	plain = buf.String()
	app, buf = tableApp(ui.Style{Color: true, Unicode: unicode, Width: width})
	render(app)
	return plain, buf.String()
}

// devicesFixture is one real-shaped dongle and one playback file: the two
// rows the devices table has to lay out well.
func devicesFixture() []*leylinev1.DeviceDescriptor {
	return []*leylinev1.DeviceDescriptor{
		{
			DeviceId: "dev_01M224S5ZRDDEGKRWJSCTABBRB", Driver: "rtlsdr",
			Model: "Generic RTL2832U (R820T)", Serial: "00000001",
			State:        leylinev1.DeviceState_AVAILABLE,
			TuningRanges: []*leylinev1.FrequencyRange{{MinHz: 24_000_000, MaxHz: 1_766_000_000}},
			SampleRates:  []uint64{250_000, 3_200_000},
			GainElements: []*leylinev1.GainElement{{Name: "TUNER", MinDb: 0, MaxDb: 49.6, SupportsAuto: true}},
		},
		{
			DeviceId: "dev_01M224S5ZTB34335N7PM0PGZZZ", Driver: "file",
			Model: "nfm_tone.cf32", Serial: "69943ab1a039f01f",
			State:        leylinev1.DeviceState_DISCONNECTED,
			TuningRanges: []*leylinev1.FrequencyRange{{MinHz: 146_520_000, MaxHz: 146_520_000}},
			SampleRates:  []uint64{2_400_000},
		},
	}
}

// TestScreensSurviveColourOff checks that on the devices, presets and bands
// screens, stripping the SGR from the coloured rendering leaves the plain
// rendering, byte for byte.
func TestScreensSurviveColourOff(t *testing.T) {
	screens := map[string]func(*App){
		"devices":      func(a *App) { printDeviceTable(a, devicesFixture(), false) },
		"devices wide": func(a *App) { printDeviceTable(a, devicesFixture(), true) },
		"devices empty": func(a *App) {
			printDeviceTable(a, nil, false)
		},
		"presets": func(a *App) {
			if err := printPresetTable(a, leyline.Presets()); err != nil {
				t.Fatal(err)
			}
		},
		"bands": func(a *App) {
			if err := printBandTable(a, leyline.Bands()); err != nil {
				t.Fatal(err)
			}
		},
	}
	for name, render := range screens {
		for _, width := range []int{40, 80, 160} {
			for _, unicode := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%d/unicode=%v", name, width, unicode), func(t *testing.T) {
					plain, styled := styledAndPlain(t, width, unicode, render)
					if plain == "" {
						t.Fatal("nothing rendered")
					}
					if styled == plain {
						t.Errorf("a coloured style left %s unstyled at %d columns", name, width)
					}
					if got := ui.Strip(styled); got != plain {
						t.Errorf("%s at %d columns:\nstripped: %q\nplain:    %q", name, width, got, plain)
					}
				})
			}
		}
	}
}

// TestDeviceTableLeadsWithTheAnswer: MODEL first, STATE second, ids and
// serials behind --wide with the full id still verbatim there.
func TestDeviceTableLeadsWithTheAnswer(t *testing.T) {
	app, buf := tableApp(ui.Style{Width: 160})
	printDeviceTable(app, devicesFixture(), false)
	out := buf.String()
	if head := strings.Fields(out)[0]; head != "MODEL" {
		t.Errorf("first column is %q, want MODEL:\n%s", head, out)
	}
	if fields := strings.Fields(out); fields[1] != "STATE" {
		t.Errorf("second column is %q, want STATE:\n%s", fields[1], out)
	}
	if strings.Contains(out, "dev_") || strings.Contains(out, "00000001") {
		t.Errorf("the default table must not carry ids or serials:\n%s", out)
	}
	// A range of one frequency reads as that frequency; a real range spells
	// out "to"; a radio with no gain elements reads as the absent glyph.
	for _, want := range []string{"24.000 MHz to 1.766 GHz", "146.520 MHz  ", "-"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "146.520 MHz to 146.520 MHz") {
		t.Errorf("a one-frequency range should not be printed twice:\n%s", out)
	}

	app, buf = tableApp(ui.Style{Width: 80})
	printDeviceTable(app, devicesFixture(), true)
	wide := buf.String()
	for _, want := range []string{"dev_01M224S5ZRDDEGKRWJSCTABBRB", "00000001", "rtlsdr", "TUNER 0–49.6 dB auto"} {
		if !strings.Contains(wide, want) {
			t.Errorf("--wide dropped %q:\n%s", want, wide)
		}
	}
}

// TestDeviceTableEmptyBody: an empty list says so in both streams, rather
// than answering "is my radio visible?" with a bare header row.
func TestDeviceTableEmptyBody(t *testing.T) {
	app, buf := tableApp(ui.Style{Width: 80})
	printDeviceTable(app, nil, false)
	if !strings.Contains(buf.String(), "(no radios found)") {
		t.Errorf("empty devices table has no body row:\n%s", buf.String())
	}
}

// TestDeviceStateInk: every state word carries ink that matches its meaning,
// and the word itself is unchanged by the ink.
func TestDeviceStateInk(t *testing.T) {
	s := ui.Style{Color: true}
	held := &leylinev1.DeviceDescriptor{
		State:    leylinev1.DeviceState_IN_USE,
		Features: map[string]*leylinev1.FeatureValue{"held_externally": {Value: &leylinev1.FeatureValue_Flag{Flag: true}}},
	}
	for _, tc := range []struct {
		name string
		d    *leylinev1.DeviceDescriptor
		want string
	}{
		{"available", &leylinev1.DeviceDescriptor{State: leylinev1.DeviceState_AVAILABLE}, "\x1b[32m"},
		{"held", held, "\x1b[33m"},
		{"disconnected", &leylinev1.DeviceDescriptor{State: leylinev1.DeviceState_DISCONNECTED}, "\x1b[31m"},
		{"file at rest", &leylinev1.DeviceDescriptor{Driver: "file", State: leylinev1.DeviceState_DISCONNECTED}, "\x1b[2m"},
	} {
		got := deviceStateCell(s, tc.d)
		if !strings.HasPrefix(got, tc.want) {
			t.Errorf("%s: %q does not start with %q", tc.name, got, tc.want)
		}
		if ui.Strip(got) != deviceStateString(tc.d) {
			t.Errorf("%s: ink changed the word: %q", tc.name, got)
		}
	}
	if !strings.Contains(deviceStateString(held), "IN_USE (other program)") {
		t.Errorf("a device another program holds must say so in words: %q", deviceStateString(held))
	}
}

// TestTableWidthDiscipline: the grouped tables fit the width they are given,
// dropping the columns whose loss the reader can afford before the ones the
// screen exists to carry. Names and aliases are typed by hand, so they are
// never truncated.
func TestTableWidthDiscipline(t *testing.T) {
	for _, width := range []int{80, 160} {
		app, buf := tableApp(ui.Style{Width: width})
		if err := printBandTable(app, leyline.Bands()); err != nil {
			t.Fatal(err)
		}
		checkWidth(t, "bands", buf.String(), width)

		app, buf = tableApp(ui.Style{Width: width})
		if err := printPresetTable(app, leyline.Presets()); err != nil {
			t.Fatal(err)
		}
		out := buf.String()
		checkWidth(t, "presets", out, width)
		for _, name := range []string{"marine16", "aircraft-guard, 121.5"} {
			if !strings.Contains(out, name) {
				t.Errorf("presets at %d columns lost %q:\n%s", width, name, out)
			}
		}
	}
	// At 40 columns the prose has to go before the columns a reader types.
	app, buf := tableApp(ui.Style{Width: 40})
	if err := printPresetTable(app, leyline.Presets()); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	if strings.Contains(out, "DESCRIPTION") || strings.Contains(out, "ALIASES") {
		t.Errorf("presets at 40 columns kept a droppable column:\n%s", out)
	}
	for _, want := range []string{"marine16", "156.800 MHz", "NOAA weather"} {
		if !strings.Contains(out, want) {
			t.Errorf("presets at 40 columns lost %q:\n%s", want, out)
		}
	}
	checkWidth(t, "presets", out, 40)
}

// TestPipedTablesAreWhole: a pipe has no width, so nothing is cut from it
// even though the resolved style carries the 80-column fallback.
func TestPipedTablesAreWhole(t *testing.T) {
	app, buf := tableApp(ui.Style{Width: 40})
	app.IsTTY = func() bool { return false }
	if err := printBandTable(app, leyline.Bands()); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	if !strings.Contains(out, "ship and coast stations; channel 16 is 156.800") {
		t.Errorf("a piped table must keep every column whole:\n%s", out)
	}
}

// checkWidth fails when any line of a screen is wider than the terminal it
// was rendered for.
func checkWidth(t *testing.T, name, out string, width int) {
	t.Helper()
	for _, l := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if v := ui.Visible(l); v > width {
			t.Errorf("%s at %d columns: line is %d wide: %q", name, width, v, l)
		}
	}
}

// A numeric column is right-aligned under its header, so digits line up and a
// short value does not sit at the far left of a wide header.
func TestColumnsRightAlign(t *testing.T) {
	cols := []column{
		{head: "NAME", cells: []string{"a", "bb"}},
		{head: "PEAK SNR (dB)", cells: []string{"22", "9"}, right: true},
		{head: "NOTE", cells: []string{"x", "y"}},
	}
	var b strings.Builder
	if _, err := printColumns(&b, ui.Style{}, cols, nil); err != nil {
		t.Fatal(err)
	}
	want := "NAME  PEAK SNR (dB)  NOTE\na                22  x\nbb                9  y\n"
	if b.String() != want {
		t.Errorf("got:\n%s\nwant:\n%s", b.String(), want)
	}
	// Right-aligned as the last column too, with no trailing spaces.
	var c strings.Builder
	_, _ = printColumns(&c, ui.Style{}, cols[:2], nil)
	if got := c.String(); got != "NAME  PEAK SNR (dB)\na                22\nbb                9\n" {
		t.Errorf("last column: %q", got)
	}
}
