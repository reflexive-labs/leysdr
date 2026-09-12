// SPDX-License-Identifier: Apache-2.0

// Package iqfile reads and writes Leyline IQ files: raw interleaved samples
// (.cf32 little-endian float32 I/Q, or .cu8 offset-binary) plus a JSON
// sidecar describing the recording. See docs/reference/iq-files.md for the format.
package iqfile

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Format names for Sidecar.Format.
const (
	FormatCF32 = "cf32"
	FormatCU8  = "cu8"
)

// Anchor ties sample 0 to the host wall clock.
type Anchor struct {
	// HostTimeNS is the wall clock (unix ns) of sample 0; 0 for synthetic fixtures.
	HostTimeNS int64 `json:"host_time_ns"`
	// DriftPPM is the measured clock drift of the source, parts per million.
	DriftPPM float64 `json:"drift_ppm"`
}

// AudioExpect describes the demodulated-audio assertion of an Expect entry.
type AudioExpect struct {
	// ToneHz is the dominant spectral peak the demodulated audio must show.
	ToneHz float64 `json:"tone_hz"`
	// MinSNRDB is the minimum peak power over the rest of the audio band, dB.
	MinSNRDB float64 `json:"min_snr_db"`
}

// MeterExpect describes the meter assertion of an Expect entry.
type MeterExpect struct {
	// PowerDBFSMin is the minimum post-filter channel power in dBFS.
	PowerDBFSMin *float64 `json:"power_dbfs_min,omitempty"`
	// PowerDBFSMax is the maximum post-filter channel power in dBFS.
	PowerDBFSMax *float64 `json:"power_dbfs_max,omitempty"`
	// SquelchOpen is whether squelch must be open at the reference threshold (-40 dBFS).
	SquelchOpen *bool `json:"squelch_open,omitempty"`
}

// Expect describes one channel to create on a capture of the file and what
// its demodulated audio and meters must satisfy.
type Expect struct {
	Mode        string       `json:"mode"`
	OffsetHz    float64      `json:"offset_hz"`
	BandwidthHz float64      `json:"bandwidth_hz"`
	Audio       *AudioExpect `json:"audio,omitempty"`
	Meter       *MeterExpect `json:"meter,omitempty"`
	SubAudible  *SubExpect   `json:"sub_audible,omitempty"`
}

// SubExpect is what a sub-audible detector should say about a fixture. It is
// the record that keeps a detector honest: a fixture carrying no tone, or one
// carrying a tone too weak to call, states so here, and a detector that
// reports one anyway has failed rather than merely disagreed.
type SubExpect struct {
	// ToneHz is the tone actually present, 0 for none.
	ToneHz float64 `json:"tone_hz"`
	// DeviationHz is the peak deviation the tone was generated at.
	DeviationHz float64 `json:"deviation_hz,omitempty"`
	// Detect is whether a detector is expected to report a tone at all. A
	// fixture can carry one and still expect false -- sub-audible energy below
	// the plausible deviation for CTCSS is hum, not a tone, and calling it a
	// tone is the failure mode this exists to catch.
	Detect bool `json:"detect"`
	// Why records the reason when Detect disagrees with ToneHz being present.
	Why string `json:"why,omitempty"`
}

// Sidecar is the JSON document stored beside the sample file.
type Sidecar struct {
	Format      string            `json:"format"`
	SampleRate  float64           `json:"sample_rate"`
	CenterHz    float64           `json:"center_hz"`
	Samples     int64             `json:"samples,omitempty"`
	CreatedAtNS int64             `json:"created_at_ns"`
	Anchor      Anchor            `json:"anchor"`
	Description string            `json:"description,omitempty"`
	Generator   json.RawMessage   `json:"generator,omitempty"`
	Expect      []Expect          `json:"expect,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`
}

// Validate checks the required fields.
func (s *Sidecar) Validate() error {
	switch s.Format {
	case FormatCF32, FormatCU8:
	case "":
		return errors.New("iqfile: sidecar missing format")
	default:
		return fmt.Errorf("iqfile: unsupported format %q", s.Format)
	}
	if s.SampleRate <= 0 {
		return errors.New("iqfile: sidecar sample_rate must be positive")
	}
	return nil
}

// BytesPerSample returns the on-disk size of one complex sample for the format.
func BytesPerSample(format string) int {
	switch format {
	case FormatCU8:
		return 2
	default:
		return 8
	}
}

// ReadSidecar loads and validates the sidecar at path. path may name the
// sidecar itself or the sample file; either is resolved via SidecarPath.
func ReadSidecar(path string) (*Sidecar, error) {
	data, err := os.ReadFile(SidecarPath(path))
	if err != nil {
		return nil, err
	}
	var s Sidecar
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("iqfile: parse sidecar: %w", err)
	}
	if err := s.Validate(); err != nil {
		return nil, err
	}
	return &s, nil
}

// WriteSidecar writes s (pretty-printed) to the sidecar path derived from path.
func WriteSidecar(path string, s *Sidecar) error {
	if err := s.Validate(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(SidecarPath(path), append(data, '\n'), 0o644)
}

// SidecarPath maps a .cf32/.cu8/.json path to its sidecar (.json) path.
func SidecarPath(path string) string {
	return stripExt(path) + ".json"
}

// SamplesPath maps a .cf32/.cu8/.json path to the sample file path. When
// given a .json path, the extension is chosen from format (cf32 by default).
func SamplesPath(path, format string) string {
	ext := strings.ToLower(filepath.Ext(path))
	if ext == ".cf32" || ext == ".cu8" {
		return path
	}
	if format == FormatCU8 {
		return stripExt(path) + ".cu8"
	}
	return stripExt(path) + ".cf32"
}

func stripExt(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".cf32", ".cu8", ".json":
		return strings.TrimSuffix(path, filepath.Ext(path))
	}
	return path
}
