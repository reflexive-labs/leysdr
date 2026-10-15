// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// Speech on a stored recording end to end (docs/plans/ai-features.md, AI-5): the real daemon
// records the keyed fixture gated on its squelch, `ley transcribe` runs the real leydec-speech
// with its scripted engine over the recording, and the records, the job and the ledger are read
// back through the real `ley`. The script fixes the words, and the fixture's keying fixes where
// the overs are, so every record is graded against the part sidecars the daemon wrote.
var speechScript = []string{"alpha one", "bravo two", "charlie three", "delta four"}

// The segment rule the daemon applies to a stored part (docs/reference/writing-a-decoder.md,
// "Segmented input"), at the speech manifest's defaults.
const (
	speechPreRollMs = 500
	speechHangMs    = 500
)

// expectedSegment is one over the plugin should be handed: the part it is in, its first opening's
// 1-based index in the part's squelch_opens, and its first capture sample.
type expectedSegment struct {
	part  int
	over  int
	start uint64
}

// transcribeRig is the aiRig with a gated recording made on it and the paid copy of the speech
// decoder installed beside the bundled one.
type transcribeRig struct {
	*aiRig
	recordingID string
	dir         string
	openMs      int64
	segments    []expectedSegment
}

func TestTranscribeAgainstRealDaemon(t *testing.T) {
	decoders := os.Getenv("LEYLINE_DECODERS")
	if decoders == "" {
		t.Skip("set LEYLINE_DECODERS to the repository's decoders/ directory (make e2e does)")
	}
	fixture, err := filepath.Abs("../../../fixtures/nfm_keyed.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	r := newTranscribeRig(t, decoders, fixture)

	t.Run("decoders lists speech as segmented", func(t *testing.T) { checkSpeechListed(t, r) })
	t.Run("refuses without a terminal or --yes", func(t *testing.T) { checkTranscribeRefusal(t, r) })
	first := r.transcribe(t, "speech", "")
	t.Run("records the job kept", func(t *testing.T) { checkStoredRecords(t, r, first) })
	t.Run("ledger line", func(t *testing.T) { checkSpeechUsage(t, r, first) })
	t.Run("again", func(t *testing.T) {
		second := r.transcribe(t, "speech", "")
		if second.jobID == first.jobID {
			t.Fatalf("a second transcription reused job %s", first.jobID)
		}
		for i, rec := range second.records {
			if rec.GetRecordId() == first.records[i].GetRecordId() {
				t.Errorf("record %d of the second job has the first's id %s", i, rec.GetRecordId())
			}
		}
		checkStoredRecords(t, r, first)
		checkStoredRecords(t, r, second)
	})
	t.Run("a decoder that needs a key", func(t *testing.T) { checkPaidSpeech(t, r) })
}

// newTranscribeRig starts the daemon with a scripted check worker, the repository's decoders and
// a temp directory holding speechpaid, then makes a gated recording of the looping keyed fixture
// and works out from its sidecars the segments a transcription must produce.
func newTranscribeRig(t *testing.T, decoders, fixture string) *transcribeRig {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "script.txt")
	if err := os.WriteFile(script, []byte(strings.Join(speechScript, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// The daemon's environment is the plugin's, so the scripted engine finds its words.
	t.Setenv("LEYDEC_SPEECH_SCRIPT", script)

	ar := &aiRig{
		t: t, dir: dir, data: filepath.Join(dir, "data"), store: filepath.Join(dir, "store"),
		logFile: filepath.Join(dir, "leylined.log"), workerBin: filepath.Join(dir, "ley"),
	}
	ar.daemonArgs = []string{
		"--no-hardware", "--data", ar.data, "--store", ar.store, "--ley", ar.workerBin, "--log-file", ar.logFile,
		"--recordings", filepath.Join(dir, "recordings"),
		"--decoders", decoders, "--decoders", writePaidSpeechDecoder(t, decoders, dir),
	}
	t.Cleanup(func() {
		if t.Failed() {
			b, _ := os.ReadFile(ar.logFile)
			t.Logf("leylined log file:\n%s\nley transcript:\n%s", b, ar.transcript.String())
		}
	})
	ar.useWorker("accepted")
	ar.start()
	r := &transcribeRig{aiRig: ar}
	r.record(fixture)
	return r
}

// writePaidSpeechDecoder installs a copy of the bundled speech manifest named speechpaid that
// names a provider and a host, in a directory of its own, and returns the directory. The alias
// is dropped so that `transcribe` still means the bundled decoder; the executable and args are
// the bundled ones, so the unchanged leydec-speech binary, whose own manifest names no provider,
// learns from LEYLINE_KEY_ON_STDIN that the key comes first.
func writePaidSpeechDecoder(t *testing.T, decoders, dir string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(decoders, "speech", "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	m["name"] = "speechpaid"
	delete(m, "aliases")
	m["credentialProvider"] = "anthropic"
	m["contactsHosts"] = []string{"api.example.test"}
	out, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	paid := filepath.Join(dir, "paid-decoders")
	if err := os.MkdirAll(filepath.Join(paid, "speechpaid"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(paid, "speechpaid", "manifest.json"), out, 0o644); err != nil {
		t.Fatal(err)
	}
	return paid
}

// record makes a ~14 s gated recording of the keyed fixture looping. The fixture keys at 1, 5
// and 8.5 s and is 10.5 s long, so the loop keys again at 11.5 s: with a 2 s hang the 3 s floors
// cut parts and the 1 s floor across the loop does not, which gives a part holding two openings
// far enough apart to be two segments.
func (r *transcribeRig) record(fixture string) {
	t := r.t
	t.Helper()
	r.mustLey("", "play", fixture, "--no-audio", "--loop", "--persistent", "--json")
	r.mustLey("", "stop", "all")
	deadline := time.Now().Add(5 * time.Second)
	for {
		st := r.state()
		if len(list(st, "captures")) == 0 && len(list(st, "devices")) > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the fixture never became an idle radio: %v", st)
		}
		time.Sleep(50 * time.Millisecond)
	}
	out, _ := r.mustLey("", "record", "146.62", "--gate", "squelch", "--squelch", "-40", "--hang", "2s", "--for", "14s")
	uri := strings.TrimSpace(out)
	id, part, ok := leyline.ParseRecordingURI(uri)
	if !ok || part != 0 {
		t.Fatalf("ley record printed %q, want the recording's uri", out)
	}
	r.recordingID = id

	// The manifest as ley shows it: every part says how long its squelch was open.
	shown, _ := r.mustLey("", "recordings", "show", id, "--json")
	manifest := parseJSON(t, shown)
	for _, p := range list(manifest, "parts") {
		ms, ok := p.(map[string]any)["squelch_open_ms"].(float64)
		if !ok || ms <= 0 {
			t.Fatalf("a part of a gated recording lacks squelch_open_ms: %v", p)
		}
		r.openMs += int64(ms)
	}

	path, _ := r.mustLey("", "recordings", "path", id)
	r.dir = strings.TrimSpace(path)
	m, err := leyline.ReadRecordingManifest(r.dir)
	if err != nil {
		t.Fatal(err)
	}
	opens := 0
	for _, p := range m.Parts {
		sc, err := leyline.ReadPartSidecar(r.dir, p)
		if err != nil {
			t.Fatal(err)
		}
		opens += len(sc.Recording.SquelchOpens)
		r.segments = append(r.segments, cutPart(p, sc)...)
	}
	if opens < 3 || len(r.segments) < 3 {
		t.Fatalf("the recording has %d openings and %d segments, want at least 3 of each: %s", opens, len(r.segments), shown)
	}
	if len(r.segments) > len(speechScript) {
		t.Fatalf("%d segments outrun the %d-line script, so the words would not tell them apart: %s",
			len(r.segments), len(speechScript), shown)
	}
	t.Logf("recording %s: %d parts, %d openings, %d segments, %d ms open", id, len(m.Parts), opens, len(r.segments), r.openMs)
}

// cutPart is the daemon's stored segment rule, written again from the reference: each opening
// starts a segment the pre-roll early, clamped to the part's start and the previous segment's
// end; it ends the hang after the close; an opening before the current segment's end continues it.
func cutPart(p leyline.RecordingPart, sc *leyline.RecordingSidecar) []expectedSegment {
	rate := float64(sc.Anchor.SampleRate)
	preRoll := uint64(speechPreRollMs * rate / 1000)
	hang := uint64(speechHangMs * rate / 1000)
	type span struct {
		expectedSegment
		end uint64
	}
	var spans []span
	for i, o := range sc.Recording.SquelchOpens {
		closeAt := max(o.CloseSample, o.OpenSample)
		if n := len(spans); n > 0 && o.OpenSample < spans[n-1].end {
			spans[n-1].end = max(spans[n-1].end, closeAt+hang)
			continue
		}
		floor := p.StartSample
		if n := len(spans); n > 0 {
			floor = max(floor, spans[n-1].end)
		}
		start := uint64(0)
		if o.OpenSample > preRoll {
			start = o.OpenSample - preRoll
		}
		spans = append(spans, span{expectedSegment{part: p.Part, over: i + 1, start: max(start, floor)}, closeAt + hang})
	}
	var out []expectedSegment
	for _, s := range spans {
		if min(s.end, p.EndSample) > s.start {
			out = append(out, s.expectedSegment)
		}
	}
	return out
}

// transcription is one `ley transcribe --yes --json` run: its job and its records in time order.
type transcription struct {
	jobID   string
	records []*leylinev1.DecodeRecord
	stderr  string
}

// transcribe runs the decoder over the recording with --yes --json and checks every record
// against the expected segments, the job's end, and how long it took.
func (r *transcribeRig) transcribe(t *testing.T, decoder, model string) transcription {
	t.Helper()
	args := []string{"transcribe", r.recordingID, "--yes", "--json"}
	if decoder != "speech" {
		args = append(args, "--engine", decoder)
	}
	if model != "" {
		args = append(args, "--model", model)
	}
	began := time.Now()
	out, errOut, code := r.callWithin(30*time.Second, args...)
	took := time.Since(began)
	if code != 0 {
		t.Fatalf("ley %s: exit %d\nstdout: %s\nstderr: %s", strings.Join(args, " "), code, out, errOut)
	}
	if took > 5*time.Second {
		t.Errorf("transcribing %d ms of overs took %v, want under 5 s", r.openMs, took)
	}
	var tr transcription
	tr.stderr = errOut
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		rec := &leylinev1.DecodeRecord{}
		unmarshalProto(t, line, rec)
		tr.records = append(tr.records, rec)
	}
	sortBySample(tr.records)
	if len(tr.records) != len(r.segments) {
		t.Fatalf("want one record per segment, %d, got %d:\n%s", len(r.segments), len(tr.records), out)
	}
	tr.jobID = tr.records[0].GetJobId()
	wantModel := "scripted"
	if model != "" {
		wantModel = model
	}
	for i, rec := range tr.records {
		r.checkSpeechRecord(t, i, rec, tr.jobID, wantModel)
	}
	r.checkJobCompleted(t, tr.jobID)
	return tr
}

// checkSpeechRecord grades record i against segment i and line i of the script.
func (r *transcribeRig) checkSpeechRecord(t *testing.T, i int, rec *leylinev1.DecodeRecord, jobID, model string) {
	t.Helper()
	seg := r.segments[i]
	f := rec.GetFields()
	if rec.GetProtocol() != "speech" && rec.GetProtocol() != "speechpaid" {
		t.Errorf("record %d: protocol %q", i, rec.GetProtocol())
	}
	if got := f["text"].GetText(); got != speechScript[i] {
		t.Errorf("record %d: text %q, want the script's %q", i, got, speechScript[i])
	}
	if want := leyline.RecordingPartURI(r.recordingID, seg.part); rec.GetClipUri() != want {
		t.Errorf("record %d: clipUri %q, want %q", i, rec.GetClipUri(), want)
	}
	if int(rec.GetOver()) != seg.over {
		t.Errorf("record %d: over %d, want %d (part %d)", i, rec.GetOver(), seg.over, seg.part)
	}
	if got := rec.GetTime().GetSampleIndex(); got != seg.start {
		t.Errorf("record %d: time.sampleIndex %d, want the segment's start %d", i, got, seg.start)
	}
	if rec.GetJobId() != jobID {
		t.Errorf("record %d: jobId %q, want %q", i, rec.GetJobId(), jobID)
	}
	u := rec.GetUsage()
	if u.GetProvider() != "scripted" || u.GetRequests() != 1 || u.GetFeature() != "speech" || u.GetJobId() != jobID ||
		u.GetAudioSeconds() <= 0 {
		t.Errorf("record %d: usage %v", i, u)
	}
	if got := f["model"].GetText(); got != model {
		t.Errorf("record %d: fields.model %q, want %q", i, got, model)
	}
	if c, ok := f["callsigns"]; !ok || c.GetText() != "" {
		t.Errorf("record %d: fields.callsigns %v, want present and empty", i, c)
	}
}

// checkJobCompleted finds the job in `ley jobs --json` and wants it COMPLETED.
func (r *transcribeRig) checkJobCompleted(t *testing.T, jobID string) {
	t.Helper()
	out, _ := r.mustLey("", "jobs", "--json")
	var jobs leylinev1.ListJobsResponse
	unmarshalProto(t, out, &jobs)
	for _, j := range jobs.GetJobs() {
		if j.GetJobId() == jobID {
			if j.GetState() != leylinev1.JobState_COMPLETED {
				t.Errorf("job %s ended %v, want COMPLETED: %v", jobID, j.GetState(), j)
			}
			return
		}
	}
	t.Errorf("ley jobs --json does not list %s: %s", jobID, out)
}

func checkSpeechListed(t *testing.T, r *transcribeRig) {
	out, _ := r.mustLey("", "decoders", "--json")
	var resp leylinev1.ListDecodersResponse
	unmarshalProto(t, out, &resp)
	for _, d := range resp.GetDecoders() {
		if d.GetName() != "speech" {
			continue
		}
		if d.GetInput().GetMode() != leylinev1.InputMode_SEGMENTED {
			t.Errorf("speech input mode %v, want SEGMENTED", d.GetInput().GetMode())
		}
		if fs := d.GetRecipe().GetFrequenciesHz(); len(fs) != 0 {
			t.Errorf("speech names frequencies %v; it decodes whatever is recorded", fs)
		}
		return
	}
	t.Fatalf("ley decoders --json lists no speech decoder: %s", out)
}

// checkTranscribeRefusal: off a terminal and without --yes nothing is sent, and the statement
// gives the squelch-open minutes the manifest sums to.
func checkTranscribeRefusal(t *testing.T, r *transcribeRig) {
	out, errOut, code := r.call("", nil, "transcribe", r.recordingID)
	if code != 2 {
		t.Errorf("ley transcribe without --yes off a terminal: exit %d, want 2\n%s", code, errOut)
	}
	if out != "" {
		t.Errorf("the refusal printed on stdout: %q", out)
	}
	minutes := fmt.Sprintf("%.1f min of squelch-open audio", float64(r.openMs)/60000)
	for _, want := range []string{minutes, "no audio leaves", "--yes"} {
		if !strings.Contains(errOut, want) {
			t.Errorf("the refusal lacks %q:\n%s", want, errOut)
		}
	}
	if jobs := r.speechJobs(t); len(jobs) != 0 {
		t.Errorf("a refused transcription started jobs: %v", jobs)
	}
}

// speechJobs is the ids of the jobs `ley jobs --json` lists other than the recording.
func (r *transcribeRig) speechJobs(t *testing.T) []string {
	t.Helper()
	out, _ := r.mustLey("", "jobs", "--json")
	var jobs leylinev1.ListJobsResponse
	unmarshalProto(t, out, &jobs)
	var ids []string
	for _, j := range jobs.GetJobs() {
		if j.GetJobId() != r.recordingID {
			ids = append(ids, j.GetJobId())
		}
	}
	return ids
}

// checkStoredRecords: `ley records` reads back the job's records, the same ids.
func checkStoredRecords(t *testing.T, r *transcribeRig, tr transcription) {
	t.Helper()
	out, _ := r.mustLey("", "records", "--protocol", "speech", "--job-id", tr.jobID, "--json")
	var page leylinev1.RecordPage
	unmarshalProto(t, out, &page)
	stored := page.GetRecords()
	sortBySample(stored)
	if len(stored) != len(tr.records) {
		t.Fatalf("ley records for %s: %d records, transcribe printed %d", tr.jobID, len(stored), len(tr.records))
	}
	for i, rec := range stored {
		if rec.GetRecordId() != tr.records[i].GetRecordId() || rec.GetJobId() != tr.jobID {
			t.Errorf("stored record %d is %s of %s, transcribe printed %s", i, rec.GetRecordId(), rec.GetJobId(),
				tr.records[i].GetRecordId())
		}
	}
}

// checkSpeechUsage: the ledger holds the job's line with the scripted engine's report.
func checkSpeechUsage(t *testing.T, r *transcribeRig, tr transcription) {
	out, _ := r.mustLey("", "ai", "usage", "--json")
	var usage leylinev1.GetUsageResponse
	unmarshalProto(t, out, &usage)
	for _, l := range usage.GetLines() {
		if l.GetScopeId() != tr.jobID {
			continue
		}
		if l.GetProvider() != "scripted" || l.GetFeature() != "speech" || l.GetAudioSeconds() <= 0 ||
			l.GetRequests() != uint64(len(tr.records)) {
			t.Errorf("the job's ledger line: %v, want scripted speech, audio, %d requests", l, len(tr.records))
		}
		return
	}
	t.Errorf("ley ai usage --json has no line for %s: %s", tr.jobID, out)
}

// checkPaidSpeech: a decoder that names a provider is refused until its key is set, is handed the
// key and the chosen model once it is, and the key shows up nowhere a person or a file can see.
func checkPaidSpeech(t *testing.T, r *transcribeRig) {
	_, errOut, code := r.callWithin(30*time.Second, "transcribe", r.recordingID, "--engine", "speechpaid", "--yes")
	if code != 1 || !strings.Contains(errOut, "[CREDENTIAL_MISSING]") || !strings.Contains(errOut, "ley ai add anthropic") {
		t.Errorf("speechpaid with no key: exit %d, want 1 naming CREDENTIAL_MISSING and ley ai add anthropic\n%s", code, errOut)
	}

	r.mustLey(anthropicKey+"\n", "ai", "add", "anthropic")
	tr := r.transcribe(t, "speechpaid", "nova-9")
	for _, want := range []string{"sends the audio to api.example.test", "nova-9"} {
		if !strings.Contains(tr.stderr, want) {
			t.Errorf("the statement lacks %q:\n%s", want, tr.stderr)
		}
	}
	var speech map[string]any
	for _, f := range list(r.aiState(), "features") {
		if m := f.(map[string]any); m["feature"] == "speech" {
			speech = m
		}
	}
	if speech["provider"] != "anthropic" || speech["model"] != "nova-9" {
		t.Errorf("ley ai --json speech feature: %v, want anthropic nova-9", speech)
	}
	// The store holds the records and the daemon's log is in --log-file, so this covers every
	// ley output, every record and the log.
	r.assertNoCanary()
}

// callWithin is aiRig.call with no stdin and a deadline: a transcription whose job never ends
// would otherwise hold the test until go test's own timeout. Past the deadline ley is killed and
// the test fails with what it had written.
func (r *aiRig) callWithin(d time.Duration, args ...string) (stdout, stderr string, code int) {
	r.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	cmd := exec.CommandContext(ctx, r.ley, append([]string{"--socket", r.socket}, args...)...)
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err := cmd.Run()
	r.mu.Lock()
	r.transcript.WriteString("$ ley " + strings.Join(args, " ") + "\n" + out.String() + errOut.String())
	r.mu.Unlock()
	var exitErr *exec.ExitError
	switch {
	case ctx.Err() != nil:
		r.t.Fatalf("ley %s did not finish within %v\nstdout: %s\nstderr: %s", strings.Join(args, " "), d, out.String(), errOut.String())
	case err == nil:
	case errors.As(err, &exitErr):
		code = exitErr.ExitCode()
	default:
		r.t.Fatalf("ley %v: %v", args, err)
	}
	return out.String(), errOut.String(), code
}

// sortBySample puts records in capture-time order, which is segment order.
func sortBySample(recs []*leylinev1.DecodeRecord) {
	sort.Slice(recs, func(i, j int) bool { return recs[i].GetTime().GetSampleIndex() < recs[j].GetTime().GetSampleIndex() })
}

func unmarshalProto(t *testing.T, s string, m proto.Message) {
	t.Helper()
	if err := (protojson.UnmarshalOptions{DiscardUnknown: true}).Unmarshal([]byte(s), m); err != nil {
		t.Fatalf("bad %T JSON %q: %v", m, s, err)
	}
}
