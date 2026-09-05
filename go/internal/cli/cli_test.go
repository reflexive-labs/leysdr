package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// harness starts a fake daemon on a temp UDS and returns its socket path plus
// a helper client for assertions.
func harness(t *testing.T, opts fakedaemon.Options) (string, *leyline.Client) {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "d.sock")
	ctx, cancel := context.WithCancel(context.Background())
	if opts.PresenceGrace == 0 {
		opts.PresenceGrace = 200 * time.Millisecond
	}
	d := fakedaemon.New(opts)
	served := make(chan error, 1)
	go func() { served <- d.Serve(ctx, sock) }()
	c, err := leyline.Dial(ctx, sock, leyline.WithKind("cli"), leyline.WithLabel("test"), leyline.WithClientID("cli_test"))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := c.State(ctx); err == nil || time.Now().After(deadline) {
			if err != nil {
				t.Fatalf("daemon never came up: %v", err)
			}
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Cleanup(func() {
		_ = c.Close()
		cancel()
		<-served
	})
	return sock, c
}

// run executes ley in-process with captured output.
func run(t *testing.T, ctx context.Context, sock string, args ...string) (string, string, error) {
	t.Helper()
	var out, errb bytes.Buffer
	app := &App{Stdout: &out, Stderr: &errb, LookupEnv: func(string) (string, bool) { return "", false }}
	err := Execute(ctx, app, append([]string{"--socket", sock}, args...))
	return out.String(), errb.String(), err
}

func mustRun(t *testing.T, sock string, args ...string) string {
	t.Helper()
	out, errOut, err := run(t, context.Background(), sock, args...)
	if err != nil {
		t.Fatalf("ley %v: %v\nstdout: %s\nstderr: %s", args, err, out, errOut)
	}
	return out
}

func TestDevicesTableAndJSON(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "devices")
	if !strings.Contains(out, "ID") || !strings.Contains(out, "rtlsdr") && !strings.Contains(out, "RTL") {
		t.Fatalf("unexpected table:\n%s", out)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("want header + 1 device, got:\n%s", out)
	}
	out = mustRun(t, sock, "--json", "devices")
	var resp struct {
		Devices []map[string]any `json:"devices"`
	}
	if err := json.Unmarshal([]byte(out), &resp); err != nil || len(resp.Devices) != 1 {
		t.Fatalf("json devices: %v %s", err, out)
	}
	if resp.Devices[0]["deviceId"] == nil || resp.Devices[0]["state"] != "AVAILABLE" {
		t.Fatalf("json shape: %s", out)
	}
}

func TestState(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "state")
	for _, want := range []string{"daemon fake-0.1", "Devices", "Captures", "Channels", "Sinks"} {
		if !strings.Contains(out, want) {
			t.Fatalf("state missing %q:\n%s", want, out)
		}
	}
	out = mustRun(t, sock, "--json", "state")
	var st map[string]any
	if err := json.Unmarshal([]byte(out), &st); err != nil || st["daemon"] == nil {
		t.Fatalf("json state: %v %s", err, out)
	}
	if out := mustRun(t, sock, "version"); !strings.HasPrefix(out, "ley ") {
		t.Fatalf("version: %s", out)
	}
}
