// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

// The commands of a scene's app list the runner runs itself, in order with the ones it sends the
// app (docs/plans/mac-loop.md, ML-9b, H6): a ley command against the scene's daemon, one started
// in the background and later interrupted, and a file of the run read.
var localCommands = map[string]bool{"ley": true, "ley_bg": true, "kill": true, "file": true}

// isLocal reports whether the runner runs the command rather than the app.
func (c *AppCommand) isLocal() bool { return localCommands[c.Cmd] }

// killGrace is how long a background ley has to exit after its interrupt before it is killed.
const killGrace = 10 * time.Second

// patterns is a list of regular expressions a text must match; one that starts with ! must not.
// In YAML it is one string or a list of them.
type patterns []string

func (p *patterns) UnmarshalYAML(n *yaml.Node) error {
	if n.Kind == yaml.ScalarNode {
		*p = patterns{n.Value}
		return nil
	}
	var list []string
	if err := n.Decode(&list); err != nil {
		return err
	}
	*p = list
	return nil
}

// split is the pattern's expression and whether it is negated.
func splitPattern(p string) (string, bool) {
	if rest, ok := strings.CutPrefix(p, "!"); ok {
		return rest, true
	}
	return p, false
}

func (p patterns) validate() error {
	for _, s := range p {
		re, _ := splitPattern(s)
		if re == "" {
			return fmt.Errorf("an empty pattern in %q", s)
		}
		if _, err := regexp.Compile(re); err != nil {
			return fmt.Errorf("pattern %q: %w", s, err)
		}
	}
	return nil
}

// check matches each pattern against text and returns a result per pattern, its item the
// pattern: ok with the line it matched (or "absent" for a negated one), fail with what was wrong.
func (p patterns) check(text string) []checkResult {
	var out []checkResult
	for _, s := range p {
		expr, negated := splitPattern(s)
		re := regexp.MustCompile(expr) // validated when the file was loaded
		r := checkResult{Status: "ok", Item: "/" + s + "/"}
		loc := re.FindStringIndex(text)
		switch {
		case loc != nil && negated:
			r.Status, r.Detail = "fail", "found "+lineAt(text, loc[0])
		case loc != nil:
			r.Detail = lineAt(text, loc[0])
		case negated:
			r.Detail = "absent"
		default:
			r.Status, r.Detail = "fail", "no match"
		}
		out = append(out, r)
	}
	return out
}

// lineAt is the line of text holding offset i, quoted and cut to a readable length.
func lineAt(text string, i int) string {
	start := strings.LastIndexByte(text[:i], '\n') + 1
	end := len(text)
	if j := strings.IndexByte(text[i:], '\n'); j >= 0 {
		end = i + j
	}
	line := strings.TrimSpace(text[start:end])
	if r := []rune(line); len(r) > 120 {
		line = string(r[:120]) + "…"
	}
	return fmt.Sprintf("%q", line)
}

// validateLocal checks what validate does not of a runner command, which has the fields its kind
// needs: ids holds the ley_bg ids started so far.
func (c *AppCommand) validateLocal(ids map[string]bool) error {
	switch c.Cmd {
	case "ley_bg":
		if ids[c.ID] {
			return fmt.Errorf("a second ley_bg with id %q", c.ID)
		}
		ids[c.ID] = true
	case "kill":
		if !ids[c.ID] {
			return fmt.Errorf("kill names %q, which no ley_bg before it started", c.ID)
		}
	case "file":
		if filepath.IsAbs(c.Path) || !filepath.IsLocal(c.Path) {
			return fmt.Errorf("file path %q is not inside the run directory", c.Path)
		}
	}
	if c.ExpectExit != nil && *c.ExpectExit < 0 {
		return errors.New("expect_exit is not negative")
	}
	return errors.Join(c.ExpectStdout.validate(), c.Contains.validate())
}

// bgProcess is a ley a scene started in the background.
type bgProcess struct {
	cmd *exec.Cmd
	log string
	// done is closed once it has exited; cmd.ProcessState then says how.
	done chan struct{}
}

// localRun is what the runner's own commands share during one scene at one size.
type localRun struct {
	c      *checker
	daemon *sceneDaemon
	// run is the scene's run directory: steps.log, the background logs and the files `file` reads.
	run string
	bg  map[string]*bgProcess
}

// leyCmd is a ley command against the scene's daemon and bookmarks.
func (l *localRun) leyCmd(ctx context.Context, args []string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, l.c.o.ley, args...)
	cmd.Env = append(os.Environ(), l.daemon.env...)
	return cmd
}

