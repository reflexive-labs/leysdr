// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
	"github.com/reflexive-labs/leysdr/go/pkg/wer"
)

// recording is a gated recording read from its directory: the manifest and every part's sidecar,
// which together say where each over is and when it was heard.
type recording struct {
	dir      string
	manifest *leyline.RecordingManifest
	parts    []recordingPart
}

// recordingPart is one part with its sidecar, the capture rate its samples count in, and the
// anchor that dates them (nil when neither the sidecar nor the manifest carries one).
type recordingPart struct {
	leyline.RecordingPart
	sidecar *leyline.RecordingSidecar
	rate    float64
	anchor  *leylinev1.CaptureAnchor
}

// overSpan is one segment a speech decoder is handed: its key (the part and its first opening),
// its last opening, and the capture samples from the first opening to the last close.
type overSpan struct {
	key           wer.Key
	last          int
	open, closeAt uint64
	part          *recordingPart
}

// isRecordingDir reports whether path is a recording's directory, holding its manifest.
func isRecordingDir(path string) bool {
	st, err := os.Stat(filepath.Join(path, "recording.json"))
	return err == nil && !st.IsDir()
}

// readRecording loads the manifest and every part's sidecar from dir. A recording with no
// squelch openings was not made with --gate squelch and has no overs to transcribe.
func readRecording(dir string) (*recording, error) {
	m, err := leyline.ReadRecordingManifest(dir)
	if err != nil {
		return nil, fmt.Errorf("the recording's manifest could not be read (%s): %w", dir, err)
	}
	if m.Kind == "iq" {
		return nil, fmt.Errorf("%s is an IQ recording; speech is decoded from audio, so record with: ley record <freq> --gate squelch", m.JobID)
	}
	r := &recording{dir: dir, manifest: m}
	for _, p := range m.Parts {
		sc, err := leyline.ReadPartSidecar(dir, p)
		if err != nil {
			return nil, fmt.Errorf("part %d's sidecar could not be read: %w", p.Part, err)
		}
		r.parts = append(r.parts, recordingPart{RecordingPart: p, sidecar: sc, rate: m.PartCaptureRate(sc, p), anchor: partAnchor(m, sc, p)})
	}
	if m.SquelchOpens() == 0 && r.openingCount() == 0 {
		return nil, fmt.Errorf("%s lists no squelch openings, so it has no overs: record with ley record <freq> --gate squelch", m.JobID)
	}
	return r, nil
}

func (r *recording) openingCount() int {
	n := 0
	for _, p := range r.parts {
		n += len(p.sidecar.Recording.SquelchOpens)
	}
	return n
}

// partAnchor is the anchor a part's samples are dated by: its sidecar's, else the manifest's
// that covers the part's first sample.
func partAnchor(m *leyline.RecordingManifest, sc *leyline.RecordingSidecar, p leyline.RecordingPart) *leylinev1.CaptureAnchor {
	if a := sc.Anchor; a.HostTimeNS != 0 && a.SampleRate > 0 {
		return &leylinev1.CaptureAnchor{CaptureId: a.CaptureID, HostTimeNs: a.HostTimeNS, SampleRate: a.SampleRate, DriftPpm: a.DriftPPM}
	}
	var chosen *leyline.RecordingAnchor
	for i := range m.Anchors {
		a := &m.Anchors[i]
		if a.SampleRate > 0 && a.FromSample <= p.StartSample && (chosen == nil || a.FromSample >= chosen.FromSample) {
			chosen = a
		}
	}
	if chosen == nil {
		return nil
	}
	return &leylinev1.CaptureAnchor{CaptureId: chosen.CaptureID, HostTimeNs: chosen.HostTimeNS, SampleRate: chosen.SampleRate, DriftPpm: chosen.DriftPPM}
}

// wallTime is when a capture sample of the part was heard, from its anchor.
func (p *recordingPart) wallTime(sample uint64) (time.Time, bool) {
	if p.anchor == nil {
		return time.Time{}, false
	}
	return leyline.AnchorWallTime(p.anchor, sample)
}

