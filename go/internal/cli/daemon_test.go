package cli

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/grpc"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/testutil"
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
