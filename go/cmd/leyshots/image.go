// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"math"
	"os"
)

// Rect is a region in window points, origin at the window frame's top-left corner.
type Rect struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// Regions is the regions.json the app writes when a staged run has settled (docs/dev/app.md,
// "Staged runs").
type Regions struct {
	WindowNumber int             `json:"window_number"`
	Regions      map[string]Rect `json:"regions"`
}

func readRegions(path string) (*Regions, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r Regions
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if _, ok := r.Regions["window"]; !ok {
		return nil, fmt.Errorf("%s has no window region", path)
	}
	return &r, nil
}

// union is the smallest rectangle holding a and b.
func union(a, b Rect) Rect {
	x0, y0 := math.Min(a.X, b.X), math.Min(a.Y, b.Y)
	x1, y1 := math.Max(a.X+a.Width, b.X+b.Width), math.Max(a.Y+a.Height, b.Y+b.Height)
	return Rect{X: x0, Y: y0, Width: x1 - x0, Height: y1 - y0}
}

// cropRect is the crop's rectangle in window points: the union of its regions, or a box of its
// size at its anchor inside that union. A region the app did not report is an error naming it.
func cropRect(c *Crop, r *Regions) (Rect, error) {
	var u Rect
	for i, name := range c.Regions {
		rect, ok := r.Regions[name]
		if !ok {
			return Rect{}, fmt.Errorf("the app reported no %s region (it reports only what is on screen)", name)
		}
		if i == 0 {
			u = rect
		} else {
			u = union(u, rect)
		}
	}
	if c.Size == nil {
		return u, nil
	}
	w, h := math.Min(c.Size.Width, u.Width), math.Min(c.Size.Height, u.Height)
	box := Rect{X: u.X, Y: u.Y, Width: w, Height: h}
	switch c.Anchor {
	case "top-right":
		box.X = u.X + u.Width - w
	case "bottom-left":
		box.Y = u.Y + u.Height - h
	case "bottom-right":
		box.X, box.Y = u.X+u.Width-w, u.Y+u.Height-h
	case "center":
		box.X, box.Y = u.X+(u.Width-w)/2, u.Y+(u.Height-h)/2
	}
	return box, nil
}

// pixelRect maps a rectangle in window points onto the window's captured image: the scale is the
// image's width over the window's width in points (2 on a Retina screen), and the result is
// rounded outward to whole pixels and clipped to the image.
func pixelRect(rect, window Rect, bounds image.Rectangle) image.Rectangle {
	scale := float64(bounds.Dx()) / window.Width
	px := image.Rect(
		int(math.Floor((rect.X-window.X)*scale)), int(math.Floor((rect.Y-window.Y)*scale)),
		int(math.Ceil((rect.X-window.X+rect.Width)*scale)), int(math.Ceil((rect.Y-window.Y+rect.Height)*scale)),
	).Add(bounds.Min)
	return px.Intersect(bounds)
}

func readPNG(path string) (image.Image, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return png.Decode(f)
}

func writePNG(path string, img image.Image) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if err := png.Encode(f, img); err != nil {
		_ = f.Close() // the encode error is the one to report
		return err
	}
	return f.Close()
}

// cropPNG writes the part of in at px to out.
func cropPNG(in image.Image, px image.Rectangle, out string) error {
	dst := image.NewRGBA(image.Rect(0, 0, px.Dx(), px.Dy()))
	draw.Draw(dst, dst.Bounds(), in, px.Min, draw.Src)
	return writePNG(out, dst)
}

// groundColour is the site's terminal background, #090B0C, which a composite is laid out on.
var groundColour = color.RGBA{R: 0x09, G: 0x0B, B: 0x0C, A: 0xff}

// composite lays the images side by side on the ground colour, top-aligned, with gap pixels
// around and between them.
func composite(images []image.Image, gap int) *image.RGBA {
	w, h := gap, 0
	for _, img := range images {
		w += img.Bounds().Dx() + gap
		h = max(h, img.Bounds().Dy())
	}
	h += 2 * gap
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.Draw(dst, dst.Bounds(), &image.Uniform{C: groundColour}, image.Point{}, draw.Src)
	x := gap
	for _, img := range images {
		b := img.Bounds()
		draw.Draw(dst, image.Rect(x, gap, x+b.Dx(), gap+b.Dy()), img, b.Min, draw.Over)
		x += b.Dx() + gap
	}
	return dst
}

// pngSize reads a PNG's dimensions without decoding its pixels.
func pngSize(path string) (int, int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	cfg, err := png.DecodeConfig(f)
	if err != nil {
		return 0, 0, fmt.Errorf("%s: %w", path, err)
	}
	return cfg.Width, cfg.Height, nil
}
