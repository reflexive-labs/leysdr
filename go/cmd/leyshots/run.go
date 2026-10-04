// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/reflexive-labs/leysdr/go/internal/daemonrun"
)

// runOptions are `leyshots run`'s inputs: where things are and which scenes to take.
type runOptions struct {
	root, scenes, out, cache string
	only                     []string
	// The programs a run drives.
	leylined, ley, leyfix, tmux, python, swift, app string
	decoders                                        string
	goos                                            string
	stdout                                          io.Writer
	logf                                            func(string, ...any)
	// leyfixSrc is leyfixSourceHash of the checkout, which a cached fixture must match.
	leyfixSrc string
}

// errHTMLOnly is a page rendered to HTML on a machine that cannot draw it to a PNG.
var errHTMLOnly = errors.New("HTML only: drawing it to a PNG needs macOS")

// errNeedsMac is a scene that drives the app or the screen.
var errNeedsMac = errors.New("needs macOS")

// outcome is what became of one scene.
type outcome struct {
	scene  string
	status string
	shot   *Shot
}

// runScenes takes each selected scene in turn, writes its image and its shots.json entry into
// o.out, and prints a line per scene. Scenes that cannot be taken on this platform are reported,
// not failed; a scene that breaks is reported and the run goes on to the next.
func runScenes(ctx context.Context, o runOptions) error {
	f, err := Load(o.scenes)
	if err != nil {
		return err
	}
	scenes, err := f.Select(o.only)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(o.out, 0o755); err != nil {
		return err
	}
	if o.leyfixSrc == "" {
		if o.leyfixSrc, err = leyfixSourceHash(o.root); err != nil {
			return err
		}
	}
	manifestPath := filepath.Join(o.out, "shots.json")
	manifest, err := readManifest(manifestPath)
	if err != nil {
		return err
	}
	tm := &tmuxRunner{bin: o.tmux}
	defer tm.stop()
	if stageManagerOn(ctx) {
		o.logf("warning: Stage Manager is on; it draws a window that is not in front as a thumbnail, and an app shot taken then fails. Turn it off in Control Centre for the run")
	}
	prov := provenance(ctx, o)
	var results []outcome
	failed := 0
	for _, s := range scenes {
		o.logf("%s: %s", s.Name(), s.Kind)
		shot, err := runScene(ctx, o, f, s, tm)
		res := outcome{scene: s.Name(), shot: shot}
		switch {
		case err == nil:
			shot.LeyVersion, shot.Commit = prov.ley, prov.commit
			manifest.put(*shot)
			res.status = fmt.Sprintf("ok %d×%d", shot.Width, shot.Height)
		case errors.Is(err, errHTMLOnly), errors.Is(err, errNeedsMac), errors.Is(err, errManual):
			res.status = "skipped: " + err.Error()
		default:
			failed++
			res.status = "failed: " + err.Error()
		}
		results = append(results, res)
		if ctx.Err() != nil {
			break
		}
	}
	if err := manifest.write(manifestPath); err != nil {
		return err
	}
	for _, r := range results {
		fmt.Fprintf(o.stdout, "%-24s %s\n", r.scene, r.status)
	}
	if failed > 0 {
		return fmt.Errorf("%d scene(s) failed; each scene's daemon log is in %s", failed, filepath.Join(o.out, "run"))
	}
	return nil
}

type prov struct{ ley, commit string }

// provenance is what shots.json records about the tools: `ley --version` and the commit.
func provenance(ctx context.Context, o runOptions) prov {
	var p prov
	if b, err := exec.CommandContext(ctx, o.ley, "--version").Output(); err == nil {
		p.ley = strings.TrimSpace(string(b))
	}
	if b, err := exec.CommandContext(ctx, "git", "-C", o.root, "describe", "--always", "--dirty", "--abbrev=7").Output(); err == nil {
		p.commit = strings.TrimSpace(string(b))
	}
	return p
}

