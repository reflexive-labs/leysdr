// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"math"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// seededID is the id the tests give their seeded recording: a job id of the daemon's length.
const seededID = "job_01SEEDSEEDSEEDSEEDSEEDSE"

// seeded is a gated recording of two parts. Part 1 holds three overs, the first two 300 ms
// apart, inside the 500 ms hang, so they are one segment; part 2 holds one.
func seeded(noOpenMs bool) fakedaemon.SeedRecording {
	return fakedaemon.SeedRecording{
		JobID: seededID, NoSquelchOpenMs: noOpenMs,
		Parts: [][]fakedaemon.SeedOver{
			{{OpenMs: 600, CloseMs: 1600}, {OpenMs: 1900, CloseMs: 2500}, {OpenMs: 4000, CloseMs: 5000}},
			{{OpenMs: 600, CloseMs: 1200}},
		},
	}
}

// The speech decoders are listed as decoders/speech/manifest.json and
// decoders/speech-scripted/manifest.json have them.
func TestSpeechManifestsMatchTheFiles(t *testing.T) {
	for dir, fake := range map[string]*leylinev1.DecoderManifest{
		"speech":          fakedaemon.SpeechManifest(),
		"speech-scripted": fakedaemon.ScriptedSpeechManifest(),
	} {
		data, err := os.ReadFile("../../../decoders/" + dir + "/manifest.json")
		if err != nil {
			t.Fatal(err)
		}
		var fromFile leylinev1.DecoderManifest
		if err := protojson.Unmarshal(data, &fromFile); err != nil {
			t.Fatal(err)
		}
		if !proto.Equal(&fromFile, fake) {
			t.Errorf("the fake's %s manifest and decoders/%s/manifest.json differ:\nfile: %v\nfake: %v", dir, dir, &fromFile, fake)
		}
	}
}

// A seeded recording reads back through the manifest: squelch_open_ms when it is written, the
// sidecars' squelch_opens when it is not, and the same total either way.
func TestASeededRecordingCountsItsSquelchOpenTime(t *testing.T) {
	for _, noOpenMs := range []bool{false, true} {
		dir := t.TempDir()
		c, _ := harness(t, fakedaemon.Options{RecordingsDir: dir, Recordings: []fakedaemon.SeedRecording{seeded(noOpenMs)}})
		path, err := c.ResolveLocalPath(t.Context(), leyline.RecordingURI(seededID))
		if err != nil {
			t.Fatal(err)
		}
		m, err := leyline.ReadRecordingManifest(path)
		if err != nil {
			t.Fatal(err)
		}
		if len(m.Parts) != 2 || m.Parts[0].SquelchOpens != 3 || (m.Parts[0].SquelchOpenMs == nil) != noOpenMs {
			t.Fatalf("manifest parts: %+v", m.Parts)
		}
		got, err := m.SquelchOpenTime(path)
		if err != nil {
			t.Fatal(err)
		}
		if want := 3200 * time.Millisecond; got != want {
			t.Errorf("without squelch_open_ms = %v: open time %v, want %v", noOpenMs, got, want)
		}
	}
}

