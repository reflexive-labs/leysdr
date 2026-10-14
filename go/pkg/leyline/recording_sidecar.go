// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// RecordingSidecar is the subset of a recording part's sidecar that says
// when the squelch was open (docs/design/recording.md, "The part sidecar"):
// the anchor, whose rate the sample indices count in, and the part's
// squelch_opens.
type RecordingSidecar struct {
	SampleRate uint64          `json:"sample_rate"`
	Anchor     SidecarAnchor   `json:"anchor"`
	Recording  SidecarPartInfo `json:"recording"`
}

// SidecarAnchor is the capture's anchor as a part's sidecar carries it.
type SidecarAnchor struct {
	CaptureID  string  `json:"capture_id"`
	HostTimeNS int64   `json:"host_time_ns"`
	SampleRate uint64  `json:"sample_rate"`
	DriftPPM   float64 `json:"drift_ppm"`
}

// SidecarPartInfo is the sidecar's recording block.
type SidecarPartInfo struct {
	Part         int           `json:"part"`
	StartSample  uint64        `json:"start_sample"`
	EndSample    uint64        `json:"end_sample"`
	SquelchOpens []SquelchOpen `json:"squelch_opens"`
}

// SquelchOpen is one open-and-close of the squelch inside a part, on the
// capture's timeline at the capture rate.
type SquelchOpen struct {
	OpenSample  uint64 `json:"open_sample"`
	CloseSample uint64 `json:"close_sample"`
}

// ReadPartSidecar loads the sidecar beside one part of the recording in dir:
// the part's file name with .json for its extension.
func ReadPartSidecar(dir string, p RecordingPart) (*RecordingSidecar, error) {
	path := filepath.Join(dir, strings.TrimSuffix(p.File, filepath.Ext(p.File))+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var sc RecordingSidecar
	if err := json.Unmarshal(data, &sc); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &sc, nil
}

// SquelchOpenTime is how long the squelch was open across the whole
// recording in dir, which is the audio a speech decoder is sent. Each part
// gives its squelch_open_ms when the manifest has it; a part from a recording
// made before that key existed is summed from its sidecar's squelch_opens,
// counted at the rate of the sidecar's anchor.
func (m *RecordingManifest) SquelchOpenTime(dir string) (time.Duration, error) {
	var total time.Duration
	for _, p := range m.Parts {
		if p.SquelchOpenMs != nil {
			total += time.Duration(*p.SquelchOpenMs) * time.Millisecond
			continue
		}
		sc, err := ReadPartSidecar(dir, p)
		if err != nil {
			return 0, fmt.Errorf("part %d has no squelch_open_ms and its sidecar could not be read: %w", p.Part, err)
		}
		rate := sc.Anchor.SampleRate
		if rate == 0 {
			rate = anchorRateFor(m, p)
		}
		if rate == 0 {
			return 0, fmt.Errorf("part %d's sidecar gives no capture rate to count its squelch openings in", p.Part)
		}
		var samples uint64
		for _, o := range sc.Recording.SquelchOpens {
			if o.CloseSample > o.OpenSample {
				samples += o.CloseSample - o.OpenSample
			}
		}
		total += time.Duration(float64(samples) / float64(rate) * float64(time.Second))
	}
	return total, nil
}

// anchorRateFor is the capture rate of the manifest anchor a part's samples are
// counted on, or 0 when the manifest has none.
func anchorRateFor(m *RecordingManifest, p RecordingPart) uint64 {
	var rate, from uint64
	for _, a := range m.Anchors {
		if a.SampleRate > 0 && a.FromSample <= p.StartSample && a.FromSample >= from {
			rate, from = a.SampleRate, a.FromSample
		}
	}
	return rate
}
