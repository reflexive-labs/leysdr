// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A part with squelch_open_ms counts it; a part without sums its sidecar's openings at the
// anchor's capture rate, as a recording from an older daemon has to be counted.
func TestSquelchOpenTime(t *testing.T) {
	dir := t.TempDir()
	sidecar := `{"format": "wav-s16", "sample_rate": 48000,
	  "anchor": {"capture_id": "cap_1", "host_time_ns": 1, "sample_rate": 2400000, "drift_ppm": 0},
	  "recording": {"part": 2, "squelch_opens": [
	    {"open_sample": 2400000, "close_sample": 4800000},
	    {"open_sample": 6000000, "close_sample": 7200000}]}}`
	if err := os.WriteFile(filepath.Join(dir, "p2.json"), []byte(sidecar), 0o644); err != nil {
		t.Fatal(err)
	}
	ms := int64(1500)
	m := &RecordingManifest{Parts: []RecordingPart{
		{Part: 1, File: "p1.wav", SquelchOpenMs: &ms},
		{Part: 2, File: "p2.wav"},
	}}
	got, err := m.SquelchOpenTime(dir)
	if err != nil {
		t.Fatal(err)
	}
	if want := 1500*time.Millisecond + 1500*time.Millisecond; got != want {
		t.Errorf("SquelchOpenTime = %v, want %v", got, want)
	}

	m.Parts = append(m.Parts, RecordingPart{Part: 3, File: "p3.wav"})
	if _, err := m.SquelchOpenTime(dir); err == nil {
		t.Error("a part with neither the key nor a sidecar was counted as silence")
	}
}