// A decode job on a recording emits one speech record per segment, stamped with its part, its
// first over, the time pre-roll before that over opened and what it used, then ends COMPLETED;
// the kept records come back from the store with the recording's anchor and the ledger counts
// the audio.
func TestSpeechJobOnARecording(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{
		RecordingsDir: t.TempDir(), Recordings: []fakedaemon.SeedRecording{seeded(true)},
		SpeechScript: []string{"this is whiskey six alpha bravo charlie", "roger"},
	})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	job, err := c.StartDecode(ctx, &leylinev1.DecodeConfig{Decoder: "speech-scripted", SourceUri: leyline.RecordingURI(seededID), Keep: true})
	if err != nil {
		t.Fatal(err)
	}
	if done := awaitJob(t, c, job.GetJobId()); done.GetState() != leylinev1.JobState_COMPLETED {
		t.Fatalf("the job ended %v: %s", done.GetState(), done.GetStatusDetail())
	}
	page, err := c.QueryRecords(ctx, &leylinev1.RecordQuery{JobId: job.GetJobId()})
	if err != nil {
		t.Fatal(err)
	}
	recs := page.GetRecords()
	if len(recs) != 3 {
		t.Fatalf("want 3 records (two segments in part 1, one in part 2), got %d", len(recs))
	}
	// Newest first from the store.
	slices.Reverse(recs)
	type want struct {
		clip            string
		over            uint32
		openMs, closeMs int64 // in the recording's timeline, from its first sample
		text, calls     string
	}
	part2 := int64(5000 + 1000 + 10_000)
	wants := []want{
		{leyline.RecordingPartURI(seededID, 1), 1, 600, 2500, "this is whiskey six alpha bravo charlie", "W6ABC"},
		{leyline.RecordingPartURI(seededID, 1), 3, 4000, 5000, "roger", ""},
		{leyline.RecordingPartURI(seededID, 2), 1, part2 + 600, part2 + 1200, "roger", ""},
	}
	for i, w := range wants {
		rec := recs[i]
		if rec.GetClipUri() != w.clip || rec.GetOver() != w.over || rec.GetSeq() != uint64(i+1) {
			t.Errorf("record %d: clip %q over %d seq %d, want %q over %d", i+1, rec.GetClipUri(), rec.GetOver(), rec.GetSeq(), w.clip, w.over)
		}
		if at := rec.GetTime().GetSampleIndex(); at != uint64(w.openMs-500)*2400 {
			t.Errorf("record %d at sample %d, want pre-roll before the over: %d", i+1, at, uint64(w.openMs-500)*2400)
		}
		f := rec.GetFields()
		if f["text"].GetText() != w.text || f["callsigns"].GetText() != w.calls || f["model"].GetText() != "scripted" {
			t.Errorf("record %d fields: %v", i+1, f)
		}
		u := rec.GetUsage()
		secs := float64(w.closeMs+500-(w.openMs-500)) / 1000
		if u.GetFeature() != "speech" || u.GetJobId() != job.GetJobId() || u.GetRequests() != 1 || math.Abs(u.GetAudioSeconds()-secs) > 1e-6 {
			t.Errorf("record %d usage %v, want %v s", i+1, u, secs)
		}
		if _, ok := leyline.RecordWallTime(rec, page.GetAnchors()); !ok {
			t.Errorf("record %d has no anchor to date it by", i+1)
		}
	}
	usage, err := c.Usage.GetUsage(ctx, &leylinev1.GetUsageRequest{Feature: "speech"})
	if err != nil {
		t.Fatal(err)
	}
	if lines := usage.GetLines(); len(lines) != 1 || lines[0].GetRequests() != 3 || lines[0].GetScopeId() != job.GetJobId() {
		t.Errorf("ledger: %v", lines)
	}
}

// The refusals a recording source answers at once.
func TestSpeechJobRefusals(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{RecordingsDir: t.TempDir(), Recordings: []fakedaemon.SeedRecording{seeded(false)}})
	ctx := t.Context()
	for _, tc := range []struct {
		cfg  *leylinev1.DecodeConfig
		code string
	}{
		{&leylinev1.DecodeConfig{Decoder: "speech-scripted", SourceUri: leyline.RecordingURI("job_01NOSUCHNOSUCHNOSUCHNOSUC")}, leyline.CodeJobNotFound},
		{&leylinev1.DecodeConfig{Decoder: "speech-scripted", SourceUri: leyline.RecordingPartURI(seededID, 1)}, leyline.CodeInvalidArgument},
		// On a radio, speech has no frequency of its own.
		{&leylinev1.DecodeConfig{Decoder: "speech-scripted"}, leyline.CodeInvalidArgument},
		// The bundled speech decoder calls OpenAI, so it needs that key.
		{&leylinev1.DecodeConfig{Decoder: "speech", SourceUri: leyline.RecordingURI(seededID)}, leyline.CodeCredentialMissing},
	} {
		if _, err := c.StartDecode(ctx, tc.cfg); leyline.Code(err) != tc.code {
			t.Errorf("%v: code %q (%v), want %s", tc.cfg, leyline.Code(err), err, tc.code)
		}
	}
}

