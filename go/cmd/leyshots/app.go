// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"image"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// appExe is the app bundle's executable (scripts/bundle-app.sh), run directly rather than through
// `open` so it inherits the scene's environment.
const appExe = "Contents/MacOS/LeylineApp"

// regionsGrace is how long past its settle time the app has to write regions.json. It covers
// launch and the 15 s the app waits for a live daemon before it gives up on the stage.
const regionsGrace = 30 * time.Second

// onAirGrace is the most an on_air stage adds after settle: the app's 30 s wait for an over that
// holds the squelch open, the 1.5 s fill and the 1 s it gives the window to come forward
// (Staging.onAirSeconds, onAirFillSeconds, frontSeconds).
const onAirGrace = 35 * time.Second

// appShot is a running staged app.
type appShot struct {
	cmd     *exec.Cmd
	exited  <-chan error // receives the app's exit, once
	run     string       // the scene's run directory
	log     string
	regions *Regions
}

// stageJSON is the stage file for s: the scene's stage with import_chirp made absolute.
func stageJSON(f *File, s *Stage) ([]byte, error) {
	st := *s
	if st.ImportChirp != "" {
		abs, err := filepath.Abs(f.Path(st.ImportChirp))
		if err != nil {
			return nil, err
		}
		st.ImportChirp = abs
	}
	return json.MarshalIndent(st, "", "  ")
}

// launchApp starts the app on the scene's daemon with its stage file in the run directory, and
// waits for the regions.json the app writes beside it.
func launchApp(ctx context.Context, app string, f *File, s *Scene, run string, env []string, logf func(string, ...any)) (*appShot, error) {
	stage, err := stageJSON(f, s.Stage)
	if err != nil {
		return nil, err
	}
	stagePath := filepath.Join(run, "stage.json")
	regionsPath := filepath.Join(run, "regions.json")
	_ = os.Remove(regionsPath)
	if err := os.WriteFile(stagePath, stage, 0o644); err != nil {
		return nil, err
	}
	a := &appShot{run: run, log: filepath.Join(run, "app.log")}
	// -ApplePersistenceIgnoreState: the window a previous launch left saved, or a saved state
	// with no windows, is not restored; the staged window is always a fresh one.
	a.cmd = exec.Command(filepath.Join(app, appExe), "-ApplePersistenceIgnoreState", "YES")
	a.cmd.Env = append(append(os.Environ(), env...), "LEYLINE_APP_STAGE="+stagePath, "LEYLINE_APP_LOG="+a.log)
	// The app's own output, where a Swift runtime trap or an AppKit exception is printed.
	stderrPath := filepath.Join(run, "app.stderr")
	stderr, err := os.Create(stderrPath)
	if err != nil {
		return nil, err
	}
	defer stderr.Close()
	a.cmd.Stdout, a.cmd.Stderr = stderr, stderr
	if err := a.cmd.Start(); err != nil {
		return nil, fmt.Errorf("start the app: %w; build it with: make app-bundle", err)
	}
	exited := make(chan error, 1)
	go func() { exited <- a.cmd.Wait() }()
	a.exited = exited
	wait := time.Duration(s.Stage.Settle*float64(time.Second)) + regionsGrace
	if s.Stage.OnAir {
		wait += onAirGrace
	}
	deadline := time.Now().Add(wait)
	logf("waiting for the app to apply the stage and settle (up to %.0f s)", wait.Seconds())
	for {
		if r, err := readRegions(regionsPath); err == nil {
			a.regions = r
			return a, nil
		}
		select {
		case err := <-exited:
			a.cmd = nil
			return nil, fmt.Errorf("the app exited before it wrote %s (%w); its log is %s and its output %s; crash reports are in ~/Library/Logs/DiagnosticReports",
				regionsPath, err, a.log, stderrPath)
		default:
		}
		if time.Now().After(deadline) {
			a.quit()
			return nil, fmt.Errorf("the app wrote no %s within %.0f s of starting; its log is %s and its output %s", regionsPath, wait.Seconds(), a.log, stderrPath)
		}
		if err := sleep(ctx, 0.25); err != nil {
			a.quit()
			return nil, err
		}
	}
}

// capture takes the app's window with screencapture (no shadow, no sound) and crops it to the
// scene's crop into out.
func (a *appShot) capture(ctx context.Context, c *Crop, out string) error {
	full := filepath.Join(a.run, "window.png")
	cmd := exec.CommandContext(ctx, "screencapture", "-o", "-x", "-l", fmt.Sprint(a.regions.WindowNumber), full)
	if b, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("screencapture: %w: %s (the terminal running make shots needs Screen Recording permission)", err, strings.TrimSpace(string(b)))
	}
	img, err := readPNG(full)
	if err != nil {
		return err
	}
	if err := checkCapture(img.Bounds(), a.regions.Regions["window"]); err != nil {
		return err
	}
	rect, err := cropRect(c, a.regions)
	if err != nil {
		return err
	}
	px := pixelRect(rect, a.regions.Regions["window"], img.Bounds())
	if px.Empty() {
		return fmt.Errorf("the crop %+v is outside the captured window", rect)
	}
	return cropPNG(img, px, out)
}

// quit ends the app: an interrupt, then a kill if it is still running 5 s later.
func (a *appShot) quit() {
	if a.cmd == nil || a.cmd.Process == nil {
		return
	}
	_ = a.cmd.Process.Signal(os.Interrupt)
	select {
	case <-a.exited:
	case <-time.After(5 * time.Second):
		_ = a.cmd.Process.Kill()
		<-a.exited
	}
}

// checkCapture refuses a capture whose shape is not the window's: Stage Manager's strip and
// Mission Control draw a window as a small tilted thumbnail, and screencapture -l takes that.
// The image must be the window's size at a whole scale of 1 to 3, give or take a pixel.
func checkCapture(b image.Rectangle, window Rect) error {
	if window.Width <= 0 || window.Height <= 0 {
		return fmt.Errorf("regions.json gave the window no size")
	}
	for scale := 1.0; scale <= 3; scale++ {
		if math.Abs(float64(b.Dx())-window.Width*scale) <= 1 && math.Abs(float64(b.Dy())-window.Height*scale) <= 1 {
			return nil
		}
	}
	return fmt.Errorf("the capture is %d×%d px, not the window's %.0f×%.0f pt at 1×, 2× or 3×; Stage Manager or Mission Control was showing it as a thumbnail; turn Stage Manager off in Control Centre and run again",
		b.Dx(), b.Dy(), window.Width, window.Height)
}