// runScene takes one scene.
func runScene(ctx context.Context, o runOptions, f *File, s *Scene, tm *tmuxRunner) (*Shot, error) {
	out := filepath.Join(o.out, s.Asset)
	shot := &Shot{Asset: s.Asset, Scale: 2, Alt: altText(s.Alt), Scene: s.Name()}
	switch s.Kind {
	case kindIcon:
		if o.goos != "darwin" {
			return nil, errNeedsMac
		}
		cmd := exec.CommandContext(ctx, o.swift, filepath.Join(o.root, "scripts", "render-icon.swift"), "--png", "1024", out)
		if b, err := cmd.CombinedOutput(); err != nil {
			return nil, fmt.Errorf("render-icon.swift: %w\n%s", err, b)
		}
		return finish(shot, out)
	case kindTable:
		src, err := os.Open(f.Path(s.Table.Source))
		if err != nil {
			return nil, err
		}
		page, err := tableHTML(s.Name(), s.Table, src)
		_ = src.Close() // read-only
		if err != nil {
			return nil, err
		}
		if err := renderPage(ctx, o, s, page, s.Table.Width, out); err != nil {
			return nil, err
		}
		return finish(shot, out)
	case kindApp, kindComposite, kindScreen:
		if o.goos != "darwin" {
			return nil, errNeedsMac
		}
	}

	run := filepath.Join(o.out, "run", s.Name())
	if err := os.RemoveAll(run); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(run, 0o755); err != nil {
		return nil, err
	}
	var files []*fixtureFile
	shot.Fixtures = map[string]json.RawMessage{}
	for _, ref := range s.Fixtures {
		ff, err := ensureFixture(ctx, o.leyfix, o.cache, ref, o.leyfixSrc, o.logf)
		if err != nil {
			return nil, err
		}
		files = append(files, ff)
		shot.Fixtures[ref.Name] = ff.Generator
	}
	// The plugins (leydec-*) are installed beside ley; the daemon finds them on PATH.
	pathEnv := "PATH=" + filepath.Dir(o.ley) + string(os.PathListSeparator) + os.Getenv("PATH")
	d, err := daemonrun.Start(ctx, daemonrun.Options{
		Bin: o.leylined, Dir: run, Decoders: o.decoders, WallClock: s.Clock, Label: "leyshots", Env: []string{pathEnv},
	})
	if err != nil {
		return nil, err
	}
	defer d.Stop()
	env := []string{
		"LEYLINE_SOCKET=" + d.Socket, "LEYLINE_BOOKMARKS=" + filepath.Join(run, "bookmarks.json"),
		pathEnv, "COLORTERM=truecolor", "LANG=en_US.UTF-8",
	}
	steps, err := os.Create(filepath.Join(run, "steps.log"))
	if err != nil {
		return nil, err
	}
	defer steps.Close()
	ley := func(args ...string) error {
		fmt.Fprintf(steps, "$ ley %s\n", strings.Join(args, " "))
		cmd := exec.CommandContext(ctx, o.ley, args...)
		cmd.Env = append(os.Environ(), env...)
		cmd.Stdout, cmd.Stderr = steps, steps
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("ley %s: %w; the output is in %s", strings.Join(args, " "), err, steps.Name())
		}
		return nil
	}
	if s.Bookmarks != "" {
		if err := ley("bookmarks", "import", f.Path(s.Bookmarks)); err != nil {
			return nil, err
		}
	}
	// Each fixture becomes a radio with a channel tuned on it, and the channel outlives the
	// command. The app needs one tuned before it starts: a staged run does not reopen a band.
	for _, ff := range files {
		if err := ley("play", ff.Path, "--persistent", "--loop"); err != nil {
			return nil, err
		}
	}
	for _, st := range s.Steps {
		if st.Wait > 0 {
			o.logf("waiting %.0f s", st.Wait)
			if err := sleep(ctx, st.Wait); err != nil {
				return nil, err
			}
			continue
		}
		if err := ley(st.Ley...); err != nil {
			return nil, err
		}
	}
	tm.env = env

	switch s.Kind {
	case kindTerminal:
		panes, err := tm.session(ctx, s.Name(), s.Terminal, s.Settle)
		if err != nil {
			return nil, err
		}
		if err := renderTerminal(ctx, o, s, panes, out); err != nil {
			return nil, err
		}
		return finish(shot, out)
	case kindApp:
		a, err := launchApp(ctx, o.app, f, s, run, env, o.logf)
		if err != nil {
			return nil, err
		}
		defer a.quit()
		if err := a.capture(ctx, s.Crop, out); err != nil {
			return nil, err
		}
		return finish(shot, out)
	case kindComposite:
		// The first pane's command runs before the app starts, so the app opens on the channel it
		// tunes; the rest are typed once the app is showing, so it shows them land.
		if err := tm.open(ctx, s.Name(), s.Terminal); err != nil {
			return nil, err
		}
		defer tm.closeSession(ctx, s.Name())
		if err := tm.typePane(ctx, s.Name(), 0, s.Terminal.Panes[0]); err != nil {
			return nil, err
		}
		if err := sleep(ctx, 2); err != nil {
			return nil, err
		}
		a, err := launchApp(ctx, o.app, f, s, run, env, o.logf)
		if err != nil {
			return nil, err
		}
		defer a.quit()
		for i, p := range s.Terminal.Panes[1:] {
			if err := tm.typePane(ctx, s.Name(), i+1, p); err != nil {
				return nil, err
			}
		}
		if err := sleep(ctx, s.Settle); err != nil {
			return nil, err
		}
		panes, err := tm.read(ctx, s.Name())
		if err != nil {
			return nil, err
		}
		appPNG, termPNG := filepath.Join(run, "app.png"), filepath.Join(run, "terminal.png")
		if err := a.capture(ctx, s.Crop, appPNG); err != nil {
			return nil, err
		}
		if err := renderTerminal(ctx, o, s, panes, termPNG); err != nil {
			return nil, err
		}
		var imgs []image.Image
		for _, p := range []string{appPNG, termPNG} {
			img, err := readPNG(p)
			if err != nil {
				return nil, err
			}
			imgs = append(imgs, img)
		}
		// 16 pt of ground around and between them, at 2×.
		if err := writePNG(out, composite(imgs, 2*paddingPx)); err != nil {
			return nil, err
		}
		return finish(shot, out)
	case kindScreen:
		if s.Manual != "" {
			fmt.Fprintf(o.stdout, "%s: %s\n", s.Name(), s.Manual)
		}
		done := make(chan error, 1)
		go func() {
			_, err := tm.session(ctx, s.Name(), s.Terminal, s.Settle)
			done <- err
		}()
		capErr := captureNotification(ctx, o.swift, run, out, o.logf)
		if err := <-done; err != nil {
			return nil, err
		}
		if capErr != nil {
			return nil, capErr
		}
		return finish(shot, out)
	}
	return nil, fmt.Errorf("unknown kind %q", s.Kind)
}

