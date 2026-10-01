// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
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
		out, _, err := run(t, context.Background(), sock, args...)
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
