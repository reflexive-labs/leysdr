// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/leyline"
	"github.com/dpup/leysdr/go/pkg/records"
)

// keptJob starts a decode job that keeps its records and leaves it running for the caller,
// which is what puts anything in the store for `ley records` to find.
func keptJob(t *testing.T, sock string, c *leyline.Client, wait time.Duration) *leylinev1.Job {
	t.Helper()
	ctx := context.Background()
	job, err := c.StartDecode(ctx, &leylinev1.DecodeConfig{Decoder: "aprs", Keep: true})
	if err != nil {
		t.Fatalf("start decode: %v", err)
	}
	t.Cleanup(func() { _, _ = c.Jobs.CancelJob(context.Background(), &leylinev1.JobRef{JobId: job.JobId}) })
	time.Sleep(wait)
	return job
}

// The table is newest first with the summary on the right, and an empty store says what puts
// something in it rather than printing a bare header.
func TestRecordsTableAndFilters(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	empty := mustRun(t, sock, "records")
	if !strings.Contains(empty, "no records") || !strings.Contains(empty, "--job") {
		t.Fatalf("an empty store must say how to fill it:\n%s", empty)
	}
	keptJob(t, sock, c, 5*fakedaemon.RecordInterval)

	out := mustRun(t, sock, "records")
	if head := strings.Fields(out)[0]; head != "TIME" {
		t.Fatalf("unexpected table:\n%s", out)
	}
	for _, want := range []string{"aprs", "LEYTST-1", "position", "37.7600N"} {
		if !strings.Contains(out, want) {
			t.Errorf("the table lacks %q:\n%s", want, out)
		}
	}
	one := mustRun(t, sock, "records", "--device-id", "LEYTST-3", "--kind", "status")
	if !strings.Contains(one, "LEYTST-3") || strings.Contains(one, "LEYTST-1") {
		t.Errorf("the filters must narrow the table:\n%s", one)
	}
	near := mustRun(t, sock, "records", "--near", "37.76,-122.42", "--radius", "10km")
	if !strings.Contains(near, "LEYTST-1") || strings.Contains(near, "LEYTST-3") {
		t.Errorf("a spatial filter keeps only records with a position in it:\n%s", near)
	}
	away := mustRun(t, sock, "records", "--near", "51.5,-0.12", "--radius", "10km")
	if strings.Contains(away, "LEYTST-1") {
		t.Errorf("a query on the other side of the world must find nothing:\n%s", away)
	}
	out = mustRun(t, sock, "--json", "records", "--limit", "2")
	var page struct {
		Records []map[string]any `json:"records"`
		Anchors []map[string]any `json:"anchors"`
	}
	if err := json.Unmarshal([]byte(out), &page); err != nil || len(page.Records) != 2 {
		t.Fatalf("json page: %v %s", err, out)
	}
	if len(page.Anchors) != 1 {
		t.Errorf("the page must carry the anchors its records are dated by: %s", out)
	}
}

// TestRecordsSinceUsesAnchors: --since is answered through the capture's anchors, so a window
// narrower than the job's lifetime returns the newest records and not the older ones.
func TestRecordsSinceUsesAnchors(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	keptJob(t, sock, c, 8*fakedaemon.RecordInterval)

	all := recordPage(t, sock)
	if len(all.GetRecords()) < 5 {
		t.Fatalf("expected the job to have kept several records, got %d", len(all.GetRecords()))
	}
	cut := time.Now().Add(-500 * time.Millisecond)
	recent := recordPage(t, sock, "--since", "500ms")
	if n := len(recent.GetRecords()); n == 0 || n >= len(all.GetRecords()) {
		t.Fatalf("--since 500ms returned %d of %d records", n, len(all.GetRecords()))
	}
	for _, rec := range recent.GetRecords() {
		at, ok := leyline.RecordWallTime(rec, recent.GetAnchors())
		if !ok {
			t.Fatalf("a record the daemon returned is not covered by the page's anchors: %v", rec.GetTime())
		}
		if at.Before(cut) {
			t.Errorf("record %d is %s old, outside the window asked for", rec.GetSeq(), time.Since(at))
		}
	}
}

