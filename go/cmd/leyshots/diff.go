// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/color"
	"math"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// pixelTolerance is how far, out of 255, one channel of a pixel may move before the pixel counts
// as changed: enough for a colour space round trip, not enough for a different ink.
const pixelTolerance = 3

// defaultThreshold is the percentage of compared pixels a snapshot may change and still pass.
const defaultThreshold = 0.1

// pixelDiff is the result of comparing a snapshot with its golden.
type pixelDiff struct {
	// Changed is the percentage of compared (unmasked) pixels that changed.
	Changed float64
	// Image draws the changed pixels red over a faded copy of the actual image, masked ones grey.
	Image *image.RGBA
}

// errSizeMismatch is a snapshot whose size is not its golden's.
var errSizeMismatch = errors.New("size")

// comparePixels compares actual with golden, skipping the masked rectangles (in actual's pixel
// coordinates). A pixel is changed when one of its channels differs by more than tolerance and it
// is not anti-aliasing, as pixelmatch's antialiased() detects it (Vysniauskas 2009): a pixel
// forgiven as anti-aliasing is a blend between a darker and a brighter neighbour, and that
// neighbour sits in a flat area in both images. Text is most of what a check looks at, so a pixel
// is not forgiven merely because its colour appears nearby: a changed glyph or an inverted 1 px
// pattern still counts.
func comparePixels(golden, actual image.Image, masks []image.Rectangle, tolerance int) (*pixelDiff, error) {
	gb, ab := golden.Bounds(), actual.Bounds()
	if gb.Dx() != ab.Dx() || gb.Dy() != ab.Dy() {
		return nil, fmt.Errorf("%w %dx%d vs %dx%d", errSizeMismatch, ab.Dx(), ab.Dy(), gb.Dx(), gb.Dy())
	}
	w, h := ab.Dx(), ab.Dy()
	g, a := toNRGBA(golden), toNRGBA(actual)
	out := image.NewRGBA(image.Rect(0, 0, w, h))
	masked := func(x, y int) bool {
		p := image.Pt(x+ab.Min.X, y+ab.Min.Y)
		for _, m := range masks {
			if p.In(m) {
				return true
			}
		}
		return false
	}
	changed, compared := 0, 0
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			ac := a.NRGBAAt(x, y)
			if masked(x, y) {
				out.SetRGBA(x, y, color.RGBA{R: 0x80, G: 0x80, B: 0x80, A: 0xff})
				continue
			}
			compared++
			gc := g.NRGBAAt(x, y)
			if within(ac, gc, tolerance) || antialiased(g, a, x, y) || antialiased(a, g, x, y) {
				// Faded towards white, so the red reads on the app's dark ground.
				out.SetRGBA(x, y, color.RGBA{R: 0xc0 + ac.R/4, G: 0xc0 + ac.G/4, B: 0xc0 + ac.B/4, A: 0xff})
				continue
			}
			changed++
			out.SetRGBA(x, y, color.RGBA{R: 0xff, A: 0xff})
		}
	}
	d := &pixelDiff{Image: out}
	if compared > 0 {
		d.Changed = 100 * float64(changed) / float64(compared)
	}
	return d, nil
}

// toNRGBA copies img into an NRGBA with its origin at 0,0.
func toNRGBA(img image.Image) *image.NRGBA {
	b := img.Bounds()
	out := image.NewNRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			out.Set(x, y, img.At(x+b.Min.X, y+b.Min.Y))
		}
	}
	return out
}

