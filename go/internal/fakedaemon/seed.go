// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// SeedRecording describes a finished gated audio recording to put in the store: parts of
// silence whose sidecars list where the squelch opened, which is everything a speech decode job
// reads from a recording. The files are the shape the daemon writes (docs/design/recording.md).
type SeedRecording struct {
	// JobID is the recording's id; empty makes a new one.
	JobID string
	// FrequencyHz and Mode are what the recording was made on. Defaults: 146.52 MHz, NFM.
	FrequencyHz uint64
	Mode        string
	// Parts lists each part's overs, in milliseconds from the part's first sample. A part ends
	// one second after its last over closes, and the next part starts ten seconds after that.
	Parts [][]SeedOver
	// NoSquelchOpenMs leaves squelch_open_ms out of the manifest, as a recording made before the
	// key existed has it, so a reader sums the sidecars.
	NoSquelchOpenMs bool
	// StartedAt is the wall clock of the first part's first sample. Default: an hour ago.
	StartedAt time.Time
	// DroppedMs puts one gap of this many milliseconds in the middle of the first part, as a
	// daemon that fell behind the radio lists it: the part's span keeps its length and its file
	// holds that much less.
	DroppedMs int64
}

// SeedOver is one opening of the squelch inside a part.
type SeedOver struct{ OpenMs, CloseMs int64 }

// seedCaptureRate is the capture rate a seeded recording's timeline counts in: an RTL-SDR's
// 2.4 MSPS, decimated by 50 to the 48 kHz audio.
const seedCaptureRate = 2_400_000

