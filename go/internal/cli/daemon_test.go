// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/testutil"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// A home directory with &, < or > in it must not break the LaunchAgent XML.
func TestPlistEscapesPaths(t *testing.T) {
	got := plist("/Users/a&b/bin/leylined", "/Users/a<b>/Library/Application Support/Leyline/leyline.sock", "/Users/a&b<c>/Library/Logs/Leyline/leylined.log")
	path := filepath.Join("testdata", "launchagent.plist.golden")
	if *update {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(want) != got {
		t.Errorf("plist differs from the golden file (run with -update if the change is intended)\n--- want\n%s\n--- got\n%s", want, got)
	}
	for _, raw := range []string{"a&b", "a<b>", "<c>"} {
		if strings.Contains(got, raw) {
			t.Errorf("plist contains unescaped %q", raw)
		}
	}
}

func TestIsDaemonComm(t *testing.T) {
	for out, want := range map[string]bool{
		//nolint:gocritic // the padded key is the case under test: ps output with whitespace around it
		"leylined\n": true, "/opt/leyline/bin/leylined\n": true, " leylined \n": true,
		"sleep\n": false, "": false, "leylined-old\n": false, "/usr/bin/ley\n": false,
	} {
		if got := isDaemonComm(out); got != want {
			t.Errorf("isDaemonComm(%q) = %v, want %v", out, got, want)
		}
	}
}

// A daemon that answers GetState with an error is running but unwell: status
// reports that error (exit 1, its code), not "not running" (exit 3), which is
// reserved for nothing listening on the socket.
func TestDaemonStatusDaemonError(t *testing.T) {
	sock := testutil.SocketPath(t, "unwell.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	srv := grpc.NewServer()
	leylinev1.RegisterControlServer(srv, &leylinev1.UnimplementedControlServer{})
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(srv.Stop)
	for _, args := range [][]string{{"daemon", "status"}, {"--json", "daemon", "status"}} {
		out, _, err := run(t, t.Context(), sock, args...)
		if exitCode(err) != 1 || !strings.HasSuffix(err.Error(), "[UNIMPLEMENTED]") || out != "" {
			t.Errorf("ley %v: err %v (exit %d), stdout %q; want exit 1 with [UNIMPLEMENTED]", args, err, exitCode(err), out)
		}
	}
}

// TestDaemonStatusLine: the state word leads, the ink is redundant emphasis
// on it, and the pid and socket stay copy-pasteable.
func TestDaemonStatusLine(t *testing.T) {
	info := &leylinev1.DaemonInfo{
		Version:     "0.1.0-dev",
		Pid:         4242,
		StartedAtNs: time.Now().Add(-46 * time.Second).UnixNano(),
		SocketPath:  "/tmp/leyline/d.sock",
	}
	plain := daemonStatusLine(ui.Style{Unicode: true, Width: 80}, info)
	styled := daemonStatusLine(ui.Style{Color: true, Unicode: true, Width: 80}, info)
	if styled == plain {
		t.Fatal("a coloured style left the status line unstyled")
	}
	if got := ui.Strip(styled); got != plain {
		t.Fatalf("Strip(styled) = %q, want %q", got, plain)
	}
	if want := "running  0.1.0-dev  pid 4242  up 46s  socket /tmp/leyline/d.sock"; plain != want {
		t.Errorf("status line = %q, want %q", plain, want)
	}
	if !strings.HasPrefix(styled, "\x1b[32mrunning\x1b[0m") {
		t.Errorf("the state word is not Ok ink: %q", styled)
	}
}

// The not-running sentence is frozen; only its state words, its socket path
// and its remedy take ink.
func TestNotRunningLineInk(t *testing.T) {
	app := &App{Socket: "/tmp/leyline/none.sock"}
	msg := app.notRunningMessage()
	styled := inkMessage(ui.Style{Color: true}, msg)
	if ui.Strip(styled) != msg {
		t.Fatalf("Strip(styled) = %q, want %q", ui.Strip(styled), msg)
	}
	for _, want := range []string{"\x1b[31mnot running\x1b[0m", "\x1b[36mley daemon start\x1b[0m"} {
		if !strings.Contains(styled, want) {
			t.Errorf("not-running line lacks %q: %q", want, styled)
		}
	}
}

// launchctlJob is `launchctl print` output for the daemon's job, trimmed to
// the lines appDaemonProgram reads and a few it must skip.
func launchctlJob(plistPath, program string) string {
	return "gui/501/com.leysdr.daemon = {\n" +
		"\tactive count = 1\n" +
		"\tpath = " + plistPath + "\n" +
		"\ttype = LaunchAgent\n" +
		"\tstate = running\n\n" +
		"\tprogram = " + program + "\n" +
		"\targuments = {\n\t\t" + program + "\n\t\t--log-file\n\t}\n" +
		"}\n"
}

// The app and `ley daemon install` share the label com.leysdr.daemon, so install and uninstall
// leave a job the app registered alone and say where it is switched off.
func TestDaemonInstallRefusesTheAppsJob(t *testing.T) {
	const program = "/Applications/Leyline.app/Contents/Helpers/leylined"
	job := launchctlJob("/Applications/Leyline.app/Contents/Library/LaunchAgents/com.leysdr.daemon.plist", program)
	for _, verb := range []string{"install", "uninstall"} {
		var targets []string
		var out, errb bytes.Buffer
		app := &App{
			Stdout: &out, Stderr: &errb,
			LookupEnv: func(string) (string, bool) { return "", false },
			launchctlPrint: func(_ context.Context, target string) (string, error) {
				targets = append(targets, target)
				return job, nil
			},
		}
		sock := filepath.Join(t.TempDir(), "none.sock")
		err := Execute(t.Context(), app, []string{"--socket", sock, "daemon", verb})
		if err == nil {
			t.Fatalf("daemon %s: no error for the app's job", verb)
		}
		for _, want := range []string{"Leyline app", program, "System Settings > General > Login Items & Extensions"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("daemon %s: error %q does not mention %q", verb, err, want)
			}
		}
		if want := fmt.Sprintf("gui/%d/com.leysdr.daemon", os.Getuid()); len(targets) != 1 || targets[0] != want {
			t.Errorf("daemon %s asked launchctl about %v, want [%s]", verb, targets, want)
		}
		if out.Len() != 0 {
			t.Errorf("daemon %s wrote to stdout after refusing: %q", verb, out.String())
		}
	}
}

// Only a job running a bundle's helper from a plist ley did not write is the app's.
func TestAppDaemonProgram(t *testing.T) {
	const helper = "/Applications/Leyline.app/Contents/Helpers/leylined"
	bundled := "/Applications/Leyline.app/Contents/Library/LaunchAgents/com.leysdr.daemon.plist"
	cases := []struct {
		name, out string
		err       error
		want      string
	}{
		{"the app's job", launchctlJob(bundled, helper), nil, helper},
		{"no job", "", errors.New("exit status 113"), ""},
		{"a source build", launchctlJob(defaultLaunchAgentPath(), "/Users/a/leysdr/engine/.build/release/leylined"), nil, ""},
		{"install pointed at the bundle", launchctlJob(defaultLaunchAgentPath(), helper), nil, ""},
	}
	for _, c := range cases {
		app := &App{launchctlPrint: func(context.Context, string) (string, error) { return c.out, c.err }}
		if got := app.appDaemonProgram(t.Context()); got != c.want {
			t.Errorf("%s: appDaemonProgram = %q, want %q", c.name, got, c.want)
		}
	}
}

// serveFake starts a fake daemon on sock and returns the function that stops it.
func serveFake(t *testing.T, sock string) (stop func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan error, 1)
	go func() { served <- fakedaemon.New(fakedaemon.Options{}).Serve(ctx, sock) }()
	var once sync.Once
	stop = func() { once.Do(func() { cancel(); <-served }) }
	t.Cleanup(stop)
	return stop
}

