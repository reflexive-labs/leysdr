// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

// drivenApp is a site scene's app driven over its command file, as a check scene's is
// (checkrun.go): launched with `open -g`, so it takes no focus, sent the scene's app commands, and
// shot by its own picture of the window (the last snapshot), which needs neither the focus nor
// screencapture. A state's expectation that fails, or a command the app refuses, fails the shot.
type drivenApp struct {
	c     *checker
	s     *CheckScene
	app   *runningApp
	local *localRun
	dir   string
	size  Size
	// shot is the last snapshot's picture and what the app said of it.
	shot    string
	shotRes snapshotResult
	// sent is how many commands have gone, so quit takes the next id.
	sent int
}

// startDriven launches the app on the scene's daemon at the stage's window size and waits for it
// to be ready.
func startDriven(ctx context.Context, o runOptions, f *File, s *Scene, sr *sceneRun, run string) (*drivenApp, error) {
	co := checkOptions{
		runOptions: o,
		launch:     openApp, alive: processAlive, kill: killProcess, findPID: findAppPID,
		grace: answerGrace, poll: 100 * time.Millisecond,
	}
	// A snapshot's golden is looked for here and never found, so the picture is kept as new.
	co.goldens = filepath.Join(run, "no-goldens")
	stage := *s.Stage
	size := defaultCheckSize
	if stage.Window != nil {
		size = *stage.Window
	}
	stage.Window = nil
	cs := &CheckScene{Name: s.Name(), Stage: &stage, App: s.App}
	c := &checker{o: co, f: &CheckFile{dir: f.dir}, buffered: true}
	sd := &sceneDaemon{
		env: sr.env, stop: sr.stop, halt: sr.daemon.Halt,
		resume: func(ctx context.Context) error { return sr.restart(ctx, o) },
	}
	o.logf("launching the app in the background (up to %.0f s for it to be ready)", (time.Duration(stage.Settle*float64(time.Second)) + answerGrace).Seconds())
	app, err := c.launch(ctx, &stage, size, run, sr.env)
	if err != nil {
		return nil, err
	}
	return &drivenApp{
		c: c, s: cs, app: app, dir: run, size: size,
		local: &localRun{c: c, daemon: sd, run: run, bg: map[string]*bgProcess{}},
	}, nil
}

// commands sends the scene's app commands in order, running the runner's own (ley, file, daemon)
// itself, and keeps the last snapshot.
func (d *drivenApp) commands(ctx context.Context) error {
	for i := range d.s.App {
		cmd := &d.s.App[i]
		id := i + 1
		d.sent = id
		if cmd.isLocal() {
			results, stop := d.local.runLocal(ctx, cmd, id)
			for _, r := range results {
				d.c.add(r)
			}
			if stop {
				break
			}
			continue
		}
		a, err := d.app.send(ctx, cmd, id, d.c.f.Path)
		if err != nil {
			return fmt.Errorf("%s: %w", cmd.label(id), err)
		}
		if cmd.Cmd == "snapshot" && a.OK {
			src, ok := answerFile(a, ".png")
			if !ok {
				return fmt.Errorf("%s: the answer names no .png", cmd.label(id))
			}
			d.shot = filepath.Join(d.app.control, src)
			d.shotRes = snapshotResult{}
			if err := json.Unmarshal(a.Result, &d.shotRes); err != nil {
				return fmt.Errorf("%s: the snapshot's result: %w", cmd.label(id), err)
			}
			continue
		}
		d.c.handle(ctx, d.s, d.size, d.dir, d.app, cmd, id, a)
	}
	var bad []string
	for _, r := range d.c.results {
		if r.failing() {
			bad = append(bad, strings.TrimSpace(r.line()))
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("the app's commands did not all pass; the app's log is %s:\n  %s", d.app.log, strings.Join(bad, "\n  "))
	}
	if d.shot == "" {
		return errors.New("no snapshot was taken")
	}
	return nil
}

// crop writes the last snapshot cut to the crop into out. The picture is the window it was taken
// of at its backing scale; a Settings picture has no regions, so its window is the whole picture.
func (d *drivenApp) crop(c *Crop, out string) error {
	img, err := readPNG(d.shot)
	if err != nil {
		return err
	}
	regions, err := d.shotRes.regions()
	if err != nil {
		return err
	}
	if regions == nil {
		regions = map[string]Rect{}
	}
	if _, ok := regions["window"]; !ok {
		regions["window"] = Rect{Width: d.shotRes.WidthPt, Height: d.shotRes.HeightPt}
	}
	r := &Regions{Regions: regions}
	if err := checkCapture(img.Bounds(), regions["window"]); err != nil {
		return err
	}
	rect, err := cropRect(c, r)
	if err != nil {
		return err
	}
	px := pixelRect(rect, regions["window"], img.Bounds())
	if px.Empty() {
		return fmt.Errorf("the crop %+v is outside the window's picture", rect)
	}
	return cropPNG(img, px, out)
}

// quit ends a background ley the commands left running, then the app.
func (d *drivenApp) quit(ctx context.Context) {
	d.local.cleanup()
	d.app.quit(ctx, d.app.nextID(d.sent+1))
}
