// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

// keyEnv names the variable a hermetic daemon's provider key is read from. It is passed to `ley
// ai add` on stdin, never as an argument, and taken out of every child's environment.
const keyEnv = "LEYSPEECH_KEY"

// leyRunner runs the ley binary against one daemon.
type leyRunner struct {
	bin    string
	socket string // empty: ley's own default
}

// command is `ley [--socket S] args...` with keyEnv taken out of its environment.
func (l *leyRunner) command(ctx context.Context, args ...string) *exec.Cmd {
	if l.socket != "" {
		args = append([]string{"--socket", l.socket}, args...)
	}
	cmd := exec.CommandContext(ctx, l.bin, args...)
	cmd.Env = withoutKey(os.Environ())
	return cmd
}

// output runs ley and returns its stdout; a failure carries what ley wrote on stderr.
func (l *leyRunner) output(ctx context.Context, args ...string) (string, error) {
	cmd := l.command(ctx, args...)
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil {
		return out.String(), fmt.Errorf("ley %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(errOut.String()))
	}
	return out.String(), nil
}

// withoutKey is environ without keyEnv.
func withoutKey(environ []string) []string {
	return slices.DeleteFunc(slices.Clone(environ), func(kv string) bool {
		return strings.HasPrefix(kv, keyEnv+"=")
	})
}

// locateRecording turns a recording named on the command line into its directory: a directory
// holding recording.json is used as it is; anything else (an id, an id prefix, a
// ley://recordings/ URI) is asked of the daemon with `ley recordings path`.
func (l *leyRunner) locateRecording(ctx context.Context, ref string) (string, error) {
	if isRecordingDir(ref) {
		return filepath.Abs(ref)
	}
	out, err := l.output(ctx, "recordings", "path", ref)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}
