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
	"github.com/reflexive-labs/leysdr/go/pkg/bookmarks"
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
	// Claude is the agent command; Model, when set, is passed as --model, or chosen with `ley ai
	// use assistant` in assistant mode.
	Claude, Model string
	// Mode is "mcp", "shell" or "assistant" unless the scenario says.
	Mode string
	// ModeChosen is true when the runner was told a mode, which then picks one of the modes a
	// scenario lists rather than running them all.
	ModeChosen bool
	// Key is the assistant's provider key (KeyEnv); Script, when set, is a scripted model's file
	// the daemon hands every assistant worker (ScriptEnv), so no key or provider is needed.
	Key, Script string
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

// SpeechScriptEnv is what the daemon's environment names the scripted speech engine's file with
// (go/cmd/leydec-speech); the plugin inherits it from the daemon.
const SpeechScriptEnv = "LEYDEC_SPEECH_SCRIPT"

// speechScriptFile is where a scenario's speech_script is written in its run directory.
const speechScriptFile = "speech-script.txt"

// startDaemon starts the run's daemon. Its environment names the ley the assistant's workers run
// (LEYLINE_LEY) and the run directory's bookmarks file, which the assistant's tools inherit
// from it as `ley mcp` gets them from mcp.json; a scripted run adds the script, and a scenario
// with a speech_script the speech engine's words. The runner's own LEYDEC_SPEECH_SCRIPT is never
// inherited, so a scenario without one hears the engine's default and nothing from the shell.
func startDaemon(ctx context.Context, env Env, dir string, speechScript []string) (*daemon, error) {
	ley, err := exec.LookPath(env.Ley)
	if err != nil {
		return nil, fmt.Errorf("ley: %w", err)
	}
	if abs, err := filepath.Abs(ley); err == nil {
		ley = abs
	}
	daemonEnv := []string{"LEYLINE_LEY=" + ley, bookmarks.BookmarksEnv + "=" + filepath.Join(dir, "bookmarks.json")}
	if env.Script != "" {
		script, err := filepath.Abs(env.Script)
		if err != nil {
			return nil, err
		}
		daemonEnv = append(daemonEnv, ScriptEnv+"="+script)
	}
	if len(speechScript) > 0 {
		path, err := filepath.Abs(filepath.Join(dir, speechScriptFile))
		if err != nil {
			return nil, err
		}
		if err := os.WriteFile(path, []byte(strings.Join(speechScript, "\n")+"\n"), 0o644); err != nil {
			return nil, fmt.Errorf("speech script: %w", err)
		}
		daemonEnv = append(daemonEnv, SpeechScriptEnv+"="+path)
	}
	// The key reaches the daemon through `ley ai add` on stdin alone, never its environment.
	run, err := daemonrun.Start(ctx, daemonrun.Options{
		Bin: env.Daemon, Dir: dir, Decoders: env.Decoders, Label: "leyeval", Env: daemonEnv,
		Unset: []string{KeyEnv, SpeechScriptEnv},
	})
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
			job, err := d.client.StartDecode(ctx, cfg)
			if err != nil {
				return fmt.Errorf("setup %d (job %s): %w", i+1, st.Job.Decoder, err)
			}
			if st.Job.Records > 0 {
				if err := d.waitRecords(ctx, job.GetJobId(), st.Job.Records); err != nil {
					return fmt.Errorf("setup %d (job %s): %w", i+1, st.Job.Decoder, err)
				}
			}
		default:
			return fmt.Errorf("setup %d: neither ley nor job", i+1)
		}
	}
	return nil
}

// recordsTimeout bounds a setup step's wait for a kept job's records: the fixtures loop every
// few seconds, so a job that has stored nothing by then hears nothing.
const recordsTimeout = 30 * time.Second

// waitRecords polls the record store until the kept job has stored at least n records.
func (d *daemon) waitRecords(ctx context.Context, jobID string, n int) error {
	deadline := time.Now().Add(recordsTimeout)
	have := 0
	for {
		page, err := d.client.QueryRecords(ctx, &leylinev1.RecordQuery{JobId: jobID})
		if err == nil {
			have = len(page.GetRecords())
			if have >= n {
				return nil
			}
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			return fmt.Errorf("the job stored %d of %d records in %s (keep: true is needed for stored records)", have, n, recordsTimeout)
		}
		time.Sleep(250 * time.Millisecond)
	}
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
