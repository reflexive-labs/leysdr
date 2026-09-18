// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// RecordingManifest is `recording.json`: what the daemon writes beside a
// recording's parts and what `ley recordings show` prints
// (docs/design/recording.md, "The manifest"). The daemon owns the format; this
// is the reader, so `ley` and the MCP adapter see the same document a person
// opens in Finder.
type RecordingManifest struct {
	JobID       string            `json:"job_id"`
	URI         string            `json:"uri"`
	Kind        string            `json:"kind"`
	FrequencyHz uint64            `json:"frequency_hz"`
	Mode        string            `json:"mode"`
	BandwidthHz uint32            `json:"bandwidth_hz"`
	SampleRate  uint64            `json:"sample_rate"`
	Format      string            `json:"format"`
	Device      *RecordingDevice  `json:"device,omitempty"`
	Gains       []RecordingGain   `json:"gains,omitempty"`
	SquelchDBFS *float64          `json:"squelch_dbfs,omitempty"`
	Gate        *RecordingGate    `json:"gate,omitempty"`
	PartMs      int64             `json:"part_ms"`
	StartedAtNS int64             `json:"started_at_ns"`
	EndedAtNS   int64             `json:"ended_at_ns"`
	EndedBy     string            `json:"ended_by"`
	CreatedBy   *RecordingClient  `json:"created_by,omitempty"`
	Anchors     []RecordingAnchor `json:"anchors,omitempty"`
	Parts       []RecordingPart   `json:"parts"`
	Gaps        []RecordingGap    `json:"coverage_gaps,omitempty"`
	Bytes       uint64            `json:"bytes"`
}

// RecordingDevice is the radio the recording was made on.
type RecordingDevice struct {
	Driver string `json:"driver"`
	Model  string `json:"model"`
	Serial string `json:"serial"`
}

// RecordingGain is one gain element and where it was pinned.
type RecordingGain struct {
	Element string  `json:"element"`
	ValueDB float64 `json:"value_db"`
}

// RecordingGate is what opened and closed the parts.
type RecordingGate struct {
	Kind      string `json:"kind"`
	PreRollMs uint32 `json:"pre_roll_ms"`
	HangMs    uint32 `json:"hang_ms"`
}

// RecordingClient is who asked for the recording.
type RecordingClient struct {
	ClientID string `json:"client_id"`
	Kind     string `json:"kind"`
	Label    string `json:"label"`
}

// RecordingAnchor dates one capture's samples. A recording that spans a detach
// and reattach spans two captures, and each part is dated by the anchor of its
// own (CLAUDE.md invariant 5).
type RecordingAnchor struct {
	CaptureID  string  `json:"capture_id"`
	HostTimeNS int64   `json:"host_time_ns"`
	SampleRate uint64  `json:"sample_rate"`
	DriftPPM   float64 `json:"drift_ppm"`
	FromSample uint64  `json:"from_sample"`
}

// RecordingPart is one file of a recording.
type RecordingPart struct {
	Part         int      `json:"part"`
	File         string   `json:"file"`
	StartSample  uint64   `json:"start_sample"`
	EndSample    uint64   `json:"end_sample"`
	Samples      uint64   `json:"samples"`
	Bytes        uint64   `json:"bytes"`
	PeakDBFS     *float64 `json:"peak_dbfs,omitempty"`
	MeanDBFS     *float64 `json:"mean_dbfs,omitempty"`
	SquelchOpens int      `json:"squelch_opens"`
}

// RecordingGap is time the recording does not cover, and why.
type RecordingGap struct {
	FromSample uint64 `json:"from_sample"`
	ToSample   uint64 `json:"to_sample"`
	Reason     string `json:"reason"`
}

// ReadRecordingManifest loads recording.json from a recording's directory. The
// path may name the directory or the manifest itself.
func ReadRecordingManifest(path string) (*RecordingManifest, error) {
	if filepath.Base(path) != "recording.json" {
		path = filepath.Join(path, "recording.json")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var m RecordingManifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

// DurationMs is how much signal the recording holds: the sum of its parts, not
// wall clock. A gated recording's gaps are not part of what it holds.
func (m *RecordingManifest) DurationMs() int64 {
	if m.SampleRate == 0 {
		return 0
	}
	var samples uint64
	for _, p := range m.Parts {
		samples += p.Samples
	}
	return int64(float64(samples) / float64(m.SampleRate) * 1000)
}

// SquelchOpens is how many times the squelch opened across the whole recording.
func (m *RecordingManifest) SquelchOpens() int {
	n := 0
	for _, p := range m.Parts {
		n += p.SquelchOpens
	}
	return n
}

// StartedAt is when the recording began, on the host clock.
func (m *RecordingManifest) StartedAt() time.Time {
	if m.StartedAtNS == 0 {
		return time.Time{}
	}
	return time.Unix(0, m.StartedAtNS)
}

// PartStartedAt is when a part's first sample was heard, derived from the
// anchor of the capture it sits on, as every time in ley is.
func (m *RecordingManifest) PartStartedAt(p RecordingPart) (time.Time, bool) {
	var chosen *RecordingAnchor
	for i := range m.Anchors {
		a := &m.Anchors[i]
		if a.SampleRate == 0 || a.FromSample > p.StartSample {
			continue
		}
		if chosen == nil || a.FromSample >= chosen.FromSample {
			chosen = a
		}
	}
	if chosen == nil {
		return time.Time{}, false
	}
	ns := float64(p.StartSample) / float64(chosen.SampleRate) * 1e9 * (1 + chosen.DriftPPM*1e-6)
	return time.Unix(0, chosen.HostTimeNS+int64(ns)), true
}
