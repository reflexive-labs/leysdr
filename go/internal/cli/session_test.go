// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/testutil"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// harnessStop is harness with the daemon's shutdown in the test's hands: stop
// cancels Serve (streams end cleanly, then the server stops) and waits for it.
func harnessStop(t *testing.T, opts fakedaemon.Options) (sock string, c *leyline.Client, stop func()) {
	t.Helper()
	sock = testutil.SocketPath(t, "d.sock")
	ctx, cancel := context.WithCancel(context.Background())
	if opts.PresenceGrace == 0 {
		opts.PresenceGrace = 200 * time.Millisecond
	}
	served := make(chan error, 1)
	go func() { served <- fakedaemon.New(opts).Serve(ctx, sock) }()
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
	stopped := false
	stop = func() {
		if stopped {
			return
		}
		stopped = true
		cancel()
		<-served
	}
	t.Cleanup(func() { _ = c.Close(); stop() })
	return sock, c, stop
}

// startTune runs a live tune in the background and returns once out shows
// want; the caller cancels ctx and reads done.
func startTune(t *testing.T, sock, want string, args ...string) (out, errOut *syncBuffer, cancel context.CancelFunc, done <-chan error) {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	res := make(chan error, 1)
	out, errOut = &syncBuffer{}, &syncBuffer{}
	app := &App{Stdout: out, Stderr: errOut, LookupEnv: func(string) (string, bool) { return "", false }}
	go func() { res <- Execute(ctx, app, append([]string{"--socket", sock}, args...)) }()
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(out.String()+errOut.String(), want) {
		select {
		case err := <-res:
			t.Fatalf("tune exited before printing %q: %v\n%s\n%s", want, err, out.String(), errOut.String())
		case <-time.After(10 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			cancel()
			t.Fatalf("tune never printed %q:\n%s\n%s", want, out.String(), errOut.String())
		}
	}
	return out, errOut, cancel, res
}

// The daemon closing its streams (shutdown) ends a live tune cleanly with
// one stderr line, not "ley: EOF" and exit 1; the teardown that then fails
// says so and names the recovery.
func TestTuneDaemonClosesStreams(t *testing.T) {
	sock, _, stop := harnessStop(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	_, errOut, cancel, done := startTune(t, sock, " dBFS  ", "tune", "146.52", "--no-audio")
	defer cancel()
	stop()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("tune should end cleanly when the daemon closes its streams, got: %v\n%s", err, errOut.String())
		}
	case <-time.After(10 * time.Second):
		t.Fatal("tune did not exit after the daemon stopped")
	}
	got := errOut.String()
	if strings.Count(got, "the daemon closed the") != 1 || !strings.Contains(got, "ley daemon status") {
		t.Fatalf("want one stderr line about the closed stream:\n%s", got)
	}
	// Which destroy fails first depends on when the connection goes; at least the capture's does.
	if !strings.Contains(got, "warning: could not remove ") || !strings.Contains(got, "ley stop --all") {
		t.Fatalf("teardown failure must be reported with the recovery:\n%s", got)
	}
}

// A channel another client adds to this run's capture while it is live
// keeps the capture alive at teardown; the run says so.
func TestTeardownKeepsSharedCapture(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	_, errOut, cancel, done := startTune(t, sock, " dBFS  ", "tune", "146.52", "--no-audio")
	ctx := t.Context()
	st, err := c.State(ctx)
	if err != nil || len(st.Captures) != 1 {
		t.Fatalf("state: %v %v", err, st)
	}
	other, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: st.Captures[0].CaptureId, OffsetHz: 25_000, BandwidthHz: 12_500, Mode: leylinev1.DemodMode_NFM, Persistent: true})
	if err != nil {
		t.Fatal(err)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("tune: %v\n%s", err, errOut.String())
	}
	st, err = c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Captures) != 1 || len(st.Channels) != 1 || st.Channels[0].ChannelId != other.ChannelId {
		t.Fatalf("the other client's channel must survive teardown: %d captures, channels %v", len(st.Captures), st.Channels)
	}
	if !strings.Contains(errOut.String(), "leaving capture "+st.Captures[0].CaptureId) || !strings.Contains(errOut.String(), other.ChannelId) {
		t.Fatalf("stderr should say why the capture stays:\n%s", errOut.String())
	}
}

// A squelch below the daemon's floor is a usage error before any RPC, and a
// squelch the daemon rejects fails the tune and tears down what tune created
// rather than listening with the wrong squelch.
func TestTuneSquelchRejected(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{})
	_, errOut, err := run(t, t.Context(), sock, "tune", "146.52", "--no-audio", "--squelch", "-1000")
	if exitCode(err) != 2 || !strings.Contains(err.Error(), "-200 dBFS") {
		t.Fatalf("want usage error naming the floor, got %v (exit %d)\n%s", err, exitCode(err), errOut)
	}

	reject := func(w *leylinev1.ParamWrite) *leyline.Error {
		if _, ok := w.Param.(*leylinev1.ParamWrite_SquelchDb); ok {
			return &leyline.Error{Code: leyline.CodeInvalidArgument, Target: w.TargetId, Message: "squelch not available on this channel"}
		}
		return nil
	}
	sock, c := harness(t, fakedaemon.Options{RejectWrites: reject})
	for _, extra := range [][]string{nil, {"--persistent"}} {
		args := append([]string{"tune", "146.52", "--no-audio", "--squelch", "-40"}, extra...)
		out, errOut, err := run(t, t.Context(), sock, args...)
		if err == nil || exitCode(err) != 1 || !strings.Contains(err.Error(), "--squelch") || !strings.Contains(err.Error(), "squelch not available") {
			t.Fatalf("%v: want the rejection as a tune failure (exit 1), got %v\n%s\n%s", args, err, out, errOut)
		}
		if strings.Contains(out, "Listening to") {
			t.Fatalf("%v: must not start listening after a rejected squelch:\n%s", args, out)
		}
		st, serr := c.State(t.Context())
		if serr != nil {
			t.Fatal(serr)
		}
		if len(st.Channels) != 0 || len(st.Captures) != 0 {
			t.Fatalf("%v: rejected tune must tear down what it created: %d channels %d captures", args, len(st.Channels), len(st.Captures))
		}
	}
}

// A subscriber that arrives while the squelch is closed is not told a transmission just ended:
// the daemon forwards the edges the engine crossed, and there is no summary to give for an
// interval nobody watched.
func TestTuneReportsNoTransmissionItDidNotHear(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	// A squelch above anything the band does, so the channel is closed for the whole run.
	_, errOut, cancel, done := startTune(t, sock, " dBFS  ", "tune", "146.52", "--no-audio", "--squelch", "-20")
	time.Sleep(200 * time.Millisecond)
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("tune: %v\n%s", err, errOut.String())
	}
	if strings.Contains(errOut.String(), "transmission") {
		t.Errorf("a closed squelch has no transmission to report:\n%s", errOut.String())
	}
}