// A speech decoder that names a provider is refused without its key, names the command that adds
// one, and once the key is set runs with the model chosen for speech.
func TestSpeechNeedsItsKey(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{
		RecordingsDir: t.TempDir(), Recordings: []fakedaemon.SeedRecording{seeded(false)},
		SpeechProvider: "deepgram", SpeechHosts: []string{"api.deepgram.com"},
	})
	ctx := t.Context()
	cfg := &leylinev1.DecodeConfig{Decoder: "speech", SourceUri: leyline.RecordingURI(seededID), Keep: true}
	_, err := c.StartDecode(ctx, cfg)
	if leyline.Code(err) != leyline.CodeCredentialMissing || !strings.Contains(err.Error(), "ley ai add deepgram") {
		t.Fatalf("want CREDENTIAL_MISSING naming ley ai add deepgram, got %v", err)
	}
	if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: "deepgram", Secret: "dg-1234"}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "speech", Provider: "deepgram", Model: "nova-3"}); err != nil {
		t.Fatal(err)
	}
	job, err := c.StartDecode(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	awaitJob(t, c, job.GetJobId())
	page, err := c.QueryRecords(ctx, &leylinev1.RecordQuery{JobId: job.GetJobId()})
	if err != nil || len(page.GetRecords()) == 0 {
		t.Fatalf("no records: %v", err)
	}
	for _, rec := range page.GetRecords() {
		if rec.GetUsage().GetProvider() != "deepgram" || rec.GetUsage().GetModel() != "nova-3" || rec.GetFields()["model"].GetText() != "nova-3" {
			t.Errorf("record used %v", rec.GetUsage())
		}
	}
	st, err := c.Credentials.GetAIState(ctx, &leylinev1.GetAIStateRequest{})
	if err != nil || len(st.GetCredentials()) != 1 || st.GetCredentials()[0].GetLastUsedAtNs() == 0 {
		t.Errorf("the key is not marked used: %v %v", st, err)
	}
}

// A key the provider refused is CREDENTIAL_REJECTED at start, with the provider's words and the
// command that replaces it.
func TestSpeechRefusesARejectedKey(t *testing.T) {
	c, _ := harness(t, fakedaemon.Options{
		RecordingsDir: t.TempDir(), Recordings: []fakedaemon.SeedRecording{seeded(false)},
		SpeechProvider: "deepgram",
	})
	ctx := t.Context()
	if _, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{Provider: "deepgram", Secret: fakedaemon.RejectedSecret}); err != nil {
		t.Fatal(err)
	}
	_, err := c.StartDecode(ctx, &leylinev1.DecodeConfig{Decoder: "speech", SourceUri: leyline.RecordingURI(seededID), Keep: true})
	if leyline.Code(err) != leyline.CodeCredentialRejected || !strings.Contains(err.Error(), "invalid x-api-key") || !strings.Contains(err.Error(), "ley ai add deepgram") {
		t.Fatalf("want CREDENTIAL_REJECTED with the provider's words and ley ai add deepgram, got %v", err)
	}
	jobs, err := c.ListJobs(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, j := range jobs {
		if j.GetDecode() != nil {
			t.Errorf("a refused decode left a job: %v", j)
		}
	}
}

// A gated recording the fake makes lists its over in the part sidecar, so it can be transcribed.
func TestAGatedRecordingListsItsOvers(t *testing.T) {
	dir := t.TempDir()
	c, _ := harness(t, fakedaemon.Options{RecordingsDir: dir, RecordGateAt: []int64{0, 300}})
	job := record(t, c, &leylinev1.RecordConfig{FrequencyHz: 146_520_000, Mode: leylinev1.DemodMode_NFM, Gate: leylinev1.RecordGate_SQUELCH, DurationMs: 500})
	awaitJob(t, c, job.GetJobId())
	path, err := c.ResolveLocalPath(t.Context(), leyline.RecordingURI(job.GetJobId()))
	if err != nil {
		t.Fatal(err)
	}
	m, err := leyline.ReadRecordingManifest(path)
	if err != nil || len(m.Parts) != 1 {
		t.Fatalf("manifest: %v %v", m, err)
	}
	sc, err := leyline.ReadPartSidecar(path, m.Parts[0])
	if err != nil {
		t.Fatal(err)
	}
	if len(sc.Recording.SquelchOpens) != 1 || sc.Anchor.SampleRate != m.Anchors[0].SampleRate {
		t.Errorf("sidecar: %+v", sc)
	}
	if m.Parts[0].SquelchOpenMs == nil || *m.Parts[0].SquelchOpenMs <= 0 {
		t.Errorf("squelch_open_ms: %v", m.Parts[0].SquelchOpenMs)
	}
}
