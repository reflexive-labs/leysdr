// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

func TestStopChannelAndAll(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	state := func() *leylinev1.GetStateResponse {
		st, err := c.State(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		return st
	}
	// Nothing running: stop says so, stop --all is a no-op that says the radio is free.
	if _, _, err := run(t, t.Context(), sock, "stop"); err == nil || !strings.Contains(err.Error(), "nothing is playing") {
		t.Fatalf("stop with nothing running: %v", err)
	}
	if out, errOut, err := run(t, t.Context(), sock, "stop", "--all"); err != nil || out != "" || !strings.Contains(errOut, "nothing is running; every radio is free") {
		t.Fatalf("stop --all with nothing running: %v stdout=%q stderr=%q", err, out, errOut)
	}
	// Usage errors never reach the daemon.
	for _, args := range [][]string{{"stop", "--all", "2"}, {"stop", "2", "--device", "1"}, {"stop", "1", "2"}} {
		if _, _, err := run(t, t.Context(), sock, args...); exitCode(err) != ExitUsage {
			t.Errorf("ley %v: exit %d (%v), want %d", args, exitCode(err), err, ExitUsage)
		}
	}
	// One persistent channel: bare stop removes it and says how to free the radio.
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent")
	out := mustRun(t, sock, "stop")
	if !strings.Contains(out, "stopped 146.520 MHz NFM (channel 1, chan_") || !strings.Contains(out, "free it with: ley stop --all") {
		t.Fatalf("stop line: %s", out)
	}
	if st := state(); len(st.Channels) != 0 || len(st.Captures) != 1 {
		t.Fatalf("after stop: %d channels, %d captures", len(st.Channels), len(st.Captures))
	}
	// Two channels, one made by the app: bare stop picks ley's; selectors pick the rest.
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent")
	app, err := leyline.Dial(t.Context(), sock, leyline.WithKind("app"), leyline.WithLabel("Leyline.app"), leyline.WithClientID("app_stop"))
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	capID := state().Captures[0].CaptureId
	for _, off := range []int64{100_000, 200_000} {
		if _, err := app.Control.CreateChannel(t.Context(), &leylinev1.CreateChannelRequest{CaptureId: capID, OffsetHz: off, BandwidthHz: 12_500, Mode: leylinev1.DemodMode_NFM, Persistent: true}); err != nil {
			t.Fatal(err)
		}
	}
	out = mustRun(t, sock, "stop")
	if !strings.Contains(out, "using channel 1, 146.520 MHz NFM") || !strings.Contains(out, "stopped 146.520 MHz NFM (channel 1, chan_") || strings.Contains(out, "free it with") {
		t.Fatalf("stop target rule: %s", out)
	}
	if st := state(); len(st.Channels) != 2 {
		t.Fatalf("after stop: %d channels", len(st.Channels))
	}
	// Both remaining channels belong to the app: a numbered list, then a frequency selector.
	// The hint is stop's own (a bare number), not set's --channel flag.
	if _, _, err := run(t, t.Context(), sock, "stop"); err == nil || !strings.Contains(err.Error(), "2 channels are playing; pick one with its number N:") || !strings.Contains(err.Error(), "e.g. ley stop 2") || strings.Contains(err.Error(), "--channel") {
		t.Fatalf("stop ambiguity: %v", err)
	}
	if _, _, err := run(t, t.Context(), sock, "stop", "chan_nope"); err == nil || !strings.HasPrefix(err.Error(), "no channel matches") {
		t.Fatalf("stop bad selector prefix: %v", err)
	}
	if out = mustRun(t, sock, "stop", "146.72"); !strings.Contains(out, "stopped 146.720 MHz NFM (channel ") {
		t.Fatalf("stop by frequency: %s", out)
	}
	if _, _, err := run(t, t.Context(), sock, "stop", "150"); err == nil || !strings.Contains(err.Error(), "pick one:\n  1  chan_") {
		t.Fatalf("stop no-match rows: %v", err)
	}
	// stop all frees the radio: no channels, no capture.
	out = mustRun(t, sock, "stop", "all")
	if !strings.Contains(out, "stopped 1 channel and freed Generic RTL2832U (R820T) (dev_") {
		t.Fatalf("stop all: %s", out)
	}
	if st := state(); len(st.Channels) != 0 || len(st.Captures) != 0 {
		t.Fatalf("after stop all: %d channels, %d captures", len(st.Channels), len(st.Captures))
	}
	if out, errOut, err := run(t, t.Context(), sock, "stop", "--all", "--device", "1"); err != nil || out != "" || !strings.Contains(errOut, "nothing is running on Generic RTL2832U (R820T)") {
		t.Fatalf("stop --all on a free radio: %v stdout=%q stderr=%q", err, out, errOut)
	}
}

// TestStopJSON: under --json stop prints the daemon's Empty answer ({}) and
// nothing when there was nothing to do; the exit status carries success.
func TestStopJSON(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	// Idle: no object to echo, no prose on stdout, exit 0.
	for _, args := range [][]string{{"--json", "stop", "--all"}, {"--json", "stop", "all", "--device", "1"}} {
		out, errOut, err := run(t, t.Context(), sock, args...)
		if err != nil || out != "" || errOut != "" {
			t.Fatalf("idle ley %v: %v stdout=%q stderr=%q", args, err, out, errOut)
		}
	}
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent")
	if out := mustRun(t, sock, "--json", "stop"); out != "{}\n" {
		t.Fatalf("stop --json: %q", out)
	}
	if st, err := c.State(t.Context()); err != nil || len(st.Channels) != 0 || len(st.Captures) != 1 {
		t.Fatalf("after stop --json: %v %v", st, err)
	}
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent")
	if out := mustRun(t, sock, "--json", "stop", "--all"); out != "{}\n" {
		t.Fatalf("stop --all --json: %q", out)
	}
	if st, err := c.State(t.Context()); err != nil || len(st.Channels) != 0 || len(st.Captures) != 0 {
		t.Fatalf("after stop --all --json: %v %v", st, err)
	}
}
