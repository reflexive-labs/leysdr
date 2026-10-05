// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"errors"
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

// notificationSwift prints the frame of the first on-screen window a notification process owns,
// as "x y width height" in global points. macOS names that process NotificationCenter or
// Notification Center depending on the release, so any owner starting "Notification" counts.
// Run with "list", it prints every on-screen window's owner, layer and frame instead, for the
// run directory when no notification was found.
const notificationSwift = `import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
func frame(_ w: [String: Any]) -> (Double, Double, Double, Double)? {
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = b["X"] as? Double, let y = b["Y"] as? Double,
          let width = b["Width"] as? Double, let height = b["Height"] as? Double else { return nil }
    return (x, y, width, height)
}
if CommandLine.arguments.dropFirst().first == "list" {
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        if let f = frame(w) { print("\(owner)\tlayer \(layer)\t\(f.0) \(f.1) \(f.2) \(f.3)") }
    }
    exit(0)
}
// A banner: a notification process's window on a display, about the size of one notification
// (Notification Center also keeps full-screen and zero-size windows). The region is clipped to
// that display, since screencapture -R refuses a rectangle that leaves every display.
var displays = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetActiveDisplayList(16, &displays, &count)
for w in list where (w[kCGWindowOwnerName as String] as? String)?.hasPrefix("Notification") == true {
    guard let f = frame(w), f.2 >= 200, f.2 <= 900, f.3 >= 40, f.3 <= 400 else { continue }
    let r = CGRect(x: f.0, y: f.1, width: f.2, height: f.3)
    for d in displays.prefix(Int(count)) {
        let c = r.intersection(CGDisplayBounds(d)).integral
        if c.width >= 100, c.height >= 30 {
            print("\(Int(c.minX)) \(Int(c.minY)) \(Int(c.width)) \(Int(c.height))")
            exit(0)
        }
    }
}
`

// errManual is a shot leyshots could not take, which the person takes by hand.
var errManual = errors.New("manual")

// captureNotification waits up to wait for a notification window and captures its frame. It is
// best effort: when no window appears, the on-screen windows are listed in windows.txt in the run
// directory and the shot is left for the person to take.
func captureNotification(ctx context.Context, swift, run, out string, wait time.Duration, logf func(string, ...any)) error {
	script := filepath.Join(run, "notification.swift")
	if err := os.WriteFile(script, []byte(notificationSwift), 0o644); err != nil {
		return err
	}
	deadline := time.Now().Add(wait)
	for time.Now().Before(deadline) {
		b, err := exec.CommandContext(ctx, swift, script).Output()
		if err == nil {
			var x, y, w, h float64
			if _, serr := fmt.Sscan(string(b), &x, &y, &w, &h); serr == nil {
				region := fmt.Sprintf("%.0f,%.0f,%.0f,%.0f", x, y, w, h)
				listWindows(ctx, swift, script, run)
				if b, err := exec.CommandContext(ctx, "screencapture", "-x", "-R", region, out).CombinedOutput(); err != nil {
					return fmt.Errorf("screencapture -R %s: %w: %s (the on-screen windows are in %s)",
						region, err, strings.TrimSpace(string(b)), filepath.Join(run, "windows.txt"))
				}
				logf("notification captured from %s", region)
				return nil
			}
		}
		if err := sleep(ctx, 0.5); err != nil {
			return err
		}
	}
	windows := listWindows(ctx, swift, script, run)
	logf("no notification window appeared within %.0f s; the on-screen windows are in %s; take %s by hand",
		wait.Seconds(), windows, filepath.Base(out))
	return errManual
}

// listWindows writes every on-screen window's owner, layer and frame to windows.txt in the run
// directory, for working out which window a notification capture took or why it found none.
func listWindows(ctx context.Context, swift, script, run string) string {
	windows := filepath.Join(run, "windows.txt")
	if b, err := exec.CommandContext(ctx, swift, script, "list").Output(); err == nil {
		_ = os.WriteFile(windows, b, 0o644)
	}
	return windows
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
