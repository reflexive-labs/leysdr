// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"math"
	"strconv"

	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// The snapshot PNG is the one picture the adapter draws (docs/plans/mcp.md,
// MCP-6): a spectrum row the daemon already computed, rendered as pixels so
// an agent that can look at an image sees what `ley spectrum` shows a person.
// It draws the trace, not the area, on a dark ground, with the same five-stop
// level ramp as the terminal chart, so a level is the same colour in both.
// No font library: the few glyphs an axis needs are the 5x7 bitmaps below.

// Geometry of the picture, in pixels. The plot is exactly one pixel per bin,
// so the negotiated bin count is the plot's width and nothing is resampled.
const (
	pngGutter  = 48  // left: dB labels
	pngPlotH   = 240 // the trace
	pngAxisH   = 28  // bottom: frequency ticks and labels
	pngTop     = 8   // headroom above the loudest column
	pngMinSpan = 50  // dB from the floor line to the top, at least
)

// renderSpectrumPNG draws one row. floor is the row's median (the noise
// floor the peaks were judged against), which becomes the drawn reference
// line; the scale runs from ten dB under it to the loudest column or fifty
// dB over it, whichever is higher, the way the terminal chart holds its
// span. mark, when non-zero, is the frequency asked for, marked under the
// axis. peaks are the loudest local maxima, marked on the trace.
func renderSpectrumPNG(bins []float64, floor float64, centerHz, spanHz uint64, peaks []Peak, mark uint64) ([]byte, error) {
	w := pngGutter + max(len(bins), 1)
	h := pngTop + pngPlotH + pngAxisH
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	ground := color.RGBA{30, 30, 30, 255}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetRGBA(x, y, ground)
		}
	}
	if len(bins) == 0 {
		return encodePNG(img)
	}
	if math.IsNaN(floor) || math.IsInf(floor, 0) {
		floor = medianDb(bins)
	}
	top := floor + pngMinSpan
	for _, v := range bins {
		if !math.IsNaN(v) && !math.IsInf(v, 0) && v+2 > top {
			top = v + 2
		}
	}
	bottom := floor - 10
	// yOf maps a level to a row: the plot's bottom edge is bottom, its top
	// edge (under the headroom) is top.
	yOf := func(db float64) int {
		if math.IsNaN(db) || math.IsInf(db, 0) {
			db = bottom
		}
		f := (db - bottom) / (top - bottom)
		if f < 0 {
			f = 0
		}
		if f > 1 {
			f = 1
		}
		return pngTop + int(math.Round(float64(pngPlotH-1)*(1-f)))
	}
	plotBottom := pngTop + pngPlotH - 1
	// The floor line, dashed, and the dB grid every ten dB above it.
	dim := color.RGBA{70, 70, 70, 255}
	for db := math.Ceil(bottom/10) * 10; db <= top; db += 10 {
		y := yOf(db)
		for x := pngGutter; x < w; x += 4 {
			img.SetRGBA(x, y, dim)
		}
		drawText(img, 2, y-3, fmtDbShort(db), color.RGBA{150, 150, 150, 255})
	}
	floorInk := color.RGBA{110, 110, 110, 255}
	fy := yOf(floor)
	for x := pngGutter; x < w; x++ {
		if x%2 == 0 {
			img.SetRGBA(x, fy, floorInk)
		}
	}
	// One column per bin: the glyph on the row the value falls in, and a
	// stem beneath it down to the floor line where it stands above the
	// floor, in the level ramp's colour for that height over the floor.
	for i, v := range bins {
		x := pngGutter + i
		y := yOf(v)
		frac := rampFrac(v, floor, top)
		r, g, b := ui.LevelRGB(frac)
		ink := color.RGBA{r, g, b, 255}
		img.SetRGBA(x, y, ink)
		if y < fy {
			stem := color.RGBA{r / 2, g / 2, b / 2, 255}
			for yy := y + 1; yy < fy; yy++ {
				img.SetRGBA(x, yy, stem)
			}
		} else if y < plotBottom {
			img.SetRGBA(x, y+1, color.RGBA{r / 2, g / 2, b / 2, 255})
		}
	}
	// Peaks: a small triangle above each, and its frequency.
	binWidth := float64(spanHz) / float64(len(bins))
	left := float64(centerHz) - float64(spanHz)/2
	white := color.RGBA{230, 230, 230, 255}
	for _, p := range peaks {
		i := int((float64(p.CenterHz) - left) / binWidth)
		if i < 0 || i >= len(bins) {
			continue
		}
		x := pngGutter + i
		y := yOf(p.Db) - 4
		for dy := 0; dy < 3; dy++ {
			for dx := -dy; dx <= dy; dx++ {
				img.SetRGBA(x+dx, y-dy, white)
			}
		}
		label := units.FormatFrequency(p.CenterHz)
		lx := x - textWidth(label)/2
		if lx < pngGutter {
			lx = pngGutter
		}
		if lx+textWidth(label) > w {
			lx = w - textWidth(label)
		}
		ly := y - 12
		if ly < 0 {
			ly = y + 6
		}
		drawText(img, lx, ly, label, white)
	}
	// The frequency axis: a rule, five ticks, and the frequency asked for
	// marked under the rule.
	axisY := pngTop + pngPlotH + 2
	for x := pngGutter; x < w; x++ {
		img.SetRGBA(x, axisY, dim)
	}
	for t := 0; t <= 4; t++ {
		x := pngGutter + (len(bins)-1)*t/4
		for y := axisY; y < axisY+4; y++ {
			img.SetRGBA(x, y, floorInk)
		}
		hz := uint64(math.Round(left + float64(x-pngGutter)*binWidth))
		label := units.FormatFrequency(hz)
		lx := x - textWidth(label)/2
		if lx < pngGutter {
			lx = pngGutter
		}
		if lx+textWidth(label) > w {
			lx = w - textWidth(label)
		}
		drawText(img, lx, axisY+8, label, color.RGBA{150, 150, 150, 255})
	}
	if mark != 0 && float64(mark) >= left && float64(mark) <= left+float64(spanHz) {
		x := pngGutter + int((float64(mark)-left)/binWidth)
		for dy := 0; dy < 4; dy++ {
			for dx := -dy; dx <= dy; dx++ {
				if x+dx >= pngGutter && x+dx < w {
					img.SetRGBA(x+dx, axisY+1+dy, white)
				}
			}
		}
	}
	drawText(img, 2, pngTop+pngPlotH-8, "dBFS", color.RGBA{110, 110, 110, 255})
	return encodePNG(img)
}

