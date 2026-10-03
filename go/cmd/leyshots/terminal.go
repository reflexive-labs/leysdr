// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"errors"
	"fmt"
	"html"
	"math"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// The site's terminal theme (docs/plans/site-shots.md, "Terminal shots").
const (
	themeBackground = "#090B0C"
	themeForeground = "#9BA1A6"
	themeBold       = "#E7E9EA"
	themeGreen      = "#2FB6A3"
	// themeRule is the line drawn where tmux leaves a column or row between two panes.
	themeRule = "#262B2F"
	// fontPx is the terminal font size, and lineHeightPx a row's height: tight enough that the
	// block glyphs of ley's meters tile.
	fontPx       = 13
	lineHeightPx = 16
	// advanceEm is SF Mono's advance width, 1229/2048 of the em, which sizes the page.
	advanceEm = 0.6
	// paddingPx is the ground left around the panes.
	paddingPx = 16
)

// tmuxSocket is the tmux server leyshots runs its scenes in, apart from the person's own.
const tmuxSocket = "leyshots"

// paneCapture is one pane's contents and its place in the window, in cells.
type paneCapture struct {
	Left, Top, Width, Height int
	// Text is `tmux capture-pane -e -p`: the pane's rows with their SGR escapes.
	Text string
}

// tmuxRunner drives the leyshots tmux server.
type tmuxRunner struct {
	bin string
	// env is set in each pane's shell, as KEY=value.
	env []string
}

