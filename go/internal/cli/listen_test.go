// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

// TestListenRowsAndTeardown: `ley listen <freq>` makes its own capture and
// channel, streams the documented audio rows and removes both on exit;
// stdout carries the rows alone (the stream note is stderr prose).
func TestListenRowsAndTeardown(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, context.Background(), sock, "listen", "146.52M", "--count", "3")
	if err != nil {
		t.Fatalf("ley listen: %v\nstderr: %s", err, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 3 {
		t.Fatalf("want 3 rows, got %d:\n%s", len(lines), out)
	}
	var rate uint32
	for i, l := range lines {
		var row AudioRow
		if err := json.Unmarshal([]byte(l), &row); err != nil {
			t.Fatalf("row %d %q: %v", i, l, err)
		}
		if row.SampleRate == 0 || row.Format != "S16" || len(row.PCM) == 0 {
			t.Fatalf("row %d shape: rate %d format %q pcm %d bytes", i, row.SampleRate, row.Format, len(row.PCM))
		}
		if rate == 0 {
			rate = row.SampleRate
		} else if row.SampleRate != rate {
			t.Fatalf("row %d changed the rate: %d != %d", i, row.SampleRate, rate)
		}
	}
	if !strings.Contains(errOut, "146.520 MHz NFM") || !strings.Contains(errOut, "S16") {
		t.Fatalf("the stream note belongs on stderr: %q", errOut)
	}
	st, serr := c.State(context.Background())
	if serr != nil {
		t.Fatal(serr)
	}
	if len(st.Captures) != 0 || len(st.Channels) != 0 {
		t.Fatalf("listen left %d captures and %d channels behind", len(st.Captures), len(st.Channels))
	}
}

// TestListenBinFrames: --format bin writes the raw PCM frames and nothing
// else, so the byte count is a whole number of S16 samples.
func TestListenBinFrames(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	one, errOut, err := run(t, context.Background(), sock, "listen", "noaa", "--format", "bin", "--count", "1")
	if err != nil {
		t.Fatalf("ley listen --format bin: %v\nstderr: %s", err, errOut)
	}
	if len(one) == 0 || len(one)%2 != 0 {
		t.Fatalf("one S16 frame should be a whole number of samples, got %d bytes", len(one))
	}
	if strings.Contains(one, "Ctrl-C stops") {
		t.Fatalf("prose leaked into the binary stream")
	}
	if !strings.Contains(errOut, "162.550 MHz NFM") {
		t.Fatalf("preset not resolved on stderr: %q", errOut)
	}
	two, errOut, err := run(t, context.Background(), sock, "listen", "noaa", "--format", "bin", "--count", "2")
	if err != nil {
		t.Fatalf("ley listen --format bin --count 2: %v\nstderr: %s", err, errOut)
	}
	if len(two) != 2*len(one) {
		t.Fatalf("two frames should be twice one: %d vs %d bytes", len(two), len(one))
	}
	// --format bin and --json ask for different stdout: that is a usage error,
	// not a silent choice.
	if _, _, err := run(t, context.Background(), sock, "--json", "listen", "noaa", "--format", "bin"); exitCode(err) != ExitUsage {
		t.Fatalf("--json with --format bin: exit %d err %v", exitCode(err), err)
	}
}

// TestListenExistingChannel: a channel id taps what someone else made and
// leaves it running; the tune flags are refused there.
func TestListenExistingChannel(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	mustRun(t, sock, "tune", "146.52M", "--no-audio", "--persistent")
	st, err := c.State(context.Background())
	if err != nil || len(st.Channels) != 1 {
		t.Fatalf("state after tune --persistent: %v %v", err, st)
	}
	id := st.Channels[0].ChannelId
	out := mustRun(t, sock, "listen", id, "--count", "1")
	var row AudioRow
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &row); err != nil {
		t.Fatalf("row %q: %v", out, err)
	}
	st, err = c.State(context.Background())
	if err != nil || len(st.Channels) != 1 || st.Channels[0].ChannelId != id {
		t.Fatalf("listen must leave a channel it did not make: %v %v", err, st)
	}
	_, _, err = run(t, context.Background(), sock, "listen", id, "--mode", "am")
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "--mode cannot be used with a channel id") {
		t.Fatalf("tune flags on a channel id: exit %d err %v", exitCode(err), err)
	}
}

// TestListenUsage: the argument is required and --format is checked before
// anything is sent to the daemon.
func TestListenUsage(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"listen"}, "listen needs a frequency, preset or channel id"},
		{[]string{"listen", "146.52", "--format", "wav"}, "--format must be json or bin"},
		{[]string{"listen", "nonsuch"}, "no preset called"},
	} {
		out, _, err := run(t, context.Background(), sock, tc.args...)
		if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("ley %v: exit %d err %v, want %d containing %q", tc.args, exitCode(err), err, ExitUsage, tc.want)
		}
		if out != "" {
			t.Errorf("ley %v: stdout should be empty, got %q", tc.args, out)
		}
	}
}

// shortDisk accepts whole rows until it has taken two of them and fails from
// then on, standing in for a full disk or a pipe whose reader has gone.
type shortDisk struct {
	rows int
}

func (d *shortDisk) Write(p []byte) (int, error) {
	if d.rows >= 2 {
		return 0, errors.New("no space left on device")
	}
	d.rows += bytes.Count(p, []byte{'\n'})
	return len(p), nil
}

// TestListenReportsAWriteFailureOnTheLastRow: the row that --count stops on is
// only flushed as the command returns, so a write that fails there must still
// be the command's error -- a script that trusts the exit status would
// otherwise keep a truncated file.
func TestListenReportsAWriteFailureOnTheLastRow(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	// Rows one and two are flushed inside the loop and land; the third is
	// still buffered when the loop returns, so its deferred flush is the
	// write that fails.
	disk := &shortDisk{}
	var errb bytes.Buffer
	app := &App{Stdout: disk, Stderr: &errb, LookupEnv: func(string) (string, bool) { return "", false }}
	err := Execute(context.Background(), app, []string{"--socket", sock, "listen", "146.52M", "--count", "3"})
	if err == nil {
		t.Fatalf("a failed write must not exit 0; stderr: %s", errb.String())
	}
	if !strings.Contains(err.Error(), "no space left on device") {
		t.Fatalf("want the write failure, got %v", err)
	}
}
