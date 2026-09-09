package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/testutil"
)

// fakeDaemonEnv makes the test binary serve a fake daemon (used by the shell
// "leylined" that daemon start spawns).
const fakeDaemonEnv = "LEY_TEST_FAKE_DAEMON"

func TestMain(m *testing.M) {
	if os.Getenv(fakeDaemonEnv) == "1" {
		sock := ""
		for i, a := range os.Args {
			if a == "--socket" && i+1 < len(os.Args) {
				sock = os.Args[i+1]
			}
		}
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
		defer stop()
		fmt.Println("fake leylined starting on", sock)
		if err := fakedaemon.New(fakedaemon.Options{}).Serve(ctx, sock); err != nil {
			fmt.Println("serve:", err)
			os.Exit(1)
		}
		fmt.Println("fake leylined stopped")
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestPlayWithSidecar(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	dir := t.TempDir()
	iq := filepath.Join(dir, "nfm_tone.cf32")
	if err := os.WriteFile(iq, make([]byte, 8*1024), 0o644); err != nil {
		t.Fatal(err)
	}
	side := `{"format":"cf32","sample_rate":2400000,"center_hz":146520000,
	  "expect":[{"mode":"AM","offset_hz":100000,"bandwidth_hz":10000}]}`
	if err := os.WriteFile(filepath.Join(dir, "nfm_tone.json"), []byte(side), 0o644); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	var out string
	go func() {
		o, _, err := run(t, ctx, sock, "play", iq, "--no-audio")
		out = o
		done <- err
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		st, err := c.State(context.Background())
		if err == nil && len(st.Channels) == 1 {
			ch := st.Channels[0]
			if ch.OffsetHz != 100_000 || ch.Mode.String() != "AM" || ch.BandwidthHz != 10000 {
				t.Fatalf("channel from sidecar: %v", ch)
			}
			if len(st.Devices) != 2 || st.Captures[0].CenterHz != 146_520_000 {
				t.Fatalf("file device/capture: %v %v", st.Devices, st.Captures)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("play never created its channel")
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("play: %v\n%s", err, out)
	}
	st, _ := c.State(context.Background())
	if len(st.Devices) != 1 || len(st.Captures) != 0 || len(st.Channels) != 0 {
		t.Fatalf("play did not detach/tear down: %d devices %d captures %d channels", len(st.Devices), len(st.Captures), len(st.Channels))
	}
	if !strings.Contains(out, "146.620 MHz AM  signal ") {
		t.Fatalf("meter line: %s", out)
	}
	// Mode precedence for play: the sidecar beats the band table and says so;
	// squelch stays off for a recording unless asked.
	if !strings.Contains(out, "using AM: the recording's sidecar says AM") || !strings.Contains(out, "Squelch off.") {
		t.Fatalf("play banner: %s", out)
	}
}

func TestPlayExplicitModeBeatsSidecar(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	dir := t.TempDir()
	iq := filepath.Join(dir, "tone.cf32")
	if err := os.WriteFile(iq, make([]byte, 8*1024), 0o644); err != nil {
		t.Fatal(err)
	}
	side := `{"format":"cf32","sample_rate":2400000,"center_hz":146520000,
	  "expect":[{"mode":"AM","offset_hz":100000,"bandwidth_hz":10000}]}`
	if err := os.WriteFile(filepath.Join(dir, "tone.json"), []byte(side), 0o644); err != nil {
		t.Fatal(err)
	}
	out, _, err := run(t, context.Background(), sock, "play", iq, "--no-audio", "--persistent", "--mode", "nfm", "--bw", "12.5", "--freq", "146.6")
	if err != nil {
		t.Fatalf("play: %v\n%s", err, out)
	}
	if strings.Contains(out, "using ") {
		t.Fatalf("explicit mode should print no rationale:\n%s", out)
	}
	st, _ := c.State(context.Background())
	ch := st.Channels[0]
	if ch.Mode.String() != "NFM" || ch.BandwidthHz != 12_500 || ch.OffsetHz != 80_000 {
		t.Fatalf("explicit flags not honoured: %v", ch)
	}
}

func TestDaemonStatus(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "daemon", "status")
	if !strings.Contains(out, "daemon fake-0.1 pid") {
		t.Fatalf("status: %s", out)
	}
	dead := testutil.SocketPath(t, "dead.sock")
	out, _, err := run(t, context.Background(), dead, "daemon", "status")
	var ee *ExitError
	if !strings.Contains(out, "not running") || !errors.As(err, &ee) || ee.Code != ExitNotRunning {
		t.Fatalf("dead status: %s %v", out, err)
	}
	// Not running: the same DaemonInfo shape with pid absent, exit status 3.
	out, _, err = run(t, context.Background(), dead, "--json", "daemon", "status")
	if !errors.As(err, &ee) || ee.Code != ExitNotRunning || ee.Message != "" {
		t.Fatalf("dead status exit: %v", err)
	}
	var js map[string]any
	if err := json.Unmarshal([]byte(out), &js); err != nil || js["socketPath"] != dead || js["pid"] != nil || js["running"] != nil {
		t.Fatalf("json dead status: %v %s", err, out)
	}
	out, _, err = run(t, context.Background(), sock, "--json", "daemon", "status")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(out), &js); err != nil || js["socketPath"] != sock || js["pid"] == nil {
		t.Fatalf("json live status: %v %s", err, out)
	}
}

// fakeDaemonScript writes a "leylined" shell script into dir that execs the
// test binary as a fake daemon (body "" for that; a custom body replaces it)
// and returns the script, socket, pidfile and log paths for that directory.
func fakeDaemonScript(t *testing.T, dir, body string) (script, sock, pidfile, logPath string) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script = filepath.Join(dir, "leylined")
	if body == "" {
		body = "#!/bin/sh\nexec env " + fakeDaemonEnv + "=1 " + exe + " \"$@\"\n"
	}
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return script, filepath.Join(dir, "d.sock"), filepath.Join(dir, "d.pid"), filepath.Join(dir, "leylined.log")
}

func TestDaemonStartStop(t *testing.T) {
	dir := t.TempDir()
	script, sock, pidfile, logPath := fakeDaemonScript(t, dir, "")
	// Discovery via the binary beside the ley executable.
	app := &App{Stdout: os.Stdout, Stderr: os.Stderr, Executable: filepath.Join(dir, "ley"), LookupEnv: func(string) (string, bool) { return "", false }}
	if bin, err := app.findDaemonBin(""); err != nil || bin != script {
		t.Fatalf("discovery beside ley: %q %v", bin, err)
	}
	app.LookupEnv = func(k string) (string, bool) { return "/nope/leylined", k == daemonBinEnv }
	if bin, _ := app.findDaemonBin(""); bin != "/nope/leylined" {
		t.Fatalf("env discovery: %q", bin)
	}
	if bin, _ := app.findDaemonBin("/flag/leylined"); bin != "/flag/leylined" {
		t.Fatalf("flag discovery: %q", bin)
	}

	out := mustRun(t, sock, "daemon", "start", "--bin", script, "--log", logPath)
	if !strings.Contains(out, "started leylined") || !strings.Contains(out, "pid") {
		t.Fatalf("start output: %s", out)
	}
	pidBytes, err := os.ReadFile(pidfile)
	if err != nil || len(pidBytes) == 0 {
		t.Fatalf("pidfile: %v", err)
	}
	if out := mustRun(t, sock, "daemon", "start", "--bin", script, "--log", logPath); !strings.Contains(out, "already running") {
		t.Fatalf("second start: %s", out)
	}
	if out := mustRun(t, sock, "daemon", "logs", "--log", logPath); !strings.Contains(out, "fake leylined starting on "+sock) {
		t.Fatalf("logs: %s", out)
	}
	if out := mustRun(t, sock, "daemon", "stop"); !strings.Contains(out, "stopped") {
		t.Fatalf("stop: %s", out)
	}
	if _, err := os.Stat(pidfile); !os.IsNotExist(err) {
		t.Fatalf("pidfile not removed: %v", err)
	}
	if out, _, err := run(t, context.Background(), sock, "daemon", "status"); !strings.Contains(out, "not running") || err == nil {
		t.Fatalf("status after stop: %s %v", out, err)
	}
	if out := mustRun(t, sock, "daemon", "stop"); !strings.Contains(out, "not running") {
		t.Fatalf("second stop: %s", out)
	}
	// --json: start and stop print the DaemonInfo status prints; a stop with
	// nothing running prints only socketPath (exit 0) and says so on stderr.
	var info map[string]any
	out = mustRun(t, sock, "--json", "daemon", "start", "--bin", script, "--log", logPath)
	if err := json.Unmarshal([]byte(out), &info); err != nil || info["socketPath"] != sock || info["pid"] == nil || info["version"] == nil {
		t.Fatalf("start --json: %v %s", err, out)
	}
	out = mustRun(t, sock, "--json", "daemon", "start", "--bin", script, "--log", logPath)
	if err := json.Unmarshal([]byte(out), &info); err != nil || info["pid"] == nil {
		t.Fatalf("second start --json: %v %s", err, out)
	}
	out = mustRun(t, sock, "--json", "daemon", "stop")
	if err := json.Unmarshal([]byte(out), &info); err != nil || info["socketPath"] != sock || info["pid"] == nil {
		t.Fatalf("stop --json: %v %s", err, out)
	}
	out, errOut, err := run(t, context.Background(), sock, "--json", "daemon", "stop")
	if err != nil || !strings.Contains(errOut, "not running") {
		t.Fatalf("stop --json not running: %v stderr=%q", err, errOut)
	}
	info = map[string]any{} // Unmarshal merges into an existing map
	if err := json.Unmarshal([]byte(out), &info); err != nil || info["socketPath"] != sock || info["pid"] != nil {
		t.Fatalf("stop --json not running stdout: %v %s", err, out)
	}
	// Verbs without a JSON shape refuse the flag before doing anything.
	for _, args := range [][]string{{"daemon", "logs", "--log", logPath}, {"daemon", "install"}, {"daemon", "uninstall"}} {
		out, _, err := run(t, context.Background(), sock, append([]string{"--json"}, args...)...)
		if exitCode(err) != ExitUsage || out != "" || !strings.Contains(err.Error(), "no --json output") {
			t.Errorf("ley --json %v: exit %d (%v) stdout=%q, want %d", args, exitCode(err), err, out, ExitUsage)
		}
	}
}

func TestPlayPersistentKeepsDeviceUntilDetach(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	dir := t.TempDir()
	iq := filepath.Join(dir, "tone.cf32")
	if err := os.WriteFile(iq, make([]byte, 8*1024), 0o644); err != nil {
		t.Fatal(err)
	}
	side := `{"format":"cf32","sample_rate":2400000,"center_hz":146520000,
	  "expect":[{"mode":"NFM","offset_hz":100000,"bandwidth_hz":12500}]}`
	if err := os.WriteFile(filepath.Join(dir, "tone.json"), []byte(side), 0o644); err != nil {
		t.Fatal(err)
	}
	out, _, err := run(t, context.Background(), sock, "play", iq, "--no-audio", "--persistent")
	if err != nil {
		t.Fatalf("play --persistent: %v\n%s", err, out)
	}
	st, err := c.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Devices) != 2 || len(st.Captures) != 1 || len(st.Channels) != 1 || !st.Channels[0].Persistent {
		t.Fatalf("persistent play must leave device+capture+channel: %d devices %d captures %d channels", len(st.Devices), len(st.Captures), len(st.Channels))
	}
	var fileDev string
	for _, d := range st.Devices {
		if d.Driver == "file" {
			fileDev = d.DeviceId
		}
	}
	if fileDev == "" || !strings.Contains(out, "ley devices detach "+fileDev) {
		t.Fatalf("expected detach hint for %q in output:\n%s", fileDev, out)
	}
	if out, _, err := run(t, context.Background(), sock, "devices", "detach", fileDev); err != nil {
		t.Fatalf("devices detach: %v\n%s", err, out)
	}
	st, _ = c.State(context.Background())
	if len(st.Devices) != 1 || len(st.Captures) != 0 || len(st.Channels) != 0 {
		t.Fatalf("detach did not tear down: %d devices %d captures %d channels", len(st.Devices), len(st.Captures), len(st.Channels))
	}
	if _, _, err := run(t, context.Background(), sock, "devices", "detach", fileDev); err == nil {
		t.Fatalf("second detach should fail")
	}
	// A persistent play whose tune fails (frequency outside the file's span)
	// must not leave an orphan file device behind.
	if _, _, err := run(t, context.Background(), sock, "play", iq, "--no-audio", "--persistent", "--freq", "900M"); err == nil {
		t.Fatalf("play outside span should fail")
	}
	st, _ = c.State(context.Background())
	if len(st.Devices) != 1 {
		t.Fatalf("failed persistent play left a file device: %v", st.Devices)
	}
}

