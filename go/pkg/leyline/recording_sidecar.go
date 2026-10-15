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

// OverPreRollMs and OverHangMs are how far before an over's first opening its
// segment starts, and how long after its last close it runs on (a re-opening
// sooner continues it): the speech decoder's defaults (decode.proto, InputMode
// SEGMENTED; the daemon's Segmenter.defaultPreRollMs and defaultHangMs), which
// the speech manifest does not override. The recording's own gate pre-roll does
// not apply: an over plays exactly what was transcribed.
const (
	OverPreRollMs = 500
	OverHangMs    = 500
)

// OverSpan is one segment of a part: capture samples Start..<End, holding the
// openings First to Last, 1-based indices into the sidecar's squelch_opens.
type OverSpan struct {
	Start, End  uint64
	First, Last int
}

// Segments cuts a part's squelch openings into the stretches a speech decoder
// hears, by the daemon's rule (Segmenter.cut): each reaches preRoll back from
// its first opening and hang on from its last close, an opening less than hang
// after the previous close continues the segment, and a segment never reaches
// before the part's start or the previous segment's end, nor past the part's
// end. A speech record's `over` is its segment's First.
func Segments(opens []SquelchOpen, partStart, partEnd, preRoll, hang uint64) []OverSpan {
	var out []OverSpan
	var current *OverSpan
	for i, o := range opens {
		closeAt := max(o.CloseSample, o.OpenSample)
		if current != nil && o.OpenSample < current.End {
			current.End = max(current.End, closeAt+hang)
			current.Last = i + 1
			continue
		}
		if current != nil {
			out = append(out, *current)
		}
		floor := partStart
		if n := len(out); n > 0 {
			floor = max(partStart, out[n-1].End)
		}
		var wanted uint64
		if o.OpenSample > preRoll {
			wanted = o.OpenSample - preRoll
		}
		current = &OverSpan{Start: max(wanted, floor), End: closeAt + hang, First: i + 1, Last: i + 1}
	}
	if current != nil {
		out = append(out, *current)
	}
	kept := out[:0]
	for _, s := range out {
		s.End = min(s.End, partEnd)
		if s.End > s.Start {
			kept = append(kept, s)
		}
	}
	return kept
}

// PartCaptureRate is the rate a part's samples count in: its sidecar's anchor,
// else the manifest's anchor that applies to it, else the part's own span over
// its frames at the audio rate. 0 when none of them says.
func (m *RecordingManifest) PartCaptureRate(sc *RecordingSidecar, p RecordingPart) float64 {
	if sc != nil && sc.Anchor.SampleRate > 0 {
		return float64(sc.Anchor.SampleRate)
	}
	if r := anchorRateFor(m, p); r > 0 {
		return float64(r)
	}
	if p.Samples > 0 && p.EndSample > p.StartSample {
		return float64(p.EndSample-p.StartSample) / float64(p.Samples) * float64(m.SampleRate)
	}
	return 0
}

// OverRange is the capture samples that play over `over` of part p (1-based,
// its index in the sidecar's squelch_opens): the segment that holds that
// opening, from OverPreRollMs before its first opening to OverHangMs after its
// last close, as the speech decoder heard it. sc is the
// part's sidecar. An over the part does not list is an error that says how
// many it has.
func (m *RecordingManifest) OverRange(sc *RecordingSidecar, p RecordingPart, over int) (start, end uint64, err error) {
	opens := sc.Recording.SquelchOpens
	if len(opens) == 0 {
		return 0, 0, fmt.Errorf("part %d lists no squelch openings, so it has no overs to choose from; only a gated recording records them", p.Part)
	}
	if over < 1 || over > len(opens) {
		if len(opens) == 1 {
			return 0, 0, fmt.Errorf("part %d has one over; --over 1 plays it", p.Part)
		}
		return 0, 0, fmt.Errorf("part %d has %d overs; choose one from 1 to %d", p.Part, len(opens), len(opens))
	}
	rate := m.PartCaptureRate(sc, p)
	if rate <= 0 {
		return 0, 0, fmt.Errorf("part %d gives no capture rate to place its overs by", p.Part)
	}
	perMs := rate / 1000
	for _, s := range Segments(opens, p.StartSample, p.EndSample, uint64(OverPreRollMs*perMs), uint64(OverHangMs*perMs)) {
		if s.First <= over && over <= s.Last {
			return s.Start, s.End, nil
		}
	}
	return 0, 0, fmt.Errorf("over %d of part %d lies outside the part's samples", over, p.Part)
}
