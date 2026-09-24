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

// DecodeExpect describes what a decoder run over the channel must produce. It
// is what a fixture carrying a data mode asserts instead of a tone: the
// protocol whose plugin is expected to read it, how many records it holds, and
// which transmitters they come from (docs/plans/decoders.md, DEC-3).
type DecodeExpect struct {
	// Protocol is the decoder manifest's name, which is also DecodeRecord.protocol.
	Protocol string `json:"protocol"`
	// Records is how many records the file yields, exactly.
	Records int `json:"records"`
	// DeviceIDs are the DecodeRecord.device_id values expected, in the order
	// the fixture transmits them.
	DeviceIDs []string `json:"device_ids,omitempty"`
}

// RecordSegment is one keyed transmission in a fixture, in seconds from the
// start of the file. A gated recording of the fixture is expected to produce
// one part per segment, less the pre-roll and the hang.
type RecordSegment struct {
	StartS float64 `json:"start_s"`
	EndS   float64 `json:"end_s"`
}

// RecordExpect describes what a gated recording of the fixture must produce
// (docs/design/recording.md, "Testing without hardware"). It is the answer key
// a fixture carrying keyed transmissions states, so a recording test compares
// the cuts it made with the keying the generator actually wrote rather than
// with whatever the daemon happened to do.
type RecordExpect struct {
	// Gate is the gate the expectation holds for: "squelch" today.
	Gate string `json:"gate"`
	// SquelchDBFS is the threshold the segments were measured against.
	SquelchDBFS float64 `json:"squelch_dbfs"`
	// Segments are the keyed transmissions, in order.
	Segments []RecordSegment `json:"segments"`
}

// Expect describes one channel to create on a capture of the file and what
// its demodulated audio and meters must satisfy.
type Expect struct {
	Mode        string        `json:"mode"`
	OffsetHz    float64       `json:"offset_hz"`
	BandwidthHz float64       `json:"bandwidth_hz"`
	Audio       *AudioExpect  `json:"audio,omitempty"`
	Meter       *MeterExpect  `json:"meter,omitempty"`
	SubAudible  *SubExpect    `json:"sub_audible,omitempty"`
	Decode      *DecodeExpect `json:"decode,omitempty"`
	Record      *RecordExpect `json:"record,omitempty"`
}

// SubExpect is what a sub-audible detector should report for a fixture. A
// fixture carrying no tone, or a tone too weak to detect, records that here,
// and a detector that reports a tone anyway fails.
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
	// DCSCode is the DCS code a decoder is expected to name, its octal digits read as decimal as
	// the contract's dcs_code carries them (023 is 23); 0 for a fixture carrying no DCS. ToneHz is
	// 0 on a DCS fixture: a DCS lock suppresses the CTCSS claim.
	DCSCode int `json:"dcs_code,omitempty"`
	// DCSInverted is the dcs_inverted a decoder is expected to report.
	DCSInverted bool `json:"dcs_inverted,omitempty"`
	// Why records the reason when Detect disagrees with ToneHz being present, or when the code
	// expected is not the one the generator sent.
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
