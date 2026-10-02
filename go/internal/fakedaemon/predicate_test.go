// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// TestDecodePredicateFilters: a predicate set on the job is a daemon-side filter before delivery,
// so only matching records reach a subscriber, and their seq stays contiguous over the records
// that were delivered (a filtered record never takes one).
func TestDecodePredicateFilters(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	pred := &leylinev1.Predicate{All: []*leylinev1.Clause{{Test: &leylinev1.Clause_Field{Field: &leylinev1.FieldTest{
		Field: "device_id", Op: leylinev1.PredicateOp_PRED_EQ,
		Values: []*leylinev1.FieldValue{{Value: &leylinev1.FieldValue_Text{Text: "LEYTST-1"}}},
	}}}}}
	job, err := c.StartDecode(ctx, &leylinev1.DecodeConfig{Decoder: "aprs", Predicate: pred})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = c.Jobs.CancelJob(t.Context(), &leylinev1.JobRef{JobId: job.JobId}) }()
	recs, errs, err := c.SubscribeRecords(ctx, leyline.RecordScopeJob(job.JobId, nil))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		select {
		case rec := <-recs:
			if rec.GetDeviceId() != "LEYTST-1" {
				t.Fatalf("a filtered-out record was delivered: %v", rec.GetDeviceId())
			}
			if rec.GetSeq() != uint64(i+1) {
				t.Errorf("record %d has seq %d, want contiguous", i, rec.GetSeq())
			}
		case err := <-errs:
			t.Fatalf("stream ended: %v", err)
		case <-ctx.Done():
			t.Fatal("timed out waiting for matching records")
		}
	}
}

// A CONTAINS predicate over the fips field is how --county matches: the station that carries a
// FIPS list matches a code in it, and one that carries none does not.
func TestDecodePredicateCountyContains(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	pred := &leylinev1.Predicate{All: []*leylinev1.Clause{{Test: &leylinev1.Clause_Field{Field: &leylinev1.FieldTest{
		Field: "fips", Op: leylinev1.PredicateOp_PRED_CONTAINS,
		Values: []*leylinev1.FieldValue{{Value: &leylinev1.FieldValue_Text{Text: "006001"}}},
	}}}}}
	job, err := c.StartDecode(ctx, &leylinev1.DecodeConfig{Decoder: "aprs", Predicate: pred})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = c.Jobs.CancelJob(t.Context(), &leylinev1.JobRef{JobId: job.JobId}) }()
	recs, errs, err := c.SubscribeRecords(ctx, leyline.RecordScopeJob(job.JobId, nil))
	if err != nil {
		t.Fatal(err)
	}
	select {
	case rec := <-recs:
		if rec.GetDeviceId() != "LEYTST-1" {
			t.Fatalf("only the station with a fips list matches --county, got %v", rec.GetDeviceId())
		}
	case err := <-errs:
		t.Fatalf("stream ended: %v", err)
	case <-ctx.Done():
		t.Fatal("no county match arrived")
	}
}
