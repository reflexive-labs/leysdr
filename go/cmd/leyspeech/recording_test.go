// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/wer"
)

// testRate is the capture rate the synthetic recordings count samples in.
const testRate = 48000

// testStart is when the synthetic recordings' capture started.
var testStart = time.Date(2026, 10, 15, 14, 3, 0, 0, time.UTC)

// writeRecording makes a gated recording directory: one part per element of opens, each opening
// given in seconds from the capture's start, and the part spanning from a second before its
// first opening to a second after its last.
func writeRecording(t *testing.T, dir string, opens ...[][2]float64) {
	t.Helper()
	at := func(s float64) uint64 { return uint64(s * testRate) }
	m := leyline.RecordingManifest{
		JobID: "job_01TESTTESTTESTTESTTESTTEST", Kind: "audio", FrequencyHz: 146_940_000, Mode: "NFM",
		SampleRate: 16000, StartedAtNS: testStart.UnixNano(),
		Anchors: []leyline.RecordingAnchor{{CaptureID: "cap_1", HostTimeNS: testStart.UnixNano(), SampleRate: testRate}},
	}
	for i, part := range opens {
		p := leyline.RecordingPart{
			Part: i + 1, File: "part-" + string(rune('1'+i)) + ".wav",
			StartSample: at(part[0][0] - 1), EndSample: at(part[len(part)-1][1] + 1), SquelchOpens: len(part),
		}
		p.Samples = (p.EndSample - p.StartSample) / 3
		m.Parts = append(m.Parts, p)
		sc := leyline.RecordingSidecar{SampleRate: 16000, Anchor: leyline.SidecarAnchor{CaptureID: "cap_1", HostTimeNS: testStart.UnixNano(), SampleRate: testRate}}
		sc.Recording.Part, sc.Recording.StartSample, sc.Recording.EndSample = p.Part, p.StartSample, p.EndSample
		for _, o := range part {
			sc.Recording.SquelchOpens = append(sc.Recording.SquelchOpens, leyline.SquelchOpen{OpenSample: at(o[0]), CloseSample: at(o[1])})
		}
		writeJSON(t, filepath.Join(dir, strings.TrimSuffix(p.File, ".wav")+".json"), sc)
	}
	writeJSON(t, filepath.Join(dir, "recording.json"), m)
}

func writeJSON(t *testing.T, path string, v any) {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestTemplate(t *testing.T) {
	dir := t.TempDir()
	// Part 1: two openings 300 ms apart, inside the half-second hang, then one more; part 2: one.
	writeRecording(t, dir, [][2]float64{{1, 3}, {3.3, 4}, {8, 9.5}}, [][2]float64{{20, 22.25}})
	rec, err := readRecording(dir)
	if err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	if err := writeTemplate(&b, rec); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	clock := func(s float64) string {
		return testStart.Add(time.Duration(s * float64(time.Second))).Local().Format("15:04:05")
	}
	for _, want := range []string{
		"# Hand transcript of job_01TESTTESTTESTTESTTESTTEST: 146.940 MHz NFM",
		"\n# " + clock(1) + "  3.0 s  (openings 1 to 2, closer together than the hang: one over)\n1/1\t?\n",
		"\n# " + clock(8) + "  1.5 s\n1/3\t?\n",
		"\n# " + clock(20) + "  2.2 s\n2/1\t?\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("the template lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "1/2\t") {
		t.Errorf("the template lists 1/2, which the decoder hears inside 1/1:\n%s", out)
	}
	// The template parses as a transcript with every over unheard.
	tr, err := wer.ParseTranscript(strings.NewReader(out), "template")
	if err != nil {
		t.Fatal(err)
	}
	if len(tr.Overs) != 0 || len(tr.Skipped) != 3 {
		t.Errorf("the template parses as %+v, want three overs skipped", tr)
	}
}

func TestReadRecordingRefusesUngated(t *testing.T) {
	dir := t.TempDir()
	writeRecording(t, dir)
	if _, err := readRecording(dir); err == nil || !strings.Contains(err.Error(), "--gate squelch") {
		t.Errorf("a recording with no openings: %v, want the gated record command", err)
	}
}