// SeedRecording writes the recording into RecordingsDir and lists it as a finished record job, and
// returns its id.
func (d *Daemon) SeedRecording(spec SeedRecording) (string, error) {
	if spec.JobID == "" {
		spec.JobID = newID("job_")
	}
	if spec.FrequencyHz == 0 {
		spec.FrequencyHz = 146_520_000
	}
	if spec.Mode == "" {
		spec.Mode = "NFM"
	}
	if spec.StartedAt.IsZero() {
		spec.StartedAt = time.Now().Add(-time.Hour)
	}
	dir := filepath.Join(d.recordingsRoot(), spec.JobID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	anchor := leyline.RecordingAnchor{CaptureID: newID("cap_"), HostTimeNS: spec.StartedAt.UnixNano(), SampleRate: seedCaptureRate}
	m := &leyline.RecordingManifest{
		JobID: spec.JobID, URI: leyline.RecordingURI(spec.JobID),
		Kind: "audio", FrequencyHz: spec.FrequencyHz, Mode: spec.Mode, BandwidthHz: 12_500,
		SampleRate: fakeAudioRate, Format: "wav-s16",
		Gate:        &leyline.RecordingGate{Kind: "squelch", PreRollMs: 500, HangMs: 5000},
		StartedAtNS: spec.StartedAt.UnixNano(),
		EndedBy:     "duration",
		CreatedBy:   &leyline.RecordingClient{ClientID: "cli_seed", Kind: "cli", Label: "ley record"},
		Anchors:     []leyline.RecordingAnchor{anchor},
		Parts:       []leyline.RecordingPart{},
	}
	squelch := -80.0
	m.SquelchDBFS = &squelch
	r := &recordJob{dir: dir, manifest: m}
	var startMs int64
	for i, overs := range spec.Parts {
		if len(overs) == 0 {
			return "", fmt.Errorf("part %d has no overs; a gated part holds at least one", i+1)
		}
		lengthMs := overs[len(overs)-1].CloseMs + 1000
		dropped := int64(0)
		if i == 0 {
			dropped = spec.DroppedMs
		}
		if err := r.writeSeedPart(i+1, startMs, lengthMs, overs, !spec.NoSquelchOpenMs, dropped); err != nil {
			return "", err
		}
		startMs += lengthMs + 10_000
	}
	m.EndedAtNS = spec.StartedAt.Add(time.Duration(startMs) * time.Millisecond).UnixNano()
	if err := writeManifest(r); err != nil {
		return "", err
	}

	d.mu.Lock()
	defer d.mu.Unlock()
	job := &leylinev1.Job{
		JobId: spec.JobID, State: leylinev1.JobState_COMPLETED, CreatedAtNs: m.StartedAtNS,
		CreatedBy: &leylinev1.ClientInfo{ClientId: "cli_seed", Kind: "cli", Label: "ley record"},
		Config: &leylinev1.Job_Record{Record: &leylinev1.RecordConfig{
			FrequencyHz: spec.FrequencyHz, Gate: leylinev1.RecordGate_SQUELCH,
		}},
		ResultUris:   []string{m.URI},
		StatusDetail: fmt.Sprintf("recorded %s in %s", forSeconds(recordedMs(r)), partsPhrase(r)),
	}
	d.jobs[spec.JobID] = &fakeJob{proto: job, owner: "cli_seed", hz: spec.FrequencyHz, keep: true, record: r}
	d.jobOrder = append(d.jobOrder, spec.JobID)
	return spec.JobID, nil
}

// recordingsRoot is where recordings are written: RecordingsDir, or a temp directory.
func (d *Daemon) recordingsRoot() string {
	if d.opts.RecordingsDir != "" {
		return d.opts.RecordingsDir
	}
	return filepath.Join(os.TempDir(), "leyline-fake-recordings")
}

// writeSeedPart writes one part of silence, its sidecar with the overs as squelch_opens, and its
// manifest entry.
func (r *recordJob) writeSeedPart(part int, startMs, lengthMs int64, overs []SeedOver, withOpenMs bool, droppedMs int64) error {
	m := r.manifest
	frames := int((lengthMs - droppedMs) * fakeAudioRate / 1000)
	data := silentWAV(frames, fakeAudioRate)
	name := fmt.Sprintf("%s_%.3fMHz_%s_%03d", time.Unix(0, m.StartedAtNS).Add(time.Duration(startMs)*time.Millisecond).Format("2006-01-02_15-04-05"),
		float64(m.FrequencyHz)/1e6, partTag(m), part)
	if err := os.WriteFile(filepath.Join(r.dir, name+".wav"), data, 0o644); err != nil {
		return err
	}
	toSample := func(ms int64) uint64 { return uint64(ms) * seedCaptureRate / 1000 }
	peak, mean := -6.0, -9.0
	entry := leyline.RecordingPart{
		Part: part, File: name + ".wav",
		StartSample: toSample(startMs), EndSample: toSample(startMs + lengthMs),
		Samples: uint64(frames), Bytes: uint64(len(data)),
		PeakDBFS: &peak, MeanDBFS: &mean, SquelchOpens: len(overs),
	}
	written := lengthMs - droppedMs
	entry.WrittenMs = &written
	if droppedMs > 0 {
		from := toSample(startMs + (lengthMs-droppedMs)/2)
		entry.Gaps = []leyline.RecordingPartGap{{Sample: from, Samples: toSample(droppedMs)}}
		m.Gaps = append(m.Gaps, leyline.RecordingGap{FromSample: from, ToSample: from + toSample(droppedMs), Reason: "samples dropped"})
	}
	var opens []leyline.SquelchOpen
	var openMs int64
	for _, o := range overs {
		opens = append(opens, leyline.SquelchOpen{OpenSample: toSample(startMs + o.OpenMs), CloseSample: toSample(startMs + o.CloseMs)})
		openMs += o.CloseMs - o.OpenMs
	}
	if withOpenMs {
		entry.SquelchOpenMs = &openMs
	}
	if last := len(m.Parts) - 1; last >= 0 {
		m.Gaps = append(m.Gaps, leyline.RecordingGap{FromSample: m.Parts[last].EndSample, ToSample: entry.StartSample, Reason: "squelch closed"})
	}
	m.Parts = append(m.Parts, entry)
	m.Bytes += entry.Bytes
	writePartSidecar(r, entry, opens)
	return nil
}

// silentWAV is a canonical 16-bit mono WAV of silence: what a gated part holds between overs, and
// all the fake's speech decoder needs, since it hears nothing.
func silentWAV(frames int, rate uint64) []byte {
	out := make([]byte, 44+frames*2)
	copy(out[0:], "RIFF")
	binary.LittleEndian.PutUint32(out[4:], uint32(36+frames*2))
	copy(out[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(out[16:], 16)
	binary.LittleEndian.PutUint16(out[20:], 1)
	binary.LittleEndian.PutUint16(out[22:], 1)
	binary.LittleEndian.PutUint32(out[24:], uint32(rate))
	binary.LittleEndian.PutUint32(out[28:], uint32(rate)*2)
	binary.LittleEndian.PutUint16(out[32:], 2)
	binary.LittleEndian.PutUint16(out[34:], 16)
	copy(out[36:], "data")
	binary.LittleEndian.PutUint32(out[40:], uint32(frames*2))
	return out
}
