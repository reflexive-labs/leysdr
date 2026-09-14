// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/records"
)

// The registry table leads with the name, because the name is what `ley decode` is given, and
// says where the daemon looked on stderr, where it cannot reach a pipe.
func TestDecodersTableAndJSON(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, context.Background(), sock, "decoders")
	if err != nil {
		t.Fatalf("ley decoders: %v", err)
	}
	if head := strings.Fields(out)[0]; head != "NAME" || !strings.Contains(out, "aprs") {
		t.Fatalf("unexpected table:\n%s", out)
	}
	for _, want := range []string{"144.390 MHz", "NFM", "records, entities", "0.1.0"} {
		if !strings.Contains(out, want) {
			t.Errorf("the table lacks %q:\n%s", want, out)
		}
	}
	if !strings.Contains(errOut, "looked in") || !strings.Contains(errOut, "90 days") {
		t.Errorf("the search path and retention belong on stderr: %q", errOut)
	}
	out = mustRun(t, sock, "--json", "decoders")
	var resp struct {
		Decoders   []map[string]any `json:"decoders"`
		SearchPath []string         `json:"searchPath"`
		StorePath  string           `json:"storePath"`
	}
	if err := json.Unmarshal([]byte(out), &resp); err != nil || len(resp.Decoders) != 1 {
		t.Fatalf("json decoders: %v %s", err, out)
	}
	if resp.Decoders[0]["name"] != "aprs" || len(resp.SearchPath) == 0 || resp.StorePath == "" {
		t.Errorf("json shape: %s", out)
	}
}

// decode prints one line per record on stdout and its banner on stderr, and --json turns the
// same records into NDJSON with nothing else in the pipe.
func TestDecodePrintsRecords(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "decode", "aprs", "--count", "3")
	if err != nil {
		t.Fatalf("ley decode: %v\n%s", err, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 3 {
		t.Fatalf("want three records, got:\n%s", out)
	}
	if !strings.Contains(lines[0], "LEYTST-1") || !strings.Contains(lines[0], "position") || !strings.Contains(lines[0], "37.7600N") {
		t.Errorf("the first line must carry who, what and what they said: %q", lines[0])
	}
	if !strings.Contains(errOut, "decoding aprs on 144.390 MHz") || !strings.Contains(errOut, "chan_") {
		t.Errorf("the banner must name the decoder, the frequency and the channel: %q", errOut)
	}

	out, errOut, err = run(t, ctx, sock, "--json", "decode", "aprs", "--count", "2")
	if err != nil {
		t.Fatalf("ley decode --json: %v", err)
	}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("NDJSON line is not JSON (%v): %s", err, line)
		}
		if rec["protocol"] != "aprs" || rec["recordId"] == nil || rec["seq"] == nil {
			t.Errorf("record shape: %s", line)
		}
	}
	if strings.Contains(out, "decoding aprs") || !strings.Contains(errOut, "decoding aprs") {
		t.Errorf("the banner belongs on stderr, whatever the format")
	}
}

// A decoder nobody installed is a plain sentence with the next command, and the daemon's code
// in brackets, as every error line is.
func TestDecodeUnknownDecoder(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	_, _, err := run(t, context.Background(), sock, "decode", "nosuch")
	if exitCode(err) != 1 || err == nil {
		t.Fatalf("exit %d (%v), want 1", exitCode(err), err)
	}
	msg := err.Error()
	if !strings.Contains(msg, `there is no decoder called "nosuch"`) || !strings.Contains(msg, "ley decoders") ||
		!strings.Contains(msg, "[DECODER_NOT_FOUND]") {
		t.Errorf("message: %q", msg)
	}
}

// TestDecodeStopsAnEphemeralJob: a decode run with no --job takes the radio for as long as it
// runs and hands it back when it stops, channel and capture and all.
func TestDecodeStopsAnEphemeralJob(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, _, err := run(t, ctx, sock, "decode", "aprs", "--count", "2"); err != nil {
		t.Fatalf("ley decode: %v", err)
	}
	jobs, err := c.ListJobs(ctx)
	if err != nil || len(jobs) != 1 {
		t.Fatalf("jobs: %v (%v)", jobs, err)
	}
	if jobs[0].GetState() != leylinev1.JobState_CANCELLED {
		t.Errorf("the job is %s, want CANCELLED", jobs[0].GetState())
	}
	st, err := c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Channels) != 0 || len(st.Captures) != 0 {
		t.Errorf("the radio must be free again: %d channels, %d captures", len(st.Channels), len(st.Captures))
	}
}