// recordPage runs `ley records --json` and parses the page it printed.
func recordPage(t *testing.T, sock string, args ...string) *leylinev1.RecordPage {
	t.Helper()
	out := mustRun(t, sock, append([]string{"--json", "records"}, args...)...)
	var page leylinev1.RecordPage
	if err := protojson.Unmarshal([]byte(out), &page); err != nil {
		t.Fatalf("records --json: %v\n%s", err, out)
	}
	return &page
}

// Durations, points and distances are read the way a person writes them, and a value with no
// unit is refused rather than guessed at.
func TestRecordsInputParsing(t *testing.T) {
	for _, c := range []struct {
		in   string
		want time.Duration
	}{{"90s", 90 * time.Second}, {"30m", 30 * time.Minute}, {"1h", time.Hour}, {"2d", 48 * time.Hour}} {
		got, err := parseAge(c.in)
		if err != nil || got != c.want {
			t.Errorf("parseAge(%q) = %v, %v", c.in, got, err)
		}
	}
	if _, err := parseAge("soon"); err == nil {
		t.Errorf("parseAge must refuse a word")
	}
	for _, c := range []struct {
		in   string
		want float64
	}{{"10km", 10000}, {"500m", 500}, {"5nm", 9260}, {"3mi", 4828.032}} {
		got, err := parseDistance(c.in)
		if err != nil || got != c.want {
			t.Errorf("parseDistance(%q) = %v, %v", c.in, got, err)
		}
	}
	if _, err := parseDistance("10"); err == nil {
		t.Errorf("a distance with no unit must be refused: 10 could be metres or kilometres")
	}
	p, err := parseLatLon("37.76, -122.42")
	if err != nil || p.GetLatitude() != 37.76 || p.GetLongitude() != -122.42 {
		t.Errorf("parseLatLon = %v, %v", p, err)
	}
	if _, err := parseLatLon("91,0"); err == nil {
		t.Errorf("a latitude off the globe must be refused")
	}
	sock, _ := harness(t, fakedaemon.Options{})
	for _, args := range [][]string{
		{"records", "--since", "soon"},
		{"records", "--near", "37.76,-122.42"},
		{"records", "--radius", "10km"},
		{"track", "aprs", "--rate", "0"},
	} {
		_, _, err := run(t, context.Background(), sock, args...)
		if exitCode(err) != ExitUsage {
			t.Errorf("ley %v: exit %d (%v), want %d", args, exitCode(err), err, ExitUsage)
		}
	}
}

// track draws one row per transmitter, newest first, and answers --json with one snapshot
// object per redraw.
func TestTrackTableAndJSON(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	keptJob(t, sock, c, 0)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "track", "aprs", "--rate", "2", "--count", "3")
	if err != nil {
		t.Fatalf("ley track: %v\n%s", err, errOut)
	}
	if !strings.Contains(out, "DEVICE") || !strings.Contains(out, "LAST HEARD") || !strings.Contains(out, "SEEN") {
		t.Fatalf("unexpected table:\n%s", out)
	}
	if !strings.Contains(out, "LEYTST-1") || !strings.Contains(out, "37.7600N") {
		t.Errorf("the table must carry the stations and their positions:\n%s", out)
	}
	if !strings.Contains(errOut, "tracking aprs") || !strings.Contains(errOut, "of silence") {
		t.Errorf("stderr must say what is tracked and when a row goes: %q", errOut)
	}
	out, _, err = run(t, ctx, sock, "--json", "track", "aprs", "--count", "2")
	if err != nil {
		t.Fatalf("ley track --json: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("want one snapshot per redraw, got %d lines:\n%s", len(lines), out)
	}
	var snap EntitySnapshot
	if err := json.Unmarshal([]byte(lines[1]), &snap); err != nil || len(snap.Entities) == 0 {
		t.Fatalf("snapshot: %v %s", err, lines[1])
	}
	e := snap.Entities[0]
	if e.DeviceID == "" || e.Protocol != "aprs" || e.Seen == 0 || e.LastSampleIndex == 0 {
		t.Errorf("entity row: %+v", e)
	}
}