// finish reads the written image's size and sha256 into the shot.
func finish(shot *Shot, path string) (*Shot, error) {
	w, h, err := pngSize(path)
	if err != nil {
		return nil, err
	}
	shot.Width, shot.Height = w, h
	if shot.PNGSHA256, err = fileSHA256(path); err != nil {
		return nil, err
	}
	return shot, nil
}

// renderTerminal writes the panes as a page beside the image and draws it.
func renderTerminal(ctx context.Context, o runOptions, s *Scene, panes []paneCapture, out string) error {
	page, err := terminalHTML(s.Name(), s.Terminal, panes, ansiToHTML(ctx, o.python, filepath.Join(o.root, "scripts", "ansi2html.py")))
	if err != nil {
		return err
	}
	return renderPage(ctx, o, s, page, terminalWidthPt(s.Terminal.Cols), out)
}

// renderPage writes page as <out>.html and, on macOS, draws it to out with
// scripts/render-html.swift at widthPt points, which gives a 2× PNG.
func renderPage(ctx context.Context, o runOptions, s *Scene, page string, widthPt float64, out string) error {
	htmlPath := strings.TrimSuffix(out, filepath.Ext(out)) + ".html"
	if err := os.WriteFile(htmlPath, []byte(page), 0o644); err != nil {
		return err
	}
	o.logf("%s: wrote %s", s.Name(), htmlPath)
	if o.goos != "darwin" {
		return errHTMLOnly
	}
	cmd := exec.CommandContext(ctx, o.swift, filepath.Join(o.root, "scripts", "render-html.swift"), htmlPath, out,
		"--width", fmt.Sprintf("%.0f", widthPt))
	if b, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("render-html.swift: %w\n%s", err, b)
	}
	return nil
}

// stageManagerOn reports whether macOS's Stage Manager is enabled; false off macOS or when the
// setting cannot be read.
func stageManagerOn(ctx context.Context) bool {
	if runtime.GOOS != "darwin" {
		return false
	}
	out, err := exec.CommandContext(ctx, "defaults", "read", "com.apple.WindowManager", "GloballyEnabled").Output()
	return err == nil && strings.TrimSpace(string(out)) == "1"
}