// TestDecodeJobOutlivesTheClient: --job is the reader saying the records matter more than this
// terminal, so the job keeps running after ley exits and says how to stop it.
func TestDecodeJobOutlivesTheClient(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{PresenceGrace: 100 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "decode", "aprs", "--job", "--count", "2")
	if err != nil {
		t.Fatalf("ley decode --job: %v", err)
	}
	if !strings.Contains(errOut, "left running") || !strings.Contains(errOut, "ley jobs cancel") {
		t.Errorf("stderr must say the job is still running and how to stop it: %q", errOut)
	}
	if len(strings.Split(strings.TrimSpace(out), "\n")) != 2 {
		t.Errorf("stdout is the records and nothing else:\n%s", out)
	}
	// Well past the presence grace: a kept job is not reaped with its client.
	time.Sleep(400 * time.Millisecond)
	jobs, err := c.ListJobs(ctx)
	if err != nil || len(jobs) != 1 {
		t.Fatalf("jobs: %v (%v)", jobs, err)
	}
	if jobs[0].GetState() != leylinev1.JobState_RUNNING {
		t.Fatalf("the kept job is %s, want RUNNING", jobs[0].GetState())
	}
	table := mustRun(t, sock, "jobs")
	if !strings.Contains(table, "decode") || !strings.Contains(table, "recipe") || !strings.Contains(table, "running") {
		t.Errorf("ley jobs must show the decode job on its recipe:\n%s", table)
	}
	if _, err := c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: jobs[0].GetJobId()}); err != nil {
		t.Fatal(err)
	}
}

// Every decode screen must read the same with colour off: the words carry the meaning and the
// ink only helps the eye find it (docs/dev/cli-style.md, section 1).
func TestDecodeScreensSurviveColourOff(t *testing.T) {
	page := &leylinev1.RecordPage{
		Records: []*leylinev1.DecodeRecord{{
			Protocol: "aprs", DeviceId: "LEYTST-1", Kind: "position",
			Position: &leylinev1.Position{Latitude: 37.76, Longitude: -122.42},
			Time:     &leylinev1.SampleTime{CaptureId: "cap_1", SampleIndex: 2_400_000},
		}, {Protocol: "aprs", DeviceId: "LEYTST-3", Kind: "status"}},
		Anchors: []*leylinev1.RecordAnchor{{
			Anchor: &leylinev1.CaptureAnchor{CaptureId: "cap_1", HostTimeNs: time.Now().UnixNano(), SampleRate: 2_400_000},
		}},
	}
	list := &leylinev1.ListDecodersResponse{
		Decoders:   []*leylinev1.DecoderManifest{fakedaemon.AprsManifest()},
		SearchPath: []string{"/fake/decoders"}, StorePath: "/fake/store",
		StoreCapBytes: 2 << 30, StoreAgeDays: 90,
	}
	table := records.NewTable()
	table.Apply(page.Records[0])
	table.Apply(page.Records[1])

	// Colour is compared at a fixed glyph set: the alphabet is the reader's
	// terminal, not the emphasis, and the track table now draws ramp glyphs.
	render := func(styled bool) string {
		var out, errb bytes.Buffer
		app := &App{Stdout: &out, Stderr: &errb, IsTTY: func() bool { return false }}
		app.Style = ui.Style{Color: styled, Unicode: true}
		app.ErrStyle = app.Style
		printDecoderTable(app, list)
		printRecordTable(app, page)
		out.WriteString(renderTrack(app, table, trackDefaultWindow))
		s := &session{app: app}
		for _, rec := range page.Records {
			if err := printRecord(s, rec); err != nil {
				t.Fatal(err)
			}
		}
		return out.String() + errb.String()
	}
	plain, styled := render(false), render(true)
	if ui.Strip(styled) != plain {
		t.Errorf("the styled screens differ from the plain ones:\n--- plain\n%s\n--- stripped\n%s", plain, ui.Strip(styled))
	}
	if !strings.Contains(plain, "LEYTST-1") || !strings.Contains(plain, "aprs") {
		t.Errorf("the screens rendered nothing to compare:\n%s", plain)
	}
}