func (t *tmuxRunner) run(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, t.bin, append([]string{"-L", tmuxSocket, "-f", "/dev/null"}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("tmux %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// shellArgs starts a pane's shell with the scene's environment and a "$ " prompt, so the
// captured pane shows the command as typed. Given more than one argument, tmux runs the command
// itself rather than through the person's shell, whose startup files could reset PATH; ENV is
// emptied so the POSIX shell reads no startup file of its own.
func (t *tmuxRunner) shellArgs() []string {
	args := []string{"/usr/bin/env", "PS1=$ ", "ENV="}
	args = append(args, t.env...)
	return append(args, "/bin/sh")
}

// session runs a terminal scene: open, each pane's command typed after its delay, then settle
// seconds, then every pane read and the session closed.
func (t *tmuxRunner) session(ctx context.Context, name string, term *Terminal, settle float64) ([]paneCapture, error) {
	if err := t.open(ctx, name, term); err != nil {
		return nil, err
	}
	defer t.closeSession(ctx, name)
	for i, p := range term.Panes {
		if err := t.typePane(ctx, name, i, p); err != nil {
			return nil, err
		}
	}
	if err := sleep(ctx, settle); err != nil {
		return nil, err
	}
	return t.read(ctx, name)
}

// open makes a window of term's size, split as it says, with a prompt in each pane. The
// session stays until closeSession; the server stays for the next scene and is ended by stop.
func (t *tmuxRunner) open(ctx context.Context, name string, term *Terminal) error {
	t.closeSession(ctx, name) // a session left by an interrupted run
	args := append([]string{"new-session", "-d", "-s", name, "-x", strconv.Itoa(term.Cols), "-y", strconv.Itoa(term.Rows)}, t.shellArgs()...)
	if _, err := t.run(ctx, args...); err != nil {
		return err
	}
	// No status line: the window's every row is the terminal's.
	if _, err := t.run(ctx, "set-option", "-t", name, "status", "off"); err != nil {
		return err
	}
	flag, layout := "-h", "even-horizontal"
	if term.Split == "vertical" {
		flag, layout = "-v", "even-vertical"
	}
	for range term.Panes[1:] {
		if _, err := t.run(ctx, append([]string{"split-window", flag, "-t", name}, t.shellArgs()...)...); err != nil {
			return err
		}
	}
	if len(term.Panes) > 1 {
		if _, err := t.run(ctx, "select-layout", "-t", name, layout); err != nil {
			return err
		}
	}
	// The shells need a moment to print their prompts before the first command is typed.
	return sleep(ctx, 0.5)
}

// typePane waits the pane's delay and types its command at its prompt.
func (t *tmuxRunner) typePane(ctx context.Context, name string, i int, p Pane) error {
	if err := sleep(ctx, p.Delay); err != nil {
		return err
	}
	_, err := t.run(ctx, "send-keys", "-t", fmt.Sprintf("%s:0.%d", name, i), p.Command, "Enter")
	return err
}

// read captures every pane with its escapes and its place in the window.
func (t *tmuxRunner) read(ctx context.Context, name string) ([]paneCapture, error) {
	out, err := t.run(ctx, "list-panes", "-t", name, "-F", "#{pane_index} #{pane_left} #{pane_top} #{pane_width} #{pane_height}")
	if err != nil {
		return nil, err
	}
	var panes []paneCapture
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		var idx int
		var p paneCapture
		if _, err := fmt.Sscan(line, &idx, &p.Left, &p.Top, &p.Width, &p.Height); err != nil {
			return nil, fmt.Errorf("tmux list-panes printed %q: %w", line, err)
		}
		text, err := t.run(ctx, "capture-pane", "-e", "-p", "-t", fmt.Sprintf("%s:0.%d", name, idx))
		if err != nil {
			return nil, err
		}
		p.Text = text
		panes = append(panes, p)
	}
	return panes, nil
}

// closeSession ends the session and whatever its panes are running.
func (t *tmuxRunner) closeSession(ctx context.Context, name string) {
	_, _ = t.run(context.WithoutCancel(ctx), "kill-session", "-t", name)
}

// stop ends the leyshots tmux server.
func (t *tmuxRunner) stop() { _, _ = t.run(context.Background(), "kill-server") }

func sleep(ctx context.Context, seconds float64) error {
	if seconds <= 0 {
		return nil
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(time.Duration(seconds * float64(time.Second))):
		return nil
	}
}

// terminalWidthPt is the page width, in points, of a terminal cols wide.
func terminalWidthPt(cols int) float64 {
	return math.Ceil(float64(cols)*advanceEm*fontPx) + 2*paddingPx
}

// themeCSS is the page style both the terminal and the table pages use.
func themeCSS() string {
	return fmt.Sprintf(`:root{--bg:%s;--fg:%s;--bold:%s;--green:%s;--rule:%s}
html,body{margin:0;background:var(--bg)}
body{font:%dpx/%dpx ui-monospace,"SF Mono",Menlo,monospace;color:var(--fg)}
`, themeBackground, themeForeground, themeBold, themeGreen, themeRule, fontPx, lineHeightPx)
}

// terminalHTML lays the panes out as a page in the site's terminal theme: each pane where tmux
// put it, in character cells, and a rule in the column or row tmux leaves between two panes.
// toHTML converts one pane's escapes to a <pre> (scripts/ansi2html.py --palette site).
func terminalHTML(title string, term *Terminal, panes []paneCapture, toHTML func(string) (string, error)) (string, error) {
	var b strings.Builder
	fmt.Fprintf(&b, "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>%s</title><style>\n%s", html.EscapeString(title), themeCSS())
	fmt.Fprintf(&b, ".screen{position:relative;padding:%dpx;width:%dch;height:%dpx}\n", paddingPx, term.Cols, term.Rows*lineHeightPx)
	b.WriteString(".pane{position:absolute;overflow:hidden}\n.pane pre{margin:0;font:inherit;white-space:pre}\n.rule{position:absolute;background:var(--rule)}\n")
	b.WriteString("</style></head><body><div class=\"screen\">\n")
	for _, p := range panes {
		body, err := toHTML(p.Text)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(&b, "<div class=\"pane\" style=\"left:calc(%dpx + %dch);top:%dpx;width:%dch;height:%dpx\">%s</div>\n",
			paddingPx, p.Left, paddingPx+p.Top*lineHeightPx, p.Width, p.Height*lineHeightPx, body)
		if p.Left > 0 {
			// The column tmux leaves to the pane's left, as a 1 px rule down its middle.
			fmt.Fprintf(&b, "<div class=\"rule\" style=\"left:calc(%dpx + %d.5ch);top:%dpx;width:1px;height:%dpx\"></div>\n",
				paddingPx, p.Left-1, paddingPx+p.Top*lineHeightPx, p.Height*lineHeightPx)
		}
		if p.Top > 0 {
			fmt.Fprintf(&b, "<div class=\"rule\" style=\"left:calc(%dpx + %dch);top:%dpx;width:%dch;height:1px\"></div>\n",
				paddingPx, p.Left, paddingPx+(p.Top-1)*lineHeightPx+lineHeightPx/2, p.Width)
		}
	}
	b.WriteString("</div></body></html>\n")
	return b.String(), nil
}

// ansiToHTML converts captured escapes with scripts/ansi2html.py, the one converter the
// repository has.
func ansiToHTML(ctx context.Context, python, script string) func(string) (string, error) {
	return func(text string) (string, error) {
		cmd := exec.CommandContext(ctx, python, script, "--palette", "site")
		cmd.Stdin = strings.NewReader(text)
		out, err := cmd.Output()
		if err != nil {
			var stderr string
			var ee *exec.ExitError
			if errors.As(err, &ee) {
				stderr = string(ee.Stderr)
			}
			return "", fmt.Errorf("%s: %w %s", script, err, strings.TrimSpace(stderr))
		}
		return string(out), nil
	}
}
