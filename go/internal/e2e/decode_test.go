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

// The decoder tier end to end: the real daemon plays the AFSK
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

// A watch with a predicate and a notifier end to end: the real daemon decodes a SAME weather
// alert, a predicate keeps only the county asked for, and a shell notifier fires with the record.
// A non-matching county fires nothing.
func TestWatchSameCountyAgainstRealDaemon(t *testing.T) {
	decoders := os.Getenv("LEYLINE_DECODERS")
	if decoders == "" {
		t.Skip("set LEYLINE_DECODERS to the repository's decoders/ directory (make e2e does)")
	}
	fixture, err := filepath.Abs("../../../fixtures/same_alert.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	e, _ := setup(t, "--store", filepath.Join(t.TempDir(), "store"), "--decoders", decoders)

	stopPlay, _ := e.startLive("play", fixture, "--no-audio", "--loop", "--json")
	defer func() { _ = stopPlay() }()
	e.waitChannels(1)

	// The alert names Kansas FIPS 20103 and 20209; a watch on 20103 sees it, one on a Texas county
	// does not. The shell notifier appends the event code to a file, so a match is a line and a
	// miss is an empty file.
	hit := filepath.Join(t.TempDir(), "hit.txt")
	out, err := e.run("watch", "same", "--county", "20103",
		"--notify=shell:printf %s\\\\n \"$LEYLINE_DEVICE_ID\" >> "+hit,
		"--json", "--count", "1")
	if err != nil {
		t.Fatalf("ley watch same: %v\nstdout: %s", err, out)
	}
	recs := ndjson(t, out)
	if len(recs) != 1 {
		t.Fatalf("want one matching alert, got %d: %s", len(recs), out)
	}
	rec := recs[0]
	if rec["protocol"] != "same" || rec["kind"] != "alert" {
		t.Errorf("not a SAME alert: %v", rec)
	}
	fields, _ := rec["fields"].(map[string]any)
	if fips, _ := fields["fips"].(map[string]any); fips == nil || !strings.Contains(fips["text"].(string), "20103") {
		t.Errorf("the alert does not name the county watched: %v", fields)
	}
	if v, _ := rec["validity"].(map[string]any); v == nil || v["endNs"] == nil {
		t.Errorf("a SAME alert carries a validity window: %v", rec)
	}
	// The notifier fired for the match.
	deadline := time.Now().Add(3 * time.Second)
	for {
		b, _ := os.ReadFile(hit)
		if strings.Contains(string(b), "KEAX/NWS") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the shell notifier did not fire for the matching county (file: %q)", string(b))
		}
		time.Sleep(100 * time.Millisecond)
	}

	// A county the alert does not name: no record within a bounded wait, and no notifier fires.
	miss := filepath.Join(t.TempDir(), "miss.txt")
	ctxOut, _ := e.runFor(6*time.Second, "watch", "same", "--county", "48113",
		"--notify=shell:printf hit >> "+miss, "--json", "--count", "1")
	if n := len(ndjson(t, ctxOut)); n != 0 {
		t.Errorf("a non-matching county still delivered %d records: %s", n, ctxOut)
	}
	if b, _ := os.ReadFile(miss); len(b) != 0 {
		t.Errorf("the notifier fired for a county the alert does not name: %q", string(b))
	}
}

// The AIS decoder end to end: the real daemon decodes the marine GMSK
// fixture into vessel records keyed by MMSI, with positions.
func TestDecodeAISAgainstRealDaemon(t *testing.T) {
	decoders := os.Getenv("LEYLINE_DECODERS")
	if decoders == "" {
		t.Skip("set LEYLINE_DECODERS to the repository's decoders/ directory (make e2e does)")
	}
	fixture, err := filepath.Abs("../../../fixtures/ais_burst.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	e, _ := setup(t, "--store", filepath.Join(t.TempDir(), "store"), "--decoders", decoders)
	stopPlay, _ := e.startLive("play", fixture, "--no-audio", "--loop", "--json")
	defer func() { _ = stopPlay() }()
	e.waitChannels(1)

	out, err := e.run("decode", "ais", "--json", "--count", "2")
	if err != nil {
		t.Fatalf("ley decode ais: %v\nstdout: %s", err, out)
	}
	recs := ndjson(t, out)
	if len(recs) != 2 {
		t.Fatalf("want 2 vessel records, got %d: %s", len(recs), out)
	}
	for _, r := range recs {
		if r["protocol"] != "ais" {
			t.Errorf("not an AIS record: %v", r)
		}
		if id, _ := r["deviceId"].(string); id == "" {
			t.Errorf("an AIS record must carry the MMSI as device_id: %v", r)
		}
		pos, _ := r["position"].(map[string]any)
		if pos == nil || pos["latitude"] == nil || pos["longitude"] == nil {
			t.Errorf("a position report must carry a position: %v", r)
		}
	}
}

// The IQ input path end to end: a decoder whose manifest declares signal IQ receives the capture's
// raw baseband. leydec-iqstat reports the block power, which on the -20 dBFS nfm_tone fixture must
// read near -20; the record carries no channel and NaN rssi/snr, as an IQ record does.
func TestIQDecoderAgainstRealDaemon(t *testing.T) {
	decoders := os.Getenv("LEYLINE_DECODERS")
	if decoders == "" {
		t.Skip("set LEYLINE_DECODERS to the repository's decoders/ directory (make e2e does)")
	}
	fixture, err := filepath.Abs("../../../fixtures/nfm_tone.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	e, _ := setup(t, "--store", filepath.Join(t.TempDir(), "store"), "--decoders", decoders)
	stopPlay, _ := e.startLive("play", fixture, "--no-audio", "--loop", "--json")
	defer func() { _ = stopPlay() }()
	e.waitChannels(1)

	// The fixture plays at 146.62 MHz; iqstat runs on that capture's raw IQ regardless of its own
	// recipe frequency.
	out, err := e.run("decode", "iqstat", "--freq", "146.62", "--json", "--count", "1")
	if err != nil {
		t.Fatalf("ley decode iqstat: %v\nstdout: %s", err, out)
	}
	recs := ndjson(t, out)
	if len(recs) != 1 {
		t.Fatalf("want 1 iqstat record, got %d: %s", len(recs), out)
	}
	r := recs[0]
	if r["protocol"] != "iqstat" {
		t.Fatalf("not an iqstat record: %v", r)
	}
	if r["channelId"] != nil && r["channelId"] != "" {
		t.Errorf("an IQ record has no channel: %v", r["channelId"])
	}
	fields, _ := r["fields"].(map[string]any)
	pw, _ := fields["power_dbfs"].(map[string]any)
	if pw == nil {
		t.Fatalf("iqstat must report power_dbfs: %v", r)
	}
	if v, ok := pw["number"].(float64); !ok || math.Abs(v+20) > 3 {
		t.Errorf("power_dbfs %v is not near the fixture's -20 dBFS", pw["number"])
	}
}