// within reports whether every channel of a and b is within tolerance.
func within(a, b color.NRGBA, tolerance int) bool {
	d := func(p, q uint8) bool { return abs(int(p)-int(q)) <= tolerance }
	return d(a.R, b.R) && d(a.G, b.G) && d(a.B, b.B) && d(a.A, b.A)
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// antialiased reports whether the pixel at x,y of img looks like anti-aliasing, as pixelmatch's
// antialiased() decides it: among its eight neighbours there are at most two of its own
// brightness (a pixel on the image's edge counts one already), at least one darker and one
// brighter, and the darkest or the brightest neighbour has more than two identical neighbours of
// its own in both img and other, so it is the flat area the blend runs into.
func antialiased(img, other *image.NRGBA, x, y int) bool {
	b := img.Bounds()
	zeroes := 0
	if x == b.Min.X || x == b.Max.X-1 || y == b.Min.Y || y == b.Max.Y-1 {
		zeroes = 1
	}
	centre := brightness(img.NRGBAAt(x, y))
	var lo, hi float64
	var loP, hiP image.Point
	for dy := -1; dy <= 1; dy++ {
		for dx := -1; dx <= 1; dx++ {
			p := image.Pt(x+dx, y+dy)
			if (dx == 0 && dy == 0) || !p.In(b) {
				continue
			}
			switch d := centre - brightness(img.NRGBAAt(p.X, p.Y)); {
			case d == 0:
				zeroes++
				if zeroes > 2 {
					return false
				}
			case d < lo:
				lo, loP = d, p
			case d > hi:
				hi, hiP = d, p
			}
		}
	}
	if lo == 0 || hi == 0 {
		return false
	}
	return (manySiblings(img, loP) && manySiblings(other, loP)) ||
		(manySiblings(img, hiP) && manySiblings(other, hiP))
}

// manySiblings reports whether more than two of p's neighbours are exactly its colour, a pixel on
// the image's edge counting one already.
func manySiblings(img *image.NRGBA, p image.Point) bool {
	b := img.Bounds()
	zeroes := 0
	if p.X == b.Min.X || p.X == b.Max.X-1 || p.Y == b.Min.Y || p.Y == b.Max.Y-1 {
		zeroes = 1
	}
	c := img.NRGBAAt(p.X, p.Y)
	for dy := -1; dy <= 1; dy++ {
		for dx := -1; dx <= 1; dx++ {
			q := image.Pt(p.X+dx, p.Y+dy)
			if (dx == 0 && dy == 0) || !q.In(b) {
				continue
			}
			if img.NRGBAAt(q.X, q.Y) == c {
				zeroes++
				if zeroes > 2 {
					return true
				}
			}
		}
	}
	return false
}

// brightness is the pixel's luma (YIQ's Y, as pixelmatch uses), blended over white by its alpha.
func brightness(c color.NRGBA) float64 {
	blend := func(v uint8) float64 { return 255 + (float64(v)-255)*float64(c.A)/255 }
	return blend(c.R)*0.29889531 + blend(c.G)*0.58662247 + blend(c.B)*0.11448223
}

// maskRects maps regions in window points (origin at the top-left corner of the window's frame,
// as regions.json gives them) onto an image at scale pixels per point, rounded outward.
func maskRects(regions []Rect, scale float64) []image.Rectangle {
	out := make([]image.Rectangle, 0, len(regions))
	for _, r := range regions {
		out = append(out, image.Rect(
			int(math.Floor(r.X*scale)), int(math.Floor(r.Y*scale)),
			int(math.Ceil((r.X+r.Width)*scale)), int(math.Ceil((r.Y+r.Height)*scale)),
		))
	}
	return out
}

// macOSRelease is the running macOS as major.minor, which names the goldens' directory: font
// metrics change between releases, so a golden from another one shows diffs nobody can see.
func macOSRelease(ctx context.Context) (string, error) {
	out, err := exec.CommandContext(ctx, "sw_vers", "-productVersion").Output()
	if err != nil {
		return "", fmt.Errorf("sw_vers: %w", err)
	}
	return majorMinor(string(out)), nil
}

// majorMinor keeps the first two parts of a version: 26.0.1 is 26.0, 26 is 26.0.
func majorMinor(v string) string {
	parts := strings.SplitN(strings.TrimSpace(v), ".", 3)
	if len(parts) == 1 {
		return parts[0] + ".0"
	}
	return parts[0] + "." + parts[1]
}

// goldenDir is where one scene's goldens at one window size live:
// <goldens>/<macOS major.minor>-<GOARCH>/<scene>/<W>x<H>.
func goldenDir(goldens, release, scene string, size Size) string {
	return filepath.Join(goldens, release+"-"+runtime.GOARCH, scene, size.String())
}

// unifiedDiff is `diff -u` of the golden and actual files, labelled with their paths; empty when
// they are the same.
func unifiedDiff(ctx context.Context, golden, actual string) (string, error) {
	cmd := exec.CommandContext(ctx, "diff", "-u", golden, actual)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	var exit *exec.ExitError
	switch {
	case err == nil:
		return "", nil
	case errors.As(err, &exit) && exit.ExitCode() == 1:
		return out.String(), nil
	}
	return "", fmt.Errorf("diff -u %s %s: %w", golden, actual, err)
}
