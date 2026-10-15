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

// Segments is the daemon's Segmenter.cut: a re-opening inside the hang continues the segment
// and keeps its first over's number, a pre-roll never reaches before the part or the previous
// segment, and the last segment stops at the part's end.
func TestSegments(t *testing.T) {
	opens := []SquelchOpen{{1000, 2000}, {2300, 2500}, {2600, 3000}, {9000, 9900}}
	got := Segments(opens, 500, 10_000, 600, 400)
	want := []OverSpan{
		{Start: 500, End: 3400, First: 1, Last: 3},
		{Start: 8400, End: 10_000, First: 4, Last: 4},
	}
	if len(got) != len(want) {
		t.Fatalf("Segments = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("segment %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	// The pre-roll stops at the previous segment's end.
	near := Segments([]SquelchOpen{{1000, 2000}, {2500, 3000}}, 0, 10_000, 1000, 400)
	if len(near) != 2 || near[1].Start != 2400 {
		t.Errorf("a pre-roll reached into the segment before: %+v", near)
	}
}

// OverRange plays the segment that holds the over, at the recording's pre-roll and the
// decoder's half-second hang, and says how many overs a part has when asked for one it lacks.
func TestOverRange(t *testing.T) {
	m := &RecordingManifest{SampleRate: 48000, Gate: &RecordingGate{Kind: "squelch", PreRollMs: 500, HangMs: 5000}}
	p := RecordingPart{Part: 1, StartSample: 0, EndSample: 6000 * 2400, Samples: 6 * 48000}
	ms := func(v uint64) uint64 { return v * 2400 }
	sc := &RecordingSidecar{Anchor: SidecarAnchor{SampleRate: 2_400_000}, Recording: SidecarPartInfo{SquelchOpens: []SquelchOpen{
		{ms(600), ms(1600)}, {ms(1900), ms(2500)}, {ms(4000), ms(5000)},
	}}}
	for over, want := range map[int][2]uint64{1: {ms(100), ms(3000)}, 2: {ms(100), ms(3000)}, 3: {ms(3500), ms(5500)}} {
		start, end, err := m.OverRange(sc, p, over)
		if err != nil || start != want[0] || end != want[1] {
			t.Errorf("over %d = %d..<%d (%v), want %d..<%d", over, start, end, err, want[0], want[1])
		}
	}
	if _, _, err := m.OverRange(sc, p, 4); err == nil || err.Error() != "part 1 has 3 overs; choose one from 1 to 3" {
		t.Errorf("over 4 of 3: %v", err)
	}
	if _, _, err := m.OverRange(&RecordingSidecar{}, p, 1); err == nil {
		t.Error("a part with no openings had an over")
	}
}
