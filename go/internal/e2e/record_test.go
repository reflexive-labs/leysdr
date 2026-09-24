// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Recording end to end (docs/design/recording.md): the real daemon plays the keyed fixture on a
// file device, `ley record --gate squelch` cuts one part per transmission, `ley recordings show
// --json` reads the manifest back, and `ley recordings path` names files that are really there.
//
// The fixture states its own keying, so the cuts are graded against what the generator wrote
// rather than against whatever the daemon happened to do.
func TestRecordAgainstRealDaemon(t *testing.T) {
	fixture, err := filepath.Abs("../../../fixtures/nfm_keyed.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	segments := keyedSegments(t, fixture)
	recordings := filepath.Join(t.TempDir(), "recordings")
	e, _ := setup(t, "--recordings", recordings)

	attachFixture(e, fixture)

	// The fixture is 10.5 s and keyed three times with 3 s of floor between, so a 1 s hang cuts
	// one part per transmission. 12 s covers the file and the last hang.
	out := e.mustRun("record", "146.62", "--gate", "squelch", "--squelch", "-40",
		"--hang", "1s", "--for", "12s")
	uri := strings.TrimSpace(out)
	if !strings.HasPrefix(uri, "ley://recordings/job_") {
		t.Fatalf("ley record printed %q, want the recording's uri", out)
	}
	jobID := strings.TrimPrefix(uri, "ley://recordings/")

	manifest := parseJSON(t, e.mustRun("recordings", "show", jobID, "--json"))
	if manifest["kind"] != "audio" || manifest["format"] != "wav-s16" || manifest["mode"] != "NFM" {
		t.Fatalf("manifest: %v", manifest)
	}
	if manifest["ended_by"] != "duration" {
		t.Errorf("ended_by: %v, want duration", manifest["ended_by"])
	}
	parts := list(manifest, "parts")
	if len(parts) != len(segments) {
		t.Fatalf("want %d parts (one per transmission), got %d: %v", len(segments), len(parts), manifest)
	}
	// Every part begins a pre-roll before its transmission did, on the capture's timeline.
	rate := anchorRate(t, manifest)
	for i, want := range segments {
		p := parts[i].(map[string]any)
		start := number(t, p, "start_sample")/rate + 0.5
		if math.Abs(start-want.StartS) > 0.2 {
			t.Errorf("part %d starts at %.2f s, the fixture keyed up at %.2f", i+1, start, want.StartS)
		}
		if number(t, p, "squelch_opens") != 1 {
			t.Errorf("part %d: %v overs, want 1 at this hang", i+1, p["squelch_opens"])
		}
	}
	// Unrecorded time between parts is listed as coverage gaps rather than padded into a file.
	if gaps := list(manifest, "coverage_gaps"); len(gaps) != len(segments)-1 {
		t.Errorf("want a gap between every pair of parts, got %d", len(gaps))
	}

	// The recording is a resource the daemon lists and can point at on disk.
	listed := parseJSON(t, e.mustRun("recordings", "--json"))
	resources := list(listed, "resources")
	if len(resources) != 1 || resources[0].(map[string]any)["uri"] != uri {
		t.Fatalf("ley recordings: %v", listed)
	}
	meta, _ := resources[0].(map[string]any)["metadata"].(map[string]any)
	if meta["mode"] != "NFM" || meta["parts"] != strconv.Itoa(len(parts)) {
		t.Errorf("the frozen metadata keys: %v", meta)
	}

	dir := strings.TrimSpace(e.mustRun("recordings", "path", jobID))
	if dir != filepath.Join(recordings, jobID) {
		t.Errorf("path: %q, want %q", dir, filepath.Join(recordings, jobID))
	}
	// Every part is a real WAV whose header agrees with its length.
	for i := range parts {
		p := parts[i].(map[string]any)
		file := strings.TrimSpace(e.mustRun("recordings", "path", jobID, "--part", strconv.Itoa(i+1)))
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("part %d: %v", i+1, err)
		}
		if string(data[:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
			t.Errorf("part %d is not a WAV: %q", i+1, data[:12])
		}
		declared := int(uint32(data[40]) | uint32(data[41])<<8 | uint32(data[42])<<16 | uint32(data[43])<<24)
		if declared != len(data)-44 {
			t.Errorf("part %d: the header says %d data bytes, the file holds %d", i+1, declared, len(data)-44)
		}
		if uint64(len(data)) != uint64(number(t, p, "bytes")) {
			t.Errorf("part %d: %d bytes on disk, the manifest says %v", i+1, len(data), p["bytes"])
		}
	}

	// An audio recording is a WAV, not a radio: ley play says so and names the path.
	if _, err := e.run("play", uri); err == nil || !strings.Contains(err.Error(), "audio recording") {
		t.Errorf("ley play on an audio recording: %v", err)
	}
}

// A carrier that never stops holds the squelch open from before the recording starts, so no
// transition arrives; the gate is seeded from the channel's meter and the recording is one part
// as long as the recording. Until 2026-09-25 it wrote nothing (docs/design/recording.md, "The
// gate").
func TestGatedRecordOfACarrierHoldsOnePart(t *testing.T) {
	fixture, err := filepath.Abs("../../../fixtures/nfm_tone.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	e, _ := setup(t, "--recordings", filepath.Join(t.TempDir(), "recordings"))
	attachFixture(e, fixture)

	// ley play attaches the fixture once through, and nfm_tone is 1 s long, so the recording is
	// shorter than the file.
	out := e.mustRun("record", "146.62", "--gate", "squelch", "--squelch", "-40", "--hang", "1s", "--for", "800ms")
	jobID := strings.TrimPrefix(strings.TrimSpace(out), "ley://recordings/")
	manifest := parseJSON(t, e.mustRun("recordings", "show", jobID, "--json"))
	parts := list(manifest, "parts")
	if len(parts) != 1 {
		t.Fatalf("want one part for a carrier that never stops, got %d: %v", len(parts), manifest)
	}
	p := parts[0].(map[string]any)
	rate := anchorRate(t, manifest)
	seconds := (number(t, p, "end_sample") - number(t, p, "start_sample")) / rate
	if math.Abs(seconds-0.8) > 0.2 {
		t.Errorf("the part is %.2f s long, want about the 0.8 s recorded: %v", seconds, manifest)
	}
	if number(t, p, "squelch_opens") != 1 {
		t.Errorf("%v overs, want the 1 already in progress", p["squelch_opens"])
	}
}

// An IQ recording is cut into parts that are contiguous on the sample timebase, and ley play
// tunes one back through the same file-device reader a fixture goes through.
func TestRecordIQRoundTripAgainstRealDaemon(t *testing.T) {
	fixture, err := filepath.Abs("../../../fixtures/nfm_tone.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v)", err)
	}
	recordings := filepath.Join(t.TempDir(), "recordings")
	e, _ := setup(t, "--recordings", recordings)
	attachFixture(e, fixture)

	// nfm_tone is one second long, so three parts of 300 ms is what fits inside it.
	uri := strings.TrimSpace(e.mustRun("record", "146.52", "--iq", "--part", "300ms", "--for", "1s"))
	jobID := strings.TrimPrefix(uri, "ley://recordings/")
	manifest := parseJSON(t, e.mustRun("recordings", "show", jobID, "--json"))
	if manifest["kind"] != "iq" || manifest["format"] != "cf32" {
		t.Fatalf("manifest: %v", manifest)
	}
	parts := list(manifest, "parts")
	if len(parts) < 3 {
		t.Fatalf("a part every 300 ms of a 1 s recording, got %d: %v", len(parts), manifest)
	}
	for i := 1; i < len(parts); i++ {
		prev, cur := parts[i-1].(map[string]any), parts[i].(map[string]any)
		if number(t, prev, "end_sample") != number(t, cur, "start_sample") {
			t.Errorf("parts %d and %d are not contiguous: %v %v", i, i+1, prev["end_sample"], cur["start_sample"])
		}
	}
	if gaps := list(manifest, "coverage_gaps"); len(gaps) != 0 {
		t.Errorf("a continuous recording covers everything it claims: %v", gaps)
	}
	// cf32 has no header: the file is exactly its samples.
	file := strings.TrimSpace(e.mustRun("recordings", "path", jobID, "--part", "1"))
	info, err := os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() != int64(number(t, parts[0].(map[string]any), "samples"))*8 {
		t.Errorf("%s: %d bytes for %v samples", file, info.Size(), parts[0].(map[string]any)["samples"])
	}

	// The round trip: the part plays back through the same reader a fixture does, and the
	// channel the daemon makes over it demodulates the fixture's tone.
	stop, _ := e.startLive("play", uri, "--part", "1", "--no-audio", "--mode", "nfm", "--freq", "146.62", "--json")
	defer func() { _ = stop() }()
	st := e.waitChannels(1)
	channel, _ := list(st, "channels")[0].(map[string]any)
	levels := ndjson(t, e.mustRun("levels", channel["channelId"].(string), "--count", "6", "--json"))
	if len(levels) == 0 {
		t.Fatal("ley levels heard nothing off the recorded part")
	}
	// The loudest band the meter reported: a recorded part that plays back silent would show a
	// noise floor and nothing above it.
	loudest := math.Inf(-1)
	for _, row := range levels {
		for _, b := range list(row, "bands") {
			if m, ok := b.(map[string]any); ok {
				if v, ok := m["db"].(float64); ok && v > loudest {
					loudest = v
				}
			}
		}
	}
	if loudest < -60 {
		t.Errorf("the recorded part plays back silent: loudest band %.1f dBFS", loudest)
	}
}

// attachFixture leaves the fixture attached as a radio with nothing tuned on it, so the next job
// creates the capture itself. That matters for a recording graded against the fixture's own
// clock: a file device restarts its file at sample 0 every time a capture opens it, so a capture
// the record job made is one whose sample 0 is the fixture's sample 0.
func attachFixture(e *env, fixture string) {
	e.t.Helper()
	e.mustRun("play", fixture, "--no-audio", "--persistent", "--json")
	e.mustRun("stop", "all")
	deadline := time.Now().Add(5 * time.Second)
	for {
		st := e.state()
		if len(list(st, "captures")) == 0 && len(list(st, "devices")) > 0 {
			return
		}
		if time.Now().After(deadline) {
			e.t.Fatalf("the fixture never became an idle radio: %v", st)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// keyedSegment is one transmission the fixture states it wrote.
type keyedSegment struct {
	StartS float64 `json:"start_s"`
	EndS   float64 `json:"end_s"`
}

// keyedSegments reads the fixture's own answer key. The fixture states when it was keyed, so a
// recording test grades the daemon against the generator rather than against itself.
func keyedSegments(t *testing.T, fixture string) []keyedSegment {
	t.Helper()
	raw, err := os.ReadFile(strings.TrimSuffix(fixture, filepath.Ext(fixture)) + ".json")
	if err != nil {
		t.Skipf("the fixture's sidecar is missing (%v)", err)
	}
	var sidecar struct {
		Expect []struct {
			Record *struct {
				Segments []keyedSegment `json:"segments"`
			} `json:"record"`
		} `json:"expect"`
	}
	if err := json.Unmarshal(raw, &sidecar); err != nil {
		t.Fatalf("the fixture's sidecar: %v", err)
	}
	if len(sidecar.Expect) == 0 || sidecar.Expect[0].Record == nil {
		t.Skip("nfm_keyed carries no record expectation; regenerate the fixtures")
	}
	return sidecar.Expect[0].Record.Segments
}

// anchorRate is the capture rate the manifest's sample indices are counted at.
func anchorRate(t *testing.T, manifest map[string]any) float64 {
	t.Helper()
	for _, a := range list(manifest, "anchors") {
		if m, ok := a.(map[string]any); ok {
			if r, ok := m["sample_rate"].(float64); ok && r > 0 {
				return r
			}
		}
	}
	t.Fatalf("the manifest carries no anchor: %v", manifest)
	return 0
}

// number reads a numeric field the manifest carries, failing rather than defaulting to zero.
func number(t *testing.T, m map[string]any, key string) float64 {
	t.Helper()
	v, ok := m[key].(float64)
	if !ok {
		t.Fatalf("%s is not a number in %v", key, m)
	}
	return v
}