// runLocal runs one of the runner's commands and returns its result lines. stop is set when the
// scene cannot go on: a ley that could not run at all.
func (l *localRun) runLocal(ctx context.Context, cmd *AppCommand, id int) (results []checkResult, stop bool) {
	label := cmd.label(id)
	errorLine := func(err error) []checkResult {
		return []checkResult{{Status: "error", Item: label, Detail: err.Error()}}
	}
	switch cmd.Cmd {
	case "ley":
		return l.ley(ctx, cmd, label)
	case "ley_bg":
		if err := l.start(ctx, cmd); err != nil {
			return errorLine(err), true
		}
	case "kill":
		if r := l.kill(cmd.ID, label); r != nil {
			return []checkResult{*r}, false
		}
	case "file":
		path := filepath.Join(l.run, cmd.Path)
		b, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			return []checkResult{{Status: "fail", Item: label, Detail: "no such file", Path: l.c.rel(path)}}, false
		}
		if err != nil {
			return []checkResult{{Status: "error", Item: label, Detail: err.Error()}}, false
		}
		for _, r := range cmd.Contains.check(string(b)) {
			r.Item = label + " " + r.Item
			r.Path = l.c.rel(path)
			results = append(results, r)
		}
	}
	return results, false
}

// ley runs a ley command to the end, logs it in steps.log and checks its exit status and output.
func (l *localRun) ley(ctx context.Context, cmd *AppCommand, label string) ([]checkResult, bool) {
	logPath := filepath.Join(l.run, "steps.log")
	tctx, cancel := context.WithTimeout(ctx, l.c.o.grace)
	defer cancel()
	c := l.leyCmd(tctx, cmd.Args)
	var stdout, stderr bytes.Buffer
	c.Stdout, c.Stderr = &stdout, &stderr
	err := c.Run()
	code := 0
	var exitErr *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exitErr) && tctx.Err() == nil:
		code = exitErr.ExitCode()
	default:
		return []checkResult{{Status: "error", Item: label, Detail: fmt.Sprintf("ley %s: %v", strings.Join(cmd.Args, " "), err)}}, true
	}
	if f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
		fmt.Fprintf(f, "$ ley %s   (%s)\n%s%sexit %d\n", strings.Join(cmd.Args, " "), label, stdout.String(), stderr.String(), code)
		_ = f.Close() // a lost log line is not worth failing the scene over
	}
	want := 0
	if cmd.ExpectExit != nil {
		want = *cmd.ExpectExit
	}
	var out []checkResult
	switch {
	case code != want:
		out = append(out, checkResult{
			Status: "fail", Item: label + " exit", Path: l.c.rel(logPath),
			Detail: fmt.Sprintf("got %d want %d: %s", code, want, firstLine(stderr.String())),
		})
	case cmd.ExpectExit != nil:
		out = append(out, checkResult{Status: "ok", Item: label + " exit", Detail: fmt.Sprint(code)})
	}
	for _, r := range cmd.ExpectStdout.check(stdout.String()) {
		r.Item = label + " stdout " + r.Item
		out = append(out, r)
	}
	return out, false
}

func firstLine(s string) string {
	s, _, _ = strings.Cut(strings.TrimSpace(s), "\n")
	return s
}

// start starts a ley in the background, its output in ley_bg-<id>.log.
func (l *localRun) start(ctx context.Context, cmd *AppCommand) error {
	log := filepath.Join(l.run, "ley_bg-"+cmd.ID+".log")
	f, err := os.Create(log)
	if err != nil {
		return err
	}
	// It outlives the command that started it: kill or cleanup ends it, not the context.
	c := l.leyCmd(context.WithoutCancel(ctx), cmd.Args)
	c.Stdout, c.Stderr = f, f
	if err := c.Start(); err != nil {
		_ = f.Close()
		return fmt.Errorf("ley %s: %w", strings.Join(cmd.Args, " "), err)
	}
	p := &bgProcess{cmd: c, log: log, done: make(chan struct{})}
	go func() {
		_ = c.Wait() // ProcessState holds how it ended
		_ = f.Close()
		close(p.done)
	}()
	l.bg[cmd.ID] = p
	return nil
}

// kill interrupts a background ley as Ctrl-C would and waits for it to exit, killing it after
// killGrace. It returns a failing line when the ley had already exited, or did not exit on the
// interrupt; nil when it exited as asked.
func (l *localRun) kill(id, label string) *checkResult {
	p := l.bg[id]
	delete(l.bg, id)
	select {
	case <-p.done:
		return &checkResult{
			Status: "fail", Item: label, Path: l.c.rel(p.log),
			Detail: fmt.Sprintf("ley_bg %s had already exited (%s)", id, p.cmd.ProcessState),
		}
	default:
	}
	_ = p.cmd.Process.Signal(syscall.SIGINT)
	select {
	case <-p.done:
		return nil
	case <-time.After(killGrace):
		_ = p.cmd.Process.Kill()
		<-p.done
		return &checkResult{
			Status: "fail", Item: label, Path: l.c.rel(p.log),
			Detail: fmt.Sprintf("ley_bg %s did not exit within %.0f s of an interrupt; killed", id, killGrace.Seconds()),
		}
	}
}

// cleanup interrupts every background ley still running and waits for each, killing any that
// outlives killGrace.
func (l *localRun) cleanup() {
	for id, p := range l.bg {
		_ = p.cmd.Process.Signal(syscall.SIGINT)
		select {
		case <-p.done:
		case <-time.After(killGrace):
			_ = p.cmd.Process.Kill()
			<-p.done
		}
		delete(l.bg, id)
	}
}