// seconds is a span of the part's capture samples in seconds.
func (p *recordingPart) seconds(from, to uint64) float64 {
	if p.rate <= 0 || to <= from {
		return 0
	}
	return float64(to-from) / p.rate
}

// overs cuts every part into the segments a decoder with this pre-roll and hang is handed, by
// the daemon's rule (leyline.Segments).
func (r *recording) overs(preRollMs, hangMs uint32) []overSpan {
	var out []overSpan
	for i := range r.parts {
		p := &r.parts[i]
		opens := p.sidecar.Recording.SquelchOpens
		if len(opens) == 0 || p.rate <= 0 {
			continue
		}
		perMs := p.rate / 1000
		for _, s := range leyline.Segments(opens, p.StartSample, p.EndSample, uint64(float64(preRollMs)*perMs), uint64(float64(hangMs)*perMs)) {
			first, last := opens[s.First-1], opens[s.Last-1]
			out = append(out, overSpan{
				key: wer.Key{Part: p.Part, Over: s.First}, last: s.Last,
				open: first.OpenSample, closeAt: max(last.CloseSample, last.OpenSample), part: p,
			})
		}
	}
	return out
}

// lastOpenings maps each segment's key to its last opening, which is what wer.Over.Last takes.
func lastOpenings(spans []overSpan) map[wer.Key]int {
	out := map[wer.Key]int{}
	for _, s := range spans {
		out[s.key] = s.last
	}
	return out
}

// segmentRule is the pre-roll and hang a decoder's segments are cut with: its manifest's, or the
// daemon's defaults where the manifest leaves them 0.
func segmentRule(dec *leylinev1.DecoderManifest) (preRollMs, hangMs uint32) {
	preRollMs, hangMs = dec.GetInput().GetPreRollMs(), dec.GetInput().GetHangMs()
	if preRollMs == 0 {
		preRollMs = leyline.OverPreRollMs
	}
	if hangMs == 0 {
		hangMs = leyline.OverHangMs
	}
	return preRollMs, hangMs
}

// openSeconds is how long the squelch was open across the recording.
func (r *recording) openSeconds() (float64, error) {
	d, err := r.manifest.SquelchOpenTime(r.dir)
	return d.Seconds(), err
}

// writeTemplate prints a hand transcript to fill in: one line per over as the default speech
// decoder cuts them, each marked unheard, under a comment giving when it was heard and how long
// the squelch was open from its first opening to its last close.
func writeTemplate(w io.Writer, r *recording) error {
	m := r.manifest
	var b strings.Builder
	fmt.Fprintf(&b, "# Hand transcript of %s: %s %s", m.JobID, units.FormatFrequency(m.FrequencyHz), m.Mode)
	if at := m.StartedAt(); !at.IsZero() {
		fmt.Fprintf(&b, ", recorded %s", at.Format("2006-01-02 15:04 MST"))
	}
	b.WriteString(".\n")
	b.WriteString("# One line per over: part/over, a tab, then the words as spoken. Write a callsign as spoken\n")
	b.WriteString("# or as W6ABC; they score the same. Replace each ? with the words, leave the text empty for\n")
	b.WriteString("# an over with no words in it, and leave ? on an over you skip: it is not scored.\n")
	fmt.Fprintf(&b, "# Save it as %s beside recording.json, or pass it to leyspeech run with --ref.\n", wer.TranscriptFile)
	for _, s := range r.overs(leyline.OverPreRollMs, leyline.OverHangMs) {
		when := "--:--:--"
		if at, ok := s.part.wallTime(s.open); ok {
			when = at.Format("15:04:05")
		}
		fmt.Fprintf(&b, "\n# %s  %.1f s", when, s.part.seconds(s.open, s.closeAt))
		if s.last > s.key.Over {
			fmt.Fprintf(&b, "  (openings %d to %d, closer together than the hang: one over)", s.key.Over, s.last)
		}
		fmt.Fprintf(&b, "\n%s\t%s\n", s.key, wer.Unheard)
	}
	_, err := io.WriteString(w, b.String())
	return err
}
