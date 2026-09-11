package cli

import (
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/internal/ui"
)

// chartViews are the live views that carry a frame: the picture each of them
// draws at one width, in one style, with the border asked for or not. The
// spectrum's own frame is TestSpectrumFrame's; these three join it.
var chartViews = []struct {
	name   string
	what   string // a fact from the header, which stands outside the border
	render func(st ui.Style, width int, frame bool) string
}{
	{"levels", "147.435 MHz NFM", func(st ui.Style, width int, frame bool) string {
		v := newLevelsView(st, width, levelsHeight, false, frame)
		return v.render(levelsTestFrame(v))
	}},
	{"waveform", "10 s", func(st ui.Style, width int, frame bool) string {
		v := newWaveformView(st, width, 10, scopeScale{fixed: waveformTestScale}, frame)
		return v.render(waveformTestFrame(v.cols()), waveformTestScale)
	}},
	{"scope", "window 40 ms", func(st ui.Style, width int, frame bool) string {
		v := newScopeView(st, width, scopeFull, frame)
		return v.render(scopeTestFrame())
	}},
}

// A terminal wide enough gets the picture in the frame `ley spectrum` draws,
// with the header above it: the chart and the axis it is read against are one
// object, and what the view is looking at is prose.
func TestLiveViewsCarryTheChartFrame(t *testing.T) {
	const width = 100
	for _, tc := range chartViews {
		t.Run(tc.name, func(t *testing.T) {
			text := tc.render(ui.Style{Unicode: true, Width: width}, width, true)
			lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
			if !strings.Contains(lines[0], tc.what) {
				t.Errorf("the header is not the first line, got %q", lines[0])
			}
			opened := -1
			for i, l := range lines {
				if strings.HasPrefix(l, "╭") && strings.HasSuffix(l, "╮") {
					opened = i
					break
				}
			}
			if opened < 0 {
				t.Fatalf("the picture is not framed:\n%s", text)
			}
			for _, l := range lines[:opened] {
				if strings.Contains(l, "│") {
					t.Errorf("the header belongs above the frame, got %q", l)
				}
			}
			if last := lines[len(lines)-1]; !strings.HasPrefix(last, "╰") {
				t.Errorf("the frame must close under the axis, got %q", last)
			}
		})
	}
}

// A pipe, --ascii and a cramped screen draw the picture bare, and the frame
// never costs the view its width: what the border and its padding take comes
// out of the chart, not out of the terminal.
func TestLiveViewFramesFitTheWidth(t *testing.T) {
	for _, tc := range chartViews {
		t.Run(tc.name, func(t *testing.T) {
			for _, bare := range []struct {
				name  string
				st    ui.Style
				width int
				frame bool
			}{
				{"piped", ui.Style{Unicode: true, Width: 100}, 100, false},
				{"ascii", ui.Style{Width: 100}, 100, true},
				{"narrow", ui.Style{Unicode: true, Width: chartFrameMinWidth - 1}, chartFrameMinWidth - 1, true},
			} {
				if got := tc.render(bare.st, bare.width, bare.frame); framed(got) {
					t.Errorf("%s must not be framed:\n%s", bare.name, got)
				}
			}
			for _, width := range []int{chartFrameMinWidth, 80, 100, ui.MaxWidth} {
				st := ui.Style{Unicode: true, Color: true, Profile: ui.ProfileTrueColor, Width: width}
				got := tc.render(st, width, true)
				if plain := tc.render(ui.Style{Unicode: true, Width: width}, width, true); ui.Strip(got) != plain {
					t.Errorf("width %d: the inked frame strips to a different picture\nplain:\n%s\nstripped:\n%s",
						width, plain, ui.Strip(got))
				}
				for _, l := range strings.Split(strings.TrimRight(got, "\n"), "\n") {
					if w := ui.Visible(l); w > width {
						t.Errorf("width %d: a framed line is %d columns: %q", width, w, ui.Strip(l))
					}
				}
			}
		})
	}
}
