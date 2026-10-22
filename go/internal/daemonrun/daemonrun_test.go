// SPDX-License-Identifier: Apache-2.0

package daemonrun

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

// fakeEnv makes the test binary a leylined: it serves the fake daemon on --socket until
// interrupted, and counts its starts in --data/starts, with the variable FAKE_SAYS and its
// --file-scan-dwell beside each.
const fakeEnv = "DAEMONRUN_FAKE_LEYLINED"

func TestMain(m *testing.M) {
	if os.Getenv(fakeEnv) == "1" {
		os.Exit(fakeLeylined())
	}
	os.Exit(m.Run())
}

func fakeLeylined() int {
	fs := flag.NewFlagSet("leylined", flag.ContinueOnError)
	socket := fs.String("socket", "", "")
	data := fs.String("data", "", "")
	dwell := fs.String("file-scan-dwell", "", "")
	for _, name := range []string{"pidfile", "store", "recordings", "log-level", "decoders", "wall-clock"} {
		fs.String(name, "", "")
	}
	fs.Bool("no-hardware", false, "")
	fs.Bool("no-audio", false, "")
	if err := fs.Parse(os.Args[1:]); err != nil {
		return 2
	}
	f, err := os.OpenFile(filepath.Join(*data, "starts"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return 1
	}
	fmt.Fprintln(f, os.Getenv("FAKE_SAYS"), *dwell)
	_ = f.Close()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := fakedaemon.New(fakedaemon.Options{}).Serve(ctx, *socket); err != nil {
		return 1
	}
	return 0
}

// Halt stops the daemon and keeps its socket, data and log; Resume starts it again on them with
// the same environment, and a client reaches it at the same socket. Stop then removes the data.
func TestHaltResume(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	d, err := Start(ctx, Options{
		Bin: exe, Dir: t.TempDir(), Env: []string{fakeEnv + "=1", "FAKE_SAYS=hello"}, NoAudio: true,
		FileScanDwellMs: 2500,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer d.Stop()
	starts := filepath.Join(d.dataDir, "starts")
	socket := d.Socket
	if !d.Running() {
		t.Fatal("a started daemon is not running")
	}
	d.Halt()
	if d.Running() || d.Client != nil {
		t.Fatal("a halted daemon still runs or has a client")
	}
	if _, err := os.Stat(d.dataDir); err != nil {
		t.Fatalf("Halt removed the data directory: %v", err)
	}
	d.Halt() // a second Halt does nothing
	if err := d.Resume(ctx); err != nil {
		t.Fatal(err)
	}
	if err := d.Resume(ctx); err == nil {
		t.Error("Resume on a running daemon succeeded")
	}
	if d.Socket != socket || d.Client == nil {
		t.Errorf("the socket moved to %s, or no client: %v", d.Socket, d.Client)
	}
	if _, err := d.Client.State(ctx); err != nil {
		t.Errorf("the resumed daemon does not answer: %v", err)
	}
	b, err := os.ReadFile(starts)
	if err != nil || string(b) != "hello 2500\nhello 2500\n" {
		t.Errorf("starts: %q, %v", b, err)
	}
	if b, _ := os.ReadFile(d.Log); !strings.Contains(string(b), "daemonrun: started again") {
		t.Errorf("the log does not mark the restart:\n%s", b)
	}
	data := d.dataDir
	d.Stop()
	if _, err := os.Stat(data); !os.IsNotExist(err) {
		t.Errorf("Stop left the data directory: %v", err)
	}
}
