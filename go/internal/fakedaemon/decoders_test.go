// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The registry answers with the one manifest it has, the directories it looked in, and the
// retention it applies -- the three things `ley decoders` prints.
func TestListDecoders(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	resp, err := c.ListDecoders(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.Decoders) != 1 || resp.Decoders[0].Name != "aprs" {
		t.Fatalf("decoders: %v", resp.Decoders)
	}
	m := resp.Decoders[0]
	if m.GetRecipe().GetFrequenciesHz()[0] != 144_390_000 || m.GetRecipe().GetMode() != leylinev1.DemodMode_NFM {
		t.Errorf("recipe: %v", m.GetRecipe())
	}
	if m.GetEntitySilenceS() != 1800 || len(m.GetOutputs()) != 2 {
		t.Errorf("outputs/silence: %v %d", m.GetOutputs(), m.GetEntitySilenceS())
	}
	if len(resp.SearchPath) == 0 || resp.StorePath == "" || resp.StoreCapBytes == 0 || resp.StoreAgeDays == 0 {
		t.Errorf("search path and retention must be filled: %v", resp)
	}
}

// A decoder nobody installed is DECODER_NOT_FOUND, the stable code `ley decode` turns into the
// line telling the reader to run `ley decoders`.
func TestStartDecodeUnknownDecoder(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	_, err := c.StartDecode(t.Context(), &leylinev1.DecodeConfig{Decoder: "nosuch"})
	if leyline.Code(err) != leyline.CodeDecoderNotFound {
		t.Fatalf("code = %q (%v), want DECODER_NOT_FOUND", leyline.Code(err), err)
	}
}

// A decode job takes a capture and a channel, stamps every record with its own identity, and
// numbers them 1, 2, 3 with no holes.
func TestDecodeJobStampsAndNumbersRecords(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	job, err := c.StartDecode(ctx, &leylinev1.DecodeConfig{Decoder: "aprs"})
	if err != nil {
		t.Fatal(err)
	}
	recs, errs, err := c.SubscribeRecords(ctx, leyline.RecordScopeJob(job.JobId, nil))
	if err != nil {
		t.Fatal(err)
	}
	var got []*leylinev1.DecodeRecord
	for len(got) < 3 {
		select {
		case rec := <-recs:
			got = append(got, rec)
		case err := <-errs:
			t.Fatalf("stream ended: %v", err)
		case <-ctx.Done():
			t.Fatal("no records")
		}
	}
	st, err := c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Channels) != 1 || !st.Channels[0].Persistent || st.Channels[0].GetOwner().GetKind() != "job" {
		t.Fatalf("the job must own one persistent channel: %v", st.Channels)
	}
	for i, rec := range got {
		if rec.Seq != uint64(i+1) {
			t.Errorf("record %d has seq %d", i, rec.Seq)
		}
		if rec.JobId != job.JobId || rec.ChannelId != st.Channels[0].ChannelId || rec.Protocol != "aprs" {
			t.Errorf("record %d is not stamped: %v", i, rec)
		}
		if rec.RecordId == "" || rec.RssiDbfs != -25 || rec.SnrDb != 20 {
			t.Errorf("record %d levels/id: %v", i, rec)
		}
		if rec.GetTime().GetCaptureId() != st.Captures[0].CaptureId {
			t.Errorf("record %d is not on the capture's timeline: %v", i, rec.GetTime())
		}
	}
	// Cancelling releases the radio: the channel and the capture the job made both go.
	if _, err := c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: job.JobId}); err != nil {
		t.Fatal(err)
	}
	st, err = c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Channels) != 0 || len(st.Captures) != 0 {
		t.Errorf("cancel must release the channel and the capture: %v %v", st.Channels, st.Captures)
	}
}

// since_seq replays the retained window: a client that subscribes after starting the job still
// sees the records it missed, which is what makes "StartJob then Subscribe" safe.
func TestSubscribeRecordsReplaysSinceSeq(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	job, err := c.StartDecode(ctx, &leylinev1.DecodeConfig{Decoder: "aprs"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = c.Jobs.CancelJob(t.Context(), &leylinev1.JobRef{JobId: job.JobId}) }()
	// Records retained before the subscription opens are what the replay must deliver.
	eventually(t, "the job's first record", func() bool {
		j, err := c.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.JobId})
		return err == nil && strings.Contains(j.GetStatusDetail(), "last just now")
	})

	from := uint64(0)
	recs, errs, err := c.SubscribeRecords(ctx, leyline.RecordScopeJob(job.JobId, &from))
	if err != nil {
		t.Fatal(err)
	}
	select {
	case rec := <-recs:
		if rec.Seq != 1 {
			t.Fatalf("replay must start at seq 1, got %d", rec.Seq)
		}
	case err := <-errs:
		t.Fatalf("stream ended: %v", err)
	case <-ctx.Done():
		t.Fatal("no replay")
	}
}

// A kept job writes to the store, and QueryRecords reads it back with the anchors a client turns
// sample time into wall clock with.
func TestQueryRecordsReadsKeptJobs(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	job, err := c.StartDecode(ctx, &leylinev1.DecodeConfig{Decoder: "aprs", Keep: true})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = c.Jobs.CancelJob(t.Context(), &leylinev1.JobRef{JobId: job.JobId}) }()
	if uris := job.GetResultUris(); len(uris) != 1 || uris[0] != "ley://records/"+job.JobId {
		t.Errorf("a kept job names its records as a resource: %v", uris)
	}
	var page *leylinev1.RecordPage
	eventually(t, "three records in the store", func() bool {
		p, err := c.QueryRecords(ctx, &leylinev1.RecordQuery{Protocol: "aprs"})
		if err != nil {
			t.Fatal(err)
		}
		page = p
		return len(page.Records) >= 3
	})
	if len(page.Records) < 3 || len(page.Anchors) != 1 {
		t.Fatalf("page: %d records, %d anchors", len(page.Records), len(page.Anchors))
	}
	if page.Records[0].Seq < page.Records[1].Seq {
		t.Errorf("records must be newest first")
	}
	if _, ok := leyline.RecordWallTime(page.Records[0], page.Anchors); !ok {
		t.Errorf("the page's anchors must cover its records")
	}
	// The device filter names the transmitter, not the radio.
	one, err := c.QueryRecords(ctx, &leylinev1.RecordQuery{DeviceId: "LEYTST-3"})
	if err != nil {
		t.Fatal(err)
	}
	if len(one.Records) == 0 {
		t.Fatal("no records for LEYTST-3")
	}
	for _, rec := range one.Records {
		if rec.DeviceId != "LEYTST-3" {
			t.Errorf("device filter let %s through", rec.DeviceId)
		}
	}
	// A query far from the station's position finds nothing; one over it finds it.
	near := &leylinev1.Position{Latitude: 37.76, Longitude: -122.42}
	far, err := c.QueryRecords(ctx, &leylinev1.RecordQuery{Near: near, RadiusM: 1000})
	if err != nil || len(far.Records) == 0 {
		t.Fatalf("near the station: %d records (%v)", len(far.GetRecords()), err)
	}
	away, err := c.QueryRecords(ctx, &leylinev1.RecordQuery{
		Near: &leylinev1.Position{Latitude: 51.5, Longitude: -0.12}, RadiusM: 1000,
	})
	if err != nil || len(away.Records) != 0 {
		t.Fatalf("across the world: %d records (%v)", len(away.GetRecords()), err)
	}
}