// waitFor polls cond for up to 3 s.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// startSleeper spawns a `sleep` that outlives the test unless stopped, and
// returns its pid: a process that is not the daemon.
func startSleeper(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	return cmd.Process.Pid
}

// #22: a daemon whose pidfile went missing is still stopped, by the pid it
// reports itself; "not running" is only for a socket nobody answers on.
func TestDaemonStopWithoutPidfile(t *testing.T) {
	script, sock, pidfile, logPath := fakeDaemonScript(t, t.TempDir(), "")
	mustRun(t, sock, "daemon", "start", "--bin", script, "--log", logPath)
	if err := os.Remove(pidfile); err != nil {
		t.Fatal(err)
	}
	if out := mustRun(t, sock, "daemon", "stop"); !strings.Contains(out, "stopped") {
		t.Fatalf("stop without pidfile: %s", out)
	}
	if _, _, err := run(t, context.Background(), sock, "daemon", "status"); exitCode(err) != ExitNotRunning {
		t.Fatalf("status after stop: %v", err)
	}
}

// #20: a pidfile naming a pid the system reused must never be signalled.
func TestDaemonStopPidReused(t *testing.T) {
	script, sock, pidfile, logPath := fakeDaemonScript(t, t.TempDir(), "")
	sleeper := startSleeper(t)
	writePid := func() {
		if err := os.WriteFile(pidfile, []byte(strconv.Itoa(sleeper)+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Nothing on the socket: the pid's command name is not leylined, so the
	// pidfile is stale; it is removed and stop reports not running.
	writePid()
	if out := mustRun(t, sock, "daemon", "stop"); !strings.Contains(out, "not running") {
		t.Fatalf("stop with reused pid: %s", out)
	}
	if _, err := os.Stat(pidfile); !os.IsNotExist(err) {
		t.Fatalf("stale pidfile kept: %v", err)
	}
	if syscall.Kill(sleeper, 0) != nil {
		t.Fatal("stop signalled the process that reused the pid")
	}
	// A daemon answering with a different pid: the pidfile is stale, the
	// daemon is stopped by its own pid, the other process is left alone.
	mustRun(t, sock, "daemon", "start", "--bin", script, "--log", logPath)
	writePid()
	if out := mustRun(t, sock, "daemon", "stop"); !strings.Contains(out, "stopped") {
		t.Fatalf("stop with reused pid beside a live daemon: %s", out)
	}
	if syscall.Kill(sleeper, 0) != nil {
		t.Fatal("stop signalled the process that reused the pid")
	}
	if _, _, err := run(t, context.Background(), sock, "daemon", "status"); exitCode(err) != ExitNotRunning {
		t.Fatalf("status after stop: %v", err)
	}
}

// #21: a daemon that dies during startup is reported as such, promptly, and
// never recorded in the pidfile.
func TestDaemonStartChildExits(t *testing.T) {
	script, sock, pidfile, logPath := fakeDaemonScript(t, t.TempDir(), "#!/bin/sh\necho boom\nexit 3\n")
	started := time.Now()
	_, _, err := run(t, context.Background(), sock, "daemon", "start", "--bin", script, "--log", logPath)
	if err == nil || !strings.Contains(err.Error(), "exited during startup") || !strings.Contains(err.Error(), "exit status 3") {
		t.Fatalf("start with a dying daemon: %v", err)
	}
	if time.Since(started) > 3*time.Second {
		t.Fatalf("start took %v to notice the exit", time.Since(started))
	}
	if _, err := os.Stat(pidfile); !os.IsNotExist(err) {
		t.Fatalf("pidfile written for a dead daemon: %v", err)
	}
	if log, _ := os.ReadFile(logPath); !strings.Contains(string(log), "boom") {
		t.Fatalf("log: %q", log)
	}
}

// #12: a daemon that came up but cannot be recorded in the pidfile is stopped
// again, so nothing runs that stop cannot find.
func TestDaemonStartPidfileUnwritable(t *testing.T) {
	script, sock, pidfile, logPath := fakeDaemonScript(t, t.TempDir(), "")
	if err := os.Mkdir(pidfile, 0o755); err != nil {
		t.Fatal(err)
	}
	_, _, err := run(t, context.Background(), sock, "daemon", "start", "--bin", script, "--log", logPath)
	if err == nil || !strings.Contains(err.Error(), "write pidfile") || !strings.Contains(err.Error(), "stopped the daemon again") {
		t.Fatalf("start with an unwritable pidfile: %v", err)
	}
	if _, _, err := run(t, context.Background(), sock, "daemon", "status"); exitCode(err) != ExitNotRunning {
		t.Fatalf("daemon left running after the failed start: %v", err)
	}
	waitFor(t, "the daemon's exit in the log", func() bool {
		log, _ := os.ReadFile(logPath)
		return strings.Contains(string(log), "fake leylined stopped")
	})
}
