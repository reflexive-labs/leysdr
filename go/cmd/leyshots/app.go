// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

// appShot is a running staged app.
type appShot struct {
	cmd     *exec.Cmd
	run     string // the scene's run directory
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
	a.cmd = exec.Command(filepath.Join(app, appExe))
	a.cmd.Env = append(append(os.Environ(), env...), "LEYLINE_APP_STAGE="+stagePath, "LEYLINE_APP_LOG="+a.log)
	if err := a.cmd.Start(); err != nil {
		return nil, fmt.Errorf("start the app: %w; build it with: make app-bundle", err)
	}
	wait := time.Duration(s.Stage.Settle*float64(time.Second)) + regionsGrace
	deadline := time.Now().Add(wait)
	logf("waiting for the app to apply the stage and settle (%.0f s)", s.Stage.Settle)
	for {
		if r, err := readRegions(regionsPath); err == nil {
			a.regions = r
			return a, nil
		}
		if time.Now().After(deadline) {
			a.quit()
			return nil, fmt.Errorf("the app wrote no %s within %.0f s of starting; its log is %s", regionsPath, wait.Seconds(), a.log)
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
	done := make(chan struct{})
	go func() { _ = a.cmd.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = a.cmd.Process.Kill()
		<-done
	}
}

// notificationSwift prints the frame of the first on-screen window NotificationCenter owns, as
// "x y width height" in global points, or nothing.
const notificationSwift = `import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "NotificationCenter" {
    if let b = w[kCGWindowBounds as String] as? [String: Any],
       let x = b["X"] as? Double, let y = b["Y"] as? Double,
       let width = b["Width"] as? Double, let height = b["Height"] as? Double, width > 0, height > 0 {
        print("\(x) \(y) \(width) \(height)")
        exit(0)
    }
}
`

// errManual is a shot leyshots could not take, which the person takes by hand.
var errManual = errors.New("manual")

// captureNotification waits up to 10 s for a NotificationCenter window and captures its frame.
// It is best effort: when the window does not appear, the shot is left for the person to take.
func captureNotification(ctx context.Context, swift, run, out string, logf func(string, ...any)) error {
	script := filepath.Join(run, "notification.swift")
	if err := os.WriteFile(script, []byte(notificationSwift), 0o644); err != nil {
		return err
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		b, err := exec.CommandContext(ctx, swift, script).Output()
		if err == nil {
			var x, y, w, h float64
			if _, serr := fmt.Sscan(string(b), &x, &y, &w, &h); serr == nil {
				region := fmt.Sprintf("%.0f,%.0f,%.0f,%.0f", x, y, w, h)
				if b, err := exec.CommandContext(ctx, "screencapture", "-x", "-R", region, out).CombinedOutput(); err != nil {
					return fmt.Errorf("screencapture: %w: %s", err, strings.TrimSpace(string(b)))
				}
				return nil
			}
		}
		if err := sleep(ctx, 0.5); err != nil {
			return err
		}
	}
	logf("no NotificationCenter window appeared within 10 s; take %s by hand", filepath.Base(out))
	return errManual
}
