// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"sort"
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/session"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// storeQuery answers a RecordQuery the way the daemon's store does: newest first by wall clock,
// until_ns inclusive, cut at the limit (1000 when it is 0) with truncated set.
func storeQuery(recs []*leylinev1.DecodeRecord, anchors []*leylinev1.RecordAnchor) func(context.Context, *leylinev1.RecordQuery) (*leylinev1.RecordPage, error) {
	return func(_ context.Context, q *leylinev1.RecordQuery) (*leylinev1.RecordPage, error) {
		var hits []*leylinev1.DecodeRecord
		for _, r := range recs {
			at, _ := leyline.RecordWallTime(r, anchors)
			if q.GetUntilNs() != 0 && at.UnixNano() > q.GetUntilNs() {
				continue
			}
			hits = append(hits, r)
		}
		sort.Slice(hits, func(i, j int) bool { return hits[i].GetSeq() > hits[j].GetSeq() })
		limit := int(q.GetLimit())
		if limit == 0 {
			limit = 1000
		}
		page := &leylinev1.RecordPage{Anchors: anchors}
		if len(hits) > limit {
			hits, page.Truncated = hits[:limit], true
		}
		page.Records = hits
		return page, nil
	}
}

// A decode of a long recording keeps more records than one page holds; every one of them comes
// back, oldest first.
func TestJobRecordsReadsEveryPage(t *testing.T) {
	t.Parallel()
	anchors := []*leylinev1.RecordAnchor{{Anchor: &leylinev1.CaptureAnchor{CaptureId: "cap_1", HostTimeNs: 1_700_000_000_000_000_000, SampleRate: 1_000_000}}}
	var recs []*leylinev1.DecodeRecord
	for i := uint64(1); i <= 2500; i++ {
		// Two records a millisecond, so a page boundary falls between records at one instant.
		recs = append(recs, &leylinev1.DecodeRecord{Seq: i, Time: &leylinev1.SampleTime{CaptureId: "cap_1", SampleIndex: i / 2 * 1000}})
	}
	got, err := jobRecords(t.Context(), storeQuery(recs, anchors), "job_1")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(recs) {
		t.Fatalf("got %d records, want %d", len(got), len(recs))
	}
	for i, r := range got {
		if r.GetSeq() != uint64(i+1) {
			t.Fatalf("record %d is seq %d; want them oldest first", i, r.GetSeq())
		}
	}
}

// A Ctrl-C or --count that cannot cancel the job says so and exits non-zero: the job would read
// the rest of the recording for nobody.
func TestDecodeRecordingStoppedReportsAFailedCancel(t *testing.T) {
	t.Parallel()
	_, c := harness(t, fakedaemon.Options{})
	var out, errb bytes.Buffer
	app := &App{Stdout: &out, Stderr: &errb, IsTTY: func() bool { return false }}
	s := &verbSession{Session: &session.Session{Client: c}, app: app}
	err := decodeRecordingStopped(t.Context(), s, &leylinev1.Job{JobId: "job_01NOSUCHNOSUCHNOSUCHNOSUC"}, 3)
	if exitCode(err) == 0 {
		t.Fatalf("a cancel that failed exited 0 (%v); stderr %q", err, errb.String())
	}
	if msg := err.Error(); !strings.Contains(msg, "ley jobs cancel job_01NOSUCHNOSUCHNOSUCHNOSUC") || !strings.Contains(msg, "no such job") {
		t.Errorf("the error must give the reason and the command that stops it: %q", msg)
	}
}
