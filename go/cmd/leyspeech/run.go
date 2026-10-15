// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/wer"
)

// engineSpec is one engine to measure: a decoder name and, for one that calls a provider, the
// model.
type engineSpec struct {
	name  string
	model string
}

// loadRef reads the hand transcript: path when given, else transcript.txt in the recording's
// directory, else none (nil, ""), which the report says.
func loadRef(path, recordingDir string) (*wer.Transcript, string, error) {
	if path == "" {
		beside := filepath.Join(recordingDir, wer.TranscriptFile)
		if _, err := os.Stat(beside); err != nil {
			return nil, "", nil
		}
		path = beside
	}
	t, err := wer.LoadTranscript(path)
	return t, path, err
}

// transcribe runs `ley transcribe` with the engine over the recording and measures the result.
func (s *session) transcribe(ctx context.Context, rec *recording, ref *wer.Transcript, refPath string, e engineSpec) (*result, error) {
	dec, err := s.decoder(ctx, e.name)
	if err != nil {
		return nil, err
	}
	if err := s.ensureKey(ctx, dec.GetCredentialProvider()); err != nil {
		return nil, err
	}
	restore, err := s.keepSpeechModel(ctx, e.model)
	if err != nil {
		return nil, err
	}
	defer restore()
	args := []string{"transcribe", rec.manifest.JobID, "--engine", dec.GetName(), "--yes", "--json"}
	if e.model != "" {
		args = append(args, "--model", e.model)
	}
	cmd := s.ley.command(ctx, args...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, s.stderr
	began := time.Now()
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("ley %s: %w", strings.Join(args, " "), err)
	}
	wall := time.Since(began)
	recs, err := parseRecords(out.Bytes())
	if err != nil {
		return nil, err
	}
	res, err := s.measure(ctx, rec, dec, e, recs)
	if err != nil {
		return nil, err
	}
	res.WallSeconds = wall.Seconds()
	if wall > 0 {
		res.Speed = res.OpenSeconds / wall.Seconds()
	}
	if ref != nil {
		res.Ref = refPath
		res.Score = score(rec, dec, ref, recs)
	}
	return res, nil
}

// parseRecords reads `--json` NDJSON: one DecodeRecord a line.
func parseRecords(out []byte) ([]*leylinev1.DecodeRecord, error) {
	var recs []*leylinev1.DecodeRecord
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		rec, err := parseRecord(line)
		if err != nil {
			return nil, err
		}
		recs = append(recs, rec)
	}
	return recs, sc.Err()
}

func parseRecord(line []byte) (*leylinev1.DecodeRecord, error) {
	rec := &leylinev1.DecodeRecord{}
	if err := (protojson.UnmarshalOptions{DiscardUnknown: true}).Unmarshal(line, rec); err != nil {
		return nil, fmt.Errorf("a record ley printed is not a DecodeRecord (%q): %w", line, err)
	}
	return rec, nil
}

// recordKey is the part and over a speech record came from.
func recordKey(rec *leylinev1.DecodeRecord) (wer.Key, bool) {
	_, part, ok := leyline.ParseRecordingURI(rec.GetClipUri())
	if !ok || part == 0 || rec.GetOver() == 0 {
		return wer.Key{}, false
	}
	return wer.Key{Part: part, Over: int(rec.GetOver())}, true
}

// score matches the records to the transcript. Each side's overs carry the openings their
// segment holds, the transcript's cut at the default hang that `leyspeech ref` lists them by and
// the records' at the decoder's own, so a decoder that cuts differently is scored over the same
// audio rather than charged for the difference.
func score(rec *recording, dec *leylinev1.DecoderManifest, ref *wer.Transcript, recs []*leylinev1.DecodeRecord) *wer.Report {
	refLast := lastOpenings(rec.overs(leyline.OverPreRollMs, leyline.OverHangMs))
	hypLast := lastOpenings(rec.overs(segmentRule(dec)))
	withRefSpans := &wer.Transcript{Skipped: ref.Skipped}
	for _, o := range ref.Overs {
		o.Last = refLast[o.Key]
		withRefSpans.Overs = append(withRefSpans.Overs, o)
	}
	var hyp []wer.Over
	for _, r := range recs {
		k, ok := recordKey(r)
		if !ok {
			continue
		}
		hyp = append(hyp, wer.Over{Key: k, Text: r.GetFields()["text"].GetText(), Last: hypLast[k]})
	}
	report := wer.Score(withRefSpans, hyp)
	return &report
}

// measure is what every run reports: the engine and model, the records, the squelch-open audio
// and what the provider counted for the job.
func (s *session) measure(ctx context.Context, rec *recording, dec *leylinev1.DecoderManifest, e engineSpec, recs []*leylinev1.DecodeRecord) (*result, error) {
	res := &result{Engine: dec.GetName(), Model: e.model, Recording: rec.manifest.JobID, Records: len(recs)}
	for _, r := range recs {
		if res.JobID == "" {
			res.JobID = r.GetJobId()
		}
		if res.Model == "" {
			res.Model = r.GetFields()["model"].GetText()
		}
	}
	open, err := rec.openSeconds()
	if err != nil {
		return nil, err
	}
	res.OpenSeconds = open
	if res.Usage, err = s.usage(ctx, res.JobID); err != nil {
		return nil, err
	}
	if res.Model == "" {
		res.Model = res.Usage.Model
	}
	if open > 0 {
		res.PerOpenHour = res.Usage.scaled(3600 / open)
	}
	return res, nil
}
