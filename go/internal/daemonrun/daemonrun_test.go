// SPDX-License-Identifier: Apache-2.0

package daemonrun

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
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
	secrets := fs.String("secrets", "", "")
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
	// As leylined does before it listens; FAKE_KEYCHAIN plays a daemon that ignored --secrets.
	if *secrets == "file" && os.Getenv("LEYLINE_SECRETS") == "file" && os.Getenv("FAKE_KEYCHAIN") == "" {
		fmt.Fprintf(os.Stderr, "info leyline.daemon: AI keys in %s\n", filepath.Join(*data, "secrets", "credentials.json"))
	} else {
		fmt.Fprintln(os.Stderr, "info leyline.daemon: AI keys in the login keychain")
	}
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

// A daemon that would keep keys in the login keychain is refused at start, whatever the caller's
// environment says; the environment it is given always ends LEYLINE_SECRETS=file.
func TestRefusesADaemonOnTheKeychain(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("LEYLINE_SECRETS", "keychain")
	d, err := Start(ctx, Options{Bin: exe, Dir: t.TempDir(), Env: []string{fakeEnv + "=1", "LEYLINE_SECRETS=keychain"}})
	if err != nil {
		t.Fatalf("a daemon on the file store was refused: %v", err)
	}
	d.Stop()
	_, err = Start(ctx, Options{Bin: exe, Dir: t.TempDir(), Env: []string{fakeEnv + "=1", "FAKE_KEYCHAIN=1"}})
	if err == nil || !strings.Contains(err.Error(), "the login keychain") {
		t.Errorf("a daemon on the keychain started: %v", err)
	}
	env := daemonEnv([]string{"LEYLINE_SECRETS=keychain", "HOME=/h"}, Options{Env: []string{"LEYLINE_SECRETS=keychain"}})
	if env[len(env)-1] != secretsEnv || slices.Contains(env, "LEYLINE_SECRETS=keychain") {
		t.Errorf("daemonEnv = %v", env)
	}
}
