// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/daemonrun"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// Env is where the runner finds what it drives.
type Env struct {
	// Daemon is the leylined binary; Ley the ley binary the setup steps and the agent's server use.
	Daemon, Ley string
	// Fixtures is the directory scenario fixtures are relative to; Decoders the plugin
	// directory the daemon searches.
	Fixtures, Decoders string
	// Claude is the agent command; Model, when set, is passed as --model.
	Claude, Model string
	// Mode is "mcp" or "shell" unless the scenario says.
	Mode string
	// MaxTurns is the default --max-turns.
	MaxTurns int
	// Timeout bounds one agent run.
	Timeout time.Duration
	// Log receives the runner's own progress lines.
	Log func(format string, args ...any)
}

// daemon is one eval's daemon: a hermetic leylined (go/internal/daemonrun) whose directory also
// holds the copied fixtures. --no-hardware keeps the machine's own dongles out of the run, so an
// agent that tunes "146.52" with no device named gets the fixture, and nothing on the air can
// leak into a graded answer.
type daemon struct {
	env    Env
	dir    string
	socket string
	client *leyline.Client
	run    *daemonrun.Daemon
}

func startDaemon(ctx context.Context, env Env, dir string) (*daemon, error) {
	run, err := daemonrun.Start(ctx, daemonrun.Options{Bin: env.Daemon, Dir: dir, Decoders: env.Decoders, Label: "leyeval"})
	if err != nil {
		return nil, err
	}
	return &daemon{env: env, dir: dir, socket: run.Socket, client: run.Client, run: run}, nil
}

func (d *daemon) stop() { d.run.Stop() }

// attach copies a fixture under its neutral name with a sidecar that says only what the daemon
// needs, attaches it as a radio and, unless the fixture says otherwise, tunes it to its centre.
func (d *daemon) attach(ctx context.Context, f Fixture) error {
	src := f.File
	if !filepath.IsAbs(src) {
		src = filepath.Join(d.env.Fixtures, src)
	}
	// Absolute, because the copy is a symlink and the daemon resolves it from its own directory.
	if abs, err := filepath.Abs(src); err == nil {
		src = abs
	}
	sideSrc := strings.TrimSuffix(src, filepath.Ext(src)) + ".json"
	raw, err := os.ReadFile(sideSrc)
	if err != nil {
		return fmt.Errorf("fixture %s: %w", f.File, err)
	}
	var side struct {
		Format     string `json:"format"`
		SampleRate uint64 `json:"sample_rate"`
		CenterHz   uint64 `json:"center_hz"`
	}
	if err := json.Unmarshal(raw, &side); err != nil {
		return fmt.Errorf("fixture %s: sidecar: %w", f.File, err)
	}
	if f.Center != "" {
		hz, err := units.ParseFrequency(f.Center)
		if err != nil {
			return fmt.Errorf("fixture %s: center: %w", f.File, err)
		}
		side.CenterHz = hz
	}
	dstDir := filepath.Join(d.dir, "radios")
	if err := os.MkdirAll(dstDir, 0o755); err != nil {
		return err
	}
	dst := filepath.Join(dstDir, f.As+filepath.Ext(src))
	if err := os.Symlink(src, dst); err != nil {
		if err := copyFile(src, dst); err != nil {
			return err
		}
	}
	neutral, _ := json.Marshal(side)
	if err := os.WriteFile(strings.TrimSuffix(dst, filepath.Ext(dst))+".json", neutral, 0o644); err != nil {
		return err
	}
	dev, err := d.client.AttachDevice(ctx, leyline.FileSource(dst, true))
	if err != nil {
		return fmt.Errorf("attach %s: %w", f.As, err)
	}
	if f.Capture != nil && !*f.Capture {
		return nil
	}
	_, err = d.client.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: dev.DeviceId, CenterHz: side.CenterHz})
	if err != nil {
		return fmt.Errorf("capture on %s: %w", f.As, err)
	}
	return nil
}

func copyFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, 0o644)
}

// setup runs the scenario's setup steps.
func (d *daemon) setup(ctx context.Context, steps []SetupStep) error {
	for i, st := range steps {
		switch {
		case len(st.Ley) > 0:
			cmd := exec.CommandContext(ctx, d.env.Ley, append([]string{"--socket", d.socket}, st.Ley...)...)
			out, err := cmd.CombinedOutput()
			if err != nil {
				return fmt.Errorf("setup %d (ley %s): %w\n%s", i+1, strings.Join(st.Ley, " "), err, out)
			}
		case st.Job != nil:
			cfg := &leylinev1.DecodeConfig{Decoder: st.Job.Decoder, Keep: st.Job.Keep}
			if st.Job.Frequency != "" {
				hz, err := units.ParseFrequency(st.Job.Frequency)
				if err != nil {
					return fmt.Errorf("setup %d: frequency %w", i+1, err)
				}
				cfg.FrequencyHz = hz
			}
			if _, err := d.client.StartDecode(ctx, cfg); err != nil {
				return fmt.Errorf("setup %d (job %s): %w", i+1, st.Job.Decoder, err)
			}
		default:
			return fmt.Errorf("setup %d: neither ley nor job", i+1)
		}
	}
	return nil
}

// fixtureMissing reports whether a fixture's file is absent.
func (env Env) fixtureMissing(f Fixture) bool {
	src := f.File
	if !filepath.IsAbs(src) {
		src = filepath.Join(env.Fixtures, src)
	}
	_, err := os.Stat(src)
	return err != nil
}
