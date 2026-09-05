// Package e2e runs the real leylined daemon against the ley CLI over a temp UDS.
// It is the living proof of the cross-language contract (CLAUDE.md): skipped
// unless LEYLINED_BIN and LEY_BIN point at built binaries.
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

type env struct {
	t       *testing.T
	ley     string
	socket  string
	fixture string
}

func setup(t *testing.T) (*env, *exec.Cmd) {
	t.Helper()
	daemonBin := os.Getenv("LEYLINED_BIN")
	leyBin := os.Getenv("LEY_BIN")
	if daemonBin == "" || leyBin == "" {
		t.Skip("set LEYLINED_BIN and LEY_BIN to run the cross-language e2e")
	}
	fixture, err := filepath.Abs("../../../fixtures/nfm_tone.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	dir, err := os.MkdirTemp("", "ley-e2e")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	e := &env{t: t, ley: leyBin, socket: filepath.Join(dir, "d.sock"), fixture: fixture}

	daemon := exec.Command(daemonBin, "--socket", e.socket, "--log-level", "debug")
	var daemonLog bytes.Buffer
	daemon.Stderr = &daemonLog
	daemon.Stdout = &daemonLog
	if err := daemon.Start(); err != nil {
		t.Fatalf("start leylined: %v", err)
	}
	t.Cleanup(func() {
		if daemon.ProcessState == nil {
			_ = daemon.Process.Kill()
			_ = daemon.Wait()
		}
		if t.Failed() {
			t.Logf("leylined log:\n%s", daemonLog.String())
		}
	})
	deadline := time.Now().Add(10 * time.Second)
	for {
		if _, err := os.Stat(e.socket); err == nil {
			if _, err := e.run("state", "--json"); err == nil {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("leylined did not come up on %s\n%s", e.socket, daemonLog.String())
		}
		time.Sleep(50 * time.Millisecond)
	}
	return e, daemon
}

// run executes one ley verb against the temp socket and returns stdout.
func (e *env) run(args ...string) (string, error) {
	cmd := exec.Command(e.ley, append([]string{"--socket", e.socket}, args...)...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if err != nil {
		return stdout.String(), &runError{err: err, stderr: stderr.String()}
	}
	return stdout.String(), nil
}

type runError struct {
	err    error
	stderr string
}

func (r *runError) Error() string { return r.err.Error() + ": " + strings.TrimSpace(r.stderr) }

func (e *env) mustRun(args ...string) string {
	e.t.Helper()
	out, err := e.run(args...)
	if err != nil {
		e.t.Fatalf("ley %s: %v\nstdout: %s", strings.Join(args, " "), err, out)
	}
	return out
}

func (e *env) state() map[string]any {
	e.t.Helper()
	return parseJSON(e.t, e.mustRun("state", "--json"))
}

func parseJSON(t *testing.T, s string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		t.Fatalf("bad JSON %q: %v", s, err)
	}
	return m
}

func list(m map[string]any, key string) []any {
	v, _ := m[key].([]any)
	return v
}

// liveOutput is what a long-running verb wrote, stdout and stderr apart:
// under --json stdout must be NDJSON only, so the two are never merged.
type liveOutput struct {
	out, errOut bytes.Buffer
}

// startLive launches a long-running ley verb (play/tune) and returns a stop func
// that sends SIGINT and waits, returning the exit error.
func (e *env) startLive(args ...string) (stop func() error, out *liveOutput) {
	e.t.Helper()
	cmd := exec.Command(e.ley, append([]string{"--socket", e.socket}, args...)...)
	out = &liveOutput{}
	cmd.Stdout, cmd.Stderr = &out.out, &out.errOut
	if err := cmd.Start(); err != nil {
		e.t.Fatalf("start ley %v: %v", args, err)
	}
	return func() error {
		_ = cmd.Process.Signal(syscall.SIGINT)
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		select {
		case err := <-done:
			return err
		case <-time.After(10 * time.Second):
			_ = cmd.Process.Kill()
			return context.DeadlineExceeded
		}
	}, out
}

func (e *env) waitChannels(n int) map[string]any {
	e.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		st := e.state()
		if len(list(st, "channels")) == n {
			return st
		}
		if time.Now().After(deadline) {
			e.t.Fatalf("state never reached %d channels: %v", n, st)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestCLIAgainstRealDaemon(t *testing.T) {
	e, daemon := setup(t)

	// Session holder: play keeps WatchEvents open, which keeps its channel alive.
	stopPlay, playOut := e.startLive("play", e.fixture, "--no-audio", "--loop", "--json")
	st := e.waitChannels(1)

	// devices --json: the file device, in use by play's capture.
	devs := list(parseJSON(t, e.mustRun("devices", "--json")), "devices")
	if len(devs) != 1 {
		t.Fatalf("devices: want 1, got %v", devs)
	}
	dev := devs[0].(map[string]any)
	devID, _ := dev["deviceId"].(string)
	if !strings.HasPrefix(devID, "dev_") || dev["driver"] != "file" || dev["state"] != "IN_USE" {
		t.Fatalf("unexpected device %v", dev)
	}

	// state --json: one capture on that device, one channel, daemon info.
	caps := list(st, "captures")
	if len(caps) != 1 {
		t.Fatalf("captures: %v", caps)
	}
	capture := caps[0].(map[string]any)
	capID := capture["captureId"].(string)
	if capture["deviceId"] != devID || capture["centerHz"] != "146520000" || capture["sampleRate"] != "2400000" || capture["state"] != "CAPTURE_ACTIVE" {
		t.Fatalf("unexpected capture %v", capture)
	}
	if anchor, _ := capture["anchor"].(map[string]any); anchor["captureId"] != capID || anchor["sampleRate"] != "2400000" {
		t.Fatalf("unexpected anchor %v", capture["anchor"])
	}
	playChan := list(st, "channels")[0].(map[string]any)
	playChanID := playChan["channelId"].(string)
	if playChan["captureId"] != capID || playChan["mode"] != "NFM" || playChan["offsetHz"] != "100000" || playChan["state"] != "CHANNEL_ACTIVE" {
		t.Fatalf("unexpected channel %v", playChan)
	}
	if owner, _ := playChan["owner"].(map[string]any); owner["kind"] != "cli" || !strings.HasPrefix(owner["clientId"].(string), "cli_") {
		t.Fatalf("unexpected owner %v", playChan["owner"])
	}
	info, _ := st["daemon"].(map[string]any)
	if info["version"] != "0.1.0-dev" || info["socketPath"] != e.socket || info["pid"] != strconv.Itoa(daemon.Process.Pid) {
		t.Fatalf("unexpected daemon info %v", info)
	}

	// fft --count 3 --json: three rows with negotiated bins and the sample timebase.
	fft := strings.Split(strings.TrimSpace(e.mustRun("fft", "--count", "3", "--json", "--device", devID)), "\n")
	if len(fft) != 3 {
		t.Fatalf("fft rows: want 3, got %d: %q", len(fft), fft)
	}
	var lastIndex float64
	for i, line := range fft {
		row := parseJSON(t, line)
		if row["seq"] != float64(i+1) || row["center_hz"] != float64(146520000) || row["span_hz"] != float64(2400000) {
			t.Fatalf("fft row %d: %v", i, row)
		}
		bins := list(row, "bins")
		if len(bins) != 1024 {
			t.Fatalf("fft row %d: want 1024 bins, got %d", i, len(bins))
		}
		idx, _ := row["sample_index"].(float64)
		if i > 0 && idx <= lastIndex {
			t.Fatalf("fft sample_index not increasing: %v then %v", lastIndex, idx)
		}
		lastIndex = idx
		// The +100 kHz tone should be the peak: bin 512 + 100e3/2.4e6*1024 ≈ 555.
		peak, peakDB := 0, -1e9
		for b, v := range bins {
			if f := v.(float64); f > peakDB {
				peak, peakDB = b, f
			}
		}
		if peak < 551 || peak > 559 {
			t.Fatalf("fft row %d: peak bin %d (%.1f dB), want ≈555", i, peak, peakDB)
		}
	}

	// set squelch -50: confirmed by the daemon's channel event, then visible in state.
	setOut := e.mustRun("set", "squelch", "-50")
	if !strings.Contains(setOut, playChanID) || !strings.Contains(setOut, "-50") {
		t.Fatalf("set output: %q", setOut)
	}
	ch := list(e.state(), "channels")[0].(map[string]any)
	if ch["squelchDb"] != float64(-50) {
		t.Fatalf("squelch not applied: %v", ch)
	}

	// Foreground tune for ~2 s, then SIGINT: its channel is gone, play's remains.
	stopTune, tuneOut := e.startLive("tune", "146.62M", "--no-audio", "--device", devID)
	e.waitChannels(2)
	time.Sleep(2 * time.Second)
	if err := stopTune(); err != nil {
		t.Fatalf("tune exit: %v\n%s\n%s", err, tuneOut.out.String(), tuneOut.errOut.String())
	}
	if !strings.Contains(tuneOut.out.String(), "dBFS") {
		t.Fatalf("tune printed no meter line:\n%s", tuneOut.out.String())
	}
	st = e.waitChannels(1)
	if got := list(st, "channels")[0].(map[string]any)["channelId"]; got != playChanID {
		t.Fatalf("surviving channel %v, want play's %s", got, playChanID)
	}
	if len(list(st, "captures")) != 1 {
		t.Fatalf("capture must survive tune exit: %v", st)
	}

	// SIGINT play: it destroys its channel, the capture it created and detaches the file device.
	if err := stopPlay(); err != nil {
		t.Fatalf("play exit: %v\n%s\n%s", err, playOut.out.String(), playOut.errOut.String())
	}
	// Prose (the mode decision, the banner) went to stderr, not into the NDJSON.
	if !strings.Contains(playOut.errOut.String(), "using NFM: the recording's sidecar says NFM") || !strings.Contains(playOut.errOut.String(), "Listening to") {
		t.Fatalf("play --json prose should be on stderr:\n%s", playOut.errOut.String())
	}
	st = e.state()
	if len(list(st, "channels")) != 0 || len(list(st, "captures")) != 0 || len(list(st, "devices")) != 0 {
		t.Fatalf("state not empty after play exit: %v", st)
	}
	// play --json printed NDJSON: Events (seq + caused_by) interleaved with
	// TelemetryMsgs (seq + sample time on this capture).
	var events, meters int
	for _, line := range strings.Split(strings.TrimSpace(playOut.out.String()), "\n") {
		msg := parseJSON(t, line)
		if _, ok := msg["seq"]; !ok {
			t.Fatalf("play line without seq: %v", msg)
		}
		if _, ok := msg["causedBy"].(map[string]any); ok {
			events++
			continue
		}
		tm, _ := msg["time"].(map[string]any)
		if tm["captureId"] != capID {
			t.Fatalf("play telemetry off the capture timebase: %v", msg)
		}
		meters++
	}
	if events == 0 || meters == 0 {
		t.Fatalf("play printed %d events and %d telemetry messages", events, meters)
	}

	// SIGTERM the daemon: clean exit, socket unlinked.
	if err := daemon.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	if err := daemon.Wait(); err != nil {
		t.Fatalf("leylined exit: %v", err)
	}
	if _, err := os.Stat(e.socket); !os.IsNotExist(err) {
		t.Fatalf("socket still present after shutdown: %v", err)
	}
}
