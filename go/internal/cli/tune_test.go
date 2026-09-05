package cli

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func TestTunePersistent(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "tune", "146.52M", "--no-audio", "--persistent")
	if !strings.Contains(out, "capture cap_") || !strings.Contains(out, "channel chan_") || strings.Contains(out, "sink") {
		t.Fatalf("persistent output:\n%s", out)
	}
	st, err := c.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Captures) != 1 || len(st.Channels) != 1 || !st.Channels[0].Persistent {
		t.Fatalf("state after persistent tune: %v", st)
	}
	if st.Captures[0].CenterHz != 146_520_000 || st.Channels[0].OffsetHz != 0 || leyline.ModeName(st.Channels[0].Mode) != "nfm" {
		t.Fatalf("channel: %v", st.Channels[0])
	}
	// A second persistent tune inside the span reuses the capture with an offset.
	out = mustRun(t, sock, "--json", "tune", "146.6M", "--no-audio", "--persistent", "--mode", "am", "--squelch", "-50")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("json persistent lines: %s", out)
	}
	var ch map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &ch); err != nil || ch["offsetHz"] != "80000" || ch["mode"] != "AM" {
		t.Fatalf("json channel: %v %s", err, lines[1])
	}
	st, _ = c.State(context.Background())
	if len(st.Captures) != 1 || len(st.Channels) != 2 {
		t.Fatalf("expected capture reuse: %d captures %d channels", len(st.Captures), len(st.Channels))
	}
	// Out of span: the capture is retuned and the run reports it.
	out = mustRun(t, sock, "tune", "150M", "--no-audio", "--persistent")
	if !strings.Contains(out, "retuning capture") {
		t.Fatalf("expected retune notice:\n%s", out)
	}
	st, _ = c.State(context.Background())
	if st.Captures[0].CenterHz != 150_000_000 {
		t.Fatalf("capture not retuned: %d", st.Captures[0].CenterHz)
	}
}

func TestTuneLifecycle(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	var out string
	go func() {
		o, _, err := run(t, ctx, sock, "tune", "146.52M", "--no-audio", "--squelch", "-40")
		out = o
		done <- err
	}()
	// Wait for the channel to exist and a meter to be printed.
	deadline := time.Now().Add(5 * time.Second)
	for {
		st, err := c.State(context.Background())
		if err == nil && len(st.Channels) == 1 && len(st.Captures) == 1 && !st.Channels[0].Persistent {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("channel never appeared")
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(150 * time.Millisecond)
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("tune returned error on cancel: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("tune did not exit after cancel")
	}
	if !strings.Contains(out, "dBFS") || !strings.Contains(out, "NFM") {
		t.Fatalf("no meter line printed:\n%s", out)
	}
	st, err := c.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Channels) != 0 || len(st.Captures) != 0 {
		t.Fatalf("expected teardown, got %d channels %d captures", len(st.Channels), len(st.Captures))
	}
}

func TestTuneJSONMeter(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	out, _, err := run(t, ctx, sock, "--json", "tune", "146.52M", "--no-audio")
	if err != nil {
		t.Fatal(err)
	}
	var sawMeter bool
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("bad NDJSON line %q: %v", line, err)
		}
		if m["meter"] != nil {
			sawMeter = true
		}
	}
	if !sawMeter {
		t.Fatalf("no meter JSON:\n%s", out)
	}
}