func encodePNG(img image.Image) ([]byte, error) {
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// fmtDbShort is a dB label with no decimals and no unit; the unit is on the
// picture once.
func fmtDbShort(db float64) string {
	return strconv.Itoa(int(math.Round(db)))
}

// The 5x7 glyphs an axis needs: digits, the signs and the unit letters
// FormatFrequency and the dB labels use. Anything else draws blank, which is
// fine for a label an agent also gets as text.
var pngFont = map[rune][7]string{
	'0': {".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."},
	'1': {"..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."},
	'2': {".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"},
	'3': {"#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."},
	'4': {"...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."},
	'5': {"#####", "#....", "####.", "....#", "....#", "#...#", ".###."},
	'6': {"..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."},
	'7': {"#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."},
	'8': {".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."},
	'9': {".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."},
	'.': {".....", ".....", ".....", ".....", ".....", ".##..", ".##.."},
	'-': {".....", ".....", ".....", "#####", ".....", ".....", "....."},
	'M': {"#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"},
	'H': {"#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"},
	'z': {".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"},
	'k': {"#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#."},
	'G': {".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"},
	'd': {"....#", "....#", ".####", "#...#", "#...#", "#...#", ".####"},
	'B': {"####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."},
	'F': {"#####", "#....", "#....", "####.", "#....", "#....", "#...."},
	'S': {".####", "#....", "#....", ".###.", "....#", "....#", "####."},
	' ': {".....", ".....", ".....", ".....", ".....", ".....", "....."},
}

// pngGlyphW is a glyph's advance: five columns and one of space.
const pngGlyphW = 6

func textWidth(s string) int { return len([]rune(s)) * pngGlyphW }

// drawText draws s with its top-left corner at (x, y).
func drawText(img *image.RGBA, x, y int, s string, ink color.RGBA) {
	for _, r := range s {
		g, ok := pngFont[r]
		if ok {
			for row, line := range g {
				for col, c := range line {
					if c == '#' {
						img.SetRGBA(x+col, y+row, ink)
					}
				}
			}
		}
		x += pngGlyphW
	}
}
