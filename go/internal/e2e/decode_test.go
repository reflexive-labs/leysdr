// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"bufio"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The decoder tier end to end (docs/plans/decoders.md, DEC-7): the real daemon plays the AFSK
// fixture, spawns the real leydec-aprs plugin over the stdio contract, and `ley decode aprs`
// prints the three packets the fixture carries. LEYLINE_DECODERS must name the repository's
// decoders/ directory and leydec-aprs must be on PATH (the Makefile's e2e target sets both).
func TestDecodeAgainstRealDaemon(t *testing.T) {
	decoders := os.Getenv("LEYLINE_DECODERS")
	if decoders == "" {
		t.Skip("set LEYLINE_DECODERS to the repository's decoders/ directory (make e2e does)")
	}
	fixture, err := filepath.Abs("../../../fixtures/aprs_afsk.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	store := filepath.Join(t.TempDir(), "store")
	e, _ := setup(t, "--store", store, "--decoders", decoders)

	// The plugin is installed: the daemon read the manifest and found the binary.
	decs := parseJSON(t, e.mustRun("decoders", "--json"))
	var found bool
	for _, d := range list(decs, "decoders") {
		if d.(map[string]any)["name"] == "aprs" {
			found = true
		}
	}
	if !found {
		t.Fatalf("the daemon lists no aprs decoder: %v", decs)
	}

	// The fixture is centred on 144.39 MHz, so the decode job's recipe lands in play's capture.
	stopPlay, _ := e.startLive("play", fixture, "--no-audio", "--loop", "--json")
	defer func() { _ = stopPlay() }()
	e.waitChannels(1)

	out, err := e.run("decode", "aprs", "--json", "--count", "3")
	if err != nil {
		t.Fatalf("ley decode aprs: %v\nstdout: %s", err, out)
	}
	recs := ndjson(t, out)
	if len(recs) != 3 {
		t.Fatalf("want 3 records, got %d: %s", len(recs), out)
	}
	seen := map[string]bool{}
	for _, r := range recs {
		id, _ := r["deviceId"].(string)
		seen[id] = true
		if r["protocol"] != "aprs" || r["jobId"] == nil || r["channelId"] == nil || r["recordId"] == nil {
			t.Errorf("record lacks the daemon's stamps: %v", r)
		}
		if tm, _ := r["time"].(map[string]any); tm == nil || tm["captureId"] == nil {
			t.Errorf("record carries no sample time: %v", r)
		}
		// The fixture's carrier is -20 dBFS; the meter reads the channel power within a few dB.
		if rssi, ok := r["rssiDbfs"].(float64); !ok || math.Abs(rssi+20) > 6 {
			t.Errorf("rssi_dbfs %v is not near the fixture's -20 dBFS: %v", r["rssiDbfs"], r)
		}
	}
	for _, id := range []string{"LEYTST-1", "LEYTST-2", "LEYTST-3"} {
		if !seen[id] {
			t.Errorf("no record from %s: %v", id, seen)
		}
	}

	// The ephemeral job went with its client; the channel it made is gone.
	st := e.state()
	if chans := list(st, "channels"); len(chans) != 1 {
		t.Errorf("decode left a channel behind: %v", chans)
	}

	// A kept job outlives the client that started it, and its records are in the store.
	out = e.mustRun("decode", "aprs", "--job", "--json", "--count", "2")
	if len(ndjson(t, out)) != 2 {
		t.Fatalf("kept decode printed %q", out)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		page := parseJSON(t, e.mustRun("records", "--protocol", "aprs", "--json"))
		if len(list(page, "records")) >= 3 || time.Now().After(deadline) {
			if len(list(page, "records")) < 3 {
				t.Fatalf("the kept job's records are not in the store: %v", page)
			}
			if len(list(page, "anchors")) == 0 {
				t.Errorf("the page carries no anchors, so a client cannot place the records in time: %v", page)
			}
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	var running int
	for _, j := range list(e.state(), "jobs") {
		m := j.(map[string]any)
		if m["state"] == "RUNNING" {
			running++
			e.mustRun("jobs", "cancel", m["jobId"].(string))
		}
	}
	if running != 1 {
		t.Errorf("want the kept decode job still running after its client left, got %d running", running)
	}
	if files, _ := filepath.Glob(filepath.Join(store, "records", "*.records")); len(files) != 1 {
		t.Errorf("the store holds %d record files, want the kept job's one", len(files))
	}
}

// ndjson parses one JSON object per non-empty line.
func ndjson(t *testing.T, s string) []map[string]any {
	t.Helper()
	var out []map[string]any
	sc := bufio.NewScanner(strings.NewReader(s))
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("bad NDJSON line %q: %v", line, err)
		}
		out = append(out, m)
	}
	return out
}