// TestTrackAgesOutASilentStation: a row silent for longer than the decoder's own timeout leaves
// the table, because a row that never ages claims a transmitter is still there when it has gone.
func TestTrackAgesOutASilentStation(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	table := records.NewTable()
	table.Now = func() time.Time { return now }
	table.Apply(&leylinev1.DecodeRecord{
		Protocol: "aprs", DeviceId: "LEYTST-1", Kind: "status",
		Fields: map[string]*leylinev1.FieldValue{"text": {Value: &leylinev1.FieldValue_Text{Text: "went quiet"}}},
	})
	now = now.Add(31 * time.Minute)
	table.Apply(&leylinev1.DecodeRecord{
		Protocol: "aprs", DeviceId: "LEYTST-3", Kind: "status",
		Fields: map[string]*leylinev1.FieldValue{"text": {Value: &leylinev1.FieldValue_Text{Text: "still here"}}},
	})
	app := &App{Stdout: nil, IsTTY: func() bool { return false }}
	// The manifest's entity_silence_s, which is what the verb reads from ley decoders.
	silence := time.Duration(fakedaemon.AprsManifest().GetEntitySilenceS()) * time.Second
	table.Expire(now, silence)
	out := renderTrack(app, table)
	if strings.Contains(out, "LEYTST-1") {
		t.Errorf("a station silent for over %s must leave the table:\n%s", silence, out)
	}
	if !strings.Contains(out, "LEYTST-3") || !strings.Contains(out, "still here") {
		t.Errorf("the station still talking must stay:\n%s", out)
	}
}

// track now runs the decoder itself: with nothing decoding, `ley track aprs` starts a decode job,
// so the table fills without a second terminal (docs/plans/decoders.md, DEC-9 follow-up).
func TestTrackStartsADecoder(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "track", "aprs", "--rate", "4", "--count", "5")
	if err != nil {
		t.Fatalf("ley track: %v\n%s", err, errOut)
	}
	if !strings.Contains(out, "LEYTST-1") {
		t.Fatalf("track did not start a decoder: the table is empty\n%s", out)
	}
	// The decoder it started is ephemeral: it is gone once track exits, so it never leaves a job
	// or a channel holding the radio.
	deadline := time.Now().Add(3 * time.Second)
	for {
		jobs, lerr := c.ListJobs(context.Background())
		if lerr != nil {
			t.Fatalf("list jobs: %v", lerr)
		}
		running := 0
		for _, j := range jobs {
			if _, ok := j.GetConfig().(*leylinev1.Job_Decode); ok && j.GetState() == leylinev1.JobState_RUNNING {
				running++
			}
		}
		if running == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("track left %d decode job(s) running after it exited", running)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// A decoder already running for the protocol is rendered, not duplicated: two viewers do not mean
// two demods on the radio.
func TestTrackAttachesToARunningDecoder(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	keptJob(t, sock, c, 0) // one kept decode job for aprs
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, errOut, err := run(t, ctx, sock, "track", "aprs", "--count", "2"); err != nil {
		t.Fatalf("ley track: %v\n%s", err, errOut)
	}
	jobs, err := c.ListJobs(context.Background())
	if err != nil {
		t.Fatalf("list jobs: %v", err)
	}
	decodeJobs := 0
	for _, j := range jobs {
		if _, ok := j.GetConfig().(*leylinev1.Job_Decode); ok {
			decodeJobs++
		}
	}
	if decodeJobs != 1 {
		t.Fatalf("track started a second decoder instead of attaching: %d decode jobs", decodeJobs)
	}
}

// --attach never starts a decoder: with nothing decoding, the table is empty and no job is left.
func TestTrackAttachDoesNotStart(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "track", "aprs", "--attach", "--count", "1")
	if err != nil {
		t.Fatalf("ley track --attach: %v\n%s", err, errOut)
	}
	if strings.Contains(out, "LEYTST-1") {
		t.Errorf("--attach must not start a decoder, so the table stays empty:\n%s", out)
	}
	if !strings.Contains(errOut, "folding what is already being decoded") {
		t.Errorf("--attach must say it is only folding: %q", errOut)
	}
	jobs, err := c.ListJobs(context.Background())
	if err != nil {
		t.Fatalf("list jobs: %v", err)
	}
	for _, j := range jobs {
		if _, ok := j.GetConfig().(*leylinev1.Job_Decode); ok {
			t.Errorf("--attach started a decode job: %v", j.GetJobId())
		}
	}
}
