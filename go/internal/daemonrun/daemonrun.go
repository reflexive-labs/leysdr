// SPDX-License-Identifier: Apache-2.0

// Package daemonrun starts a hermetic leylined: --no-hardware, with its socket, pidfile, record
// store, recordings and log in one directory, so nothing it does reaches the machine's radios,
// its default daemon or the user's data. The agent evals (go/internal/eval) and the site
// screenshots (go/cmd/leyshots) each run one per scenario or scene.
package daemonrun

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// Options says which daemon to start and where.
type Options struct {
	// Bin is the leylined binary.
	Bin string
	// Dir holds the socket, pidfile, store, recordings and log. It is created if missing.
	Dir string
	// Decoders is a plugin directory the daemon searches before its default, or empty.
	Decoders string
	// WallClock, as HH:MM, starts the daemon's clock at that time today (leylined --wall-clock).
	WallClock string
	// Label is the client label the readiness connection uses, as the daemon's log shows it.
	Label string
	// Env is added to the daemon's environment, as KEY=value.
	Env []string
}

// Daemon is a running hermetic daemon.
type Daemon struct {
	// Dir is Options.Dir; Socket, Store, Recordings and Log are the paths the daemon was given.
	Dir, Socket, Store, Recordings, Log string
	// Client is connected and has answered GetState.
	Client *leyline.Client

	cmd *exec.Cmd
	// socketDir is the short temp directory the socket was moved to, or empty; removed on Stop.
	socketDir string
	logFile   *os.File
}

// socketPathMax is the longest Unix socket path both platforms accept (104 bytes on macOS,
// 108 on Linux), with room for the pidfile the daemon puts beside it.
const socketPathMax = 96

// readyTimeout bounds how long Start waits for the daemon to answer.
const readyTimeout = 15 * time.Second

// Start brings up the daemon and waits until it answers GetState. The socket sits in Dir unless
// that path is too long for a Unix socket, in which case it goes in a short temp directory of its
// own and Dir gets socket.txt saying where.
func Start(ctx context.Context, o Options) (*Daemon, error) {
	if err := os.MkdirAll(o.Dir, 0o755); err != nil {
		return nil, err
	}
	d := &Daemon{
		Dir: o.Dir, Socket: filepath.Join(o.Dir, "d.sock"), Store: filepath.Join(o.Dir, "store"),
		Recordings: filepath.Join(o.Dir, "recordings"), Log: filepath.Join(o.Dir, "leylined.log"),
	}
	if len(d.Socket) > socketPathMax {
		short, err := os.MkdirTemp("", "ley")
		if err != nil {
			return nil, err
		}
		d.socketDir = short
		d.Socket = filepath.Join(short, "d.sock")
		_ = os.WriteFile(filepath.Join(o.Dir, "socket.txt"), []byte(d.Socket+"\n"), 0o644)
	}
	f, err := os.Create(d.Log)
	if err != nil {
		d.Stop()
		return nil, err
	}
	d.logFile = f
	// --no-hardware: the machine's own dongles stay out of the run. A client that tunes "146.52"
	// with no device named gets the fixture, not the machine's radio.
	args := []string{
		"--socket", d.Socket, "--pidfile", filepath.Join(o.Dir, "leylined.pid"),
		"--store", d.Store, "--recordings", d.Recordings, "--log-level", "info", "--no-hardware",
	}
	if o.Decoders != "" {
		args = append(args, "--decoders", o.Decoders)
	}
	if o.WallClock != "" {
		args = append(args, "--wall-clock", o.WallClock)
	}
	d.cmd = exec.Command(o.Bin, args...)
	d.cmd.Stdout, d.cmd.Stderr = f, f
	if len(o.Env) > 0 {
		d.cmd.Env = append(os.Environ(), o.Env...)
	}
	if err := d.cmd.Start(); err != nil {
		d.Stop()
		return nil, fmt.Errorf("start %s: %w", o.Bin, err)
	}
	label := o.Label
	if label == "" {
		label = "daemonrun"
	}
	c, err := leyline.Dial(ctx, d.Socket, leyline.WithKind("cli"), leyline.WithLabel(label))
	if err != nil {
		d.Stop()
		return nil, err
	}
	d.Client = c
	deadline := time.Now().Add(readyTimeout)
	for {
		if _, err := c.State(ctx); err == nil {
			return d, nil
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			d.Stop()
			return nil, fmt.Errorf("leylined did not answer on %s within %s; its log is %s", d.Socket, readyTimeout, d.Log)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// Stop interrupts the daemon, kills it if it has not exited 5 s later, and removes the short
// socket directory. It is safe on a partly started Daemon.
func (d *Daemon) Stop() {
	if d.Client != nil {
		_ = d.Client.Close()
	}
	if d.cmd != nil && d.cmd.Process != nil {
		_ = d.cmd.Process.Signal(os.Interrupt)
		done := make(chan struct{})
		go func() { _ = d.cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			_ = d.cmd.Process.Kill()
			<-done
		}
	}
	if d.socketDir != "" {
		_ = os.RemoveAll(d.socketDir)
	}
	if d.logFile != nil {
		_ = d.logFile.Close()
	}
}
