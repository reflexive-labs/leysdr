// SPDX-License-Identifier: Apache-2.0

// Package e2e runs the real leylined daemon against the ley CLI over a temp UDS.
// It is the end-to-end test of the cross-language contract (AGENTS.md): skipped
// unless LEYLINED_BIN and LEY_BIN point at built binaries.
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

type env struct {
	t       *testing.T
	ley     string
	socket  string
	fixture string
}

// setup starts a daemon on a temp socket; daemonArgs are appended to its command line (a decode
// test names a temp store and the repository's plugin directory).
func setup(t *testing.T, daemonArgs ...string) (*env, *exec.Cmd) {
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

	daemon := exec.Command(daemonBin, append([]string{"--socket", e.socket, "--log-level", "debug"}, daemonArgs...)...)
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

// runFor runs a ley verb with a deadline, SIGINT-ing it when the deadline passes, and returns
// whatever it wrote. It is how a watch that is meant to find nothing is tested: it cannot finish
// on its own, so the test stops it and asserts that it printed nothing.
func (e *env) runFor(d time.Duration, args ...string) (string, error) {
	cmd := exec.Command(e.ley, append([]string{"--socket", e.socket}, args...)...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Start(); err != nil {
		e.t.Fatalf("start ley %v: %v", args, err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return stdout.String(), err
	case <-time.After(d):
		_ = cmd.Process.Signal(syscall.SIGINT)
		<-done
		return stdout.String(), nil
	}
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

// repoVersion is the root VERSION file, the one number `make version` stamps
// into the daemon. Reading it means a release bump does not have to edit this
// test.
func repoVersion(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("../../../VERSION")
	if err != nil {
		t.Fatalf("read VERSION: %v", err)
	}
	return strings.TrimSpace(string(raw))
}

func parseJSON(t *testing.T, s string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		t.Fatalf("bad JSON %q: %v", s, err)
	}
	return m
}

// testDevices drops real RTL-SDR dongles from a devices list: the daemon under test enumerates
// whatever is plugged into the machine, and these assertions are about the devices the test made.
func testDevices(devs []any) []map[string]any {
	var out []map[string]any
	for _, d := range devs {
		m, _ := d.(map[string]any)
		if m != nil && m["driver"] != "rtlsdr" {
			out = append(out, m)
		}
	}
	return out
}

// peakBin is the strongest bin of a decoded FFT row and its level.
func peakBin(bins []any) (int, float64) {
	peak, peakDB := 0, math.Inf(-1)
	for b, v := range bins {
		if f, ok := v.(float64); ok && f > peakDB {
			peak, peakDB = b, f
		}
	}
	return peak, peakDB
}

func list(m map[string]any, key string) []any {
	v, _ := m[key].([]any)
	return v
}

// liveOutput is what a long-running verb wrote, stdout and stderr apart:
// under --json stdout must be NDJSON only, so the two are never merged.
// syncBuffer is a bytes.Buffer a test may read while the child is still writing it: exec copies
// the process's output from its own goroutine, so an unguarded read of the buffer is a data race.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

type liveOutput struct {
	out, errOut syncBuffer
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

	// devices --json: the file device, in use by play's capture. A real dongle plugged into the
	// developer's machine is listed too and ignored here.
	devs := testDevices(list(parseJSON(t, e.mustRun("devices", "--json")), "devices"))
	if len(devs) != 1 {
		t.Fatalf("devices: want 1, got %v", devs)
	}
	dev := devs[0]
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
	if info["version"] != repoVersion(t) || info["socketPath"] != e.socket || info["pid"] != strconv.Itoa(daemon.Process.Pid) {
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
		peak, peakDB := peakBin(bins)
		if peak < 551 || peak > 559 {
			t.Fatalf("fft row %d: peak bin %d (%.1f dB), want ≈555", i, peak, peakDB)
		}
	}

	// The same spectrum asked for as DB_U8. Bulk frames carry no proto message, so
	// their payload encoding is hand-written on both sides of the wire; this is the
	// one test where the daemon's quantisation and the Go decode meet. Every level
	// must land on the grid the encoding defines, and the tone must still be the
	// peak, at the same bin and the same height.
	f32Bins := list(parseJSON(t, fft[len(fft)-1]), "bins")
	f32Peak, f32PeakDB := peakBin(f32Bins)
	u8Bins := list(parseJSON(t, strings.TrimSpace(e.mustRun("fft", "--count", "1", "--json", "--u8", "--device", devID))), "bins")
	if len(u8Bins) != len(f32Bins) {
		t.Fatalf("u8 row: %d bins, want %d", len(u8Bins), len(f32Bins))
	}
	for b, v := range u8Bins {
		db, _ := v.(float64)
		if db < -120 || db > 7.5 || math.Abs(db/leyline.DBU8Step-math.Round(db/leyline.DBU8Step)) > 1e-9 {
			t.Fatalf("u8 bin %d = %v: not a %g dB step within -120..7.5", b, db, leyline.DBU8Step)
		}
	}
	u8Peak, u8PeakDB := peakBin(u8Bins)
	// The two rows are different moments of a tone frequency-modulated at
	// ±2.5 kHz, and a 2.34 kHz bin sees that sweep as the peak wandering a bin
	// either side of its centre. Two rows can therefore sit two bins apart when
	// one catches the low extreme and the other the high; the quantisation itself
	// moves nothing. Half a step for the quantisation, and a dB for the two moments.
	if diff := u8Peak - f32Peak; diff < -2 || diff > 2 {
		t.Fatalf("u8 peak bin %d (%.1f dB), f32 peak bin %d (%.1f dB): further apart than the tone's sweep", u8Peak, u8PeakDB, f32Peak, f32PeakDB)
	}
	if math.Abs(u8PeakDB-f32PeakDB) > leyline.DBU8Step/2+1 {
		t.Fatalf("u8 peak %.2f dB, f32 peak %.2f dB: further apart than the quantisation", u8PeakDB, f32PeakDB)
	}

	// set squelch -50: confirmed by the daemon's channel event, then visible in state.
	// The confirmation names the old and new values and the channel by frequency
	// and row, not by id (docs/dev/cli-style.md: ids the reader is not asked to read
	// are dropped from prose), so assert on what it does print.
	setOut := e.mustRun("set", "squelch", "-50")
	if !strings.Contains(setOut, "-50") || !strings.Contains(setOut, "146.620") {
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
	// A live session's prose is all on stderr, so stdout carries ids and
	// nothing else.
	if said := tuneOut.errOut.String(); !strings.Contains(said, "signal ") || !strings.Contains(said, "dBFS") {
		t.Fatalf("tune printed no meter line on stderr:\n%s", said)
	}
	if strings.Contains(tuneOut.out.String(), "dBFS") {
		t.Fatalf("a level belongs to the person, not to stdout:\n%s", tuneOut.out.String())
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
	if len(list(st, "channels")) != 0 || len(list(st, "captures")) != 0 || len(testDevices(list(st, "devices"))) != 0 {
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

// TestScanAgainstRealDaemon sweeps a known band through the real daemon, which is the only place
// the whole chain runs: the Swift detector, the sweep's own capture lease, Detection over
// telemetry, and the Go client rendering it. Everything else about scan is tested against the fake.
func TestScanAgainstRealDaemon(t *testing.T) {
	e, _ := setup(t)
	band, err := filepath.Abs("../../../fixtures/scan_band.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(band); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	// Attach the recording as a radio and leave it idle: a sweep needs the device, not a channel.
	e.mustRun("play", band, "--no-audio", "--loop", "--persistent", "--json")
	e.mustRun("stop", "--all")

	// Wider than the carriers themselves: a signal straddling the edge of the requested range is
	// reported at the centroid of the part inside it, which for the 150 kHz-wide FM carrier at
	// 146.8 MHz would be tens of kHz low.
	out := e.mustRun("--json", "scan", "145.0M..147.0M", "--dwell", "500")
	scan := parseJSON(t, out)
	if scan["scanId"] == nil || !strings.HasPrefix(scan["scanId"].(string), "scan_") {
		t.Fatalf("no scan id: %v", scan)
	}
	// scan_band.cf32 puts carriers 800 and 400 kHz either side of 146 MHz.
	want := []uint64{145_200_000, 145_600_000, 146_400_000, 146_800_000}
	dets := list(scan, "detections")
	var found, widths []uint64
	for _, d := range dets {
		m := d.(map[string]any)
		hz, err := strconv.ParseUint(m["centerHz"].(string), 10, 64)
		if err != nil {
			t.Fatalf("centerHz %v: %v", m["centerHz"], err)
		}
		found = append(found, hz)
		width, _ := m["bandwidthHz"].(float64)
		widths = append(widths, uint64(width))
		// Every detection carries the evidence it was judged on.
		for _, k := range []string{"snrDb", "floorDbfs", "looks", "looksPossible", "firstSeen"} {
			if m[k] == nil {
				t.Errorf("detection at %d lacks %q: %v", hz, k, m)
			}
		}
		if m["modulationGuess"] != nil && m["modulationGuess"] != "" {
			t.Errorf("v0 has no opinion about modulation (invariant 12): %v", m["modulationGuess"])
		}
	}
	for _, w := range want {
		// Within a bin (2.344 kHz at 2.4 MSPS over 1024 bins) for a narrow carrier: the centroid
		// is that accurate, and a looser bound would let a half-bin offset back in unnoticed.
		// A wide FM carrier's centroid wanders with its own modulation, so it gets a twentieth of
		// its width instead.
		best, bestDiff, bestWidth := uint64(0), uint64(math.MaxUint64), uint64(0)
		for i, f := range found {
			d := w - f
			if f > w {
				d = f - w
			}
			if d < bestDiff {
				best, bestDiff, bestWidth = f, d, widths[i]
			}
		}
		tol := uint64(2_500)
		if bestWidth/20 > tol {
			tol = bestWidth / 20
		}
		if bestDiff > tol {
			t.Errorf("nearest detection to %d Hz is %d (%d Hz off, tolerance %d) in %v", w, best, bestDiff, tol, found)
		}
	}
	// The noise floor is reported per step whether or not anything was found there.
	if len(list(scan, "noiseFloor")) == 0 {
		t.Errorf("no noise floor segments: %v", scan)
	}
	// The sweep pinned the gain and reported the value.
	if gains := list(scan, "gains"); len(gains) == 0 {
		t.Logf("no gains pinned (a file device has none), which is honest for this radio")
	}

	// The radio is free again: the sweep released its capture.
	st := e.state()
	if caps := list(st, "captures"); len(caps) != 0 {
		t.Errorf("the sweep left a capture behind: %v", caps)
	}
	if jobs := list(st, "jobs"); len(jobs) == 0 {
		t.Errorf("the finished job should still be in state: %v", st)
	} else if j := jobs[0].(map[string]any); j["state"] != "COMPLETED" {
		t.Errorf("job did not complete: %v", j)
	}
}

// `ley jobs` is the other terminal's view of the same work: the scan above ran in a daemon that
// outlives it, so a second client must be able to list what it did and stop it if it is still
// going. Only the real daemon can say whether its ListJobs and CancelJob agree with the fake's.
func TestJobsAgainstRealDaemon(t *testing.T) {
	e, _ := setup(t)
	band, err := filepath.Abs("../../../fixtures/scan_band.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(band); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	e.mustRun("play", band, "--no-audio", "--loop", "--persistent", "--json")
	e.mustRun("stop", "--all")

	// Nothing has run yet: an empty list, not an error.
	if empty := parseJSON(t, e.mustRun("--json", "jobs")); len(list(empty, "jobs")) != 0 {
		t.Fatalf("a daemon that has done nothing should list no jobs: %v", empty)
	}

	scan := parseJSON(t, e.mustRun("--json", "scan", "145.0M..147.0M", "--dwell", "100"))
	jobs := list(parseJSON(t, e.mustRun("--json", "jobs")), "jobs")
	if len(jobs) != 1 {
		t.Fatalf("want the finished sweep: %v", jobs)
	}
	j := jobs[0].(map[string]any)
	if j["state"] != "COMPLETED" {
		t.Errorf("job did not complete: %v", j)
	}
	if uris := list(j, "resultUris"); len(uris) == 0 || uris[0] != "ley://scans/"+scan["scanId"].(string) {
		t.Errorf("the job should name the scan it produced: %v", j)
	}
	// The table names the same job, and the row number is a handle on it.
	if table := e.mustRun("jobs"); !strings.Contains(table, "scan") || !strings.Contains(table, "completed") {
		t.Errorf("jobs table does not describe the sweep:\n%s", table)
	}
	// Cancelling what has already finished leaves it alone rather than failing.
	done := parseJSON(t, e.mustRun("--json", "jobs", "cancel", "1"))
	if done["jobId"] != j["jobId"] || done["state"] != "COMPLETED" {
		t.Errorf("cancel changed a finished job: %v", done)
	}

	// The main use of the verb: stop a sweep that another client started. The dwell is
	// long enough that the sweep is certain to still be running when the second terminal looks.
	stop, live := e.startLive("scan", "145.0M..147.0M", "--dwell", "2000")
	running := e.waitJob("RUNNING")
	cancelled := parseJSON(t, e.mustRun("--json", "jobs", "cancel", running["jobId"].(string)))
	if cancelled["state"] != "CANCELLED" {
		t.Errorf("the sweep did not stop: %v", cancelled)
	}
	// The terminal that started it is told, by the same event stream every client reads, and ends.
	if err := stop(); err != nil {
		t.Errorf("ley scan did not end cleanly after the job was cancelled: %v\nstderr: %s", err, live.errOut.String())
	}
	// And the radio is free: a cancelled sweep releases its capture.
	if caps := list(e.state(), "captures"); len(caps) != 0 {
		t.Errorf("the cancelled sweep left a capture behind: %v", caps)
	}
}

// waitJob polls `ley jobs --json` for a job in the named state and returns it.
func (e *env) waitJob(state string) map[string]any {
	e.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		jobs := list(parseJSON(e.t, e.mustRun("--json", "jobs")), "jobs")
		for _, x := range jobs {
			if j := x.(map[string]any); j["state"] == state {
				return j
			}
		}
		if time.Now().After(deadline) {
			e.t.Fatalf("no job reached %s: %v", state, jobs)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// ley monitor parks on a band and reports the carriers over a window, as a time-ordered log rather
// than a swept census. Against the real daemon it must catch the fixture's carriers without
// sweeping, and fold each into a single row despite the detector's per-row centre wobble.
func TestMonitorAgainstRealDaemon(t *testing.T) {
	e, _ := setup(t)
	band, err := filepath.Abs("../../../fixtures/scan_band.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(band); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	e.mustRun("play", band, "--no-audio", "--loop", "--persistent", "--json")
	e.mustRun("stop", "--all")

	// The band is chosen so the monitor's off-DC centre (range_lo - 0.10*Fs) lands on the file's
	// own tuning point (146.0 MHz), the only frequency a file device accepts.
	out := e.mustRun("--json", "monitor", "146.24M..146.9M", "--for", "4s")
	carriers := ndjson(t, out)
	if len(carriers) == 0 {
		t.Fatalf("monitor heard nothing:\n%s", out)
	}
	// scan_band's strong carrier at 146.4 MHz is in the watched band and reliable over the window
	// (the 146.8 one is weaker and intermittent, so it is not required). It must be caught, and
	// folded to one row despite the detector's per-row centre wobble -- not a smear of duplicates.
	near146_4 := 0
	for _, c := range carriers {
		hz := uint64(c["center_hz"].(float64))
		if diffU(hz, 146_400_000) <= 60_000 {
			near146_4++
		}
		if c["detection_id"] == nil || c["peak_snr_db"] == nil {
			t.Errorf("carrier row is missing fields: %v", c)
		}
	}
	if near146_4 != 1 {
		t.Errorf("want exactly one folded carrier near 146.400 MHz, got %d:\n%s", near146_4, out)
	}
	// A handful of in-band carriers at most, never a smear of near-duplicate rows.
	if len(carriers) > 4 {
		t.Errorf("expected the carriers folded to a few rows, got %d:\n%s", len(carriers), out)
	}
}

func diffU(a, b uint64) uint64 {
	if a > b {
		return a - b
	}
	return b - a
}