// The app's agent has no plist in ~/Library/LaunchAgents, so start and stop find launchd's job by
// its label and drive it with launchctl, never by spawning or signalling a process themselves.
func TestDaemonStartAndStopDriveALoadedLabel(t *testing.T) {
	const program = "/Applications/Leyline.app/Contents/Helpers/leylined"
	job := launchctlJob("/Applications/Leyline.app/Contents/Library/LaunchAgents/com.leysdr.daemon.plist", program)
	target := fmt.Sprintf("gui/%d/com.leysdr.daemon", os.Getuid())
	sock := testutil.SocketPath(t, "agent.sock")
	var calls [][]string
	stopFake := func() {}
	var out, errb bytes.Buffer
	app := &App{
		Stdout: &out, Stderr: &errb,
		LookupEnv:      func(string) (string, bool) { return "", false },
		launchctlPrint: func(context.Context, string) (string, error) { return job, nil },
		launchctlRun: func(_ context.Context, args ...string) error {
			calls = append(calls, args)
			switch args[0] {
			case "kickstart":
				stopFake = serveFake(t, sock)
			case "kill":
				stopFake()
			}
			return nil
		},
	}
	if err := Execute(t.Context(), app, []string{"--socket", sock, "daemon", "start"}); err != nil {
		t.Fatalf("daemon start: %v\nstderr: %s", err, errb.String())
	}
	if err := Execute(t.Context(), app, []string{"--socket", sock, "daemon", "stop"}); err != nil {
		t.Fatalf("daemon stop: %v\nstderr: %s", err, errb.String())
	}
	want := [][]string{{"kickstart", "-k", target}, {"kill", "SIGTERM", target}}
	if fmt.Sprint(calls) != fmt.Sprint(want) {
		t.Errorf("launchctl calls = %v, want %v", calls, want)
	}
	if !strings.Contains(out.String(), "started leylined") || !strings.Contains(out.String(), "stopped") {
		t.Errorf("stdout = %q, want the start and stop reports", out.String())
	}
}

// Without a plist or a loaded label, start and stop keep to the pidfile.
func TestLaunchdOwnsDaemonNeedsALoadedLabel(t *testing.T) {
	if launchAgentInstalled() {
		t.Skip("this machine has ley's LaunchAgent installed")
	}
	none := &App{launchctlPrint: func(context.Context, string) (string, error) {
		return "", errors.New("exit status 113")
	}}
	if none.launchdOwnsDaemon(t.Context()) {
		t.Error("launchdOwnsDaemon is true with no job loaded")
	}
	loaded := &App{launchctlPrint: func(context.Context, string) (string, error) { return "gui/501/com.leysdr.daemon = {\n}\n", nil }}
	if !loaded.launchdOwnsDaemon(t.Context()) {
		t.Error("launchdOwnsDaemon is false with the label loaded")
	}
}
